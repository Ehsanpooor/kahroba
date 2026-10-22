#!/usr/bin/env bash
# Build the release APKs, signed with the Zood Gamers key:
#
#   build/android/splendor-arm64.apk   64-bit ARM, version code N    (Cafe Bazaar)
#   build/android/splendor-armv7.apk   32-bit ARM, version code N-1  (Cafe Bazaar)
#   build/android/splendor.apk         both, version code N          (the website)
#
# N is version/code in export_presets.cfg. Both Bazaar APKs go into the same
# release; Bazaar gives each phone the highest version code it can run, so the
# 64-bit one must have the higher code (a 64-bit phone can also run 32-bit).
# For the next release raise version/code by 2, so its 32-bit APK is still
# newer than this release's 64-bit one.
#
#   ./tools/build_android.sh
set -euo pipefail
cd "$(dirname "$0")/.."
GODOT="${GODOT:-/c/Users/ehsan/Downloads/Compressed/Godot_v4.7.2-stable_win64.exe/Godot_v4.7.2-stable_win64_console.exe}"
KEYS="${SPLENDOR_KEYS:-C:/projects/splendor-keys}"
export GODOT_ANDROID_KEYSTORE_RELEASE_PATH="$KEYS/zoodgamers-release.keystore"
export GODOT_ANDROID_KEYSTORE_RELEASE_USER=splendor
GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD="$(grep '^password:' "$KEYS/KEYSTORE-README.txt" | cut -d' ' -f2)"
export GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD

PRESETS=export_presets.cfg
cp "$PRESETS" "$PRESETS.orig"
trap 'mv -f "$PRESETS.orig" "$PRESETS"' EXIT
N="$(grep -m1 '^version/code=' "$PRESETS.orig" | cut -d= -f2)"

# build <file> <version code> <armv7 true|false> <arm64 true|false>
build() {
  sed -e "s/^version\/code=.*/version\/code=$2/" \
      -e "s/^architectures\/armeabi-v7a=.*/architectures\/armeabi-v7a=$3/" \
      -e "s/^architectures\/arm64-v8a=.*/architectures\/arm64-v8a=$4/" \
      "$PRESETS.orig" > "$PRESETS"
  rm -f "$1"
  "$GODOT" --headless --path . --export-release "Android" "$1" 2>&1 \
    | grep -iE "error|fail" | grep -v "resources still in use" || true
  [ -f "$1" ] || { echo "export failed: $1"; exit 1; }
  echo "built $1 (version code $2)"
}

mkdir -p build/android
build build/android/splendor-arm64.apk "$N" false true
build build/android/splendor-armv7.apk "$((N - 1))" true false
build build/android/splendor.apk "$N" true true
