# OneOS Pixel Fold (felix) Port Audit — Samsung-Host Assumptions

Audit of the OneOS port from Samsung Galaxy hosts (Z Fold8 / S-series One UI) to the Google Pixel Fold (felix, Tensor G2, stock Pixel Android 17 / AOSP framework, KernelSU, AIDL composer3, no Samsung vendor HALs). Every file below was read in full; findings quote the code. No files were modified.

> Written before the port's changes: the A findings and the B items the port
> fixed were then implemented (see `docs/pixel-fold-host.md`, "What was
> audited, what was fixed"). The B items recorded there as acceptable
> degradation remain as this audit describes them.

**Classification:** (A) breaks hard — fails, aborts, or takes a wrong destructive path on a Pixel host; (B) breaks soft — guarded/fallback path degrades; (C) cosmetic — Samsung/One UI references that work fine.

---

## A — BREAKS HARD

### A1. Camera binder tables are One UI's — every guest camera call is misnumbered on a Pixel host

- **Files:** `switcher/patches/host_camera.txt` (whole file, header + line 34), `switcher/patches/pixel_camera_abi.py`, `switcher/patches/pixel_camera_native.py`, applied by `scripts/make-overlays.sh:759-760` and emitted at `make-overlays.sh:829-844`.
- **What the code does:** the table is Samsung-specific:
  > `# One UI 9 (Z Fold8 Ultra, CP2A.260605.016) camera binder tables: scripts/aidl-table.py on /system/framework/framework.jar, 2026-10-27.`
  > `# <interface> <method> <code> <signature>; switcher/patches/pixel_camera_abi.py renumbers a Pixel guest's calls to these.`

  It contains Samsung-only methods, e.g. line 34:
  > `android.hardware.ICameraService setRequestInjectorCallback 32 (Lcom/samsung/android/camera/IRequestInjectorCallback;)Z`

  `make-overlays.sh:759-760`: "A Pixel (AOSP) or ColorOS guest's camera calls with One UI's transaction codes (patches/pixel_camera_abi.py and pixel_camera_native.py...)". The patchers rewrite the guest image's `ICameraService`/`ICameraDeviceUser` transaction codes to these Samsung codes (e.g. guest `createDefaultRequest` 23 is renumbered to Samsung's 24) and `pixel_camera_native.py` also removes a sixth field from `CameraCompatibilityInfo` that "One UI's framework doesn't read".
