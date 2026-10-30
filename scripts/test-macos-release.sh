#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="$(mktemp -d /private/tmp/dragon-macos-release.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT
fixture="$scratch/repo"
mkdir -p "$fixture/scripts" "$scratch/bin"
cp "$repo_root/scripts/"*macos*.sh "$fixture/scripts/"
printf '0.0.0\n' > "$fixture/VERSION"
export MACOS_TEST_EVENTS="$scratch/events" MACOS_TEST_SOURCE="$scratch/source.app"
export MACOS_SIGNING_IDENTITY= MACOS_NOTARY_PROFILE=
cat > "$fixture/scripts/build-macos-standalone.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'build\n' >> "$MACOS_TEST_EVENTS"
[[ "${MACOS_TEST_REJECT_BUILD:-0}" != 1 ]] || exit 77
root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$root/build/macos"
if [[ "$(basename "$0")" == build-macos.sh ]]; then
  ditto "$MACOS_TEST_SOURCE" "$root/build/DragonCodexBoot.app"
else
  ditto "$MACOS_TEST_SOURCE" "$root/build/macos/Dragon Codex Boot.app"
fi
SH
cp "$fixture/scripts/build-macos-standalone.sh" "$fixture/scripts/build-macos.sh"
chmod +x "$fixture/scripts/"*.sh
identity='Developer ID Application: Offline Test (ABCDEFGHIJ)'
expect_early_failure() {
  : > "$MACOS_TEST_EVENTS"
  if MACOS_TEST_REJECT_BUILD=1 bash "$fixture/scripts/package-macos.sh" "$@" > "$scratch/output" 2>&1; then
    printf 'FAIL: accepted invalid release arguments\n' >&2; exit 1
  fi
  if [[ -s "$MACOS_TEST_EVENTS" ]]; then
    printf 'FAIL: invalid release arguments reached build\n' >&2; exit 1
  fi
}
expect_early_failure --mode release
expect_early_failure --mode release --identity "$identity"
expect_early_failure --mode release --identity - --notary-profile offline
expect_early_failure --mode release --identity 'Apple Development: Test' --notary-profile offline
expect_early_failure --mode invalid
expect_early_failure --variant invalid

mkdir -p "$MACOS_TEST_SOURCE/Contents/MacOS"
cp /bin/echo "$MACOS_TEST_SOURCE/Contents/MacOS/Test"
plutil -create xml1 "$MACOS_TEST_SOURCE/Contents/Info.plist"
plutil -insert CFBundleExecutable -string Test "$MACOS_TEST_SOURCE/Contents/Info.plist"
plutil -insert CFBundleIdentifier -string example.offline-test "$MACOS_TEST_SOURCE/Contents/Info.plist"
codesign --force --sign - --timestamp=none "$MACOS_TEST_SOURCE" >/dev/null 2>&1
bash "$fixture/scripts/package-macos-standalone.sh"
test -s "$fixture/dist/DragonCodexBoot-0.0.0-macos-arm64-with-video.zip"
bash "$fixture/scripts/package-macos.sh" --variant integration --mode local
test -s "$fixture/dist/DragonCodexBoot-0.0.0-macos-$(uname -m)-integration.zip"
cat > "$scratch/bin/xcrun" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$MACOS_TEST_EVENTS"
case "$*" in
  '--find notarytool'|'--find stapler') printf '/offline/tool\n' ;;
  'notarytool submit '*)
    [[ "${MACOS_TEST_NOTARY_FAILURE:-}" != command ]] || exit 1
    if [[ "${MACOS_TEST_NOTARY_FAILURE:-}" == rejected ]]; then
      printf '<?xml version="1.0"?><plist version="1.0"><dict><key>status</key><string>Invalid</string></dict></plist>\n'
    else
      printf '<?xml version="1.0"?><plist version="1.0"><dict><key>status</key><string>Accepted</string></dict></plist>\n'
    fi ;;
  'stapler staple '*) [[ "${MACOS_TEST_NOTARY_FAILURE:-}" != staple ]] ;;
  'stapler validate '*) [[ "${MACOS_TEST_NOTARY_FAILURE:-}" != validate ]] ;;
  *) printf 'Unexpected xcrun invocation\n' >&2; exit 99 ;;
