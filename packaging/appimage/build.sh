#!/bin/sh
# Build Asterism-<version>-x86_64.AppImage: the app's Python files, desktop entry and icon; Python,
# PyGObject, GTK 4 and libadwaita come from the system (AppRun checks them).
# Needs appimagetool and the type2 runtime from their GitHub releases (check both SHA-256 digests
# against the release page first); with the runtime given, appimagetool downloads nothing.
# The signed agent and provider add-ons come along (usr/lib/asterism/addons, all switched off until the
# first start's Set up): adapters-<version>.zip from asterism-addons (tools/release-adapters.sh).
#   build.sh <version> <appimagetool> <runtime-x86_64> <adapters.zip>
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
version=${1:?usage: build.sh <version> <appimagetool> <runtime-x86_64>}
tool=${2:?usage: build.sh <version> <appimagetool> <runtime-x86_64>}
runtime=${3:?usage: build.sh <version> <appimagetool> <runtime-x86_64> <adapters.zip>}
adapters=${4:?usage: build.sh <version> <appimagetool> <runtime-x86_64> <adapters.zip>}
if ! printf '%s\n' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "build.sh: version must be X.Y.Z" >&2
    exit 2
fi
stage=$(mktemp -d)
checksums=''
trap 'rm -rf -- "$stage"; if [ -n "$checksums" ]; then rm -f -- "$checksums"; fi' 0
dir="$stage/Asterism.AppDir"
mkdir -p "$dir/usr/lib/asterism"
for module in "$root"/*.py; do
    case "$(basename "$module")" in flutter_*.py|terminal_sessions.py) continue ;; esac
    cp "$module" "$dir/usr/lib/asterism/"
done
cp -r "$root/translations" "$dir/usr/lib/asterism/"
cp -r "$root/icons" "$dir/usr/lib/asterism/"          # the app's own icons (icons.py)
mkdir -p "$dir/usr/lib/asterism/adapters"              # the built-in agents as data (adapter_data.py)
cp "$root"/adapters/*.toml "$root"/adapters/*.py "$dir/usr/lib/asterism/adapters/"
mkdir -p "$dir/usr/lib/asterism/data" && cp "$root"/data/user-manual*.pdf "$dir/usr/lib/asterism/data/"
cp -r "$root/data/icons" "$dir/usr/lib/asterism/data/"     # the app's icon for About and the welcome page
python3 "$root/packaging/unpack-adapters.py" "$adapters" "$dir/usr/lib/asterism/addons"
cp "$root/packaging/appimage/AppRun" "$dir/AppRun"
cp "$root/data/io.github.ubruckhaus.Asterism.desktop" "$dir/"
cp "$root/data/icons/io.github.ubruckhaus.Asterism.svg" "$dir/"
mkdir -p "$dir/usr/share/metainfo"
cp "$root/data/io.github.ubruckhaus.Asterism.metainfo.xml" "$dir/usr/share/metainfo/"
ARCH=x86_64 APPIMAGE_EXTRACT_AND_RUN=1 "$tool" --no-appstream --runtime-file "$runtime" "$dir" \
    "$root/Asterism-$version-x86_64.AppImage"
# Fixed release asset for the thin launcher's installer. Keep the versioned asset too.
# Replace the directory entry, never follow a stale output symlink.
cp --remove-destination -- "$root/Asterism-$version-x86_64.AppImage" "$root/Asterism-x86_64.AppImage"
checksums=$(mktemp "$root/.SHA256SUMS.XXXXXXXX")
(
    cd "$root"
    sha256sum "Asterism-$version-x86_64.AppImage" "Asterism-x86_64.AppImage"
) > "$checksums"
mv -f -- "$checksums" "$root/SHA256SUMS"
cat "$root/SHA256SUMS"
