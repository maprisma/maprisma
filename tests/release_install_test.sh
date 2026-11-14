#!/usr/bin/env bash
# Task 073: packaging/install.sh and uninstall.sh against a small fake release archive in a temp HOME
# (per-user mode; --system needs root and is covered by the fresh-VM tests).
#   tests/release_install_test.sh
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/release install.XXXXXX") || { echo "no temp folder" >&2; exit 1; }   # a space on purpose
[[ $T == */release\ install.* && -d $T ]] || { echo "unexpected temp folder: $T" >&2; exit 1; }
trap 'rm -rf "$T"' EXIT
pass=0 fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$*"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }

archive() { # dir version
  local a=$1 v=$2
  mkdir -p "$a/app/lib" "$a/app/data/flutter_assets" "$a/share/applications" "$a/share/metainfo" \
    "$a/share/icons/hicolor/scalable/apps"
  cp /usr/bin/true "$a/app/maprisma"; cp /usr/bin/true "$a/app/lib/maprisma-core"
  printf '{"app_name":"maprisma","version":"%s"}' "$v" >"$a/app/data/flutter_assets/version.json"
  : >"$a/app/data/instance.lock"
  printf '[Desktop Entry]\nType=Application\nName=Maprisma\nExec=maprisma\nIcon=com.maprisma.Maprisma\n' \
    >"$a/share/applications/com.maprisma.Maprisma.desktop"
  echo "<component>$v</component>" >"$a/share/metainfo/com.maprisma.Maprisma.metainfo.xml"
  echo "<svg>$v</svg>" >"$a/share/icons/hicolor/scalable/apps/com.maprisma.Maprisma.svg"
  echo MIT >"$a/LICENSE"; echo 2.34 >"$a/glibc"
  cp "$ROOT/packaging/install.sh" "$ROOT/packaging/uninstall.sh" "$a/"
}
archive "$T/a1" 1.0.0
archive "$T/a2" 2.0.0
H="$T/home"
fresh() { [[ $H == "$T"/home ]] || exit 1; rm -rf "$H"; mkdir -p "$H"; }
# the host's own Maprisma package is not this test's business
TESTENV=(MAPRISMA_INSTALL_TEST=1 MAPRISMA_INSTALL_TEST_SYSAPP=/nonexistent/maprisma)
run() { env -i HOME="$H" PATH="$PATH" USER=tester LANG=C "${TESTENV[@]}" "$@"; }
L="$H/.local/lib/maprisma"
ENTRY="$H/.local/share/applications/com.maprisma.Maprisma.desktop"
ICON="$H/.local/share/icons/hicolor/scalable/apps/com.maprisma.Maprisma.svg"
leftovers() { find "$H/.local" \( -name '*.new.*' -o -name '*.old.*' -o -name '.maprisma-new.*' -o -name '.maprisma-backup.*' -o -name '*.journal' \) 2>/dev/null | head -1; }

# 1 fresh install
fresh
out=$(run "$T/a1/install.sh" --ignore-missing 2>&1); rc=$?
check "fresh install succeeds ($out)" '[[ $rc == 0 ]]'
check "link" '[[ $(readlink "$H/.local/bin/maprisma") == "$L/maprisma" ]]'
check "entry has an absolute quoted Exec" 'grep -qxF "Exec=\"$L/maprisma\"" "$ENTRY"'
check "receipt" '[[ $(wc -l <"$L/.install-receipt") == 4 ]]'
check "no leftovers" '[[ -z $(leftovers) ]]'
check "uninstaller in place" '[[ -x $L/uninstall.sh && -f $L/.installer.sh ]]'

# 2 reinstall (upgrade) swaps everything
out=$(run "$T/a2/install.sh" --ignore-missing 2>&1); rc=$?
check "upgrade succeeds ($out)" '[[ $rc == 0 ]]'
check "new version in place" 'grep -q 2.0.0 "$L/data/flutter_assets/version.json" && grep -q 2.0.0 "$ICON"'
check "no leftovers after upgrade" '[[ -z $(leftovers) ]]'

# 3 refused while Maprisma runs (it holds the instance lock shared)
exec {held}<"$L/data/instance.lock"; flock -s "$held"
out=$(run "$T/a1/install.sh" --ignore-missing 2>&1); rc=$?
check "refused while running ($out)" '[[ $rc != 0 && $out == *"is running"* ]]'
check "unchanged while running" 'grep -q 2.0.0 "$L/data/flutter_assets/version.json"'
out=$(run "$L/uninstall.sh" 2>&1); rc=$?
check "uninstall refused while running" '[[ $rc != 0 && -d $L ]]'
exec {held}<&-

# 4 a foreign file in a target place is never replaced
fresh
mkdir -p "$(dirname "$ICON")"; echo mine >"$ICON"
out=$(run "$T/a1/install.sh" --ignore-missing 2>&1); rc=$?
check "foreign icon refused ($out)" '[[ $rc != 0 && $(cat "$ICON") == mine && ! -e $L ]]'
fresh
mkdir -p "$L"; echo x >"$L/foo"
out=$(run "$T/a1/install.sh" --ignore-missing 2>&1); rc=$?
check "foreign folder refused" '[[ $rc != 0 && -f $L/foo ]]'

