#!/usr/bin/env bash
# ===========================================================================
# OneOS Pixel Fold (felix) - ColorOS guest image builder
# ===========================================================================
# Builds the ColorOS 17 GSI (system.img) for the Pixel Fold's x9u-in-felix
# package set, from an official OPPO Find X9 Ultra (CPH2841, global) firmware
# package, and then compiles the OneOS felix set (the patched jars, payload
# images and overlays) that the OneOS app stages on the Fold.
#
# What it does, in order:
#   1. installs the host requirements (apt packages, JDK 21, Android SDK)
#   2. checks out this repo (branch pixel-fold-felix) and MysticGSI,
#      and applies the OP_REPLACE_ZSTD payload fix Android 17 OTAs need
#   3. takes the latest official firmware package (--firmware) and builds
#      the ColorOS GSI with MysticGSI
#   4. runs ONEOS_HOST=pixel scripts/make-overlays.sh against that image
#      -> out/overlays_x9u_in_felix_r1 (the x9u-in-felix set)
#   5. writes the set's pin files (app-android/packages/x9u-in-felix.*)
#   6. fetches the other fold-series sets and validates everything with
#      gradle :app:oneosFiles
#
# Usage:
#   ./build-oneos-coloros.sh --firmware /path/to/CPH2841EX01_17.0.0.101.zip
#   ./build-oneos-coloros.sh --firmware https://example.com/full-ota.zip
#   ./build-oneos-coloros.sh --prebuilt ~/OneOS_ColorOS17_FindX9Ultra_IN_Full.img
#
# Options:
#   --firmware <path|URL>  the latest ColorOS 17 full OTA / .ozip for the
#                          Find X9 Ultra global (CPH2841EX01). Required
#                          unless --prebuilt is given.
#   --prebuilt <img>       skip MysticGSI and build the felix set from an
#                          existing ColorOS 17 system.img (for example the
#                          OneOS_ColorOS17_FindX9Ultra_IN_Full.img from the
#                          project's Drive folder, build CP2A.260605.016).
#   --name <name>          the MysticGSI build name (default coloros17-felix)
#   --debloat              let MysticGSI remove its default app list (the
#                          OneOS image is built "Full", so the default keeps
#                          everything)
#   --skip-sets            skip fetching the other fold-series sets and the
#                          gradle validation (step 6)
#
# Environment:
#   ONEOS_BUILD_DIR        work dir (default ~/oneos-build); JDK, Android SDK,
#                          the repo checkout and the set cache live here.
#                          Needs ~45 GB free: the firmware package (4-10 GB),
#                          MysticGSI's extraction and patching (~2x the super
#                          partition) and the ~14.7 GB GSI.
#   ONEOS_REPO_URL         git remote (default
#                          https://github.com/chrispilot2293/OneOS)
#   ONEOS_BRANCH           git branch (default pixel-fold-felix)
#
# Getting the firmware (the only manual part):
#   OPPO does not publish direct download links like Google's factory
#   images. The official sources for the latest ColorOS 17 (Android 17)
#   full package for the Find X9 Ultra global are:
#     - the phone itself: Settings > System & update > Software update
#       (the downloaded full package can be pulled from the phone, or use
#       the ColorOS Assistant PC tool: https://www.oppo.com/en/rom/)
#     - OPPO's official community threads, where the ColorOS team posts
#       each build: https://community.oppo.com/thread/2245661012256620547
#       (Find X9 Ultra, CPH2841EX01_17.0.0.x)
#   Give this script the package as --firmware <path or URL>.
#
# A note on "latest": OneOS pins per build. make-overlays.sh was written
# against the Find X9 Ultra IN build CP2A.260605.016; a newer firmware
# changes vold/surfaceflinger/services.jar, and the patchers refuse a build
# they do not know (by design - a set is never half patched). If that
# happens, either port the new pins (docs/new-guest-systems.md) or build
# from the pinned prebuilt image with --prebuilt.
# ===========================================================================
set -e

