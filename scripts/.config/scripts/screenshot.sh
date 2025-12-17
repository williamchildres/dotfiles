#!/usr/bin/env bash
set -euo pipefail

mode="${1:-area}"
dir="${XDG_PICTURES_DIR:-$HOME/Pictures}/Screenshots"
mkdir -p "$dir"

ts="$(date +'%Y-%m-%d_%H-%M-%S')"
file="$dir/satty_${mode}_${ts}.png"

notify() { notify-send -a "Screenshot" "$1" "${2:-}"; }

# Satty: read from stdin (-f -), start fullscreen, save to file, and on Enter:
# copy to clipboard + save to file + exit.
SATTY=(satty -f - --output-filename "$file" --early-exit
  --actions-on-enter "save-to-file,exit"
  --actions-on-right-click "save-to-file,exit"
  --disable-notifications)

case "$mode" in
area)
  geom="$(slurp)"
  [ -n "${geom:-}" ] || exit 0
  grim -g "$geom" -t ppm - | "${SATTY[@]}"
  ;;
window)
  geom="$(hyprctl -j activewindow | jq -r \
    '.at[0] as $x | .at[1] as $y | .size[0] as $w | .size[1] as $h | "\($x),\($y) \($w)x\($h)"')"
  grim -g "$geom" -t ppm - | "${SATTY[@]}"
  ;;
monitor | full)
  grim -t ppm - | "${SATTY[@]}"
  ;;
*)
  echo "Usage: $0 {area|window|monitor}"
  exit 2
  ;;
esac

# Only claim success if the file actually got written
if [[ -s "$file" ]]; then
  wl-copy <"$file"
  notify "Saved + copied" "$file"
  echo "$file"
else
  notify "Canceled" "No file was saved"
  exit 0
fi

echo "$file"