# 5 Maprisma Settings manages it: refused
fresh
mkdir -p "$H/.local/state/maprisma-settings/installed"; echo '{}' >"$H/.local/state/maprisma-settings/installed/maprisma.json"
out=$(run "$T/a1/install.sh" --ignore-missing 2>&1); rc=$?
check "Settings receipt refused ($out)" '[[ $rc != 0 && $out == *"Maprisma Settings"* && ! -e $L ]]'

# 5b a package owns Maprisma (the host's own file as a stand-in when it is owned by one)
fresh
if owned=$(pacman -Qqo /usr/bin/true 2>/dev/null); then
  out=$(env -i HOME="$H" PATH="$PATH" USER=tester MAPRISMA_INSTALL_TEST=1 MAPRISMA_INSTALL_TEST_SYSAPP=/usr/bin/true "$T/a1/install.sh" --ignore-missing 2>&1); rc=$?
  check "package refused, --ignore-missing does not override ($out)" '[[ $rc != 0 && $out == *"package $owned"* && ! -e $L ]]'
fi

# 6 missing libraries: refused without --ignore-missing (a fake ldconfig without sqlite/zstd)
fresh
mkdir -p "$T/fakebin"; printf '#!/bin/sh\necho "1 libs found"\n' >"$T/fakebin/ldconfig"; chmod +x "$T/fakebin/ldconfig"
out=$(env -i HOME="$H" PATH="$T/fakebin:$PATH" USER=tester LANG=C "${TESTENV[@]}" "$T/a1/install.sh" 2>&1); rc=$?
check "missing libs refused ($out)" '[[ $rc != 0 && $out == *libsqlite3* && ! -e $L ]]'

# 7 an edited file is kept on uninstall, the rest goes; providers unit of this install removed
fresh
run "$T/a1/install.sh" --ignore-missing >/dev/null 2>&1
echo "# edited" >>"$ENTRY"
mkdir -p "$H/.config/systemd/user"
printf '[Service]\nExecStart=%s/lib/maprisma-core provider-watch\n' "$L" >"$H/.config/systemd/user/maprisma-providers.service"
out=$(run "$L/uninstall.sh" 2>&1); rc=$?
check "uninstall succeeds ($out)" '[[ $rc == 0 && ! -e $L ]]'
check "edited entry kept" '[[ -f $ENTRY && $out == *"Kept $ENTRY"* ]]'
check "icon and link removed" '[[ ! -e $ICON && ! -L $H/.local/bin/maprisma ]]'
check "providers unit removed" '[[ ! -e $H/.config/systemd/user/maprisma-providers.service ]]'

# 8 an invalid receipt removes nothing
fresh
run "$T/a1/install.sh" --ignore-missing >/dev/null 2>&1
printf 'bin\tlink\t/etc/passwd\nevil\tsha256\t%s\n' "$(printf %064d 0)" >"$L/.install-receipt"
out=$(run "$L/uninstall.sh" 2>&1); rc=$?
check "invalid receipt refused ($out)" '[[ $rc != 0 && -d $L && -f $ICON ]]'

# 9 an interrupted install is rolled back completely by the next run (each step)
for at in staged prepared moved-old activated outer; do
  fresh
  run "$T/a1/install.sh" --ignore-missing >/dev/null 2>&1
  before=$(cd "$H" && find . -path ./.local/lib/maprisma -prune -o -print | sort | xargs -d '\n' sha256sum 2>/dev/null | sha256sum)
  run env MAPRISMA_INSTALL_TEST_FAIL_AT=$at "$T/a2/install.sh" --ignore-missing >/dev/null 2>&1
  out=$(run "$T/a1/install.sh" --ignore-missing 2>&1); rc=$?
  check "after a stop at $at: the next run succeeds ($out)" '[[ $rc == 0 ]]'
  check "after a stop at $at: version 1 in place" 'grep -q 1.0.0 "$L/data/flutter_assets/version.json" && grep -q 1.0.0 "$ICON"'
  check "after a stop at $at: no leftovers" '[[ -z $(leftovers) ]]'
done

# 9b recovery itself interrupted (after a stop at "outer"): running again still ends in the old state
for rat in recover-outer recover-folder recover-cleanup; do
  fresh
  run "$T/a1/install.sh" --ignore-missing >/dev/null 2>&1
  run env MAPRISMA_INSTALL_TEST_FAIL_AT=outer "$T/a2/install.sh" --ignore-missing >/dev/null 2>&1
  run env MAPRISMA_INSTALL_TEST_FAIL_AT=$rat "$T/a1/install.sh" --ignore-missing >/dev/null 2>&1
  out=$(run "$T/a1/install.sh" --ignore-missing 2>&1); rc=$?
  check "recovery stopped at $rat, then run again: succeeds ($out)" '[[ $rc == 0 ]]'
  check "recovery stopped at $rat: version 1 in place" 'grep -q 1.0.0 "$L/data/flutter_assets/version.json" && grep -q 1.0.0 "$ICON"'
  check "recovery stopped at $rat: no leftovers" '[[ -z $(leftovers) ]]'
