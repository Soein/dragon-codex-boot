#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_root/scripts/macos-signing-common.sh"
# Use the real production requirement invocation and the OS signature as a
# positive control: a malformed -R argument cannot make only negative tests pass.
macos_verify_code_requirement /bin/echo 'anchor apple'
if macos_verify_code_requirement /bin/echo 'anchor apple and identifier "example.wrong.application"' >/dev/null 2>&1; then
  printf 'FAIL: accepted a wrong application requirement\n' >&2; exit 1
fi
if [[ -n "${MACOS_TEST_DEVELOPER_ID_APP:-}" ]]; then
  signing_identity="${MACOS_TEST_DEVELOPER_ID_IDENTITY:?Supply the independently verified full Developer ID certificate name}"
  macos_verify_release_app "$MACOS_TEST_DEVELOPER_ID_APP"
  signing_identity='Developer ID Application: Wrong Publisher (XXXXXXXXXX)'
  if macos_verify_release_app "$MACOS_TEST_DEVELOPER_ID_APP" >/dev/null 2>&1; then
    printf 'FAIL: accepted a wrong Developer ID publisher\n' >&2; exit 1
  fi
fi
printf 'PASS: real Apple signature accepted; wrong identity rejected by the production inline requirement check.\n'
