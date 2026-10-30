#!/usr/bin/env bash

macos_install_fail() {
  printf '%s\n' "$*" >&2
  return 1
}

macos_check_directory_chain() {
  local path="$1" current="/" component
  case "$path" in
    /*) ;;
    *) macos_install_fail "Expected an absolute path: $path"; return 1 ;;
  esac
  case "$path/" in
    *//*|*/./*|*/../*) macos_install_fail "Refusing a non-normalized path: $path"; return 1 ;;
  esac
  local remaining="${path#/}"
  while [[ -n "$remaining" ]]; do
    component="${remaining%%/*}"
    current="${current%/}/$component"
    if [[ -L "$current" || ( -e "$current" && ! -d "$current" ) ]]; then
      macos_install_fail "Refusing a symlink or non-directory: $current"; return 1
    fi
    [[ "$remaining" == */* ]] || break
    remaining="${remaining#*/}"
  done
}

macos_check_regular_file() {
  [[ ! -L "$1" && -f "$1" ]] || macos_install_fail "Refusing a symlink or non-file: $1"
}

macos_check_integration_app() {
  local app="$1" plist="$1/Contents/Info.plist"
  macos_check_directory_chain "$app/Contents/MacOS" || return 1
  [[ -d "$app" ]] || { macos_install_fail "Expected an application directory: $app"; return 1; }
  macos_check_regular_file "$plist" || return 1
  macos_check_regular_file "$app/Contents/MacOS/DragonCodexBootMac" || return 1
  if [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist" 2>/dev/null)" != community.dragoncodexboot.macos ||
        "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist" 2>/dev/null)" != DragonCodexBootMac ||
        "$(/usr/libexec/PlistBuddy -c 'Print :CFBundlePackageType' "$plist" 2>/dev/null)" != APPL ]]; then
    macos_install_fail "Refusing an unrelated application: $app"; return 1
  fi
}

macos_integration_paths() {
  user_root="$HOME"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --user-root)
        [[ $# -ge 2 && -n "$2" ]] || { macos_install_fail '--user-root requires a directory'; return 1; }
        user_root="$2"; shift 2 ;;
      --help)
        printf 'Usage: %s [--user-root ABSOLUTE_DIRECTORY]\nDefault: current user home; never run with sudo.\n' "$0"
        exit 0 ;;
      *) macos_install_fail "Unknown argument: $1"; return 1 ;;
    esac
  done
  [[ "$(id -u)" != 0 ]] || { macos_install_fail 'Run as the current user, without sudo.'; return 1; }
  macos_check_directory_chain "$user_root" || return 1
  [[ -d "$user_root" && "$(stat -f %u "$user_root")" == "$(id -u)" ]] || {
    macos_install_fail "User root must be an existing directory owned by the current user: $user_root"; return 1;
  }
  install_root="$user_root/Applications"
  install_app="$install_root/DragonCodexBoot.app"
  agent_label=community.dragoncodexboot.codex-watcher
  agent_directory="$user_root/Library/LaunchAgents"
  agent_plist="$agent_directory/$agent_label.plist"
  launch_domain="gui/$(id -u)"
  macos_check_integration_paths
}

macos_check_integration_paths() {
  macos_check_directory_chain "$install_root" || return 1
  macos_check_directory_chain "$agent_directory" || return 1
  if [[ -e "$install_app" || -L "$install_app" ]]; then
    macos_check_integration_app "$install_app" || return 1
  fi
  if [[ -e "$agent_plist" || -L "$agent_plist" ]]; then
    macos_check_regular_file "$agent_plist" || return 1
  fi
}
