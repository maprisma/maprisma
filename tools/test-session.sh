#!/bin/bash
# A manual test of Maprisma, kept for review afterwards (task 001). Each run gets its own folder:
#
#   <base>/<date>_<time>/
#     protocol.jsonl   every request between GUI and core and its answer (secrets blanked)
#     app.log          the app's own output
#     system.txt       distribution, desktop, graphics, the installed Maprisma
#     notes.md         your notes: a checklist to fill in while you test
#     after.txt        what Maprisma left on the PC when it closed (folders, user units)
#     shots/           F9 in the running app: a picture of its window and a note (in protocol.jsonl)
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
# The program is called maprisma in the package and inside the AppImage alike (pgrep -f would also
# find this script, whose command line holds the AppImage's name).
if pgrep -x maprisma >/dev/null; then
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
F9 in Maprisma saves a picture of its window into shots/ and asks for a note. It shows what is on
screen, also keys and file names: look at the pictures before you share them. GTK's title bar and
windows of other programs are not in it; take a normal screenshot of those.

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
- [ ] an agent started in its own terminal, not inside the window (which terminal opened?)
- [ ] a link or the manual opens in the browser / PDF viewer

## COSMIC (or any desktop that is not Omarchy)
- [ ] light or dark as the desktop is (or how it differs)
- [ ] the title bar: once, not twice
- [ ] `maprisma --toggle` on a custom shortcut: opens, brings to the front, hides

## Remove
- [ ] Settings › Start local LLMs with their agents off, then remove the package / AppImage

## Notes
EOF

echo "Recording into $run"
echo "Write your notes into $run/notes.md while you test. F9 in Maprisma: a screenshot with a note."
echo "Close Maprisma to finish."
status=0
MAPRISMA_RECORD_PROTOCOL="$run/protocol.jsonl" "$app" > "$run/app.log" 2>&1 || status=$?

{
  echo "== ended    $(date --iso-8601=seconds) (exit $status)"
  echo "== folders after"
  for d in ~/.config/maprisma ~/.cache/maprisma ~/.local/share/maprisma ~/.local/state/maprisma; do
    [[ -e $d ]] && find "$d" -maxdepth 2 -printf '%y %8s %p\n' | sort -k3
  done
  echo "== user units (Maprisma's own and the local LLMs it installed)"
  units=$(grep -l -e 'installed by Maprisma' -e 'Maprisma:' ~/.config/systemd/user/*.service 2>/dev/null || true)
  if [[ -n $units ]]; then
    for u in $units; do echo "$(basename "$u")  $(systemctl --user is-active "$(basename "$u")" 2>/dev/null)"; done
  else
    echo none
  fi
} > "$run/after.txt" 2>&1

echo "Done (exit $status). Everything is in $run"
