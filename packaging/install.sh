#!/usr/bin/env bash
# Install Maprisma from the release archive (maprisma-<version>-x86_64.tar.gz), unpacked:
#
#   ./install.sh            for you (no root): ~/.local/lib/maprisma, ~/.local/bin/maprisma,
#                           the menu entry and icon in ~/.local/share
#   sudo ./install.sh --system
#                           for every user: /opt/maprisma, /usr/local/bin/maprisma, /usr/local/share
#   --force                 install although libraries are missing or a package install exists
#
# An earlier install in the same place is replaced as a whole. What it wrote outside its folder is
# listed in <folder>/.install-manifest; <folder>/uninstall.sh removes exactly that.
set -euo pipefail

system=0 force=0
for arg in "$@"; do
  case $arg in
    --system) system=1 ;;
    --force) force=1 ;;
    -h|--help) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "install.sh: unknown option $arg (see --help)" >&2; exit 2 ;;
  esac
done

here=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
app_id=com.maprisma.Maprisma
[[ -x $here/app/maprisma && -x $here/app/lib/maprisma-core ]] || {
  echo "install.sh: run it from the unpacked archive (app/maprisma is missing next to it)" >&2; exit 1; }
version=$(sed -n 's/.*"version" *: *"\([^"]*\)".*/\1/p' "$here/app/data/flutter_assets/version.json" 2>/dev/null | head -1)

if (( system )); then
  [[ $(id -u) -eq 0 ]] || { echo "install.sh --system needs root: sudo ./install.sh --system" >&2; exit 1; }
  lib=/opt/maprisma bin=/usr/local/bin share=/usr/local/share
else
  [[ $(id -u) -ne 0 ]] || { echo "install.sh: as root, use --system (or run it as your user for a personal install)" >&2; exit 1; }
  lib=$HOME/.local/lib/maprisma bin=$HOME/.local/bin share=${XDG_DATA_HOME:-$HOME/.local/share}
fi

say() { printf '%s\n' "$*"; }
problem() { printf '  ✗ %s\n' "$*"; problems=$((problems + 1)); }
problems=0

# 1. The system: x86_64, glibc ≥ 2.34, every library the bundle links to.
say "Maprisma ${version:-?}: checking this system"
[[ $(uname -m) == x86_64 ]] || problem "this build is for x86_64, this machine is $(uname -m)"
glibc=$(getconf GNU_LIBC_VERSION 2>/dev/null | awk '{print $2}')
if [[ -z $glibc ]]; then
  problem "no GNU C library found (musl systems are not supported)"
elif [[ $(printf '%s\n2.34\n' "$glibc" | sort -V | head -1) != 2.34 ]]; then
  problem "glibc $glibc is too old (2.34 or newer is needed)"