done

# 9c a journal that names anything outside this install is refused; nothing is touched
fresh
run "$T/a1/install.sh" --ignore-missing >/dev/null 2>&1
mkdir -p "$T/victim"; echo keep >"$T/victim/file"
printf 'txn\tabcdef\nnew\t%s\n' "$L.new.abcdef/../../../victim" >"$H/.local/lib/.maprisma-install.journal"
out=$(run "$T/a2/install.sh" --ignore-missing 2>&1); rc=$?
check "forged journal refused ($out)" '[[ $rc != 0 && $out == *"journal"* && -f $T/victim/file ]]'
check "forged journal: install untouched" 'grep -q 1.0.0 "$L/data/flutter_assets/version.json"'
rm -f "$H/.local/lib/.maprisma-install.journal"
ln -s "$T/victim/file" "$H/.local/lib/.maprisma-install.journal"
out=$(run "$T/a2/install.sh" --ignore-missing 2>&1); rc=$?
check "journal symlink refused" '[[ $rc != 0 && $(cat "$T/victim/file") == keep ]]'
rm -f "$H/.local/lib/.maprisma-install.journal"

# 9d an incomplete journal (no bak) is refused before anything moves
fresh
run "$T/a1/install.sh" --ignore-missing >/dev/null 2>&1
printf 'txn\tabcdef\nouter\tbin\n' >"$H/.local/lib/.maprisma-install.journal"
out=$(run "$T/a2/install.sh" --ignore-missing 2>&1); rc=$?
check "incomplete journal refused ($out)" '[[ $rc != 0 && -L $H/.local/bin/maprisma ]]'
rm -f "$H/.local/lib/.maprisma-install.journal"

# 9e recovery's deletion of the activated folder cut short (its id file already gone): finished next time
fresh
run "$T/a1/install.sh" --ignore-missing >/dev/null 2>&1
run env MAPRISMA_INSTALL_TEST_FAIL_AT=activated "$T/a2/install.sh" --ignore-missing >/dev/null 2>&1
run env MAPRISMA_INSTALL_TEST_FAIL_AT=recover-folder "$T/a1/install.sh" --ignore-missing >/dev/null 2>&1
staged=$(ls -d "$L".new.* 2>/dev/null | head -1)
check "the activated folder was moved back to its staged name" '[[ -n $staged && ! -e $L ]]'
rm -f "$staged/.install-id" "$staged/maprisma"     # a deletion cut short
out=$(run "$T/a1/install.sh" --ignore-missing 2>&1); rc=$?
check "partial deletion finished, old restored, then installed ($out)" '[[ $rc == 0 ]] && grep -q 1.0.0 "$L/data/flutter_assets/version.json" && [[ -z $(leftovers) ]]'

# 9f a Maprisma running from the moved-away old folder blocks the next run (lock before recovery)
fresh
run "$T/a1/install.sh" --ignore-missing >/dev/null 2>&1
run env MAPRISMA_INSTALL_TEST_FAIL_AT=moved-old "$T/a2/install.sh" --ignore-missing >/dev/null 2>&1
oldd=$(ls -d "$L".old.* | head -1)
exec {held2}<"$oldd/data/instance.lock"; flock -s "$held2"
out=$(run "$T/a1/install.sh" --ignore-missing 2>&1); rc=$?
check "running old bundle blocks recovery ($out)" '[[ $rc != 0 && $out == *"is running"* && -d $oldd ]]'
exec {held2}<&-
out=$(run "$T/a1/install.sh" --ignore-missing 2>&1); rc=$?
check "then recovered and installed" '[[ $rc == 0 && -z $(leftovers) ]]'

# 10 custom XDG_DATA_HOME with a space
fresh
D="$H/my data"
out=$(env -i HOME="$H" XDG_DATA_HOME="$D" PATH="$PATH" USER=tester "${TESTENV[@]}" "$T/a1/install.sh" --ignore-missing 2>&1); rc=$?
check "custom XDG_DATA_HOME ($out)" '[[ $rc == 0 && -f "$D/applications/com.maprisma.Maprisma.desktop" ]]'
out=$(env -i HOME="$H" XDG_DATA_HOME="$D" PATH="$PATH" USER=tester "${TESTENV[@]}" "$L/uninstall.sh" 2>&1); rc=$?
check "uninstall with custom XDG_DATA_HOME" '[[ $rc == 0 && ! -e "$D/applications/com.maprisma.Maprisma.desktop" ]]'

# 11 --purge removes the settings
fresh
run "$T/a1/install.sh" --ignore-missing >/dev/null 2>&1
mkdir -p "$H/.config/maprisma"; echo '{}' >"$H/.config/maprisma/settings.json"
run "$L/uninstall.sh" --purge >/dev/null 2>&1
check "purge" '[[ ! -e $H/.config/maprisma ]]'

printf '%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))
