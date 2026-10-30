#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_root/scripts/macos-install-common.sh"
macos_integration_paths "$@"

launchctl bootout "$launch_domain/$agent_label" >/dev/null 2>&1 || true
macos_check_integration_paths
rm -f "$agent_plist"
if [[ -d "$install_app" ]]; then
  rm -rf "$install_app"
  printf 'Removed Codex launch monitor and app: %s\n' "$install_app"
else
  printf 'Installed app was not found: %s\n' "$install_app"
fi
printf 'Configuration and copied video in %s/Library/Application Support/DragonCodexBoot were kept.\n' "$user_root"
