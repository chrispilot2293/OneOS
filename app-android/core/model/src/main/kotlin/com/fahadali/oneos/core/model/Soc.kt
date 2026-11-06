package com.fahadali.oneos.core.model

import java.util.Locale

enum class SocVendor(val label: String) {
    QUALCOMM("Qualcomm Snapdragon"),
    EXYNOS("Samsung Exynos"),
    MEDIATEK("MediaTek"),
    GOOGLE("Google Tensor"),
    UNKNOWN("Unknown"),
}

/** The props the SoC rule reads (all may be empty). */
data class SocProps(
    /** `ro.soc.manufacturer` (or Build.SOC_MANUFACTURER): `QTI`, `Samsung`, ... */
    val manufacturer: String = "",
    /** `ro.soc.model` (or Build.SOC_MODEL): `SM8850`, `s5e9945`, ... */
    val model: String = "",
    /** `ro.board.platform`: `canoe`, `sun`, `s5e9945`, ... */
    val platform: String = "",
    /** `ro.hardware`: `qcom` on Snapdragon. */
    val hardware: String = "",
    /** `ro.hardware.chipname`: set on Exynos builds. */
    val chipname: String = "",
    /** `ro.hardware.egl`: `adreno` on Snapdragon. */
    val egl: String = "",
)

data class SocInfo(
    val vendor: SocVendor,
    /** SoC model (`SM8850`), or the platform-derived one when the prop is empty. */
    val model: String,
    val platform: String,
    /** Marketing name when known (`Snapdragon 8 Elite Gen 5`). */
    val marketingName: String?,
) {
    /** e.g. "Snapdragon 8 Elite Gen 5 (SM8850, canoe)". */
    val display: String
        get() {
            val ids = listOf(model, platform).filter { it.isNotBlank() }.distinct()
            val head = marketingName ?: vendor.label
            return if (ids.isEmpty()) head else "$head (${ids.joinToString(", ")})"
        }
}

/**
 * SoC (docs/app/compat-safety-logs.md section 1.3): `ro.soc.manufacturer`
 * QTI or a Qualcomm platform name = Snapdragon; Samsung LSI (`s5e*`/`erd*`)
 * = Exynos. Only the Snapdragon display path is known in this build.
 */
object SocRules {
    private val QUALCOMM_PLATFORMS = setOf(
        "msmnile", "kona", "lahaina", "taro", "kalama", "pineapple", "sun", "canoe",
    )
    private val QUALCOMM_PREFIXES = listOf("msm", "sdm", "sm8", "sm7", "sm6", "qcom")
    private val EXYNOS_PREFIXES = listOf("s5e", "exynos", "erd", "universal")
    private val MEDIATEK_RE = Regex("^mt\\d")

    /** Google's Tensor SoCs name themselves `ro.soc.manufacturer=Google`, `ro.soc.model=GS201` (the Pixel Fold), platform `gs201`. */
    private val TENSOR_RE = Regex("^gs\\d+$")

    /** Platform codename -> SoC model, for builds that leave `ro.soc.model` empty. */
    private val PLATFORM_MODEL = mapOf(
        "taro" to "SM8450",
        "kalama" to "SM8550",
        "pineapple" to "SM8650",
        "sun" to "SM8750",
        "canoe" to "SM8850",
    )

    private val MARKETING = mapOf(
        "SM8450" to "Snapdragon 8 Gen 1",
        "SM8475" to "Snapdragon 8+ Gen 1",
        "SM8550" to "Snapdragon 8 Gen 2",
        "SM8650" to "Snapdragon 8 Gen 3",
        "SM8750" to "Snapdragon 8 Elite",
        "SM8850" to "Snapdragon 8 Elite Gen 5",
        "S5E9925" to "Exynos 2200",
        "S5E9945" to "Exynos 2400",
        "S5E9955" to "Exynos 2500",
        "GS101" to "Tensor",
        "GS201" to "Tensor G2",
        "GS301" to "Tensor G3",
        "ZUMA" to "Tensor G3",
        "ZUMAPRO" to "Tensor G4",
    )

    fun resolve(p: SocProps): SocInfo {
        val maker = p.manufacturer.trim().lowercase(Locale.ROOT)
        val names = listOf(p.platform, p.hardware, p.chipname, p.model)
            .map { it.trim().lowercase(Locale.ROOT) }
            .filter { it.isNotEmpty() }

        val vendor = when {
            maker.contains("qti") || maker.contains("qualcomm") -> SocVendor.QUALCOMM
            maker.contains("samsung") || maker.contains("slsi") -> SocVendor.EXYNOS
            maker.contains("mediatek") || maker == "mtk" -> SocVendor.MEDIATEK
            maker.contains("google") && (names.any { TENSOR_RE.matches(it) } || p.model.trim().uppercase(Locale.ROOT).startsWith("GS")) -> SocVendor.GOOGLE
            names.any { TENSOR_RE.matches(it) } -> SocVendor.GOOGLE
            names.any { n -> EXYNOS_PREFIXES.any { n.startsWith(it) } } -> SocVendor.EXYNOS
            names.any { n -> n in QUALCOMM_PLATFORMS || QUALCOMM_PREFIXES.any { n.startsWith(it) } } ->
                SocVendor.QUALCOMM
            names.any { MEDIATEK_RE.containsMatchIn(it) } -> SocVendor.MEDIATEK
            p.egl.trim().equals("adreno", ignoreCase = true) -> SocVendor.QUALCOMM
            else -> SocVendor.UNKNOWN
        }

        val platform = p.platform.trim()
        val model = p.model.trim().ifEmpty {
            PLATFORM_MODEL[platform.lowercase(Locale.ROOT)].orEmpty()
        }
        val marketing = MARKETING[model.uppercase(Locale.ROOT)]
            ?: MARKETING[p.chipname.trim().uppercase(Locale.ROOT)]
            ?: MARKETING[platform.uppercase(Locale.ROOT)]
        return SocInfo(vendor, model, platform, marketing)
    }
}
