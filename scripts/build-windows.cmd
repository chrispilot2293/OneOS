@echo off
setlocal EnableExtensions EnableDelayedExpansion
title OneOS Pixel Fold (felix) build
rem ============================================================================
rem  build-oneos.cmd - one-shot build of the OneOS Pixel Fold fork
rem
rem  Everything this needs it downloads itself:
rem    - Temurin JDK 21              (Adoptium)
rem    - Android SDK cmdline-tools   (platform 37.0, build-tools 36.0)
rem    - the fork                    (chrispilot2293/OneOS, pixel-fold-felix)
rem    - the fold-series set files   (~3.4 GB, from the OneOS-files release,
rem                                   cached in setcache\ and copied into out\)
rem    - a release signing keystore  (~\.oneos-release\, generated once)
rem
rem  One thing only you can provide: GitHub Packages reads the SESL UI
rem  libraries from maven.pkg.github.com, which needs a GitHub account and a
rem  token with the read:packages scope (free, fine-grained tokens work).
rem
rem  Output: %USERPROFILE%\oneos-build\app-full-release.apk
rem    (the fold edition: Galaxy Z Fold + Pixel Fold phones, files kept out of
rem     the APK and downloaded by the app - as upstream ships it. Add
rem     -Poneos.packSets=true to the Gradle line for a self-contained APK.)
rem
rem  Requires Windows 10 1809+ (curl, tar) and Git for Windows.
rem ============================================================================

set "WORK=%USERPROFILE%\oneos-build"
if defined ONEOS_BUILD_DIR set "WORK=%ONEOS_BUILD_DIR%"
set "REPO=%WORK%\OneOS"
set "JDK=%WORK%\jdk21"
set "SDK=%WORK%\android-sdk"
set "SERIES=fold"
set "BRANCH=pixel-fold-felix"
set "TASK=assembleFullRelease"

echo === OneOS Pixel Fold (felix) build ===
echo   work dir: %WORK%

where git >nul 2>nul || (echo [!] git is required - install Git for Windows first. & exit /b 1)
where tar >nul 2>nul || (echo [!] tar is required - Windows 10 1809 or newer. & exit /b 1)
if not exist "%WORK%" mkdir "%WORK%"

rem ---------------------------------------------------------------- 1. JDK 21
if exist "%JDK%\bin\java.exe" goto jdk_done
echo [1/6] Downloading Temurin JDK 21...
powershell -NoProfile -Command "$ProgressPreference='SilentlyContinue'; Invoke-WebRequest 'https://api.adoptium.net/v3/binary/latest/21/ga/windows/x64/jdk/hotspot/normal/eclipse' -OutFile '%WORK%\jdk21.zip'"
if errorlevel 1 (echo [!] JDK download failed. & exit /b 1)
tar -xf "%WORK%\jdk21.zip" -C "%WORK%"
for /f "delims=" %%d in ('dir /b /ad "%WORK%" ^| findstr /i "^jdk-21"') do ren "%WORK%\%%d" jdk21
del "%WORK%\jdk21.zip" 2>nul
:jdk_done
set "JAVA_HOME=%JDK%"
set "PATH=%JAVA_HOME%\bin;%PATH%"

rem ------------------------------------------------------- 2. Android SDK
if not exist "%SDK%\cmdline-tools\latest\bin\sdkmanager.bat" (
  echo [2/6] Downloading Android command line tools...
  powershell -NoProfile -Command "$ProgressPreference='SilentlyContinue'; Invoke-WebRequest 'https://dl.google.com/android/repository/commandlinetools-win-13114758_latest.zip' -OutFile '%WORK%\ctools.zip'"
  if errorlevel 1 (echo [!] cmdline-tools download failed. & exit /b 1)
  mkdir "%WORK%\ctools-extract" 2>nul
  tar -xf "%WORK%\ctools.zip" -C "%WORK%\ctools-extract"
  mkdir "%SDK%\cmdline-tools" 2>nul
  move /y "%WORK%\ctools-extract\cmdline-tools" "%SDK%\cmdline-tools\latest" >nul
  rmdir /s /q "%WORK%\ctools-extract" 2>nul
  del "%WORK%\ctools.zip" 2>nul
)
set "ANDROID_HOME=%SDK%"
set "SDKMANAGER=%SDK%\cmdline-tools\latest\bin\sdkmanager.bat"
if not exist "%SDK%\platforms\android-37.0" (
  echo         Installing platform 37.0 and build-tools 36.0...
  > "%WORK%\yes.txt" (for /l %%i in (1,1,30) do @echo y)
  call "%SDKMANAGER%" --licenses < "%WORK%\yes.txt" >nul 2>nul
  call "%SDKMANAGER%" "platforms;android-37.0" "build-tools;36.0.0" < "%WORK%\yes.txt"
  del "%WORK%\yes.txt" 2>nul
)

