#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_root/scripts/macos-signing-common.sh"
variant=standalone
signing_args=(--mode local)
while [[ $# -gt 0 ]]; do
  case "$1" in
    --variant)
      [[ $# -ge 2 ]] || { macos_release_fail '--variant requires standalone or integration'; exit 1; }
      variant="$2"; shift 2 ;;
    --help)
      printf 'Usage: %s [--variant standalone|integration] [--mode local|release] [--identity IDENTITY] [--notary-profile NAME]\n' "$0"
      exit 0 ;;
    *) signing_args+=("$1"); shift ;;
  esac
done
case "$variant" in
  standalone)
    build_script="$repo_root/scripts/build-macos-standalone.sh"
    app="$repo_root/build/macos/Dragon Codex Boot.app"
    archive_suffix=macos-arm64-with-video ;;
  integration)
    build_script="$repo_root/scripts/build-macos.sh"
    app="$repo_root/build/DragonCodexBoot.app"
    archive_suffix="macos-$(uname -m)-integration" ;;
  *) macos_release_fail "Unknown app variant: $variant"; exit 1 ;;
esac
macos_signing_options "${signing_args[@]}"
build_args=(--mode "$signing_mode")
if [[ -n "$signing_identity" ]]; then build_args+=(--identity "$signing_identity"); fi
if [[ -n "$notary_profile" ]]; then build_args+=(--notary-profile "$notary_profile"); fi
"$build_script" "${build_args[@]}"
version="$(tr -d '\r\n' < "$repo_root/VERSION")"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]] || { macos_release_fail 'Invalid VERSION'; exit 1; }
name="DragonCodexBoot-$version-$archive_suffix"
mkdir -p "$repo_root/dist"
work="$(mktemp -d "$repo_root/dist/.macos-package-XXXXXX")"
trap 'rm -rf "$work"' EXIT

if [[ "$signing_mode" == release ]]; then
  macos_verify_release_app "$app"
  ditto -c -k --sequesterRsrc --keepParent "$app" "$work/submission.zip"
  xcrun notarytool submit "$work/submission.zip" --keychain-profile "$notary_profile" --wait --output-format plist > "$work/notarization.plist"
  status="$(/usr/libexec/PlistBuddy -c 'Print :status' "$work/notarization.plist")"
  [[ "$status" == Accepted ]] || { macos_release_fail "Notarization was not accepted: $status"; exit 1; }
  xcrun stapler staple "$app"
  xcrun stapler validate "$app"
  macos_verify_release_app "$app"
  name="$name-notarized"
fi

# Only publish the final archive/hash after every required signing/notary check.
name="$name.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$work/$name"
(cd "$work" && shasum -a 256 "$name" > "$name.sha256")
mv -f "$work/$name" "$repo_root/dist/$name"
mv -f "$work/$name.sha256" "$repo_root/dist/$name.sha256"
printf 'Packaged (%s): %s\n' "$signing_mode" "$repo_root/dist/$name"
