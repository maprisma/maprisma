# Clean-VM scenarios for the Flutter app (runs inside a throwaway Omarchy VM over ssh).
set -u
echo "== A system"
uname -r
pacman -Q omarchy hyprland gtk3 2>&1 | head -4
echo omarchy | sudo -S mkdir -p /mnt/asterism 2>/dev/null
echo omarchy | sudo -S mount -t 9p -o trans=virtio,version=9p2000.L,ro asterism /mnt/asterism 2>&1 | tail -1
B=/mnt/asterism
ls "$B" "$B/lib" | tr '\n' ' '; echo
echo "== A libraries missing"
for f in "$B/asterism" "$B"/lib/*.so; do ldd "$f" | grep "not found" | sed "s|^|$(basename "$f"): |"; done
echo "(end)"

echo "== B core on a fresh home"
export ASTERISM_FLUTTER_DEVEL=1
coproc CORE { "$B/lib/asterism-core" 2>/tmp/core.err; }
n=0
ask() {  # method [params-json] -> prints the answer line
  n=$((n + 1))
  printf '{"id":%d,"protocol":1,"method":"%s","params":%s}\n' "$n" "$1" "${2:-{\}}" >&"${CORE[1]}"
  IFS= read -r -t 120 REPLY_LINE <&"${CORE[0]}" || { REPLY_LINE="no answer to $1"; return 1; }
}
wait_task() {  # method [params] -> the task's result (polls tasks.status)
  local started task status
  ask "$1" "${2:-{\}}"; started=$REPLY_LINE
  task=$(printf '%s' "$started" | sed -n 's/.*"task":"\([^"]*\)".*/\1/p')
  [ -n "$task" ] || { REPLY_LINE="$1 started no task: ${started:0:300}"; return; }
  for _ in $(seq 1 240); do
    ask tasks.status "{\"task\":\"$task\"}"
    case "$REPLY_LINE" in *'"state":"running"'*) sleep 0.5 ;; *) break ;; esac
  done
}
short() { cut -c1-${2:-600}; }
echo "-- app.snapshot"; ask app.snapshot; printf '%s\n' "${REPLY_LINE:0:900}"
echo "-- settings.get"; ask settings.get; printf '%s\n' "${REPLY_LINE:0:400}"
echo "-- settings.update language de"; ask settings.update '{"values":{"language":"de"}}'; printf '%s\n' "${REPLY_LINE:0:200}"
echo "-- files in config"; ls -la ~/.config/asterism
echo "-- changes.history"; ask changes.history; printf '%s\n' "${REPLY_LINE:0:600}"
echo "-- helper.snapshot"; ask helper.snapshot; printf '%s\n' "${REPLY_LINE:0:300}"
echo "-- checks.mcp_updates"; ask checks.mcp_updates; printf '%s\n' "${REPLY_LINE:0:300}"
echo "-- health.report"; wait_task health.report; printf '%s\n' "${REPLY_LINE:0:1500}"
echo "-- guide.snapshot"; wait_task guide.snapshot; printf '%s\n' "${REPLY_LINE:0:1500}"
echo "-- found.scan"; wait_task found.scan; printf '%s\n' "${REPLY_LINE:0:600}"
echo "-- map.snapshot"; ask map.snapshot '{"force":true}'; printf '%s\n' "${REPLY_LINE:0:900}"
exec {CORE[1]}>&-
sleep 1
echo "-- core stderr"; head -c 2000 /tmp/core.err; echo
echo "-- user units"; ls ~/.config/systemd/user 2>/dev/null | grep -i asterism || echo none

echo "== C the app in the session"
sleep 5
export XDG_RUNTIME_DIR=/run/user/$(id -u)
export WAYLAND_DISPLAY=$(ls "$XDG_RUNTIME_DIR" | grep -m1 '^wayland-[0-9]*$')
echo "display: ${WAYLAND_DISPLAY:-none}"
export HYPRLAND_INSTANCE_SIGNATURE=$(ls "$XDG_RUNTIME_DIR/hypr" 2>/dev/null | head -1)
rm -rf ~/.config/asterism   # first start, as a new user sees it
setsid "$B/asterism" >/tmp/app.out 2>&1 &
app=$!
sleep 15
echo "app alive: $(kill -0 $app 2>/dev/null && echo yes || echo no)"
hyprctl clients 2>/dev/null | grep -E "class|title" | head -8
grim /tmp/shot.png 2>&1 | head -2
echo "-- app output"; head -c 3000 /tmp/app.out; echo
echo "== SHOT"; base64 -w0 /tmp/shot.png 2>/dev/null; echo
echo "== END"
kill $app 2>/dev/null
