#!/usr/bin/env bash
set -euo pipefail
umask 077

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_root/scripts/macos-path-safety.sh"
macos_assert_safe_directory_chain "$repo_root"
macos_assert_safe_regular_file "$repo_root/scripts/macos-signing-common.sh"
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
macos_assert_safe_regular_file "$repo_root/VERSION"
version="$(tr -d '\r\n' < "$repo_root/VERSION")"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]] || { macos_release_fail 'Invalid VERSION'; exit 1; }
name="DragonCodexBoot-$version-$archive_suffix"
if [[ "$signing_mode" == release ]]; then name="$name-notarized"; fi
name="$name.zip"
macos_check_package_outputs() {
  local output
  macos_assert_safe_directory_chain "$repo_root/build/macos"
  macos_assert_safe_directory_chain "$app"
  macos_assert_safe_directory_chain "$repo_root/dist"
  for output in "$repo_root/dist/$name" "$repo_root/dist/$name.sha256"; do
    if [[ -e "$output" || -L "$output" ]]; then macos_assert_safe_regular_file "$output"; fi
  done
}
macos_check_package_outputs
macos_assert_safe_regular_file "$build_script"
build_args=(--mode "$signing_mode")
if [[ -n "$signing_identity" ]]; then build_args+=(--identity "$signing_identity"); fi
if [[ -n "$notary_profile" ]]; then build_args+=(--notary-profile "$notary_profile"); fi
"$build_script" "${build_args[@]}"
macos_check_package_outputs
mkdir -p "$repo_root/dist"
work="$(mktemp -d "$repo_root/dist/.macos-package-XXXXXX")"
had_archive=0
had_checksum=0
publishing=0
completed=0
cleanup() {
  local status=$?
  if [[ "$publishing" == 1 && "$completed" != 1 ]]; then
    rm -f "$repo_root/dist/$name" "$repo_root/dist/$name.sha256"
    if [[ "$had_archive" == 1 ]]; then mv "$work/previous.zip" "$repo_root/dist/$name"; fi
    if [[ "$had_checksum" == 1 ]]; then mv "$work/previous.sha256" "$repo_root/dist/$name.sha256"; fi
  fi
  rm -rf "$work"
  return "$status"
}
trap cleanup EXIT

if [[ "$signing_mode" == release ]]; then
  macos_verify_release_app "$app"
  ditto -c -k --sequesterRsrc --keepParent "$app" "$work/submission.zip"
  xcrun notarytool submit "$work/submission.zip" --keychain-profile "$notary_profile" --wait --output-format plist > "$work/notarization.plist"
  status="$(/usr/libexec/PlistBuddy -c 'Print :status' "$work/notarization.plist")"
  [[ "$status" == Accepted ]] || { macos_release_fail "Notarization was not accepted: $status"; exit 1; }
  xcrun stapler staple "$app"
  xcrun stapler validate "$app"
  macos_verify_release_app "$app"
fi

# Only publish the final archive/hash after every required signing/notary check.
ditto -c -k --sequesterRsrc --keepParent "$app" "$work/$name"
(cd "$work" && shasum -a 256 "$name" > "$name.sha256")
macos_check_package_outputs
if [[ -f "$repo_root/dist/$name" ]]; then cp -p "$repo_root/dist/$name" "$work/previous.zip"; had_archive=1; fi
if [[ -f "$repo_root/dist/$name.sha256" ]]; then cp -p "$repo_root/dist/$name.sha256" "$work/previous.sha256"; had_checksum=1; fi
publishing=1
mv -f "$work/$name" "$repo_root/dist/$name"
mv -f "$work/$name.sha256" "$repo_root/dist/$name.sha256"
(cd "$repo_root/dist" && shasum -a 256 -c "$name.sha256")
completed=1
printf 'Packaged (%s): %s\n' "$signing_mode" "$repo_root/dist/$name"
