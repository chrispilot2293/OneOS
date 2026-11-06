package com.fahadali.oneos.core.model

/** One method of One UI's `android.os.IInstalld`: name, transaction code, proxy signature. */
data class InstalldMethod(val name: String, val code: Int, val signature: String)

/**
 * What the app derived from the captured dex files (`:core:safety`
 * `HostInstalldTable`). [error] null = derived; the server derives it again
 * from the same files before anything is shipped.
 */
data class InstalldDerivation(
    val methods: List<InstalldMethod>,
    /** Jar One UI loads the class from (first in class-loader order), e.g. `/system/framework/services.jar`. */
    val sourceJar: String?,
    /** Dex entry inside [sourceJar], e.g. `classes.dex`. */
    val sourceEntry: String?,
    /** SHA-256 of [sourceJar] as read on the phone (installd/jars.txt). */
    val sourceSha256: String?,
    /** Capture files the derivation read. */
    val inputs: List<String>,
    val error: String?,
    val notes: List<String> = emptyList(),
) {
    val ok: Boolean get() = error == null && methods.isNotEmpty()

    fun has(name: String): Boolean = methods.any { it.name == name }

    companion object {
        fun failed(error: String, inputs: List<String> = emptyList()) =
            InstalldDerivation(emptyList(), null, null, null, inputs, error)
    }
}

/**
 * The runtime host installd table, format `oneos.installd-table 1`
 * (docs/app/DESIGN.md section 6.2), and the older `host_installd.txt` layout
 * (`name code signature`, what `guest_installd_abi.py` reads today).
 */
object InstalldTableFormat {
    const val MAGIC = "oneos.installd-table 1"
    const val MAX_BYTES = 64 * 1024
    const val MAX_METHODS = 512
    const val FIRST_CALL = 1
    const val LAST_CALL = 16_777_215

    private val NAME = Regex("^[A-Za-z_][A-Za-z0-9_]*$")
    private val SIG = Regex("""^\([^\s()]*\)\S+$""")
    private val SHA = Regex("^[0-9a-f]{64}$")

    /** Problems with these methods; empty = they can be written. */
    fun check(methods: List<InstalldMethod>): List<String> {
        val p = mutableListOf<String>()
        if (methods.isEmpty() || methods.size > MAX_METHODS) p += "methods ${methods.size} not in 1..$MAX_METHODS"
        for (m in methods) {
            if (!NAME.matches(m.name)) p += "bad name '${m.name}'"
            if (m.code < FIRST_CALL || m.code > LAST_CALL) p += "${m.name}: code ${m.code} out of range"
            if (!SIG.matches(m.signature)) p += "${m.name}: bad signature '${m.signature}'"
        }
        methods.groupBy { it.name }.filterValues { it.size > 1 }.keys.forEach { p += "duplicate name $it" }
        methods.groupBy { it.code }.filterValues { it.size > 1 }.keys.forEach { p += "duplicate code $it" }
        return p
    }

    /** Format 1 text, methods sorted by code, ending with the SHA-256 trailer. */
    fun write(fingerprint: String, sourcePath: String, sourceSha256: String, methods: List<InstalldMethod>): String {
        val problems = check(methods).toMutableList()
        if (fingerprint.isEmpty() || fingerprint.any { it.isWhitespace() }) problems += "bad fingerprint"
        if (sourcePath.isEmpty() || sourcePath.any { it.isWhitespace() }) problems += "bad source path"
        if (!SHA.matches(sourceSha256)) problems += "bad source sha256"
        require(problems.isEmpty()) { problems.joinToString("; ") }
        val body = buildString {
            append(MAGIC).append('\n')
            append("fingerprint ").append(fingerprint).append('\n')
            append("source ").append(sourcePath).append(' ').append(sourceSha256).append('\n')
            append("methods ").append(methods.size).append('\n')
            for (m in methods.sortedBy { it.code }) append(m.name).append(' ').append(m.code).append(' ').append(m.signature).append('\n')
        }
        val text = body + "sha256 " + Hashes.sha256(body) + "\n"
        require(text.length <= MAX_BYTES) { "table over $MAX_BYTES bytes" }
        return text
    }

