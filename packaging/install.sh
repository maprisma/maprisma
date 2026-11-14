#!/usr/bin/env bash
# Install Maprisma from the unpacked release archive (maprisma-<version>-x86_64.tar.gz):
#
#   ./install.sh                  for you, no root: ~/.local/lib/maprisma, ~/.local/bin/maprisma,
#                                 the menu entry and icon in ~/.local/share
#   sudo ./install.sh --system    for every user: /opt/maprisma, /usr/local/bin, /usr/local/share
#   --ignore-missing              install although libraries are missing (dependencies only)
#
# Remove it with <folder>/uninstall.sh (as root for --system; --purge also removes your settings).
# What it writes outside its folder is fixed (the command, the menu entry, the metainfo, the icon) and
# recorded with checksums in <folder>/.install-receipt: nothing else is ever replaced or removed, and a
# file you changed is kept. An earlier install is replaced as a whole, or nothing changes.
set -euo pipefail
umask 022

APP_ID=com.maprisma.Maprisma
NAMES=(bin desktop metainfo icon)

say() { printf '%s\n' "$*"; }
die() { printf 'Maprisma: %s\n' "$*" >&2; exit 1; }

action=install system=0 ignore_missing=0 purge=0 folder=""
while (($#)); do
  case $1 in
    --system) system=1 ;;
    --ignore-missing) ignore_missing=1 ;;
    --uninstall) action=uninstall ;;
    --purge) purge=1 ;;
    --folder) folder=${2:-}; shift ;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option $1 (see --help)" ;;
  esac
  shift
done

# ---------------------------------------------------------------- where (fixed by the mode, never read)
if [[ $action == uninstall ]]; then
  [[ -n $folder ]] || die "uninstall needs --folder (run <folder>/uninstall.sh)"
  [[ $folder == /opt/maprisma ]] && system=1
fi
if ((system)); then
  if [[ $(id -u) -ne 0 ]]; then
    [[ $action == uninstall ]] && die "removing a system install needs root: sudo $folder/uninstall.sh"
    die "a system install needs root: sudo $0 --system"
  fi
  lib=/opt/maprisma bin=/usr/local/bin share=/usr/local/share
