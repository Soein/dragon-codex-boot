#!/usr/bin/env bash

macos_path_safety_fail() {
  printf '%s\n' "$*" >&2
  return 1
}

macos_path_check_permissions() {
  local path="$1" current_uid="$2" sticky_ancestor="${3:-0}" metadata owner group mode listing line principal entry rights permission identity trusted
  metadata="$(/usr/bin/stat -f '%u %g %Lp' "$path")" || return 1
  read -r owner group mode <<< "$metadata"
  if [[ "$owner" != "$current_uid" && "$owner" != 0 ]]; then
    macos_path_safety_fail "Refusing a path owned by another account: $path"; return 1
  fi
  # Sticky directories only protect an existing trusted child, never a new fixed destination.
  if (( (8#$mode & 0002) != 0 || ((8#$mode & 0020) != 0 && group != 0 && group != 80) )); then
    if [[ ! -d "$path" || ! -k "$path" || "$owner" != 0 || "$sticky_ancestor" != 1 ]]; then
      macos_path_safety_fail "Refusing a path writable by another account: $path"; return 1
    fi
  fi
  # Numeric ls output uses UUID principals, avoiding ambiguous names and whitespace in account names.
  # https://github.com/apple-oss-distributions/file_cmds/blob/main/ls/print.c
  listing="$(LC_ALL=C /bin/ls -ldne "$path")" || return 1
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*[0-9]+: ]] || continue
    entry="${line#*: }"
    principal="${entry%% *}"
    entry="${entry#* }"
    entry="${entry#inherited }"
    case "$entry" in
      deny\ *) continue ;;
      allow\ *) rights="${entry#allow }" ;;
      *) macos_path_safety_fail "Unrecognized access control entry: $path"; return 1 ;;
    esac
    case ",$rights," in
      *,write,*|*,append,*|*,add_file,*|*,add_subdirectory,*|*,delete,*|*,delete_child,*|*,writeattr,*|*,writeextattr,*|*,writesecurity,*|*,chown,*) ;;
      *) continue ;;
    esac
    # Inherit-only write grants also matter: new install/LaunchAgent directories would inherit them.
    trusted=0
    for identity in "u:$current_uid" u:0 g:0 g:80; do
      permission="$(/usr/bin/dsmemberutil getuuid "-${identity%%:*}" "${identity#*:}")" || return 1
      if [[ "$principal" == "$permission" ]]; then trusted=1; break; fi
    done
    if [[ "$trusted" != 1 ]]; then
      macos_path_safety_fail "Refusing access granted to another account: $path"; return 1
    fi
  done <<< "$listing"
}

# Read-only validation; a nonexistent suffix is permitted after all existing ancestors pass.
macos_assert_safe_directory_chain() {
  local path="$1" current="/" component remaining current_uid next_component sticky_ancestor
  case "$path" in
    /*) ;;
    *) macos_path_safety_fail "Expected an absolute path: $path"; return 1 ;;
  esac
  if [[ "$path" == *$'\n'* || "$path" == *$'\r'* ]]; then
    macos_path_safety_fail 'Refusing a path containing line breaks.'; return 1
  fi
  if [[ "$path" != / ]]; then
    case "$path/" in
      *//*|*/./*|*/../*) macos_path_safety_fail "Refusing a non-normalized path: $path"; return 1 ;;
    esac
  fi
  current_uid="$(/usr/bin/id -u)" || return 1
  macos_path_check_permissions / "$current_uid" || return 1
  remaining="${path#/}"
  while [[ -n "$remaining" ]]; do
    component="${remaining%%/*}"
    current="${current%/}/$component"
    if [[ -L "$current" || ( -e "$current" && ! -d "$current" ) ]]; then
      macos_path_safety_fail "Refusing a symlink or non-directory: $current"; return 1
    fi
    if [[ -e "$current" ]]; then
      sticky_ancestor=0
      if [[ "$remaining" == */* ]]; then
        next_component="${remaining#*/}"
        next_component="${next_component%%/*}"
        if [[ -d "$current/$next_component" && ! -L "$current/$next_component" ]]; then sticky_ancestor=1; fi
      fi
      macos_path_check_permissions "$current" "$current_uid" "$sticky_ancestor" || return 1
    fi
    [[ "$remaining" == */* ]] || break
    remaining="${remaining#*/}"
  done
}

macos_assert_safe_regular_file() {
  local path="$1" parent="${1%/*}"
  [[ -n "$parent" ]] || parent=/
  macos_assert_safe_directory_chain "$parent" || return 1
  if [[ -L "$path" || ! -f "$path" ]]; then
    macos_path_safety_fail "Refusing a symlink or non-file: $path"; return 1
  fi
  macos_path_check_permissions "$path" "$(/usr/bin/id -u)"
}
