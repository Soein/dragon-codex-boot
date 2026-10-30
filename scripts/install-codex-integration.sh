#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_root/scripts/macos-install-common.sh"
macos_integration_paths "$@"
source_app="$repo_root/build/DragonCodexBoot.app"

# Validate destinations before building or changing the running LaunchAgent.
"$repo_root/scripts/build-macos.sh"
macos_check_integration_app "$source_app"
codesign --verify --deep --strict "$source_app"
macos_check_integration_paths
mkdir -p "$install_root" "$agent_directory"
stage=
plist_stage=
had_app=0
had_plist=0
replaced=0
completed=0
cleanup() {
  local status=$?
  if [[ "$completed" == 0 && "$replaced" == 1 ]]; then
    rm -rf "$install_app"
    if [[ "$had_app" == 1 ]]; then mv "$stage/previous.app" "$install_app"; fi
    if [[ "$had_plist" == 1 ]]; then
      mv "$stage/previous.plist" "$agent_plist"
    else
      rm -f "$agent_plist"
    fi
  elif [[ "$completed" == 0 && "$had_app" == 1 && ! -e "$install_app" ]]; then
    mv "$stage/previous.app" "$install_app"
  fi
  if [[ -n "$stage" ]]; then rm -rf "$stage"; fi
  if [[ -n "$plist_stage" ]]; then rm -f "$plist_stage"; fi
  return "$status"
}
trap cleanup EXIT
stage="$(mktemp -d "$install_root/.dragon-codex-XXXXXX")"
plist_stage="$(mktemp "$agent_directory/.dragon-codex-XXXXXX")"

ditto "$source_app" "$stage/DragonCodexBoot.app"
macos_check_integration_app "$stage/DragonCodexBoot.app"
codesign --verify --deep --strict "$stage/DragonCodexBoot.app"
plutil -create xml1 "$plist_stage"
plutil -insert Label -string "$agent_label" "$plist_stage"
plutil -insert ProgramArguments -array "$plist_stage"
plutil -insert ProgramArguments.0 -string "$install_app/Contents/MacOS/DragonCodexBootMac" "$plist_stage"
plutil -insert ProgramArguments.1 -string --watch "$plist_stage"
plutil -insert RunAtLoad -bool true "$plist_stage"
plutil -insert LimitLoadToSessionType -string Aqua "$plist_stage"
plutil -lint "$plist_stage" >/dev/null
macos_check_integration_paths
if [[ -f "$agent_plist" ]]; then cp -p "$agent_plist" "$stage/previous.plist"; had_plist=1; fi
launchctl bootout "$launch_domain/$agent_label" >/dev/null 2>&1 || true
if [[ -d "$install_app" ]]; then mv "$install_app" "$stage/previous.app"; had_app=1; fi
mv "$stage/DragonCodexBoot.app" "$install_app"
replaced=1
mv -f "$plist_stage" "$agent_plist"
launchctl bootstrap "$launch_domain" "$agent_plist"
completed=1
printf 'Installed app: %s\n' "$install_app"
printf 'Quit and reopen Codex to test the launch monitor.\n'
