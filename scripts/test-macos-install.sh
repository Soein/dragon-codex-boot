#!/usr/bin/env bash
set -euo pipefail

# Mutations stay in /private/tmp; system ancestors are inspected read-only and launchctl/build are isolated.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="$(mktemp -d /private/tmp/dragon-macos-install.XXXXXX)"
clear_fixture_acls() {
  find "$scratch" ! -type l -exec chmod -N {} +
}
trap 'chmod 700 "$scratch"; clear_fixture_acls; rm -rf "$scratch"' EXIT
fixture="$scratch/repo"
mkdir -p "$fixture/scripts" "$fixture/build" "$scratch/bin"
cp "$repo_root/scripts/"*macos*.sh "$repo_root/scripts/"*codex-integration.sh "$fixture/scripts/"
export MACOS_TEST_EVENTS="$scratch/events" MACOS_TEST_SOURCE="$scratch/source.app"
cat > "$fixture/scripts/build-macos.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'build\n' >> "$MACOS_TEST_EVENTS"
[[ "${MACOS_TEST_REJECT_BUILD:-0}" != 1 ]] || exit 77
ditto "$MACOS_TEST_SOURCE" "$(dirname "$0")/../build/DragonCodexBoot.app"
SH
cat > "$scratch/bin/launchctl" <<'SH'
#!/usr/bin/env bash
printf 'launchctl %s\n' "$*" >> "$MACOS_TEST_EVENTS"
if [[ "$1" == bootstrap && "${MACOS_TEST_BOOTSTRAP_FAILURE:-0}" == 1 ]]; then exit 89; fi
SH
chmod +x "$fixture/scripts/build-macos.sh" "$scratch/bin/launchctl"
export PATH="$scratch/bin:$PATH"

make_app() {
  local app="$1" bundle_id="${2:-community.dragoncodexboot.macos}"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
  cp /bin/echo "$app/Contents/MacOS/DragonCodexBootMac"
  /usr/bin/plutil -create xml1 "$app/Contents/Info.plist"
  /usr/bin/plutil -insert CFBundleIdentifier -string "$bundle_id" "$app/Contents/Info.plist"
  /usr/bin/plutil -insert CFBundleExecutable -string DragonCodexBootMac "$app/Contents/Info.plist"
  /usr/bin/plutil -insert CFBundlePackageType -string APPL "$app/Contents/Info.plist"
}
reset_user() {
  chmod 700 "$scratch"
  clear_fixture_acls
  rm -rf "$scratch/user" "$scratch/other" "$fixture/build/DragonCodexBoot.app"
  mkdir -p "$scratch/user/Applications" "$scratch/user/Library/LaunchAgents" "$scratch/other"
  : > "$MACOS_TEST_EVENTS"
}
reject_before_side_effects() {
  local entry="$1"
  if MACOS_TEST_REJECT_BUILD=1 bash "$fixture/scripts/$entry" --user-root "$scratch/user" > "$scratch/output" 2>&1; then
    printf 'FAIL: accepted unsafe path (%s)\n' "$case_name" >&2; exit 1
  fi
  if [[ -s "$MACOS_TEST_EVENTS" ]]; then
    printf 'FAIL: unsafe path reached build/launchctl (%s)\n' "$case_name" >&2
    cat "$MACOS_TEST_EVENTS" >&2; exit 1
  fi
}

