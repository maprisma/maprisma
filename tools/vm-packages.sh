# The release packages in a throwaway Omarchy VM (runs inside it over ssh, see tools/vm-packages).
set -u
echo omarchy | sudo -S mkdir -p /mnt/dist 2>/dev/null
echo omarchy | sudo -S mount -t 9p -o trans=virtio,version=9p2000.L,ro dist /mnt/dist 2>&1 | tail -1
D=/mnt/dist
ls "$D" | tr '\n' ' '; echo

n=0
ask() {  # method [params-json] -> REPLY_LINE
  n=$((n + 1))
  printf '{"id":%d,"protocol":1,"method":"%s","params":%s}\n' "$n" "$1" "${2:-{\}}" >&"${CORE[1]}"
  IFS= read -r -t 120 REPLY_LINE <&"${CORE[0]}" || REPLY_LINE="no answer to $1"
}
addons() {  # core binary -> add-on states
  coproc CORE { "$1" 2>/tmp/core.err; }
  ask addons.list
  printf '%s' "$REPLY_LINE" | grep -o '"state":"[a-z]*"' | sort | uniq -c
  printf '%s' "$REPLY_LINE" | grep -o '"reason":"[^"]\+"' | sort -u | head -5
  kill "$CORE_PID" 2>/dev/null; wait "$CORE_PID" 2>/dev/null
}
session() {  # command -> starts it in the VM's Hyprland session, screenshot
  export XDG_RUNTIME_DIR=/run/user/$(id -u)
  export WAYLAND_DISPLAY=$(ls "$XDG_RUNTIME_DIR" | grep -m1 '^wayland-[0-9]*$')
  export HYPRLAND_INSTANCE_SIGNATURE=$(ls "$XDG_RUNTIME_DIR/hypr" 2>/dev/null | head -1)
  rm -rf ~/.config/maprisma ~/.local/share/maprisma ~/.cache/maprisma ~/.local/state/maprisma
  setsid "$@" >/tmp/app.out 2>&1 &
  app=$!
  sleep 15
  echo "app alive: $(kill -0 $app 2>/dev/null && echo yes || echo no)"
  hyprctl clients 2>/dev/null | grep -E "class:|title:" | grep -i maprisma | head -2
  grim "/tmp/$2.png" 2>&1 | head -2
  echo "-- app output"; head -c 1500 /tmp/app.out; echo
  pkill -x maprisma 2>/dev/null; kill $app 2>/dev/null; sleep 2
  echo "-- user units"; ls ~/.config/systemd/user 2>/dev/null | grep -i maprisma || echo none
}

echo "== A the AUR package (pacman -U)"
pkg=$(ls "$D"/maprisma-bin-*.pkg.tar.zst | head -1)
echo omarchy | sudo -S pacman -U --noconfirm "$pkg" 2>&1 | grep -E "error|warning|installing|missing" | head -8
pacman -Qi maprisma-bin | grep -E "^(Name|Version|Installed Size)"
command -v maprisma; ls -l /usr/bin/maprisma
for f in /usr/lib/maprisma/maprisma /usr/lib/maprisma/lib/*.so /usr/lib/maprisma/lib/maprisma-core; do
  ldd "$f" | grep "not found" | sed "s|^|$(basename "$f"): |"
done
echo "-- add-ons"; addons /usr/lib/maprisma/lib/maprisma-core
echo "-- python in the package: $(pacman -Ql maprisma-bin | grep -c '\.py$')"
sleep 5
echo "-- start"; session maprisma pkg

echo "== B the package removed"
echo omarchy | sudo -S pacman -R --noconfirm maprisma-bin 2>&1 | grep -E "error|removing" | head -3
ls /usr/lib/maprisma 2>&1 | head -1

echo "== C the AppImage"
cp "$D"/Maprisma-*-x86_64.AppImage /tmp/Maprisma.AppImage && chmod +x /tmp/Maprisma.AppImage
echo "-- add-ons"
/tmp/Maprisma.AppImage --appimage-extract >/dev/null 2>&1 && addons squashfs-root/usr/lib/maprisma/lib/maprisma-core
echo "-- start"; session /tmp/Maprisma.AppImage appimage
echo "== SHOT pkg"; base64 -w0 /tmp/pkg.png 2>/dev/null; echo
echo "== SHOT appimage"; base64 -w0 /tmp/appimage.png 2>/dev/null; echo
echo "== END"
