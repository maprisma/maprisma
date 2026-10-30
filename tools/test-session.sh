#!/bin/bash
# A manual test of Maprisma, kept for review afterwards (task 001). Each run gets its own folder:
#
#   <base>/<date>_<time>/
#     protocol.jsonl   every request between GUI and core and its answer (secrets blanked)
#     app.log          the app's own output
#     system.txt       distribution, desktop, graphics, the installed Maprisma
#     notes.md         your notes: a checklist to fill in while you test
#     after.txt        what Maprisma left on the PC when it closed (folders, user units)
#
#   test-session.sh                 start the installed maprisma
#   test-session.sh <AppImage>      start this AppImage instead
#
# base: MAPRISMA_TEST_DIR, default /mnt/Data/maprisma-test. Nothing is sent anywhere.
set -euo pipefail
base=${MAPRISMA_TEST_DIR:-/mnt/Data/maprisma-test}
app=${1:-maprisma}
if [[ $app == maprisma ]]; then
  command -v maprisma >/dev/null || { echo "maprisma is not installed (or give an AppImage)" >&2; exit 1; }
else
  [[ -x $app ]] || { echo "$app is not an executable AppImage (chmod +x it)" >&2; exit 1; }
  app=$(realpath "$app")
fi
if pgrep -x maprisma >/dev/null || pgrep -f '[M]aprisma.*AppImage' >/dev/null; then
  echo "Maprisma is already running: close it first (its window would only be brought to the front," >&2
  echo "and nothing of this run would be recorded)." >&2
  exit 1
fi

run="$base/$(date +%Y-%m-%d_%H-%M-%S)"
mkdir -p "$run"

{
  echo "== started  $(date --iso-8601=seconds)"
  echo "== app      $app"
  echo "== system";   grep -E '^(PRETTY_NAME|VERSION_ID|BUILD_ID)=' /etc/os-release || true
  echo "kernel $(uname -r)"
  echo "desktop ${XDG_CURRENT_DESKTOP:-?} · session ${XDG_SESSION_TYPE:-?} · wayland ${WAYLAND_DISPLAY:-none}"
  echo "== graphics"; lspci 2>/dev/null | grep -Ei 'vga|3d|display' || echo "(lspci not available)"
  echo "== package";  pacman -Q maprisma-bin 2>/dev/null || echo "(no maprisma-bin package)"
  echo "== tools";    for t in mise xdg-open xdg-terminal-exec git node npm python3 hyprctl; do
                        printf '%-18s %s\n' "$t" "$(command -v "$t" || echo -)"; done
  echo "== folders before"
  for d in ~/.config/maprisma ~/.cache/maprisma ~/.local/share/maprisma ~/.local/state/maprisma \
           ~/.config/asterism; do
    printf '%-40s %s\n' "$d" "$([[ -e $d ]] && echo present || echo -)"
  done
} > "$run/system.txt" 2>&1

cat > "$run/notes.md" <<'EOF'
# Test notes

Write what you did, what you expected and what happened, with the time (`date +%T`).
Tick what worked, cross out what did not, add anything odd.

## Install
- [ ] package / AppImage installed without errors
- [ ] Maprisma in the app launcher, icon shown

## First start
- [ ] welcome page, the agents found on this PC are ticked
- [ ] "Look at this PC": what it found matches what is installed
- [ ] Switch on: the agents appear on the map

## Use
- [ ] an agent's details (click its card)
- [ ] connect an MCP server to an agent (drag on the map), Undo
- [ ] Settings: language, theme, corners
- [ ] Help: the manual opens
- [ ] window: close and open again

## Remove
- [ ] Settings › Start local LLMs with their agents off, then remove the package / AppImage

## Notes
EOF

echo "Recording into $run"
echo "Write your notes into $run/notes.md while you test. Close Maprisma to finish."
status=0
MAPRISMA_RECORD_PROTOCOL="$run/protocol.jsonl" "$app" > "$run/app.log" 2>&1 || status=$?

{
  echo "== ended    $(date --iso-8601=seconds) (exit $status)"
  echo "== folders after"
  for d in ~/.config/maprisma ~/.cache/maprisma ~/.local/share/maprisma ~/.local/state/maprisma; do
    [[ -e $d ]] && find "$d" -maxdepth 2 -printf '%y %8s %p\n' | sort -k3
  done
  echo "== user units"
  ls ~/.config/systemd/user 2>/dev/null | grep -i maprisma || echo none
} > "$run/after.txt" 2>&1

echo "Done (exit $status). Everything is in $run"
