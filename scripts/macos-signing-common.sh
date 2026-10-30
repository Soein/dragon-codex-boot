#!/usr/bin/env bash

macos_release_fail() {
  printf '%s\n' "$*" >&2
  return 1
}

macos_signing_options() {
  signing_mode=local
  signing_identity="${MACOS_SIGNING_IDENTITY:-}"
  notary_profile="${MACOS_NOTARY_PROFILE:-}"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mode|--identity|--notary-profile)
        [[ $# -ge 2 && -n "$2" ]] || { macos_release_fail "$1 requires a value"; return 1; }
        case "$1" in
          --mode) signing_mode="$2" ;;
          --identity) signing_identity="$2" ;;
          --notary-profile) notary_profile="$2" ;;
        esac
        shift 2 ;;
      --help)
        printf 'Usage: %s [--mode local|release] [--identity "Developer ID Application: NAME (TEAMID)"] [--notary-profile NAME]\n' "$0"
        printf 'Release requires an existing Developer ID identity and notarytool keychain profile.\n'
        exit 0 ;;
      *) macos_release_fail "Unknown argument: $1"; return 1 ;;
    esac
  done
  case "$signing_mode" in
    local) ;;
    release)
      if [[ "$signing_identity" != 'Developer ID Application: '* || ! "$signing_identity" =~ \([A-Z0-9]{10}\)$ || "$signing_identity" == *$'\n'* ]]; then
        macos_release_fail 'Release requires a full Developer ID Application signing identity (--identity or MACOS_SIGNING_IDENTITY).'; return 1
      fi
      [[ -n "$notary_profile" ]] || { macos_release_fail 'Release requires --notary-profile or MACOS_NOTARY_PROFILE.'; return 1; }
      xcrun --find notarytool >/dev/null || return 1
      xcrun --find stapler >/dev/null || return 1 ;;
    *) macos_release_fail "Unknown signing mode: $signing_mode"; return 1 ;;
  esac
}

macos_verify_release_app() {
  local app="$1" escaped_identity details requirement team_id
  escaped_identity="${signing_identity//\\/\\\\}"
  escaped_identity="${escaped_identity//\"/\\\"}"
  team_id="${signing_identity##*\(}"
  team_id="${team_id%\)}"
  requirement="anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.CN] = \"$escaped_identity\" and certificate leaf[subject.OU] = \"$team_id\""
  macos_verify_code_requirement "$app" "$requirement" || return 1
  details="$(codesign --display --verbose=4 "$app" 2>&1)" || return 1
  if [[ "$details" != *'(runtime)'* || "$details" != *$'\nTimestamp='* ]]; then
    macos_release_fail "Release signature must enable Hardened Runtime and include a secure timestamp: $app"; return 1
  fi
}

macos_verify_code_requirement() {
  codesign --verify --deep --strict -R "=$2" "$1"
}

macos_sign_app() {
  local app="$1"
  if [[ "$signing_mode" == release ]]; then
    codesign --force --sign "$signing_identity" --options runtime --timestamp "$app" || return 1
    macos_verify_release_app "$app"
  else
    codesign --force --sign - --timestamp=none "$app" || return 1
    codesign --verify --deep --strict "$app"
  fi
}