else
  [[ $(id -u) -ne 0 ]] || die "as root, use --system (or run it as your user for a personal install)"
  [[ $HOME == /* ]] || die "HOME is not an absolute path"
  data_home=${XDG_DATA_HOME:-}
  [[ $data_home == /* ]] || data_home=$HOME/.local/share
  lib=$HOME/.local/lib/maprisma bin=$HOME/.local/bin share=$data_home
fi
if [[ $action == uninstall && $folder != "$lib" ]]; then
  die "$folder is not where this installer puts Maprisma ($lib): nothing was removed"
fi
parent=$(dirname "$lib")
declare -A target=(
  [bin]=$bin/maprisma
  [desktop]=$share/applications/$APP_ID.desktop
  [metainfo]=$share/metainfo/$APP_ID.metainfo.xml
  [icon]=$share/icons/hicolor/scalable/apps/$APP_ID.svg
)
journal=$parent/.maprisma-install.journal

# Root acts only on root-owned folders nobody else can write, never through a link.
root_safe() { # path
  local p=$1
  while [[ $p != / ]]; do
    if [[ -e $p || -L $p ]]; then
      [[ ! -L $p ]] || return 1
      [[ $(stat -c %u "$p") == 0 ]] || return 1
      (( (8#$(stat -c %a "$p") & 8#022) == 0 )) || return 1
    fi
    p=$(dirname "$p")
  done
}
if ((system)); then
  for p in "$lib" "$bin" "$share/applications" "$share/metainfo" "$share/icons/hicolor/scalable/apps"; do
    root_safe "$p" || die "$p (or a folder above it) is not root-owned or is writable by others: nothing was changed"
  done
fi

# ---------------------------------------------------------------- the receipt: data, never sourced
declare -A rkind=() rval=()
receipt_ok=0
read_receipt() { # file -> rkind/rval, receipt_ok
  rkind=() rval=() receipt_ok=0
  local file=$1 name kind value extra n=0
  [[ -f $file && ! -L $file ]] || return 0
  if ((system)) || [[ $(id -u) -eq 0 ]]; then
    [[ $(stat -c %u "$file") == 0 ]] && (( (8#$(stat -c %a "$file") & 8#022) == 0 )) || return 0
  else
    [[ $(stat -c %u "$file") == "$(id -u)" ]] || return 0
  fi
  while IFS= read -r line || [[ -n $line ]]; do
    n=$((n + 1))
    ((n <= 8)) || return 0
    IFS=$'\t' read -r name kind value extra <<<"$line"
    [[ -z ${extra:-} && -n ${value:-} ]] || return 0
    case $name in bin|desktop|metainfo|icon) ;; *) return 0 ;; esac
    [[ -z ${rkind[$name]:-} ]] || return 0
    case $kind in
      sha256) [[ $value =~ ^[0-9a-f]{64}$ ]] || return 0 ;;
      link) [[ $value == /* && $value != *$'\n'* ]] || return 0 ;;
      *) return 0 ;;
    esac
    rkind[$name]=$kind rval[$name]=$value
  done <"$file"
  receipt_ok=1
}
# Is the file at a target still exactly what the receipt recorded?
ours() { # name
  local name=$1 t=${target[$1]}
  ((receipt_ok)) && [[ -n ${rkind[$name]:-} ]] || return 1
  case ${rkind[$name]} in
    link) [[ -L $t && $(readlink "$t") == "${rval[$name]}" ]] ;;
    sha256) [[ -f $t && ! -L $t && $(sha256sum "$t" | cut -d' ' -f1) == "${rval[$name]}" ]] ;;
  esac
}

# ---------------------------------------------------------------- locks
# A refused install leaves nothing behind: the folders and the lock file made only for the lock go
# again (drop_lock, until the transaction starts); an uninstall removes the lock file at its end.
made_dirs=$(LC_ALL=C mkdir -pv -- "$parent" | sed -n "s/^mkdir: created directory '\(.*\)'$/\1/p")
lock_file=$parent/.maprisma-install.lock
lock_made=0; [[ -e $lock_file ]] || lock_made=1
exec {install_lock}>>"$lock_file"
drop_lock() {
  ((lock_made)) && rm -f -- "$lock_file"
  local d
  while IFS= read -r d; do [[ -n $d ]] && rmdir -- "$d" 2>/dev/null; done < <(tac <<<"$made_dirs")
  return 0
}
trap drop_lock EXIT
flock -n "$install_lock" || { lock_made=0; made_dirs=""; die "another Maprisma install or uninstall is running: nothing was changed"; }
# A running Maprisma holds <bundle>/data/instance.lock shared; we take it exclusively, for the old
# bundle now and for the new one before it is activated (the descriptors follow the folders' renames).
lock_instance() { # bundle folder
  local fd
  [[ -f $1/data/instance.lock && ! -L $1/data/instance.lock ]] || return 0
  exec {fd}<"$1/data/instance.lock"
  flock -n -x "$fd"
}
# Every bundle this run or an interrupted one may touch: $lib and leftovers of a run. The locks
# follow the folders through recovery's renames.
for d in "$lib" "$lib".old.* "$lib".new.*; do
  [[ -d $d && ! -L $d ]] || continue
  lock_instance "$d" || die "Maprisma is running (for you or another user): close it first; nothing was changed"
done
if [[ -d $lib && ! -f $lib/data/instance.lock ]]; then
  for exe in /proc/[0-9]*/exe; do
    case $(readlink "$exe" 2>/dev/null) in "$lib"/*) die "Maprisma is running: close it first; nothing was changed" ;; esac
  done
fi

# Tests only (MAPRISMA_INSTALL_TEST=1): stop at a named step, as a crash there would.
[[ -n ${MAPRISMA_INSTALL_TEST:-} && -n ${MAPRISMA_INSTALL_TEST_FAIL_AT:-} ]] && fail_at=$MAPRISMA_INSTALL_TEST_FAIL_AT || fail_at=""
step() { [[ $fail_at != "$1" ]] || { say "(test: stopping at $1)"; trap - EXIT; exit 99; }; }

# ---------------------------------------------------------------- recovery of an interrupted run
# The journal lists what a run did, each staged folder carries the run's id (.install-id): an
# unfinished run is rolled back to the complete old state, a finished one cleaned up. Every step
# looks at the state first, so an interrupted recovery can simply run again.
own_uid=$(id -u)
id_re='[A-Za-z0-9]{6}'
re_quote() { printf '%s' "$1" | sed 's/[][\.*^$+?(){}|/]/\\&/g'; }
lib_re=$(re_quote "$lib") parent_re=$(re_quote "$parent")
private_file() { # a regular file of ours (root's for --system) nobody else can write
  [[ -f $1 && ! -L $1 && $(stat -c %u "$1") == "$own_uid" ]] && (( (8#$(stat -c %a "$1") & 8#022) == 0 ))
}
txn_of() { [[ -f $1/.install-id && ! -L $1/.install-id ]] && head -c 64 "$1/.install-id" || true; }
recover() {
  [[ -e $journal || -L $journal ]] || return 0
  private_file "$journal" || die "the install journal $journal is not a private file of yours: check and remove it"
  local key a b extra txn="" new="" old="" bak="" done=0 n=0
  local -A tmp_of=() outer=()
  while IFS=$'\t' read -r key a b extra || [[ -n ${key:-} ]]; do
    n=$((n + 1)); ((n <= 32)) && [[ -z ${extra:-} ]] || die "the install journal $journal is not valid: check and remove it"
    case $key in
      txn) [[ -z $txn && $a =~ ^$id_re$ && -z $b ]] || die "the install journal $journal is not valid" ; txn=$a ;;
      new) [[ -z $new && $a =~ ^$lib_re\.new\.$id_re$ ]] || die "the install journal $journal is not valid"; new=$a ;;
      old) [[ -z $old && $a =~ ^$lib_re\.old\.$id_re$ ]] || die "the install journal $journal is not valid"; old=$a ;;
      bak) [[ -z $bak && $a =~ ^$parent_re/\.maprisma-backup\.$id_re$ ]] || die "the install journal $journal is not valid"; bak=$a ;;
      tmp) [[ -n ${target[$a]:-} && -z ${tmp_of[$a]:-} && $b =~ ^$(re_quote "$(dirname "${target[$a]}")")/\.maprisma-new\.$id_re$ ]] ||
             die "the install journal $journal is not valid"; tmp_of[$a]=$b ;;
      outer) [[ -n ${target[$a]:-} && -z ${outer[$a]:-} ]] || die "the install journal $journal is not valid"; outer[$a]=1 ;;
      done) ((!done)) || die "the install journal $journal is not valid"; done=1 ;;
      *) die "the install journal $journal is not valid" ;;
    esac
  done <"$journal"
  # written whole before anything else happens: txn, new and bak are always there
  [[ -n $txn && -n $new && -n $bak ]] || die "the install journal $journal is not valid: check and remove it"
  if ((done)); then
    [[ -n $old && -d $old && $(txn_of "$old") != "$txn" ]] && rm -rf -- "$old"
  else
    say "Rolling back an install that did not finish…"
    # Outer files back as they were, but only while they are still what this run wrote (its
    # receipt, in its folder): a file changed since the interruption is kept.
    local txn_dir=""
    if [[ -d $lib && $(txn_of "$lib") == "$txn" ]]; then txn_dir=$lib; elif [[ -d $new ]]; then txn_dir=$new; fi
    receipt_ok=0
    [[ -n $txn_dir ]] && read_receipt "$txn_dir/.install-receipt"
    for name in "${!outer[@]}"; do
      local t=${target[$name]}
      if [[ -e $t || -L $t ]] && ! ours "$name"; then
        say "Kept $t: it was changed after the interrupted install."
        continue
      fi
      if [[ -e $bak/$name || -L $bak/$name ]]; then mv -fT -- "$bak/$name" "$t"
      elif [[ -e $bak/$name.absent ]]; then rm -f -- "$t"; fi
    done
    step recover-outer
    for name in "${!tmp_of[@]}"; do rm -f -- "${tmp_of[$name]}"; done
    # the folder: $lib is the new one only when it carries this run's id
    # (moved back to its staged name first: a deletion cut short is finished by the next run)
    if [[ -d $lib && ! -e $new && $(txn_of "$lib") == "$txn" ]]; then mv -T -- "$lib" "$new"; fi
    step recover-folder
    if [[ -d $new ]]; then rm -rf -- "$new"; fi
    if [[ ! -e $lib && -n $old && -d $old ]]; then mv -T -- "$old" "$lib"; fi
  fi
  step recover-cleanup
  [[ -n $bak && -d $bak ]] && rm -rf -- "$bak"
  rm -f -- "$journal"
  return 0
}
recover
note() { printf '%s\n' "$*" >>"$journal"; }

# ---------------------------------------------------------------- uninstall
if [[ $action == uninstall ]]; then
  [[ -d $lib && ! -L $lib ]] || die "$lib is not there"
  read_receipt "$lib/.install-receipt"
  ((receipt_ok)) || die "$lib/.install-receipt is missing or not valid: nothing was removed"
  for name in "${NAMES[@]}"; do
    t=${target[$name]}
    if ours "$name"; then rm -f -- "$t"
    elif [[ -e $t || -L $t ]]; then say "Kept $t: it was changed or replaced since the install."; fi
  done
  if ((!system)); then
    unit=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/maprisma-providers.service
    if [[ -f $unit ]] && grep -qF "ExecStart=$lib/lib/maprisma-core " "$unit"; then
      systemctl --user disable --now maprisma-providers.service >/dev/null 2>&1 || true
      rm -f -- "$unit"
      systemctl --user daemon-reload >/dev/null 2>&1 || true
      say "Removed your providers service (it ran this install's core)."
    fi
  fi
  rm -rf -- "$lib"
  lock_made=1 made_dirs=""   # the lock file goes with the install (drop_lock at exit)
  command -v update-desktop-database >/dev/null && update-desktop-database -q "$share/applications" 2>/dev/null || true
  command -v gtk-update-icon-cache >/dev/null && gtk-update-icon-cache -q -t "$share/icons/hicolor" 2>/dev/null || true
  if ((system)); then
    say "Each user who used Maprisma may still have a providers service that ran it; they remove it with:"
    say "  systemctl --user disable --now maprisma-providers.service; rm ~/.config/systemd/user/maprisma-providers.service"
  elif ((purge)); then
    for d in "${XDG_CONFIG_HOME:-$HOME/.config}/maprisma" "${XDG_DATA_HOME:-$HOME/.local/share}/maprisma" \
             "${XDG_CACHE_HOME:-$HOME/.cache}/maprisma" "${XDG_STATE_HOME:-$HOME/.local/state}/maprisma"; do
      [[ -d $d && ! -L $d ]] && rm -rf -- "$d" && say "Removed $d"
    done
  fi
  say "Maprisma was removed.$( ((system || purge)) || echo ' Your settings stay in ~/.config/maprisma (--purge removes them).')"
  exit 0
fi

# ---------------------------------------------------------------- install: checks, nothing written yet
here=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
[[ -x $here/app/maprisma && -x $here/app/lib/maprisma-core && -f $here/glibc ]] ||
  die "run install.sh from the unpacked release archive (app/ and glibc are missing next to it)"
version=$(sed -n 's/.*"version" *: *"\([^"]*\)".*/\1/p' "$here/app/data/flutter_assets/version.json" 2>/dev/null | head -1)
say "Maprisma ${version:-?}: checking this system"
problems=0
problem() { printf '  ✗ %s\n' "$*"; problems=$((problems + 1)); }
blockers=0
blocker() { printf '  ✗ %s\n' "$*"; blockers=$((blockers + 1)); }

[[ $(uname -m) == x86_64 ]] || blocker "this build is for x86_64; this computer is $(uname -m)"
need=$(tr -d '[:space:]' <"$here/glibc")
have=$(getconf GNU_LIBC_VERSION 2>/dev/null | awk '{print $2}')
if [[ -z $have ]]; then
  blocker "no GNU C library (glibc) found: musl systems are not supported"
elif [[ $(printf '%s\n%s\n' "$need" "$have" | sort -V | head -1) != "$need" ]]; then
  blocker "glibc $have is too old: this build needs $need or newer"
fi
# every ELF file of the bundle: missing libraries and too old versions of present ones
ldd_all() { # bundle folder -> ldd output of every ELF in it
  local f
  while IFS= read -r -d '' f; do
    [[ $(head -c 4 "$f" | od -An -c | tr -d ' ') == 177ELF ]] || continue
    # -r: also symbols a library of this system lacks (e.g. too old a GLib)
    LD_LIBRARY_PATH="$1/lib" ldd -r "$f" 2>&1 || true
  done < <(find "$1" -type f -print0)
}
ldd_out=$(ldd_all "$here/app")
missing=$(awk '/=> not found/ {print $1}' <<<"$ldd_out" | sort -u | tr '\n' ' ')
too_old=$(grep -o "version \`[^']*' not found" <<<"$ldd_out" | sort -u | tr '\n' ' ' || true)
[[ -z $too_old ]] || blocker "the system's libraries are older than this build needs: $too_old"
# (only meaningful when every library is there: a missing one leaves its symbols undefined too)
if [[ -z ${missing// } ]]; then
  undefined=$(grep -o 'undefined symbol: [A-Za-z0-9_]*' <<<"$ldd_out" | sort -u | head -5 | tr '\n' ' ' || true)
  [[ -z $undefined ]] || blocker "this system's libraries lack what this build needs (too old?): $undefined"
fi
ldconfig=$(command -v ldconfig || echo /sbin/ldconfig)
# loaded at run time, not linked: SQLite and zstd by the core, EGL and GLES by Flutter's renderer
for so in libsqlite3.so.0 libzstd.so.1 libEGL.so.1 libGLESv2.so.2; do
  "$ldconfig" -p 2>/dev/null | awk -v so="$so" '$1 == so {found = 1} END {exit !found}' || missing+="$so "
done
if [[ -n ${missing// } ]]; then
  problem "missing libraries: $missing"
  . /etc/os-release 2>/dev/null || true
  case " ${ID:-} ${ID_LIKE:-} " in
    *" arch "*) hint="sudo pacman -S --needed gtk3 sqlite zstd libglvnd" ;;
    *" debian "*|*" ubuntu "*) hint="sudo apt install libgtk-3-0t64 libsqlite3-0 libzstd1 libegl1 libgles2   (before 24.04: libgtk-3-0)" ;;
    *" fedora "*|*" rhel "*) hint="sudo dnf install gtk3 sqlite-libs libzstd libglvnd-egl libglvnd-gles" ;;
    *" suse "*|*" opensuse "*) hint="sudo zypper install libgtk-3-0 libsqlite3-0 libzstd1 libEGL1 libGLESv2-2" ;;
    *) hint="GTK 3, SQLite, zstd, EGL and GLES from your package manager" ;;
  esac
  say "    Install them with:  $hint"
fi
# Another install of Maprisma that this one would shadow or fight with: never overridable.
pkg="" sys_app=/usr/lib/maprisma/maprisma
[[ -n ${MAPRISMA_INSTALL_TEST:-} && -n ${MAPRISMA_INSTALL_TEST_SYSAPP:-} ]] && sys_app=$MAPRISMA_INSTALL_TEST_SYSAPP
if [[ -e $sys_app ]]; then
  pkg=$(pacman -Qqo "$sys_app" 2>/dev/null) || pkg=$(dpkg -S "$sys_app" 2>/dev/null) || pkg=$(rpm -qf "$sys_app" 2>/dev/null) || pkg=""
  pkg=${pkg%%:*}
  if [[ -n $pkg ]]; then
    blocker "Maprisma is installed as the package $pkg: remove it first (two installs would show two menu entries)"
  else
    say "  ! $(dirname "$sys_app") exists but belongs to no package: it is left alone"
  fi
fi
settings_state=${XDG_STATE_HOME:-$HOME/.local/state}
for s in maprisma-settings maprisma-manager; do
  [[ -f $settings_state/$s/installed/maprisma.json ]] &&
    blocker "Maprisma Settings manages your Maprisma: update or remove it there instead" && break
done
# Files in the places we write: only ours (by the receipt) may be replaced.
read_receipt "$lib/.install-receipt"
if [[ -e $lib || -L $lib ]] && ! ((receipt_ok)); then
  blocker "$lib exists but is no install of this installer (no valid receipt): nothing is replaced"
fi
for name in "${NAMES[@]}"; do
  t=${target[$name]}
  if [[ -e $t || -L $t ]] && ! ours "$name"; then
    blocker "$t exists and is not this installer's (or was changed): remove or rename it first"
  fi
done
if ((blockers)); then say "Nothing was installed."; exit 1; fi
if ((problems)); then
  if ((ignore_missing)); then say "Installing anyway (--ignore-missing): Maprisma will not start until they are installed."
  else say "Nothing was installed. Install the libraries, or install anyway with --ignore-missing."; exit 1; fi
fi

# ---------------------------------------------------------------- install: the transaction
mkdir -p "$bin" "$(dirname "${target[desktop]}")" "$(dirname "${target[metainfo]}")" "$(dirname "${target[icon]}")"
if ((system)); then   # again, now that they exist
  for name in "${NAMES[@]}"; do
    root_safe "$(dirname "${target[$name]}")" || die "$(dirname "${target[$name]}") is not root-owned or is writable by others: nothing was changed"
  done
fi
txn=$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')   # 6 hex digits, no SIGPIPE under pipefail
new=$(mktemp -u "$lib.new.XXXXXX")
bak=$(mktemp -u "$parent/.maprisma-backup.XXXXXX")
# the journal appears whole (renamed into place) before the folders it names exist
printf 'txn\t%s\nnew\t%s\nbak\t%s\n' "$txn" "$new" "$bak" >"$journal.tmp"
mv -fT -- "$journal.tmp" "$journal"
mkdir -m 700 -- "$new"
printf '%s\n' "$txn" >"$new/.install-id"     # first: recovery knows the folder by it
mkdir -m 700 -- "$bak"
lock_made=0 made_dirs=""   # installed from here on: the lock file stays with the install
trap 'say "Install failed: rolling back."; recover; exit 1' ERR
trap 'recover' EXIT
cp -R --preserve=mode,timestamps,links --no-preserve=ownership -- "$here/app/." "$new/"
install -m755 "$here/uninstall.sh" "$new/uninstall.sh"
install -m755 "$0" "$new/.installer.sh"
install -m644 "$here/LICENSE" "$new/LICENSE"
chmod -R go-w "$new"
chmod 755 "$new"
((system)) && chown -R 0:0 "$new"
# the staged copy must load (every ELF), and its core must start
staged=$(ldd_all "$new")
if grep -q "=> not found\|version \`[^']*' not found\|undefined symbol" <<<"$staged" && ! ((ignore_missing)); then
  say "The installed copy does not load:"; grep "not found" <<<"$staged" | sort -u | head -5
  false
fi
# an unknown subcommand: 64 (or 0) from a core that loaded; 127 when the loader fails
core_rc=0
"$new/lib/maprisma-core" --installer-check </dev/null >/dev/null 2>&1 || core_rc=$?
if ! ((ignore_missing)) && [[ $core_rc != 0 && $core_rc != 64 ]]; then
  say "The installed copy's core does not start (exit $core_rc)."; false
fi
lock_instance "$new"   # a Maprisma started from the new folder waits until we are done
step staged

desktop_exec() { # quoted for a desktop file: spaces, quotes, $, `, \ and % escaped
  local v=$1
  v=${v//\\/\\\\}; v=${v//\"/\\\"}; v=${v//\$/\\\$}; v=${v//\`/\\\`}; v=${v//%/%%}; v=${v//\\/\\\\}
  printf '"%s"' "$v"
}
declare -A tmp=()
for name in "${NAMES[@]}"; do
  tmp[$name]=$(mktemp -u "$(dirname "${target[$name]}")/.maprisma-new.XXXXXX")
  note "tmp	$name	${tmp[$name]}"
done
ln -sT -- "$lib/maprisma" "${tmp[bin]}"
(
  umask 022
  set -o noclobber
  {
    grep -v -e '^Exec=' -e '^TryExec=' "$here/share/applications/$APP_ID.desktop"
    printf 'Exec=%s\nTryExec=%s\nX-Maprisma-Install=%s\n' "$(desktop_exec "$lib/maprisma")" "$lib/maprisma" "$lib"
  } >"${tmp[desktop]}"
  cat "$here/share/metainfo/$APP_ID.metainfo.xml" >"${tmp[metainfo]}"
  cat "$here/share/icons/hicolor/scalable/apps/$APP_ID.svg" >"${tmp[icon]}"
)
{
  printf 'bin\tlink\t%s\n' "$lib/maprisma"
  for name in desktop metainfo icon; do printf '%s\tsha256\t%s\n' "$name" "$(sha256sum "${tmp[$name]}" | cut -d' ' -f1)"; done
} >"$new/.install-receipt"
chmod 644 "$new/.install-receipt"
((system)) && chown 0:0 "$new/.install-receipt"
# backups of what is there now (ours, checked above)
for name in "${NAMES[@]}"; do
  t=${target[$name]}
  if [[ -e $t || -L $t ]]; then cp -P -- "$t" "$bak/$name"; else : >"$bak/$name.absent"; fi
done
step prepared

old=""
if [[ -e $lib ]]; then
  old=$(mktemp -u "$lib.old.XXXXXX")
  note "old	$old"
  mv -T -- "$lib" "$old"
  step moved-old
fi
mv -T -- "$new" "$lib"
step activated
for name in "${NAMES[@]}"; do
  note "outer	$name"
  mv -fT -- "${tmp[$name]}" "${target[$name]}"
done
step outer
note "done"
trap - ERR EXIT
recover   # finishes: the old folder and the backups go
command -v update-desktop-database >/dev/null && update-desktop-database -q "$share/applications" 2>/dev/null || true
command -v gtk-update-icon-cache >/dev/null && gtk-update-icon-cache -q -t "$share/icons/hicolor" 2>/dev/null || true

say "Done: Maprisma ${version:-} is in your app menu."
# COSMIC's dock reads the menu entries once per login: until the next one it shows a gear for it.
case ":${XDG_CURRENT_DESKTOP:-}:" in
  *:COSMIC:*) say "COSMIC shows Maprisma's icon in the dock after your next login." ;;
esac
case ":$PATH:" in
  *":$bin:"*) say "Start it with: maprisma" ;;
  *) say "Start it from the menu or with: $lib/maprisma   ($bin is not in your PATH)" ;;
esac
# A desktop without any font (a bare Hyprland) shows every text as boxes.
if command -v fc-list >/dev/null && [[ -z $(fc-list 2>/dev/null | head -1) ]]; then
  say "  ! No font is installed: Maprisma's text would show as boxes. Install one, e.g. noto-fonts (Arch),"
  say "    fonts-noto-core (Debian, Ubuntu) or google-noto-sans-fonts (Fedora)."
fi
# What some features need (not required to start).
declare -A feature=([curl]="downloads of agents, models and updates" [tar]="installing local LLMs" [setsid]="starting programs"
  [xdg-open]="opening links and the manual" [notify-send]="limit warnings" [wl-paste]="pasting into agent terminals"
  [ss]="the traffic view")
for tool in curl tar setsid xdg-open notify-send wl-paste ss; do
  command -v "$tool" >/dev/null || say "  ! $tool is not installed: needed for ${feature[$tool]}"
done
say "Remove it with: $lib/uninstall.sh$( ((system)) && echo '   (as root)')"
say "The bar icon is Maprisma Control: github.com/maprisma/control (its own release)."