rem ---------------------------------------------------------------- 3. the repo
if exist "%REPO%\.git" goto repo_ok
echo [3/6] Cloning the fork (%BRANCH%)...
git clone --branch %BRANCH% https://github.com/chrispilot2293/OneOS.git "%REPO%"
if errorlevel 1 (echo [!] clone failed. & exit /b 1)
goto repo_done
:repo_ok
echo [3/6] Updating the checkout...
git -C "%REPO%" fetch origin %BRANCH% || exit /b 1
git -C "%REPO%" checkout -q %BRANCH% || exit /b 1
git -C "%REPO%" pull -q origin %BRANCH% || exit /b 1
:repo_done

rem ------------------------------------------ 4. GitHub Packages credentials
set "GHPROP=%USERPROFILE%\.config\twidget\github.properties"
if exist "%GHPROP%" goto gh_ok
if defined GH_PACKAGES_USER if defined GH_PACKAGES_TOKEN goto gh_write
echo.
echo The app's UI libraries (SESL) come from GitHub Packages, which needs
echo your GitHub username and a token with the read:packages scope:
echo   https://github.com/settings/tokens?type=beta  ^(Packages: Read-only^)
set /p "GH_PACKAGES_USER=GitHub username: "
set /p "GH_PACKAGES_TOKEN=GitHub token (read:packages): "
if "%GH_PACKAGES_TOKEN%"=="" (echo [!] a token is required to build. & exit /b 1)
:gh_write
mkdir "%USERPROFILE%\.config\twidget" 2>nul
> "%GHPROP%" echo ghUsername=%GH_PACKAGES_USER%
>> "%GHPROP%" echo ghAccessToken=%GH_PACKAGES_TOKEN%
:gh_ok

rem ------------------------------- 5. set files + signing key (PowerShell part)
echo [4/6] Fetching the %SERIES%-series set files (~3.4 GB, cached) and
echo       making the release signing key...
powershell -NoProfile -Command "$l = Get-Content -LiteralPath '%~f0'; $i = [array]::IndexOf($l, '::__PS1__'); $l[($i+1)..($l.Count-1)] | Set-Content -LiteralPath \"$env:TEMP\oneos-build.ps1\""
if errorlevel 1 (echo [!] could not unpack the helper script. & exit /b 1)
powershell -NoProfile -ExecutionPolicy Bypass -File "%TEMP%\oneos-build.ps1" -Repo "%REPO%" -Work "%WORK%" -Series %SERIES%
if errorlevel 1 exit /b 1

rem ------------------------------------------------------------------ 6. build
echo [5/6] Building the APK (the first Gradle run downloads ~1 GB more)...
cd /d "%REPO%\app-android"
call gradlew.bat :app:%TASK% -Poneos.series=%SERIES% --no-daemon
if errorlevel 1 (
  echo [!] the build failed - the log above says why.
  exit /b 1
)

for %%f in ("%REPO%\app\build\outputs\apk\full\release\app-full-release.apk") do (
  if exist %%f copy /y %%f "%WORK%\app-full-release.apk" >nul && echo [6/6] Signed APK: %WORK%\app-full-release.apk
)
if not exist "%WORK%\app-full-release.apk" echo [!] no APK found - check %REPO%\app\build\outputs\apk\full\release\
endlocal
exit /b 0

