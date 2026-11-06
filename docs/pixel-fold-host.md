# The Pixel Fold as a host (felix, 0.4.58-felix)

This fork of OneOS runs the same guest systems on a rooted Google Pixel Fold
(`google/felix`, Tensor G2 `GS201`, stock Android 17, SDK 37), switching into
them and back the way OneOS switches a rooted Galaxy into ColorOS or Infinity-X
and back, without flashing. The Pixel's own system takes One UI's place: it
stays untouched on the other slot, and every guest runs on the Pixel's kernel
and vendor services.

## Why the Pixel Fold

- The same Android as the guests: stock Android 17 (SDK 37, build
  `CP3A.261005.002.A1`), so a guest's framework matches the host's vendor the
  way a One UI 9 host's does.
- An ARMv8.2 CPU without SVE (Tensor G2, `GS201`). Every image OneOS can offer
  on felix was proven on a no-SVE ARMv8.2 host already (the Fold8's SM8850).
- A fold: two panels, a hinge, the fold layout (`guest_start.sh`, 0.4.57) works
  on it the same way it works on a Galaxy Z Fold.

## What the port is

The `felix` profile (`Profiles.FELIX`): model `Pixel Fold`, device `felix`,
SoC `GS201`, form fold. Two guest choices, both already shipped for Samsung
hosts and both no-SVE-proven:

- Infinity-X 4.1 (`infinityx41-findx9u`), set `infinityx-felix`
- ColorOS 17, Find X9 Ultra IN (`coloros17-findx9u-in`), set `x9u-in-felix`

The Pixel 11 images (`yogi`, `kodiak`) are deliberately **not** offered: they
are built for newer Tensor CPUs with SVE, and the Tensor G2 has none - a guest
binary that uses SVE cannot run on felix at all.

### The host's installd table

The installd guard jars map the guest's binder transaction codes onto the
host's. The Samsung tables (One UI 9, 85 methods, pinned in
`InstalldTable.ONE_UI_9`) do not fit a Pixel: the Pixel runs unmodified AOSP,
whose Android 17 `installd` has 37 methods (18 dexopt-family methods were
removed from the AIDL interface since; the AIDL source still declares 55, the
built `installd` answers 37). The port adds a second pinned table
(`InstalldTable.PIXEL_17`, 37 methods), extracted from the AOSP 17 GSI's
`framework.jar`:

```
switcher/patches/host_installd_pixel17.txt
sha256 (non-comment lines): 487d024a5aa681cb8f3ad237ba6589289e8d3df979cb517c1169f989eaea1f9a
```

`oneos_root.sh` stages both tables with every set and picks the profile's one
(`check_table`, `host_installd_pixel17.txt` for felix, `host_installd.txt`
otherwise); the app stages the right file for the profile (`AppAssets`).

### What the felix sets leave out

The Samsung sets carry patches for the Samsung host: the framework's and
camera client's One UI camera transaction codes (`framework_patched.jar`,
`libcamera_client_patched.so`), `samcam.tar`, the Samsung status bar
(`OneOSPixelStatusBar.apk`), the SMS service-centre fix
(`telephony-common_patched.jar`). None of that applies to a Pixel host, and
`ONEOS_HOST=pixel` builds without all of it (`make-overlays.sh`): the felix
sets hold only the guest-side patches - guard jars against the Pixel installd
table, the guest vold pair, the telephony injection, the APEX payloads, and
the ColorOS fold/theme files for the X9U IN set.

## Building the felix sets

```
ONEOS_HOST=pixel scripts/make-overlays.sh   # overlays_infinityx_felix_r1, overlays_x9u_in_felix_r1
```

The same run makes both felix sets. As with the Samsung sets, the built sets
are the out/ directories the app's package lists describe
(`app-android/packages/infinityx-felix.sha256` and
`x9u-in-felix.sha256` arrive with the first build), and the guest images
themselves are the shared downloads from `docs/download-images.md` - the repo
does not host images.

## What was audited, what was fixed

A full audit of the Samsung assumptions in the session scripts and patchers
(`docs/pixel-fold-audit.md`) found the port's hard breakers, all fixed:

- A1 camera: no Samsung camera HAL tables are built or staged on a Pixel host
  (`ONEOS_HOST=pixel` skips `pixel_camera_abi.py`/`pixel_camera_native.py`
  and the samcam payloads).
- A2 installd: the Pixel table above; the root script's checks are
  profile-aware.
- A3 NetworkStack: the guest keeps the host's NetworkStack apex on felix
  (`guest_prepare.sh`), as on One UI.
- A4 fold layout: the fold geometry works on felix's 2:3-ish inner panel
  (`panel_scale`, the 928 backlight, the fold layout in `guest_start.sh`).

Remaining, accepted degradations (no fix, by design of the port):

- B4 brightness: the Samsung brightness curves are not applied; the guest
  uses the Pixel's own backlight range.
- B6 Samsung IMS and camera apps are off in the guest - there is no Samsung
  IMS to answer on a Pixel, and the guest's camera is the guest's own.
- B9 hinge and panel keepers are no-ops on felix (no Samsung hinge service).
- B10 the HyperOS modem prop does not apply (no Samsung modem; the Pixel's
  own radio props stay).

## Untested

No session has run on a Pixel Fold yet. The profile is marked untested
(`testedWithAnyImage = false`), the compatibility report says so, and the
first runs should expect the same kind of iteration the Exynos and ColorOS
ports needed (`docs/exynos-hosts.md`, `docs/fold8-coloros.md`): watch
`takeover_app.log`, the installd guard's `guards.txt` report, and the guest's
`system_server` for anything that assumes a Samsung vendor.