make_app "$MACOS_TEST_SOURCE"
codesign --force --sign - --timestamp=none "$MACOS_TEST_SOURCE" >/dev/null 2>&1
for case_name in app-symlink dangling-app applications-symlink applications-file library-symlink agents-symlink agents-file app-file wrong-app contents-symlink macos-symlink plist-symlink executable-symlink agent-symlink agent-directory user-symlink ancestor-writable user-writable group-writable applications-writable library-writable agents-writable app-writable contents-writable macos-writable resources-writable plist-writable executable-writable agent-writable ancestor-acl agents-acl app-acl plist-acl executable-acl agent-acl inherited-acl; do
  reset_user
  app="$scratch/user/Applications/DragonCodexBoot.app"
  agent="$scratch/user/Library/LaunchAgents/community.dragoncodexboot.codex-watcher.plist"
  case "$case_name" in
    app-symlink) make_app "$scratch/other/target.app"; ln -s "$scratch/other/target.app" "$app" ;;
    dangling-app) ln -s "$scratch/other/missing.app" "$app" ;;
    applications-symlink) rmdir "$scratch/user/Applications"; ln -s "$scratch/other" "$scratch/user/Applications" ;;
    applications-file) rmdir "$scratch/user/Applications"; touch "$scratch/user/Applications" ;;
    library-symlink) rm -rf "$scratch/user/Library"; ln -s "$scratch/other" "$scratch/user/Library" ;;
    agents-symlink) rmdir "$scratch/user/Library/LaunchAgents"; ln -s "$scratch/other" "$scratch/user/Library/LaunchAgents" ;;
    agents-file) rmdir "$scratch/user/Library/LaunchAgents"; touch "$scratch/user/Library/LaunchAgents" ;;
    app-file) touch "$app" ;;
    wrong-app) make_app "$app" example.unrelated ;;
    contents-symlink) mkdir -p "$app"; make_app "$scratch/other/target.app"; ln -s "$scratch/other/target.app/Contents" "$app/Contents" ;;
    macos-symlink) make_app "$app"; mv "$app/Contents/MacOS" "$scratch/other/MacOS"; ln -s "$scratch/other/MacOS" "$app/Contents/MacOS" ;;
    plist-symlink) make_app "$app"; mv "$app/Contents/Info.plist" "$scratch/other/Info.plist"; ln -s "$scratch/other/Info.plist" "$app/Contents/Info.plist" ;;
    executable-symlink) make_app "$app"; rm "$app/Contents/MacOS/DragonCodexBootMac"; ln -s /bin/echo "$app/Contents/MacOS/DragonCodexBootMac" ;;
    agent-symlink) ln -s "$scratch/other/agent.plist" "$agent" ;;
    agent-directory) mkdir "$agent" ;;
    user-symlink) mv "$scratch/user" "$scratch/other/user"; ln -s "$scratch/other/user" "$scratch/user" ;;
    ancestor-writable) chmod 777 "$scratch" ;;
    user-writable) chmod 777 "$scratch/user" ;;
    group-writable)
      ordinary_group="$(id -G | /usr/bin/awk '{for(i=1;i<=NF;i++) if($i!=0 && $i!=80) {print $i;exit}}')"
      [[ -n "$ordinary_group" ]] || continue
      chgrp "$ordinary_group" "$scratch/user"; chmod 770 "$scratch/user" ;;
    applications-writable) chmod 777 "$scratch/user/Applications" ;;
    library-writable) chmod 777 "$scratch/user/Library" ;;
    agents-writable) chmod 777 "$scratch/user/Library/LaunchAgents" ;;
    app-writable) make_app "$app"; chmod 777 "$app" ;;
    contents-writable) make_app "$app"; chmod 777 "$app/Contents" ;;
    macos-writable) make_app "$app"; chmod 777 "$app/Contents/MacOS" ;;
    resources-writable) make_app "$app"; chmod 777 "$app/Contents/Resources" ;;
    plist-writable) make_app "$app"; chmod 666 "$app/Contents/Info.plist" ;;
    executable-writable) make_app "$app"; chmod 777 "$app/Contents/MacOS/DragonCodexBootMac" ;;
    agent-writable) printf 'unsafe\n' > "$agent"; chmod 666 "$agent" ;;
    ancestor-acl) chmod +a 'group:everyone allow delete_child' "$scratch/user/Library" ;;
    agents-acl) chmod +a 'group:everyone allow add_file,delete_child' "$scratch/user/Library/LaunchAgents" ;;
    app-acl) make_app "$app"; chmod +a 'group:everyone allow writesecurity' "$app" ;;
    plist-acl) make_app "$app"; chmod +a 'group:everyone allow write' "$app/Contents/Info.plist" ;;
    executable-acl) make_app "$app"; chmod +a 'group:everyone allow write' "$app/Contents/MacOS/DragonCodexBootMac" ;;
    agent-acl) printf 'unsafe\n' > "$agent"; chmod +a 'group:everyone allow write' "$agent" ;;
    inherited-acl) chmod +a 'group:everyone allow write,file_inherit,directory_inherit,only_inherit' "$scratch/user/Library" ;;
  esac
  reject_before_side_effects install-codex-integration.sh
  reject_before_side_effects uninstall-codex-integration.sh
done

# Standard system permissions and protective/read-only ACLs must remain usable.
source "$repo_root/scripts/macos-path-safety.sh"
macos_assert_safe_directory_chain /Applications
macos_assert_safe_directory_chain "$HOME"
if macos_assert_safe_directory_chain /private/tmp > "$scratch/output" 2>&1 ||
   macos_assert_safe_directory_chain "$scratch.missing/child" > "$scratch/output" 2>&1; then
  printf 'FAIL: sticky system directories must only protect an existing private child\n' >&2; exit 1