::__PS1__
param(
  [Parameter(Mandatory=$true)][string]$Repo,
  [Parameter(Mandatory=$true)][string]$Work,
  [string]$Series = 'fold'
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# The series' sets (app-android/packages/series.txt).
$seriesLine = Get-Content (Join-Path $Repo 'app-android\packages\series.txt') |
  Where-Object { $_ -match "^\s*$Series\s" } | Select-Object -First 1
if (-not $seriesLine) { throw "no '$Series' series in series.txt" }
$sets = $seriesLine.Trim() -split '\s+' | Select-Object -Skip 1

# The set -> out/ directory map (app/build.gradle.kts packageSets).
$bg = Get-Content (Join-Path $Repo 'app-android\app\build.gradle.kts') -Raw
$dirs = @{}
foreach ($m in [regex]::Matches($bg, '"([a-z0-9-]+)"\s+to\s+\(File\(repoRoot,\s*"([^"]+)"\)\s+to\s+listOf\(([^)]*)\)\)')) {
  $dirs[$m.Groups[1].Value] = $m.Groups[2].Value
}

# Where each file's bytes come from (app-android/packages/remote.txt).
$remote = @{}
foreach ($line in Get-Content (Join-Path $Repo 'app-android\packages\remote.txt')) {
  $t = $line.Trim(); if ($t -and -not $t.StartsWith('#')) { $p = $t -split '\s+'; $remote[$p[0]] = $p[1] }
}

$cache = Join-Path $Work 'setcache'
New-Item -ItemType Directory -Force -Path $cache | Out-Null

function Get-OneOsFile([string]$sha) {
  $dst = Join-Path $cache $sha
  if ((Test-Path $dst) -and ((Get-FileHash $dst -Algorithm SHA256).Hash -eq $sha.ToUpper())) { return }
  $tmp = "$dst.part"
  $src = $remote[$sha]
  if ($src -notmatch '^gh:(.+)$') { throw "no GitHub release source for $sha (only $($src))" }
  $tag = $Matches[1]
  $url = "https://github.com/fahadalijaved/OneOS-files/releases/download/$tag/$sha"
  Invoke-WebRequest -Uri $url -OutFile $tmp
  $h = (Get-FileHash $tmp -Algorithm SHA256).Hash
  if ($h -ne $sha.ToUpper()) { throw "sha256 mismatch for $sha (got $h)" }
  Move-Item $tmp $dst
}

$fetched = 0
foreach ($set in $sets) {
  $list = Join-Path $Repo "app-android\packages\$set.sha256"
  if (-not (Test-Path $list)) {
    Write-Host "  $set : no package list yet (the felix sets arrive with their first build) - skipped" -ForegroundColor Yellow
    continue
  }
  $dir = Join-Path $Repo $dirs[$set]
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  foreach ($line in Get-Content $list) {
    $t = $line.Trim(); if (-not $t -or $t.StartsWith('#')) { continue }
    $sha, $name = $t -split '\s+'
    if (-not (Test-Path (Join-Path $cache $sha))) { Get-OneOsFile $sha; $fetched++ }
    $target = Join-Path $dir $name
    if (-not (Test-Path $target)) { Copy-Item (Join-Path $cache $sha) $target }
  }
  Write-Host "  $set -> $($dirs[$set])"
}
Write-Host ("  {0} files fetched this run (the rest were cached)" -f $fetched)

# The release signing key, generated once (app/build.gradle.kts reads
# ~\.oneos-release\keystore.properties).
$home_ = if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }
$rel = Join-Path $home_ '.oneos-release'
$ks  = Join-Path $rel 'oneos-release.keystore'
$kp  = Join-Path $rel 'keystore.properties'
if (Test-Path $kp) { Write-Host '  signing key already there'; exit 0 }
New-Item -ItemType Directory -Force -Path $rel | Out-Null
$chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'
$pass = -join (1..32 | ForEach-Object { $chars[(Get-Random -Maximum $chars.Length)] })
$keytool = Join-Path (Join-Path $env:JAVA_HOME 'bin') 'keytool.exe'
& $keytool -genkeypair -keystore $ks -alias oneos `
  -keyalg RSA -keysize 4096 -validity 10950 -storepass $pass -keypass $pass `
  -dname "CN=OneOS local build, OU=OneOS, O=OneOS, C=US" | Out-Null
"storeFile=$($ks -replace '\\','/')`nstorePassword=$pass`nkeyAlias=oneos`nkeyPassword=$pass" |
  Set-Content -LiteralPath $kp
Write-Host '  generated a release signing key (password is in keystore.properties)'