- **Why it breaks on felix:** the host cameraserver is Pixel's AOSP framework, not One UI. A Pixel-image guest's native codes already match the Pixel host; renumbering sends every call to the wrong host method (guest `createDefaultRequest` lands on the host's `isSessionConfigurationWithParametersSupported`), and the nop'd sixth `CameraCompatibilityInfo` field is one the AOSP host *does* read. Result: broken cameras at best, parcel-decode exceptions and cameraserver crash loops at worst.
- **Minimal fix:** the mechanism is table-driven — regenerate `host_camera.txt` from the Pixel host's `framework.jar` with `scripts/aidl-table.py` and rebuild the set; or simpler for a Pixel-image guest on a Pixel host, skip `pixel_camera_abi.py`/`pixel_camera_native.py` entirely (guest and host already agree) and keep the patches only for ColorOS guests (which still need a Pixel-host table).

### A2. Installd transaction table is One UI's — guest install calls carry Samsung codes to Pixel's installd

- **Files:** `switcher/patches/host_installd.txt` (whole file), `switcher/patches/guest_installd_abi.py`, applied by `scripts/make-overlays.sh:207-209`:
  > `# Send installd calls with One UI's transaction codes, block the rest`
  > `KEY_DIRS="$KEY_DIRS $(python3 -I "$ROOT/switcher/patches/guest_installd_abi.py" "$WORK/services" "$ROOT/switcher/patches/host_installd.txt")"`
- **What the code does:** `host_installd.txt` is the Samsung F976B One UI 17 table (it includes Samsung-only methods 57-83: Knox, LFO, Heimdall). The patched guest `IInstalld` proxy sends these codes to the **host's** installd binder; only create/query/relabel/compile are allowed, everything else throws RemoteException (fails closed), and the build-time signature check compares the guest's method signature against the table.
- **Why it breaks on felix:** Pixel's installd is stock AOSP. The low-numbered AOSP codes are *probably* identical (Samsung appends methods), but that is unverified — if any allowed method's code or signature differs on the Pixel build, guest package installs fail, or worse, a code lands on a different host installd method (AOSP installd includes destructive methods like `rmdex`, `rmPackageDir`, `clearAppData`) — a wrong destructive path against host data.
- **Minimal fix:** regenerate `host_installd.txt` from the Pixel host's `services.jar` with `scripts/host-installd-table.sh` and rebuild the set. The patcher already fails closed on signature mismatch; extend that check to verify the live host installd stub's descriptor before first use so drift is detected at runtime instead of misfiring.

### A3. NetworkStack shared-uid signature mismatch — guest system_server abort for OPPO-signed guests

- **File:** `switcher/assets/guest_prepare.sh:4068-4080`
- **What the code does:**
  > `# host's NetworkStackGoogle and CaptivePortalLoginGoogle in place of ColorOS's`
  > `# OPPO-signed NetworkStack and CaptivePortalLogin, and hide ColorOS's own`
  > `# CellBroadcastService.`
  > `bind_host_app /system/priv-app/NetworkStackGoogle "$ROOTFS/system/priv-app/NetworkStack"`
  > `bind_host_app /system/app/CaptivePortalLoginGoogle "$ROOTFS/system/app/CaptivePortalLogin"`

  `bind_host_app` (L4072-4074) is guarded: `[ -d "$1" ] && [ -d "$2" ] || { echo "!!! cannot replace $2 with $1"; return 0; }`. The comment block documents why the bind exists: keeping `android.uid.networkstack` single-signer — the host's Google-signed networkstack APEX plus the guest's OPPO-signed NetworkStack app produces "Signature mismatch ... android.uid.networkstack" and system_server death.
- **Why it breaks on felix:** a Pixel host has no `/system/priv-app/NetworkStackGoogle` (Pixel's NetworkStack ships as an APEX), so both binds are skipped with "!!! cannot replace". Meanwhile the host `/apex` bind loop (guest_prepare.sh:3986, which only skips `*samsung*` APEX names) binds the Pixel host's Google-signed networkstack APEX into the guest — so the guest ends up with the host's Google-signed networkstack APEX *and* its own OPPO-signed `/system/priv-app/NetworkStack`, i.e. exactly the shared-uid signature mismatch the bind was written to prevent. ColorOS/Infinity-X guests' system_server aborts during boot.
- **Minimal fix:** when the host app dirs are absent, hide the guest's `NetworkStack` and `CaptivePortalLogin` app dirs with read-only tmpfs exactly as done for `CellBroadcastService` at L4077-4080 (`mount -t tmpfs -o ro,size=4k,mode=755 tmpfs <dir>`), so only the host APEX serves the uid; or bind the Pixel host's own networkstack app path.

### A4. Fold layout: host layout file hidden, then Samsung-only port names fail to find the panels

- **File:** `switcher/assets/guest_start.sh:154-178` (hide) and `367-384` (ports), `483` (give-up)
- **What the code does:** L154-178 hides the host's `/vendor/etc/displayconfig/display_layout_configuration.xml` (`LAYOUT_HIDDEN=1`; the comment says Samsung's file NPEs ColorOS's `DeviceStateToLayoutMapExtImpl`; escape hatch `ONEOS_KEEP_FOLD_LAYOUT=1` at L170). Then L367-384 derives the fold ports:
  > `# OneOS: the ports come from the host's touch-to-display associations`
  > `# (sec_touchscreen = inner, sec_touchscreen2 = cover), 147/148 when the file`
  > `# does not say, so another foldable does not get the Fold's.`
  > `IN_PORT=$(sed -n 's/.*<port display="\([0-9][0-9]*\)" input="sec_touchscreen".*/\1/p' "$f" | head -1)`
  > `CV_PORT=$(sed -n 's/.*<port display="\([0-9][0-9]*\)" input="sec_touchscreen2".*/\1/p' "$f" | head -1)`
  > `[ -n "$IN_PORT" ] && [ -n "$CV_PORT" ] && [ "$IN_PORT" != "$CV_PORT" ] || { IN_PORT=147; CV_PORT=148; }`

  followed by 25 x 0.2 s polls of `dumpsys SurfaceFlinger --display-id` matching `port=$IN_PORT`/`port=$CV_PORT`.
- **Why it breaks on felix:** Pixel Fold's `input-port-associations.xml` does not use Samsung's `sec_touchscreen`/`sec_touchscreen2` input names, so the defaults 147/148 (the Samsung Fold's ports) are used; the Pixel Fold's display ports differ, `INNER`/`COVER` never match, and the script gives up ("WARNING: no fold layout... inner display only") — after having hidden the host's (Google's) layout file, so the guest is left with **no** layout file at all. The dual-display fold experience degrades to single-display.
- **Minimal fix:** when the `sec_touchscreen` names are absent, derive the two ports from the two `INTERNAL` displays in `dumpsys display` (or parse Pixel's own association file with its input names) instead of defaulting to 147/148; or default `ONEOS_KEEP_FOLD_LAYOUT=1` on non-Samsung hosts so the host's own layout file survives.

---

## B — BREAKS SOFT

### B1. A2DP keeper sends a hand-built vendor parcel to transaction 34 of the host audio HAL

- **File:** `switcher/assets/guest_start.sh:848-876`
- **What it does:** every 10 s (and on each HAL restart) it calls
  > `service call android.hardware.audio.core.IModule/default 34 i32 1 i32 1 i32 $ps s16 l_a2dp_format ... s16 qti.audio.core.VString ...`
  to push `l_a2dp_format` into the audio HAL, checking for confirmation via logcat tag `AHAL_SecModulePrimary` (Samsung-only): "HAL NEVER logged it (no AHAL_SecModulePrimary line ...)".
- **On felix:** transaction 34 is `setVendorParameters` in the *guest image's* audio.core-V4; the Pixel host HAL may be a different AIDL version where transaction 34 is a different method — a misdirected, hand-marshalled parcel into the host's audio HAL (it does no harm in the tested Samsung case, but on Pixel it is an unverified call path repeated forever, 3 tries per HAL pid). Confirmation can never succeed because the log tag is Samsung's.
- **Minimal fix:** gate the keeper the way the `g_call_sim_slot` keeper (guest_start.sh:976-1112) already does — grep the host's `/vendor/lib64/*audio*.so` for `l_a2dp_format` and exit "A2DP loop off" when absent; also verify the host HAL's AIDL version before choosing transaction 34.

### B2. Backlight keeper node is right, but the constant is Samsung-panel-calibrated

- **File:** `switcher/assets/guest_start.sh:584-606`
- **What it does:**
  > `BL=/sys/class/backlight/panel0-backlight; BL2=/sys/class/backlight/panel1-backlight`
  > `[ -d "$BL" ] || { BL=/sys/class/backlight/panel; BL2=/sys/class/backlight/panel1; }`
  > `# 928: about 135 nits on this panel (max/4 was ~660 nits).`
  > `echo 928 > $BL/brightness`
- **On felix:** the node path is correct (Pixel Fold exposes `panel0-backlight`/`panel1-backlight`), but 928 was calibrated against the Samsung panel's scale; the Pixel panel's `max_brightness` differs, so the boot-time floor lands at a different brightness.
- **Minimal fix:** compute the floor from `$BL/max_brightness` (e.g. `max/4`) instead of the hardcoded 928.

### B3. Panel brightness scale (`panel_scale_milli`) is Samsung-composer math

- **File:** `switcher/assets/guest_props.sh:370-374`
- **What it does:**
  > `bm=$(grep 'DisplayDeviceInfo{' "$STAGE/display_modes_host.log" ... brightnessMaximum ... )`
  > `sc=$(awk -v m="$bm" 'BEGIN { if (m + 0 >= 1.5 && m + 0 <= 8) printf "%d", 5298.0394 / m + 0.5; else print 1000 }')`
  > `echo "ro.oneos.panel_scale_milli=$sc" >> "$NEW"`
- **On felix:** `5298.0394/bm` is the Samsung Z Fold8 Ultra composer float multiplier; Pixel's `brightnessMaximum` (~1.0) falls outside 1.5..8 so the prop becomes 1000 (pass-through) — safe but unverified brightness behavior; if a Pixel build ever reports a value in range, the scale would be wrong.
- **Minimal fix:** skip setting `ro.oneos.panel_scale_milli` (leave 1000) when the host is not One UI, or re-derive the constant from the Pixel host's composer.

### B4. ColorOS guest display configs: nits→float curve written "for Samsung's composer float"

- **File:** `switcher/assets/guest_prepare.sh:1093-1230` (ddc_xml), plus `scripts/make-overlays.sh:339-340` + `switcher/patches/samsung_backlight_curve.py` + `switcher/patches/OneOSPanelBacklight.smali`
- **What they do:** guest_prepare writes nits→float brightness curves into the guest's `product/etc/displayconfig` for non-ColorOS images ("for Samsung's composer float"), taking panel ports from `port=` lines in `display_modes_host.log`; the patcher hardcodes "Samsung's composer maps this float linearly onto panel0-backlight 0..13510" with a static One UI nits table (`OneOSPanelBacklight.smali`), and make-overlays builds a "One UI's brightness range" overlay (`make-overlays.sh:1187-1200`).
- **On felix:** the `port=` parsing may not match the Tensor composer's `--display-id` output → "no panel ports... none written" (L1211); where curves are written they are calibrated to Samsung's float→backlight mapping, so brightness on the Pixel composer is off.
- **Minimal fix:** parse the Pixel host's display-id format (or take the two INTERNAL displays) and regenerate the nits table from the Pixel host's `dumpsys display` output; or skip `samsung_backlight_curve.py`/the brightness-range overlay on a Pixel host and let the guest's own mapping stand.

### B5. IMS gate waits on Samsung's `imsd`

- **Files:** `switcher/assets/oneos_switch.sh:726-739` (gate), `818-837` (ims_watchdog.sh keepalive)
- **What it does:** the IMS gate runs `pidof imsd` / `setprop ctl.start imsd` and waits up to 90 s for `mVoiceRegState=0`; the watchdog restarts `imsd` forever.
- **On felix:** there is no `imsd` service on a Pixel host (IMS lives in the AOSP framework/modem and dies with system_server). `ctl.start imsd` is a no-op; the gate's voice-registration wait adds up to 90 s of delay for nothing, and the keepalive restarts a nonexistent service.
- **Minimal fix:** gate on service existence — if `getprop init.svc.imsd` is empty (service undefined in the host's init rc), skip the imsd start/keepalive entirely and rely on the framework IMS path.

### B6. Samsung IMS and Samsung Camera staging turn off — features unavailable

- **File:** `switcher/assets/guest_prepare.sh:420-571` (IMS: copies host `/system/priv-app/imsservice` etc. when `ONEOS_GUEST_SEC_IMS=1` default), `572-834` (Camera: needs `samcam.tar` + host `/system/cameradata`, L724)
- **On felix:** the host paths don't exist, so both stage off gracefully ("this One UI lacks..." / "Samsung Camera: off"). The port loses these features; the related guest-side patches (`guest_secims_*`, applied unconditionally by `make-overlays.sh:238-244`) are inert without staged packages. The Pixel guest camera path is covered by A1 instead.
- **Minimal fix:** none required (guards are correct); document the features as host-specific.

### B7. Audio HAL service-name regex misses Pixel's AIDL audio HAL

- **File:** `switcher/assets/oneos_switch.sh:1320`
- **What it does:** `getprop | sed -n 's/...vendor\.audio-hal[^]]*.../p'` collects host audio HAL service names (used by return_to_oneui to restart them).
- **On felix:** Pixel's audio HAL is AIDL `android.hardware.audio.core...`, which the `vendor.audio-hal` regex doesn't match → `host_audio_hal_svcs` is empty → the HAL is not explicitly restarted when returning to the host (audioserver restart covers some of it).
- **Minimal fix:** extend the regex to also match `android.hardware.audio.core`/`audio.*hal` AIDL service names.

### B8. SEH Bluetooth audio bridge is VINTF-gated off

- **File:** `switcher/assets/oneos_switch.sh:1390-1433`
- **What it does:** binds the Samsung SEH Bluetooth audio bridge only if the vendor manifest declares `vendor.samsung.hardware.bluetooth.audio`.
- **On felix:** absent → bridge skipped gracefully; Pixel declares the standard `IBluetoothAudioProviderFactory` itself, so audio routing works through the standard path. Degradation is limited to whatever the SEH bridge added on Samsung hosts.
- **Minimal fix:** none needed (the gate is the correct behavior).

### B9. Touch-IC / panel keeper / hinge-sensor functions are Samsung-sysfs-gated no-ops

- **Files:** `switcher/assets/oneos_switch.sh:2516-2543` (touch IC: `/sys/class/sec/tsp*`, `sec_touchscreen2`, flip input), `2888-2921` (panel keeper: `if [ -r /sys/class/lcd/panel/vrr ]` — absent on Pixel → keeper entirely off, so a low-refresh-stuck panel is unmitigated), `switcher/assets/guest_prepare.sh:2733-2777` (`fold8-hinge` option references `com.samsung.sensor.folding_angle` — absent on Pixel, `HALF_OPENED` never matches; lid-switch states 0/3 still work).
- **Minimal fixes:** none strictly required (all guarded); optionally add Pixel's panel sysfs (e.g. Tensor's panel vrr node under the panel device) to the keeper's condition, and map `fold8-hinge` to the Pixel's `android.hardware.devicestate` sensor.

### B10. HyperOS modem provider prop not set on a non-QTI-`ro.soc.manufacturer` host

- **File:** `switcher/assets/guest_props.sh:498-507`
- **What it does:** sets `ro.vendor.radio.modem.provider=qcom` only when `ro.soc.manufacturer=QTI`.
- **On felix:** `ro.soc.manufacturer` is Google → prop left unset → the Xiaomi 18 Fold guest's XRING radio extension stays unregistered → no mobile data (same outcome as the tested Exynos S26+ path). Note the Pixel Fold's modem is not Qualcomm either, so simply forcing the prop would not be right.
- **Minimal fix:** none clean at the prop level; port the guest radio-provider expectation to the Pixel host's modem (or set the prop to whatever provider string the guest's radio expects for a Samsung-baseband host, if HyperOS supports one).

### B11. `skip_host_apex_services.py` only skips `com.samsung.*` APEX services

- **File:** `switcher/patches/skip_host_apex_services.py` (applied by `scripts/make-overlays.sh:200-201`)
- **What it does:** the guest's system_server reads the host's apex-info-list (copied in guest_prepare.sh); any host APEX declaring an `apex-system-service` whose jar is not on the guest's classpath aborts the guest ("Creating a ClassLoader from /apex/... is not allowed"). The patcher only skips services whose jar lives under `/apex/com.samsung.`.
- **On felix:** no Samsung APEXes exist, so nothing is skipped. If any Google-signed Pixel APEX declares an `apex-system-service`, the guest's system_server would abort — this could not be verified from the repo alone (it depends on the host's apex list), hence B rather than A.
- **Minimal fix:** generalize the skip to any host APEX service whose jar is not among the modules the guest itself mounted, instead of the `com.samsung.` prefix.

### B12. Misc degradations

- `switcher/assets/guest_prepare.sh:1750-1761` — UniRender forced off when `ro.soc.manufacturer != QTI` → off on Pixel (Tensor): safe, possible performance cost.
- `switcher/assets/oneos_switch.sh:560-565` — `DisplayRenderIntent` (Samsung vendor intent) absent on Pixel → guest keeps its own render intent.
- `switcher/assets/oneos_switch.sh:417-459` — camera-hole rect parsed from host dumpsys (generic parsing); Pixel Fold's inner panel has no top cutout → `host_screenhole` absent → guest cutout overlays skipped (guarded at oneos_switch.sh:2381).
- `switcher/assets/guest_props.sh:822-840` — `ro.boot.hardware=qcom` override when the guest ships `libqti_performance.so` and the host hw isn't `qcom*` → applies on Pixel (same as tested Exynos path).
- `scripts/make-overlays.sh:981-1037` — `pixel_statusbar` overlay compensates Samsung vendor inset gaps ("the battery sat 47-60 px further from the right" on Samsung's vendor partition); on Pixel it is unnecessary and may mis-space the status bar (build-time; needs re-derivation from the Pixel host).
- `scripts/make-overlays.sh:1221+` — `fold_display_cutout` overlay is Z Fold-specific ("the ids and the hole are that phone's", installed on F8U only) — not applied on felix, no action.

---

## C — COSMETIC

- `switcher/assets/oneos_switch.sh:818-837` — `ims_watchdog.sh` keepalive restarts `imsd` forever: no-op on Pixel, log noise only (see B5).
- `switcher/assets/oneos_switch.sh:1158` — softdog greps `/system/etc/init/init.sysfw.rc` (Samsung-only file, absent → block skipped); `1121` unconditional `printf V > /dev/watchdog` is host-generic watchdog stroking.
- `switcher/assets/oneos_switch.sh:947-951` — OPPO `log.tag` silencing; harmless on Pixel.
- `switcher/assets/oneos_switch.sh:381-384, 3040` — `/sys/class/lcd/panel` vrr reads are guarded diagnostics.
- `switcher/assets/oneos_switch.sh:1023` — `cpufreq_limit` read with `|| echo none`.
- `switcher/assets/guest_props.sh:210-234` — `persist.sys.usb.config` `sec_charging` override only triggers on `sec_*` values; no-op on Pixel.
- `switcher/assets/guest_props.sh:714-746` — Nothing About-phone `ro.soc.model` case list (SM8850/SM8750/...) doesn't include GS201 → `cpu=""` → `ro.product.cpu_info` skipped (cosmetic, guest-side).
- `switcher/assets/guest_props.sh:777-796` — `ro.audio.ihaladaptervendorextension_enabled` skipped unless the host defines it.
- `switcher/assets/guest_prepare.sh:3986` — `case "$base" in *samsung*) continue ;;` skips Samsung APEXes in the host bind loop; none exist on Pixel, harmless.
- `switcher/assets/guest_prepare.sh:4378-4397` — PermissionController patched-APK bind keeps Samsung's RANGING-capable build; the warning text is moot on Pixel but the bind itself is generic.
- `switcher/assets/return_to_oneui.sh:946` — `com.sec.android.app.launcher` fallback in the get-started-user-state probe.
- `switcher/assets/guest_google.sh` (throughout) — "One UI's copy" wording; the snapshot/prepare mechanism itself is host-generic and works on Pixel (the `/apex/com.google.android.gmssystem/priv-app/*` APK path is allowed at L63).
- `switcher/assets/boot_status.sh:7` — "One OS / One UI not up yet" wording.
- Log wording "One UI" / "Samsung" throughout oneos_switch.sh, guest_prepare.sh, guest_start.sh — messages only.

---

## Confirmed host-generic (verified, no action needed)

- **Framework stop/restart:** `oneos_switch.sh:1060-1115` (ctl.stop zygote/surfaceflinger, kill app_process64/zygote64/system_server), `1296-1308` (media stops); `return_to_oneui.sh:833-916` (audioserver, camera providers, cameraserver/media/wificond/gnss_service/perfmond/update_engine, netd, zygote/zygote_secondary/zygote_next) — all guarded by `init.svc.*` props or generic `getprop` greps. The reboot path (`return_to_oneui.sh:456-481`) is the default and fully generic.
- **Composer detection:** all three scripts (`guest_start.sh:209-231`, `boot_status.sh:35-41`, `return_to_oneui.sh:791-796`) try `vendor.qti.hardware.display.composer` / `vendor.hwcomposer-3`, then fall back to a generic grep of running init services for `hwcomposer|display.composer|graphics.composer` — this matches Pixel's AIDL composer3 service; the wait on `android.hardware.graphics.composer3.IComposer/default` (`guest_start.sh:231`, `return_to_oneui.sh:814-824`) succeeds on felix (Pixel declares composer3 in its vendor VINTF).
- **HWSM check:** `guest_prepare.sh:398-419` greps the vendor VINTF for `android.hardware.graphics.composer3` + `android.hardware.audio.core` — Pixel declares both → HWSM=0.
- **VNDK:** `guest_prepare.sh:941-959` derives `VNDK_NEED` from the compatibility matrix — generic.
- **Device states:** the guest uses the host's own `/vendor/etc/devicestate/device_state_configuration.xml` (Pixel has one); diag copies at `oneos_switch.sh:1180-1188` are generic path loops.
- **wificond:** `oneos_switch.sh:1442-1457` is already Pixel-17-aware.
- **Cover-display detection:** `oneos_switch.sh:536-553` via `dumpsys display` — generic (Pixel Fold reports two INTERNAL displays).
- **Bridges and APEX plumbing:** `bridges.sh`, `check_host_apex.sh`, guest APEX payload mounting (guest_prepare.sh:3830-3931), KernelSU helper (5d), host-part-mount leak check (L4660-4668) — host-generic.
- **Google apps:** `guest_google.sh` snapshot/prepare works against any host whose Play services live in a normal app path or the gmssystem APEX (both allowed).
- **Perf governor:** `fold8_coloros.sh` probes cpufreq/gpu sysfs nodes with `-r`/`-w` guards and generic fallbacks (kgsl or `/sys/kernel/gpu`); on felix the probes simply report unsupported and the keeper disables itself.
- **Deploy/diag scripts:** `deploy-phone.sh`, `pull-run-logs.sh`, `apply-verified-overlays.sh` — no Samsung host assumptions beyond wording.

---

## Priority fix order

1. **A3** (guest boot failure for OPPO-signed guests) — one tmpfs-hide patch in guest_prepare.sh.
2. **A1/A2** (camera and installd tables) — regenerate `host_camera.txt`/`host_installd.txt` from the Pixel host with the existing `scripts/aidl-table.py`/`scripts/host-installd-table.sh`, rebuild sets.
3. **A4 + B4** (fold layout + display configs) — port detection to Pixel's display-id/port format.
4. **B1-B3, B5, B7** — small gating/calibration fixes; the rest of B items are correct-by-guard degradation to document.
