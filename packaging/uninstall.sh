#!/usr/bin/env bash
# Remove Maprisma installed by install.sh: <folder>/uninstall.sh (as root for a --system install).
#   --purge   also remove your Maprisma settings, data, cache and state (~/.config/maprisma …)
# Only the files the installer recorded are removed, and only while unchanged. Your agents, models and
# their settings are never touched.
here=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
exec bash "$here/.installer.sh" --uninstall --folder "$here" "$@"
