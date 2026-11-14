#!/usr/bin/env bash
# Remove a Maprisma installed by install.sh: run <folder>/uninstall.sh (as root for a --system install).
#   --purge   also remove your Maprisma settings, data, cache and state (~/.config/maprisma …)
# Only what the installer listed in <folder>/.install-manifest is removed, and only while it still is
# Maprisma's (the link points into the folder, the menu entry names it). Your agents, models and their
# settings are never touched.
set -euo pipefail

purge=0
for arg in "$@"; do
  case $arg in
    --purge) purge=1 ;;
    -h|--help) sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "uninstall.sh: unknown option $arg (see --help)" >&2; exit 2 ;;
  esac
done

lib=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
manifest=$lib/.install-manifest
[[ -f $manifest && -x $lib/maprisma ]] || { echo "uninstall.sh: $lib is not an install of install.sh" >&2; exit 1; }
[[ -w $(dirname "$lib") ]] || { echo "uninstall.sh: $lib belongs to the system: run it as root" >&2; exit 1; }

share=$(dirname "$(dirname "$(grep -m1 '\.desktop$' "$manifest" 2>/dev/null || echo /x/x/x)")")
while IFS= read -r f; do
  [[ -n $f ]] || continue
  if [[ -L $f ]]; then
    [[ $(readlink "$f") == "$lib"/* ]] && rm -f -- "$f"
  elif [[ $f == *.desktop ]]; then
    grep -qxF "X-Maprisma-Install=$lib" "$f" 2>/dev/null && rm -f -- "$f"
  elif [[ -f $f ]]; then
    rm -f -- "$f"
  fi
done < "$manifest"

# The providers service (local LLMs with their agents) of this user, when it runs this install's core.
unit=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/maprisma-providers.service
if [[ $(id -u) -ne 0 && -f $unit ]] && grep -qF "ExecStart=$lib/lib/maprisma-core " "$unit"; then
  systemctl --user disable --now maprisma-providers.service >/dev/null 2>&1 || true
  rm -f -- "$unit"
  systemctl --user daemon-reload >/dev/null 2>&1 || true
fi

rm -rf -- "$lib"
command -v update-desktop-database >/dev/null && update-desktop-database -q "$share/applications" 2>/dev/null || true
command -v gtk-update-icon-cache >/dev/null && gtk-update-icon-cache -q -t "$share/icons/hicolor" 2>/dev/null || true

if (( purge )); then
  for d in "${XDG_CONFIG_HOME:-$HOME/.config}/maprisma" "${XDG_DATA_HOME:-$HOME/.local/share}/maprisma" \
           "${XDG_CACHE_HOME:-$HOME/.cache}/maprisma" "${XDG_STATE_HOME:-$HOME/.local/state}/maprisma"; do
    [[ -d $d && ! -L $d ]] && rm -rf -- "$d" && echo "removed $d"
  done
fi
echo "Maprisma was removed.$( (( purge )) || echo ' Your settings stay in ~/.config/maprisma (--purge removes them).')"