FIRMWARE=""
PREBUILT=""
GSI_NAME="coloros17-felix"
DEBLOAT=0
SKIP_SETS=0
while [ $# -gt 0 ]; do
  case "$1" in
    --firmware) FIRMWARE="$2"; shift 2 ;;
    --prebuilt) PREBUILT="$2"; shift 2 ;;
    --name) GSI_NAME="$2"; shift 2 ;;
    --debloat) DEBLOAT=1; shift ;;
    --skip-sets) SKIP_SETS=1; shift ;;
    *) echo "unknown option: $1 (see the header of this script)" >&2; exit 2 ;;
  esac
done

WORK="${ONEOS_BUILD_DIR:-$HOME/oneos-build}"
REPO_URL="${ONEOS_REPO_URL:-https://github.com/chrispilot2293/OneOS}"
BRANCH="${ONEOS_BRANCH:-pixel-fold-felix}"
REPO="$WORK/OneOS"
SDK="$WORK/android-sdk"
JDK="$WORK/jdk21"
SET_ID="x9u-in-felix"
SET_DIR="out/overlays_x9u_in_felix_r1"

say()  { echo "  $*"; }
die()  { echo "  ERROR: $*" >&2; exit 1; }

echo "=== OneOS Pixel Fold (felix) - ColorOS image build ==="
say "work dir: $WORK"
[ "$(uname -s)" = Linux ] || die "this script runs on Linux (WSL on Windows)."
mkdir -p "$WORK"
AVAILABLE_KB=$(df -Pk "$WORK" | awk 'NR==2 {print $4}')
MIN_GB="${ONEOS_MIN_GB:-40}"
[ "$AVAILABLE_KB" -lt $((MIN_GB * 1048576)) ] && \
  die "only $((AVAILABLE_KB / 1048576)) GB free in $WORK; the build needs ~$MIN_GB GB (firmware package, extraction, ~14.7 GB GSI). Free space, point ONEOS_BUILD_DIR elsewhere, or lower ONEOS_MIN_GB if you know better."
[ -n "$FIRMWARE" ] || [ -n "$PREBUILT" ] || {
  echo
  say "no --firmware and no --prebuilt given."
  say "Get the latest official ColorOS 17 full OTA package for the Find X9"
  say "Ultra global (CPH2841EX01) from OPPO (see 'Getting the firmware'"
  say "in this script's header), then re-run with --firmware <path|URL>."
  exit 1
}

# --------------------------------------------------------------------------
echo "[1/6] Host requirements"
# --------------------------------------------------------------------------
NEEDED=""
for c in curl git python3 unzip zip file patch sha256sum; do
  command -v "$c" >/dev/null 2>&1 || NEEDED="$NEEDED $c"
done
command -v debugfs >/dev/null 2>&1 || NEEDED="$NEEDED e2fsprogs"
if [ -n "$NEEDED" ]; then
  say "installing host packages:$NEEDED"
  sudo apt-get update -qq
  sudo apt-get install -y -qq $NEEDED python3-venv python3-pip aria2 openssl \
    ca-certificates libarchive-tools >/dev/null
else
  say "host packages already there"
fi
command -v debugfs >/dev/null 2>&1 || \
  die "debugfs is missing (apt-get install e2fsprogs)"

# JDK 21 (apktool, keytool, gradle).
if [ ! -x "$JDK/bin/java" ]; then
  say "downloading Temurin JDK 21"
  mkdir -p "$JDK"
  curl -sL "https://api.adoptium.net/v3/binary/latest/21/ga/linux/x64/jdk/hotspot/normal/eclipse" \
    | tar xz -C "$JDK" --strip-components 1
else
  say "JDK 21 already there"
fi
export JAVA_HOME="$JDK"
"$JDK/bin/java" -version 2>&1 | head -1 | sed 's/^/  /'