    /** Checks every rule of section 6.2; empty = valid. */
    fun validate(text: String, expectFingerprint: String? = null): List<String> {
        val p = mutableListOf<String>()
        if (text.length > MAX_BYTES) p += "over $MAX_BYTES bytes"
        if (!text.endsWith("\n") || text.endsWith("\n\n")) p += "must end with exactly one newline"
        val lines = text.removeSuffix("\n").split('\n')
        if (lines.firstOrNull() != MAGIC) return p + "line 1 is not '$MAGIC'"
        val fp = lines.getOrNull(1)?.takeIf { it.startsWith("fingerprint ") }?.removePrefix("fingerprint ")
        if (fp == null || fp.isEmpty() || fp.contains(' ')) p += "bad fingerprint line"
        if (expectFingerprint != null && fp != expectFingerprint) p += "fingerprint is not this phone's"
        val src = lines.getOrNull(2)?.split(' ')
        if (src == null || src.size != 3 || src[0] != "source" || !SHA.matches(src[2])) p += "bad source line"
        val n = lines.getOrNull(3)?.takeIf { it.startsWith("methods ") }?.removePrefix("methods ")?.toIntOrNull()
        if (n == null || n < 1 || n > MAX_METHODS) return p + "bad methods line"
        if (lines.size != 4 + n + 1) return p + "expected $n method lines and a sha256 line"
        val methods = mutableListOf<InstalldMethod>()
        for (k in 0 until n) {
            val parts = lines[4 + k].split(' ')
            val code = parts.getOrNull(1)?.toIntOrNull()
            if (parts.size != 3 || code == null) {
                p += "bad method line ${5 + k}"
                continue
            }
            methods += InstalldMethod(parts[0], code, parts[2])
        }
        p += check(methods)
        if (methods.map { it.code } != methods.map { it.code }.sorted()) p += "codes not ascending"
        val trailer = lines.last()
        val body = lines.dropLast(1).joinToString("\n") + "\n"
        if (trailer != "sha256 " + Hashes.sha256(body)) p += "sha256 trailer does not match"
        return p
    }

    /** The `host_installd.txt` layout of `scripts/host-installd-table.sh`. */
    fun legacy(methods: List<InstalldMethod>, fingerprint: String): String = buildString {
        append("# host IInstalld: name code signature (from the host's services.jar)\n")
        append("# One UI build: ").append(fingerprint).append('\n')
        for (m in methods.sortedBy { it.code }) append(m.name).append(' ').append(m.code).append(' ').append(m.signature).append('\n')
    }

    fun parseLegacy(text: String): List<InstalldMethod> = text.lineSequence()
        .map { it.trim() }
        .filter { it.isNotEmpty() && !it.startsWith("#") }
        .mapNotNull { line ->
            val p = line.split(' ')
            val code = p.getOrNull(1)?.toIntOrNull()
            if (p.size == 3 && code != null && p[2] != "-") InstalldMethod(p[0], code, p[2]) else null
        }
        .toList()
}

/**
 * The installd table the shipped jars carry (build 2 gate, XP7 / AA13). Until
 * the guest reads a runtime table, OneOSInstalldProxy has the codes of
 * switcher/patches/host_installd.txt baked in (make-overlays.sh), so the
 * phone's own table must be byte-equal to that file's method lines:
 * `name code signature\n`, sorted by code, the same lines as the method block
 * of a format-1 table. A One UI update that changes IInstalld then blocks
 * switching until a new app build exists.
 */
object InstalldExpected {
    /**
     * One pinned host table: the asset the app ships next to it, its SHA-256
     * and its method count. [ONE_UI_9] is every Samsung host; [PIXEL_17] is
     * the Pixel Fold (the felix port, 0.4.58-felix).
     */
    data class Pinned(val sha256: String, val methods: Int)

    /** SHA-256 of the non-comment lines of switcher/patches/host_installd.txt (F8U F976BXXS3AZIJ; same on S26U and S25U). */
    @Deprecated("Per-host tables; use pinnedFor(profile)", ReplaceWith("ONE_UI_9.sha256"))
    const val SHA256 = "791e52c441b62944f88244a2610b9433c869c9c3916a49f43d14552de82280f2"
    @Deprecated("Per-host tables; use pinnedFor(profile)", ReplaceWith("ONE_UI_9.methods"))
    const val METHODS = 85

    val ONE_UI_9 = Pinned(SHA256, 85)

    /**
     * The Pixel hosts' table (switcher/patches/host_installd_pixel17.txt):
     * AOSP Android 17's IInstalld as the Pixel builds it - 37 methods (One
     * UI's has 85, and only the first six codes agree), parcelable-style
     * createAppData/reconcileSdkData, and none of the dexopt family (Android
     * 17 moved it to ART Service). Derived from the CP3A.261005.002.A1 train's
     * own framework.jar.
     */
    val PIXEL_17 = Pinned("487d024a5aa681cb8f3ad237ba6589289e8d3df979cb517c1169f989eaea1f9a", 37)