fi
missing=$(
  for f in "$here/app/maprisma" "$here"/app/lib/*.so "$here/app/lib/maprisma-core"; do
    LD_LIBRARY_PATH="$here/app/lib" ldd "$f" 2>/dev/null | awk '/not found/ {print $1}'
  done | sort -u)
if [[ -n $missing ]]; then
  problem "missing libraries: $(echo $missing)"
  . /etc/os-release 2>/dev/null || true
  case " ${ID:-} ${ID_LIKE:-} " in
    *" arch "*) hint="sudo pacman -S --needed gtk3" ;;
    *" debian "*|*" ubuntu "*) hint="sudo apt install libgtk-3-0t64   (older releases: libgtk-3-0)" ;;
    *" fedora "*|*" rhel "*) hint="sudo dnf install gtk3" ;;
    *" suse "*|*" opensuse "*) hint="sudo zypper install libgtk-3-0" ;;
    *) hint="install GTK 3 with your package manager" ;;
  esac
  say "    Maprisma's window needs GTK 3. Install it with:  $hint"
fi
if [[ -e /usr/lib/maprisma/maprisma ]]; then
  problem "Maprisma is installed as a package already (/usr/lib/maprisma, e.g. maprisma-bin): two installs would show two menu entries"
fi
command -v curl >/dev/null || say "  ! curl is not installed: Maprisma uses it for every download (agents, models, updates)"
if (( problems )); then
  if (( force )); then
    say "Installing anyway (--force)."
  else
    say "Nothing was installed. Fix the above, or install anyway with --force."
    exit 1
  fi
fi

# 2. The bundle: a new folder next to the old one, then swapped in.
say "Installing into $lib"
parent=$(dirname "$lib")
mkdir -p "$parent" "$bin" "$share/applications" "$share/metainfo" "$share/icons/hicolor/scalable/apps"
new=$(mktemp -d "$lib.new.XXXXXX")
trap 'rm -rf -- "$new"' EXIT
cp -a "$here/app/." "$new/"
cp -a "$here/uninstall.sh" "$new/uninstall.sh"
cp -a "$here/LICENSE" "$new/LICENSE"
chmod 755 "$new"
old=""
if [[ -e $lib ]]; then
  [[ -f $lib/.install-manifest ]] || {
    echo "install.sh: $lib exists but was not made by this installer: nothing was changed" >&2; exit 1; }
  old=$(mktemp -u "$lib.old.XXXXXX")
  mv -- "$lib" "$old"
fi
if ! mv -- "$new" "$lib"; then
  [[ -n $old ]] && mv -- "$old" "$lib"
  echo "install.sh: the new folder could not be put in place: the old install is unchanged" >&2
  exit 1
fi
trap - EXIT
[[ -n $old ]] && rm -rf -- "$old"

# 3. The command, the menu entry, the icon; each listed in the manifest.
manifest=$lib/.install-manifest
: > "$manifest"
ln -sfn "$lib/maprisma" "$bin/maprisma" && echo "$bin/maprisma" >> "$manifest"
# Exec quoted for the desktop file (spaces, quotes, $, `, \ and % escaped).
desktop_exec() {
  local v=$1
  v=${v//\\/\\\\}; v=${v//\"/\\\"}; v=${v//\$/\\\$}; v=${v//\`/\\\`}; v=${v//%/%%}; v=${v//\\/\\\\}
  printf '"%s"' "$v"
}
entry=$share/applications/$app_id.desktop
{
  grep -v -e '^Exec=' -e '^TryExec=' "$here/share/applications/$app_id.desktop"
  printf 'Exec=%s\nTryExec=%s\nX-Maprisma-Install=%s\n' "$(desktop_exec "$lib/maprisma")" "$lib/maprisma" "$lib"
} > "$entry"
echo "$entry" >> "$manifest"
install -m644 "$here/share/metainfo/$app_id.metainfo.xml" "$share/metainfo/$app_id.metainfo.xml"
echo "$share/metainfo/$app_id.metainfo.xml" >> "$manifest"
install -m644 "$here/share/icons/hicolor/scalable/apps/$app_id.svg" "$share/icons/hicolor/scalable/apps/$app_id.svg"
echo "$share/icons/hicolor/scalable/apps/$app_id.svg" >> "$manifest"
command -v update-desktop-database >/dev/null && update-desktop-database -q "$share/applications" 2>/dev/null || true
command -v gtk-update-icon-cache >/dev/null && gtk-update-icon-cache -q -t "$share/icons/hicolor" 2>/dev/null || true

say "Done: Maprisma ${version:-} is in your app menu."
case ":$PATH:" in
  *":$bin:"*) say "Start it with: maprisma" ;;
  *) say "Start it from the menu or with: $lib/maprisma   ($bin is not in your PATH)" ;;
esac
[[ -n $old ]] && say "A running Maprisma keeps the old version until you close and start it again."
say "Remove it again with: $lib/uninstall.sh$( (( system )) && echo ' (as root)')"
say "The bar icon is Maprisma Control (its own release: github.com/maprisma/control)."