# Android SDK (aapt2, zipalign, apksigner, android.jar for the RROs).
if [ ! -d "$SDK/platforms/android-37.0" ]; then
  say "setting up the Android SDK"
  mkdir -p "$SDK/cmdline-tools"
  if [ ! -d "$SDK/cmdline-tools/latest" ]; then
    curl -sL "https://dl.google.com/android/repository/commandlinetools-linux-13114758_latest.zip" \
      -o "$WORK/ctools.zip"
    unzip -q -o "$WORK/ctools.zip" -d "$SDK/cmdline-tools"
    rm -f "$WORK/ctools.zip"
    mv "$SDK/cmdline-tools/cmdline-tools" "$SDK/cmdline-tools/latest"
  fi
  yes | "$SDK/cmdline-tools/latest/bin/sdkmanager" --licenses >/dev/null
  "$SDK/cmdline-tools/latest/bin/sdkmanager" \
    "platforms;android-37.0" "build-tools;36.0.0" >/dev/null
else
  say "Android SDK already there"
fi
export ANDROID_HOME="$SDK"

# --------------------------------------------------------------------------
echo "[2/6] The checkouts (OneOS + MysticGSI) and the payload fix"
# --------------------------------------------------------------------------
if [ -d "$REPO/.git" ]; then
  say "updating $REPO ($BRANCH)"
  git -C "$REPO" fetch -q origin "$BRANCH"
  git -C "$REPO" checkout -q "$BRANCH"
  git -C "$REPO" reset -q --hard "origin/$BRANCH"
else
  say "cloning $REPO_URL ($BRANCH)"
  git clone -q -b "$BRANCH" --single-branch "$REPO_URL" "$REPO"
fi
if [ -d "$REPO/mysticgsi/.git" ]; then
  say "updating MysticGSI"
  git -C "$REPO/mysticgsi" pull -q
else
  say "cloning MysticGSI (the GSI build; its tools are the overlay build's apktool)"
  git clone -q https://github.com/MysticGSI/mysticgsi.git "$REPO/mysticgsi"
fi

# Android 17 full OTAs use OP_REPLACE_ZSTD (op type 14), which MysticGSI's
# payload extractor does not know; the OneOS patch fixes it (this is the
# fix docs/new-guest-systems.md describes).
if python3 "$REPO/scripts/fix-mysticgsi-payload.py" "$REPO/mysticgsi"; then :; else
  die "the OP_REPLACE_ZSTD payload fix failed"
fi

# --------------------------------------------------------------------------
echo "[3/6] The ColorOS GSI (system.img)"
# --------------------------------------------------------------------------
GSI_IMG=""
if [ -n "$PREBUILT" ]; then
  [ -f "$PREBUILT" ] || die "--prebuilt image not found: $PREBUILT"
  GSI_IMG="$PREBUILT"
  say "using the prebuilt image: $GSI_IMG"
else
  FIRMWARE_PATH="$FIRMWARE"
  if case "$FIRMWARE" in http://*|https://*) true ;; *) false ;; esac; then
    FIRMWARE_PATH="$WORK/firmware-$(basename "${FIRMWARE%%\?*}")"
    if [ ! -f "$FIRMWARE_PATH" ]; then
      say "downloading the firmware package"
      curl -L --retry 5 --retry-delay 3 -C - -o "$FIRMWARE_PATH" "$FIRMWARE"
    else
      say "firmware package already downloaded"
    fi
  fi
  [ -f "$FIRMWARE_PATH" ] || die "firmware package not found: $FIRMWARE_PATH"
  [ "$(stat -c %s "$FIRMWARE_PATH")" -gt 1000000000 ] || \
    die "$FIRMWARE_PATH is too small for a full OTA package - a full ColorOS 17
package is several GB. (An incremental OTA cannot be used: it needs the
source build.)"

  if [ ! -d "$REPO/mysticgsi/.venv" ]; then
    say "creating MysticGSI's virtualenv"
    python3 -m venv "$REPO/mysticgsi/.venv"
    "$REPO/mysticgsi/.venv/bin/pip" -q install -r "$REPO/mysticgsi/requirements.txt"
  else
    say "MysticGSI virtualenv already there"
  fi

  say "building the GSI with MysticGSI (this extracts and repacks the whole"
  say "system - expect an hour or more, and tens of GB of disk)"
  DEBLOAT_FLAG="--no-debloat"
  [ "$DEBLOAT" = 1 ] && DEBLOAT_FLAG=""
  ( cd "$REPO/mysticgsi" && .venv/bin/python cli.py build "$GSI_NAME" \
      "$FIRMWARE_PATH" --type coloros $DEBLOAT_FLAG ) || \
    die "the MysticGSI build failed (its output above names the cause)"

  GSI_IMG=$(find "$REPO/mysticgsi/out/$GSI_NAME" -name "$GSI_NAME-system.img" 2>/dev/null | head -1)
  [ -n "$GSI_IMG" ] && [ -f "$GSI_IMG" ] || \
    die "no $GSI_NAME-system.img under $REPO/mysticgsi/out/$GSI_NAME/"
  say "GSI: $GSI_IMG ($(du -h "$GSI_IMG" | cut -f1))"