    /** The table a phone's set was built against: Samsung hosts One UI 9's, the Pixel Fold AOSP 17's. */
    fun pinnedFor(profile: PhoneProfile?): Pinned = if (profile?.id == Profiles.ID_FELIX) PIXEL_17 else ONE_UI_9

    /** Method lines of a derived table, in the host_installd.txt layout. */
    fun methodLines(methods: List<InstalldMethod>): String =
        methods.sortedBy { it.code }.joinToString("") { "${it.name} ${it.code} ${it.signature}\n" }

    /** The lines of a host_installd.txt that do not start with `#`, as `grep -v '^#'` prints them. */
    fun nonCommentLines(hostInstalldTxt: String): String {
        val lines = hostInstalldTxt.removeSuffix("\n").split('\n').filterNot { it.startsWith("#") }
        return if (hostInstalldTxt.isEmpty()) "" else lines.joinToString("") { "$it\n" }
    }

    /** The method block of a valid format-1 table; null when [InstalldTableFormat.validate] refuses it. */
    fun methodsBlock(table: String, expectFingerprint: String? = null): String? {
        if (InstalldTableFormat.validate(table, expectFingerprint).isNotEmpty()) return null
        val lines = table.removeSuffix("\n").split('\n')
        return lines.subList(4, lines.size - 1).joinToString("") { "$it\n" }
    }

    /**
     * Problems with [derived] against the expected table; empty = byte-equal.
     * [expectedText] is the host_installd.txt the app ships (the one for
     * [pinned]'s host kind); it must itself hash to [pinned.sha256] (a wrong
     * asset fails closed). Null compares with the pinned hash only.
     */
    fun problems(derived: InstalldDerivation?, expectedText: String? = null, pinned: Pinned = ONE_UI_9): List<String> {
        if (derived == null) return listOf("installd table not derived on this phone")
        if (!derived.ok) return listOf("installd table not derived: ${derived.error ?: "no methods"}")
        val p = mutableListOf<String>()
        val expected = expectedText?.let(::nonCommentLines)
        if (expected != null && Hashes.sha256(expected) != pinned.sha256) p += "the app's host_installd.txt is not the pinned table"
        val got = methodLines(derived.methods)
        if (Hashes.sha256(got) != pinned.sha256) p += "this phone's installd table differs from the one the OneOS files carry"
        if (expected != null && got != expected) {
            val want = expected.removeSuffix("\n").split('\n').toSet()
            val have = got.removeSuffix("\n").split('\n').toSet()
            (have - want).take(5).forEach { p += "phone has: $it" }
            (want - have).take(5).forEach { p += "files expect: $it" }
        }
        return p.distinct()
    }
}

/**
 * `installd/jars.txt` from the probe: `<size> <sha256>  <path>` per candidate
 * jar (stat + sha256sum), then directory listings, which are ignored here.
 */
object JarsListing {
    data class Jar(val path: String, val bytes: Long, val sha256: String)

    private val LINE = Regex("""^(\d+) ([0-9a-f]{64})\s+(/\S+)$""")

    fun parse(text: String): List<Jar> = text.lineSequence()
        .mapNotNull { LINE.matchEntire(it.trim()) }
        .map { Jar(it.groupValues[3], it.groupValues[1].toLong(), it.groupValues[2]) }
        .distinctBy { it.path }
        .toList()
}

/** `installd/classpath.txt`: `BOOTCLASSPATH=a:b`, `SYSTEMSERVERCLASSPATH=c:d` lines. */
object ClassPath {
    /** Jars in class-loader order for system_server: boot class path, then system server class path. */
    fun order(text: String): List<String> {
        val vars = text.lineSequence().mapNotNull { l ->
            val eq = l.indexOf('=')
            if (eq <= 0) null else l.substring(0, eq).trim() to l.substring(eq + 1).trim()
        }.toMap()
        val jars = listOf("BOOTCLASSPATH", "SYSTEMSERVERCLASSPATH")
            .flatMap { vars[it].orEmpty().split(':') }
            .map { it.trim() }
            .filter { it.isNotEmpty() }
        return (jars + "/system/framework/services.jar").distinct()
    }
}
