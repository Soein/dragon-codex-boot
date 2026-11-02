#!/bin/bash
set -euo pipefail
umask 077

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="$repo_root/build/macos"
app="$build_dir/Dragon Codex Boot.app"
source_dir="$repo_root/src/macos"
source "$repo_root/scripts/macos-path-safety.sh"
macos_assert_safe_directory_chain "$repo_root"
macos_assert_safe_regular_file "$repo_root/scripts/macos-signing-common.sh"
source "$repo_root/scripts/macos-signing-common.sh"
macos_signing_options "$@"

if [[ "$(uname -s)" != Darwin ]]; then
  printf 'This build requires macOS and Xcode Command Line Tools.\n' >&2
  exit 1
fi
macos_assert_safe_directory_chain "$build_dir"
macos_assert_safe_directory_chain "$app"
for input in \
  "$source_dir/Info.plist" "$source_dir/PlaybackProgressWatchdog.swift" \
  "$source_dir/main.swift" "$source_dir/icon.swift" \
  "$repo_root/macos/Sources/DragonCodexBootCore/TrustedApplication.swift" \
  "$repo_root/VERSION" "$repo_root/media/startup.mp4" "$repo_root/LICENSE" \
  "$repo_root/THIRD_PARTY_NOTICES.md" "$repo_root/media/MEDIA_NOTICE.md" \
  "$repo_root/docs/MACOS-STANDALONE.md"; do
  macos_assert_safe_regular_file "$input"
done
test -s "$repo_root/media/startup.mp4"
mkdir -p "$build_dir"
work="$(mktemp -d "$build_dir/.macos-build-XXXXXX")"
trap 'rm -rf "$work"' EXIT
module_cache="$work/module-cache"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/Licenses" "$module_cache" "$work/AppIcon.iconset"
cp "$source_dir/Info.plist" "$app/Contents/Info.plist"
version="$(tr -d '\r\n' < "$repo_root/VERSION")"
/usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString $version" "$app/Contents/Info.plist"
xcrun swiftc -swift-version 5 -O -target arm64-apple-macosx13.0 \
  -module-cache-path "$module_cache" \
  -framework AppKit -framework AVFoundation -framework QuartzCore -framework Security \
  "$repo_root/macos/Sources/DragonCodexBootCore/TrustedApplication.swift" \
  "$source_dir/PlaybackProgressWatchdog.swift" "$source_dir/main.swift" -o "$app/Contents/MacOS/DragonCodexBoot"
xcrun swift -module-cache-path "$module_cache" "$source_dir/icon.swift" "$work/AppIcon.iconset"
cp "$work/AppIcon.iconset.icns" "$app/Contents/Resources/AppIcon.icns"
cp "$repo_root/media/startup.mp4" "$app/Contents/Resources/startup.mp4"
cp "$repo_root/LICENSE" "$repo_root/THIRD_PARTY_NOTICES.md" "$repo_root/media/MEDIA_NOTICE.md" "$app/Contents/Resources/Licenses/"
cp "$repo_root/docs/MACOS-STANDALONE.md" "$app/Contents/Resources/"
macos_sign_app "$app"
printf 'Built (%s): %s\n' "$signing_mode" "$app"