esac
SH
chmod +x "$scratch/bin/xcrun"
export PATH="$scratch/bin:$PATH"
: > "$MACOS_TEST_EVENTS"
if bash "$fixture/scripts/package-macos.sh" --mode release --identity "$identity" --notary-profile offline > "$scratch/output" 2>&1; then
  printf 'FAIL: accepted a real ad hoc signature for release\n' >&2; exit 1
fi
if /usr/bin/grep -q 'notarytool submit' "$MACOS_TEST_EVENTS"; then
  printf 'FAIL: uploaded before rejecting ad hoc signature\n' >&2; exit 1
fi

# Only this orchestration section substitutes signing/Apple services; it never uploads.
cat > "$scratch/bin/codesign" <<'SH'
#!/usr/bin/env bash
printf 'codesign %s\n' "$*" >> "$MACOS_TEST_EVENTS"
if [[ "$*" == *--force* && "${MACOS_TEST_SIGNATURE_FAILURE:-}" == signing ]]; then exit 88; fi
if [[ "$*" == *--display* ]]; then
  if [[ "${MACOS_TEST_SIGNATURE_FAILURE:-}" != runtime ]]; then
    printf 'CodeDirectory v=20500 flags=0x10000(runtime)\n' >&2
  fi
  if [[ "${MACOS_TEST_SIGNATURE_FAILURE:-}" != timestamp ]]; then
    printf 'Timestamp=offline fixture\n' >&2
  fi
fi
exit 0
SH
chmod +x "$scratch/bin/codesign"
for failure in runtime timestamp; do
  rm -rf "$fixture/dist"
  : > "$MACOS_TEST_EVENTS"
  if MACOS_TEST_SIGNATURE_FAILURE="$failure" bash "$fixture/scripts/package-macos.sh" --mode release --identity "$identity" --notary-profile offline > "$scratch/output" 2>&1; then
    printf 'FAIL: accepted missing release signature property (%s)\n' "$failure" >&2; exit 1
  fi
  if /usr/bin/grep -q 'notarytool submit' "$MACOS_TEST_EVENTS"; then
    printf 'FAIL: uploaded before validating signature properties\n' >&2; exit 1
  fi
done
: > "$MACOS_TEST_EVENTS"
if MACOS_TEST_SIGNATURE_FAILURE=signing bash -c 'source "$1"; signing_mode=release; signing_identity="$3"; macos_sign_app "$2"' _ "$repo_root/scripts/macos-signing-common.sh" "$MACOS_TEST_SOURCE" "$identity" > "$scratch/output" 2>&1; then
  printf 'FAIL: accepted failed Developer ID signing\n' >&2; exit 1
fi
if /usr/bin/grep -q -- '--sign -' "$MACOS_TEST_EVENTS"; then
  printf 'FAIL: release signing fell back to ad hoc\n' >&2; exit 1
fi
for failure in command rejected staple validate; do
  rm -rf "$fixture/dist"
  : > "$MACOS_TEST_EVENTS"
  if MACOS_TEST_NOTARY_FAILURE="$failure" bash "$fixture/scripts/package-macos.sh" --mode release --identity "$identity" --notary-profile offline > "$scratch/output" 2>&1; then
    printf 'FAIL: accepted failed notarization (%s)\n' "$failure" >&2; exit 1
  fi
  test -z "$(find "$fixture/dist" -name '*notarized.zip*' -print 2>/dev/null)"
done
bash "$fixture/scripts/package-macos.sh" --mode release --identity "$identity" --notary-profile offline
archive="$fixture/dist/DragonCodexBoot-0.0.0-macos-arm64-with-video-notarized.zip"
test -s "$archive"
unzip -tq "$archive"
(cd "$fixture/dist" && shasum -a 256 -c "$(basename "$archive").sha256")
bash "$fixture/scripts/package-macos.sh" --variant integration --mode release --identity "$identity" --notary-profile offline
test -s "$fixture/dist/DragonCodexBoot-0.0.0-macos-$(uname -m)-integration-notarized.zip"
printf 'PASS: invalid release inputs and real ad hoc signatures rejected; offline notary/stapler failures never produce a release archive.\n'
