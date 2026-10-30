#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
test_root="$(mktemp -d /private/tmp/dragon-macos-security.XXXXXX)"
fixture_pid=""
cleanup() {
  if [[ -n "$fixture_pid" ]]; then
    kill "$fixture_pid" 2>/dev/null || true
    wait "$fixture_pid" 2>/dev/null || true
  fi
  rm -rf "$test_root"
}
trap cleanup EXIT
fixture="$test_root/FakeCodex.app"
mkdir -p "$fixture/Contents/MacOS" "$test_root/module-cache"
cat > "$fixture/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.openai.codex</string>
<key>CFBundleExecutable</key><string>FakeCodex</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
xcrun clang "$repo_root/tests/macos-security/fixture.c" -o "$fixture/Contents/MacOS/FakeCodex"
codesign --force --sign - --identifier com.openai.codex "$fixture"
codesign --verify --strict "$fixture"
"$fixture/Contents/MacOS/FakeCodex" > "$test_root/fixture.log" &
fixture_pid=$!

xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$test_root/module-cache" \
  "$repo_root/macos/Sources/DragonCodexBootCore/TrustedApplication.swift" \
  "$repo_root/tests/macos-security/SecurityAPITests.swift" -o "$test_root/security-api-tests"
"$test_root/security-api-tests" "$fixture" "$fixture_pid"

# Compile the actual private controller and resolver in the same Swift file as the tests.
# Remove only the executable's @main entry; do not substitute its launch implementation.
awk '/^@main$/ { exit } { print }' "$repo_root/macos/Sources/DragonCodexBootMac/main.swift" > "$test_root/EntrypointTests.swift"
cat "$repo_root/tests/macos-security/RunningApplicationSpy.swift" >> "$test_root/EntrypointTests.swift"
cat "$repo_root/tests/macos-security/EntrypointTests.swift" >> "$test_root/EntrypointTests.swift"
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$test_root/module-cache" \
  "$repo_root/macos/Sources/DragonCodexBootCore/LauncherConfiguration.swift" \
  "$repo_root/macos/Sources/DragonCodexBootCore/TrustedApplication.swift" \
  "$test_root/EntrypointTests.swift" -o "$test_root/entrypoint-tests"
"$test_root/entrypoint-tests" "$fixture" "$fixture_pid"

awk '/^let application = NSApplication.shared$/ { exit } { print }' "$repo_root/src/macos/main.swift" > "$test_root/StandaloneTests.swift"
cat "$repo_root/tests/macos-security/StandaloneTests.swift" >> "$test_root/StandaloneTests.swift"
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$test_root/module-cache" \
  "$repo_root/macos/Sources/DragonCodexBootCore/TrustedApplication.swift" \
  "$repo_root/src/macos/PlaybackProgressWatchdog.swift" \
  "$test_root/StandaloneTests.swift" -o "$test_root/standalone-tests"
set +e
TMPDIR="$test_root/" "$test_root/standalone-tests" "$fixture_pid" --verify > "$test_root/standalone.log" 2>&1
status=$?
set -e
cat "$test_root/standalone.log"
if [[ "$status" -ne 1 ]]; then
  echo "FAIL: standalone rejection exited $status instead of 1" >&2
  exit 1
fi
echo "PASS: standalone final handoff stops before untrusted activation"