fi
GSI_SHA=$(sha256sum "$GSI_IMG" | cut -d' ' -f1)
GSI_BYTES=$(stat -c %s "$GSI_IMG")

# --------------------------------------------------------------------------
echo "[4/6] The OneOS felix set (out/overlays_x9u_in_felix_r1)"
# --------------------------------------------------------------------------
# The RROs are signed with the debug keystore; make one if it is missing.
KS="$HOME/.android/debug.keystore"
if [ ! -f "$KS" ]; then
  say "generating the Android debug keystore"
  mkdir -p "$HOME/.android"
  "$JDK/bin/keytool" -genkeypair -keystore "$KS" -alias androiddebugkey \
    -keyalg RSA -keysize 2048 -validity 10950 \
    -storepass android -keypass android \
    -dname "CN=Android Debug,O=Android,C=US" >/dev/null 2>&1
fi

if ! ( cd "$REPO" && ONEOS_HOST=pixel ANDROID_HOME="$SDK" JAVA_HOME="$JDK" \
    scripts/make-overlays.sh "$GSI_IMG" "$SET_DIR" ); then
  echo
  say "make-overlays.sh failed. If the message above names vold or"
  say "surfaceflinger as 'not a build this was written against', the"
  say "firmware is newer than the pinned CP2A.260605.016 build: the patchers"
  say "refuse builds they do not know (docs/new-guest-systems.md). Port the"
  say "new pins, or build from the pinned image with --prebuilt."
  exit 1
fi
say "felix set built: $REPO/$SET_DIR ($(du -sh "$REPO/$SET_DIR" | cut -f1))"

# --------------------------------------------------------------------------
echo "[5/6] The set's pin files (app-android/packages/$SET_ID.*)"
# --------------------------------------------------------------------------
PIN="$REPO/app-android/packages/$SET_ID.sha256"
GUARDS_PIN="$REPO/app-android/packages/$SET_ID.guards.txt"
TESTRES="$REPO/app-android/core/model/src/test/resources/packages"
mkdir -p "$(dirname "$PIN")" "$TESTRES"
{
  echo "# OneOS package set $SET_ID: sha256sum of $SET_DIR (scripts/make-overlays.sh with ONEOS_HOST=pixel, from the ColorOS 17 Find X9 Ultra global GSI $GSI_NAME)."
  echo "# app/build.gradle.kts packs exactly these files into the APK and fails the build when $SET_DIR differs."
  ( cd "$REPO/$SET_DIR" && sha256sum * )
} > "$PIN"
if [ -f "$REPO/$SET_DIR/guards.txt" ]; then
  cp "$REPO/$SET_DIR/guards.txt" "$GUARDS_PIN"
  cp "$GUARDS_PIN" "$TESTRES/$SET_ID.guards.txt"
fi
cp "$PIN" "$TESTRES/$SET_ID.sha256"
say "wrote $PIN"
say "wrote $GUARDS_PIN (+ the test resource copies)"

echo
say "Image pins for Images.kt (ID_FIND_X9U_IN, coloros17-findx9u-in):"
say "  rawBytes = $GSI_BYTES"
say "  rawSha256 = \"$GSI_SHA\""
say "A locally built GSI is a new build: the app pins the published image"
say "size and sha256, and shows a new build as untested until it has run"
say "on a named phone (docs/new-guest-systems.md). To ship it, host the"
say "image (the project uses Drive) and update Images.kt."

