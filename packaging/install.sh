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
  [[ $(id -u) -eq 0 ]] || die "a system install needs root: sudo $0 ${action/uninstall/--uninstall} --system"
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
  for p in "$lib" "$bin" "$share/applications" "$share/metainfo" "$share/icons"; do
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
mkdir -p "$parent"
exec {install_lock}>>"$parent/.maprisma-install.lock"
flock -n "$install_lock" || die "another Maprisma install or uninstall is running: nothing was changed"
# A running Maprisma of this install holds data/instance.lock shared; we take it exclusively.
if [[ -f $lib/data/instance.lock ]]; then
  exec {instance_lock}<"$lib/data/instance.lock"
  flock -n -x "$instance_lock" || die "Maprisma is running (for you or another user): close it first; nothing was changed"
elif [[ -d $lib ]]; then
  for exe in /proc/[0-9]*/exe; do
    case $(readlink "$exe" 2>/dev/null) in "$lib"/*) die "Maprisma is running: close it first; nothing was changed" ;; esac
  done
fi

# ---------------------------------------------------------------- recovery of an interrupted run
# The journal lists what a run did; an unfinished one is rolled back to the complete old state.
recover() {
  [[ -f $journal ]] || return 0
  local key a b new="" old="" bak="" done=0
  local -a tmps=() outers=()
  while IFS=$'\t' read -r key a b; do
    case $key in
      new) new=$a ;; old) old=$a ;; bak) bak=$a ;; done) done=1 ;;
      tmp) tmps+=("$b") ;; outer) outers+=("$a") ;;
    esac
  done <"$journal"
  # only paths of this install (a journal is ours, but never trusted beyond our own folders)
  for p in "$new" "$old"; do [[ -z $p || $p == "$lib".new.* || $p == "$lib".old.* ]] || die "the install journal $journal is not valid: fix or remove it"; done
  [[ -z $bak || $bak == "$parent"/.maprisma-backup.* ]] || die "the install journal $journal is not valid: fix or remove it"
  if ((done)); then
    [[ -n $old ]] && rm -rf -- "$old"
  else
    say "Rolling back an install that did not finish…"
    for name in "${outers[@]}"; do
      case $name in bin|desktop|metainfo|icon) ;; *) continue ;; esac
      if [[ -e $bak/$name || -L $bak/$name ]]; then mv -fT -- "$bak/$name" "${target[$name]}"
      elif [[ -e $bak/$name.absent ]]; then rm -f -- "${target[$name]}"; fi
    done
    for t in "${tmps[@]}"; do [[ $t == */.maprisma-new.* ]] && rm -f -- "$t"; done
    if [[ -n $new && -e $new ]]; then
      rm -rf -- "$new"                                    # never activated
    elif [[ -n $new ]]; then
      rm -rf -- "$lib"                                    # activated: the new folder is $lib
    fi
    [[ -n $old && -e $old && ! -e $lib ]] && mv -T -- "$old" "$lib"
  fi
  [[ -n $bak ]] && rm -rf -- "$bak"
  rm -f -- "$journal"
  return 0
}
recover
note() { printf '%s\n' "$*" >>"$journal"; }
[[ -n ${MAPRISMA_INSTALL_TEST:-} && -n ${MAPRISMA_INSTALL_TEST_FAIL_AT:-} ]] && fail_at=$MAPRISMA_INSTALL_TEST_FAIL_AT || fail_at=""
step() { [[ $fail_at != "$1" ]] || { say "(test: stopping at $1)"; trap - EXIT; exit 99; }; }

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
ldd_out=$(for f in "$here/app/maprisma" "$here"/app/lib/*.so "$here/app/lib/maprisma-core"; do
  LD_LIBRARY_PATH="$here/app/lib" ldd "$f" 2>&1; done)
missing=$(awk '/=> not found/ {print $1}' <<<"$ldd_out" | sort -u | tr '\n' ' ')
grep -q "version \`GLIBC" <<<"$ldd_out" && blocker "the system's C library is older than this build needs"
ldconfig=$(command -v ldconfig || echo /sbin/ldconfig)
for so in libsqlite3.so.0 libzstd.so.1; do
  "$ldconfig" -p 2>/dev/null | awk -v so="$so" '$1 == so {found = 1} END {exit !found}' || missing+="$so "
done
if [[ -n ${missing// } ]]; then
  problem "missing libraries: $missing"
  . /etc/os-release 2>/dev/null || true
  case " ${ID:-} ${ID_LIKE:-} " in
    *" arch "*) hint="sudo pacman -S --needed gtk3 sqlite zstd" ;;
    *" debian "*|*" ubuntu "*) hint="sudo apt install libgtk-3-0t64 libsqlite3-0 libzstd1   (before 24.04: libgtk-3-0)" ;;
    *" fedora "*|*" rhel "*) hint="sudo dnf install gtk3 sqlite-libs libzstd" ;;
    *" suse "*|*" opensuse "*) hint="sudo zypper install libgtk-3-0 libsqlite3-0 libzstd1" ;;
    *) hint="GTK 3, SQLite and zstd from your package manager" ;;
  esac
  say "    Install them with:  $hint"
fi
# Another install of Maprisma that this one would shadow or fight with: never overridable.
pkg="" sys_app=/usr/lib/maprisma/maprisma
[[ -n ${MAPRISMA_INSTALL_TEST:-} && -n ${MAPRISMA_INSTALL_TEST_SYSAPP:-} ]] && sys_app=$MAPRISMA_INSTALL_TEST_SYSAPP
if [[ -e $sys_app ]]; then
  pkg=$(pacman -Qqo "$sys_app" 2>/dev/null || dpkg -S "$sys_app" 2>/dev/null | cut -d: -f1 ||
        rpm -qf "$sys_app" 2>/dev/null || true)
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
new=$(mktemp -d "$lib.new.XXXXXX")
bak=$(mktemp -d "$parent/.maprisma-backup.XXXXXX")
note "new	$new"
note "bak	$bak"
trap 'say "Install failed: rolling back."; recover; exit 1' ERR
trap 'recover' EXIT
cp -a "$here/app/." "$new/"
install -m755 "$here/uninstall.sh" "$new/uninstall.sh"
install -m755 "$0" "$new/.installer.sh"
install -m644 "$here/LICENSE" "$new/LICENSE"
chmod 755 "$new"
# the staged copy must load
if LD_LIBRARY_PATH="$new/lib" ldd "$new/maprisma" "$new/lib/maprisma-core" 2>&1 | grep -q "version \`GLIBC"; then
  false
fi
step staged

desktop_exec() { # quoted for a desktop file: spaces, quotes, $, `, \ and % escaped
  local v=$1
  v=${v//\\/\\\\}; v=${v//\"/\\\"}; v=${v//\$/\\\$}; v=${v//\`/\\\`}; v=${v//%/%%}; v=${v//\\/\\\\}
  printf '"%s"' "$v"
}
declare -A tmp=()
for name in desktop metainfo icon; do
  tmp[$name]=$(mktemp "$(dirname "${target[$name]}")/.maprisma-new.XXXXXX")
  note "tmp	$name	${tmp[$name]}"
done
{
  grep -v -e '^Exec=' -e '^TryExec=' "$here/share/applications/$APP_ID.desktop"
  printf 'Exec=%s\nTryExec=%s\nX-Maprisma-Install=%s\n' "$(desktop_exec "$lib/maprisma")" "$lib/maprisma" "$lib"
} >"${tmp[desktop]}"
cat "$here/share/metainfo/$APP_ID.metainfo.xml" >"${tmp[metainfo]}"
cat "$here/share/icons/hicolor/scalable/apps/$APP_ID.svg" >"${tmp[icon]}"
chmod 644 "${tmp[desktop]}" "${tmp[metainfo]}" "${tmp[icon]}"
{
  printf 'bin\tlink\t%s\n' "$lib/maprisma"
  for name in desktop metainfo icon; do printf '%s\tsha256\t%s\n' "$name" "$(sha256sum "${tmp[$name]}" | cut -d' ' -f1)"; done
} >"$new/.install-receipt"
chmod 644 "$new/.install-receipt"
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
note "outer	bin"
ln -sfnT -- "$lib/maprisma" "$bin/.maprisma-new.$$" && mv -fT -- "$bin/.maprisma-new.$$" "${target[bin]}"
for name in desktop metainfo icon; do
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
case ":$PATH:" in
  *":$bin:"*) say "Start it with: maprisma" ;;
  *) say "Start it from the menu or with: $lib/maprisma   ($bin is not in your PATH)" ;;
esac
# What some features need (not required to start).
declare -A feature=([curl]="downloads of agents, models and updates" [tar]="installing local LLMs" [setsid]="starting programs"
  [xdg-open]="opening links and the manual" [notify-send]="limit warnings" [wl-paste]="pasting into agent terminals"
  [ss]="the traffic view")
for tool in curl tar setsid xdg-open notify-send wl-paste ss; do
  command -v "$tool" >/dev/null || say "  ! $tool is not installed: needed for ${feature[$tool]}"
done
say "Remove it with: $lib/uninstall.sh$( ((system)) && echo '   (as root)')"
say "The bar icon is Maprisma Control: github.com/maprisma/control (its own release)."