fi
macos_assert_safe_directory_chain "$scratch/missing/child"
reset_user
chmod +a 'group:everyone deny delete' "$scratch/user"
chmod +a 'group:everyone allow list,search,readattr,readsecurity' "$scratch/user/Library/LaunchAgents"
chmod +a "user:$(id -un) allow add_file,delete_child" "$scratch/user/Applications"
macos_assert_safe_directory_chain "$scratch/user/Applications"
macos_assert_safe_directory_chain "$scratch/user/Library/LaunchAgents"
macos_assert_safe_directory_chain "$scratch/user/Library/LaunchAgents/missing/child"
chmod -RN "$scratch/user"

# Newly created destinations remain private even when the caller uses a permissive umask.
rm -rf "$scratch/user/Applications" "$scratch/user/Library"
(umask 000; bash "$fixture/scripts/install-codex-integration.sh" --user-root "$scratch/user")
for directory in "$scratch/user/Applications" "$scratch/user/Library" "$scratch/user/Library/LaunchAgents"; do
  test "$(/usr/bin/stat -f %Lp "$directory")" = 700
done
test "$(/usr/bin/stat -f %Lp "$scratch/user/Library/LaunchAgents/community.dragoncodexboot.codex-watcher.plist")" = 600
bash "$fixture/scripts/uninstall-codex-integration.sh" --user-root "$scratch/user"

reset_user
app="$scratch/user/Applications/DragonCodexBoot.app"
configuration="$scratch/user/Library/Application Support/DragonCodexBoot/launcher.json"
mkdir -p "$(dirname "$configuration")"
printf 'user configuration\n' > "$configuration"
make_app "$app"
printf 'old\n' > "$app/Contents/Resources/stale"
bash "$fixture/scripts/install-codex-integration.sh" --user-root "$scratch/user"
test ! -e "$app/Contents/Resources/stale"
codesign --verify --deep --strict "$app"
agent="$scratch/user/Library/LaunchAgents/community.dragoncodexboot.codex-watcher.plist"
test "$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$agent")" = "$app/Contents/MacOS/DragonCodexBootMac"
test "$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:1' "$agent")" = --watch

# If activation fails after replacement, retain the previous complete artifacts.
printf 'rollback\n' > "$app/Contents/Resources/rollback"
cp "$agent" "$scratch/previous.plist"
if MACOS_TEST_BOOTSTRAP_FAILURE=1 bash "$fixture/scripts/install-codex-integration.sh" --user-root "$scratch/user" > "$scratch/output" 2>&1; then
  printf 'FAIL: ignored failed LaunchAgent activation\n' >&2; exit 1
fi
test -f "$app/Contents/Resources/rollback"
cmp "$agent" "$scratch/previous.plist"
test -z "$(find "$scratch/user/Applications" "$scratch/user/Library/LaunchAgents" -name '.dragon-codex-*' -print)"

# A failed signature check must retain the old installation and avoid launchctl.
printf 'old\n' > "$app/Contents/Resources/keep"
printf 'tampered\n' > "$MACOS_TEST_SOURCE/Contents/Resources/unsigned"
: > "$MACOS_TEST_EVENTS"
if bash "$fixture/scripts/install-codex-integration.sh" --user-root "$scratch/user" > "$scratch/output" 2>&1; then
  printf 'FAIL: installed a tampered source bundle\n' >&2; exit 1
fi
test -f "$app/Contents/Resources/keep"
if /usr/bin/grep -q launchctl "$MACOS_TEST_EVENTS"; then
  printf 'FAIL: signature failure reached launchctl\n' >&2; exit 1
fi
test -z "$(find "$scratch/user/Applications" -name '.dragon-codex-*' -print)"

# Uninstall must never execute a user-writable old app, including a replaced executable.
cat > "$app/Contents/MacOS/DragonCodexBootMac" <<'SH'
#!/usr/bin/env bash
touch "$MACOS_TEST_EVENTS.executed"
exit 99
SH
chmod +x "$app/Contents/MacOS/DragonCodexBootMac"
bash "$fixture/scripts/uninstall-codex-integration.sh" --user-root "$scratch/user"
test ! -e "$MACOS_TEST_EVENTS.executed"
test ! -e "$app"
test ! -e "$agent"
test "$(cat "$configuration")" = 'user configuration'
printf 'PASS: unsafe paths rejected before side effects; verified whole-app replacement; uninstall never executes old code.\n'