# --------------------------------------------------------------------------
echo "[6/6] Validation (the other fold sets + gradle oneosFiles)"
# --------------------------------------------------------------------------
if [ "$SKIP_SETS" = 1 ]; then
  say "skipped (--skip-sets)"
else
  # The other fold-series sets: their files are published on the OneOS-files
  # release (app-android/packages/remote.txt); each file lands in its set's
  # out/ directory, sha256-verified, deduplicated through a cache.
  CACHE="$WORK/setcache"
  mkdir -p "$CACHE"
  python3 - "$REPO" "$CACHE" <<'PYEOF'
import os, re, subprocess, sys

repo, cache = sys.argv[1], sys.argv[2]
series = open(os.path.join(repo, "app-android/packages/series.txt")).read()
fold = next(l.split()[1:] for l in series.splitlines()
           if l.strip() and not l.startswith("#") and l.split()[:1] == ["fold"])
bg = open(os.path.join(repo, "app-android/app/build.gradle.kts")).read()
dirs = dict(re.findall(r'"([a-z0-9-]+)"\s+to\s+\(File\(repoRoot,\s*"([^"]+)"\)', bg))
remote = {}
for line in open(os.path.join(repo, "app-android/packages/remote.txt")):
    t = line.strip()
    if t and not t.startswith("#"):
        sha, src = t.split()
        remote[sha] = src.split(",")[0]
fetched = 0
for sid in fold:
    pin = os.path.join(repo, "app-android/packages", sid + ".sha256")
    outd = os.path.join(repo, dirs[sid])
    if not os.path.exists(pin):
        print(f"  {sid}: no package list yet (the felix sets arrive with"
              " their first build) - skipped")
        continue
    print(f"  {sid} -> {dirs[sid]}")
    for line in open(pin):
        if line.startswith("#"):
            continue
        sha, name = line.split()
        dst = os.path.join(cache, sha)
        target = os.path.join(outd, name)
        if os.path.exists(target):
            continue
        if not (os.path.exists(dst) and subprocess.run(
                ["sha256sum", dst], capture_output=True, text=True
            ).stdout.split()[0] == sha):
            src = remote.get(sha, "")
            m = re.match(r"^gh:(.+)$", src)
            if not m:
                sys.exit(f"no GitHub release source for {sha} (only {src!r})")
            url = f"https://github.com/fahadalijaved/OneOS-files/releases/download/{m.group(1)}/{sha}"
            tmp = dst + ".part"
            for attempt in range(5):
                r = subprocess.run(["curl", "-sS", "-L", "--fail",
                                    "--retry", "5", "--connect-timeout", "30",
                                    "-o", tmp, url])
                if r.returncode == 0:
                    break
            else:
                sys.exit(f"download failed for {sha}")
            if subprocess.run(["sha256sum", tmp], capture_output=True,
                             text=True).stdout.split()[0] != sha:
                sys.exit(f"sha256 mismatch for {sha}")
            os.replace(tmp, dst)
            fetched += 1
        os.makedirs(outd, exist_ok=True)
        try:
            os.link(dst, target)
        except OSError:
            import shutil
            shutil.copyfile(dst, target)
print(f"  {fetched} files fetched this run (the rest were cached)")
PYEOF
  say "validating with gradle :app:oneosFiles (packSets: the felix set's"
  say "files are not on the project's release yet)"
  ( cd "$REPO/app-android" && JAVA_HOME="$JDK" ANDROID_HOME="$SDK" \
      ./gradlew :app:oneosFiles -Poneos.series=fold -Poneos.packSets=true \
      --no-daemon ) || die "oneosFiles failed - see the gradle output above"
fi

echo
echo "Done."
echo "  GSI image:        $GSI_IMG"
echo "  felix set:        $REPO/$SET_DIR"
echo "  set pin files:    $REPO/app-android/packages/$SET_ID.*"
echo "  (then build the APK with build-oneos.cmd, or gradlew"
echo "   :app:assembleFullRelease -Poneos.series=fold -Poneos.packSets=true)"
