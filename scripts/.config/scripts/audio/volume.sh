#!/usr/bin/env bash
set -euo pipefail

SINK='@DEFAULT_AUDIO_SINK@'
SOURCE='@DEFAULT_AUDIO_SOURCE@'
LIMIT="1.5" # 1.0 = 100%, 1.5 = 150%

action="${1:-}"
step="${2:-2}"

get_percent() {
  local out vol
  out="$(wpctl get-volume "$SINK")"
  if grep -qi 'MUTED' <<<"$out"; then
    echo "MUTED"
    return
  fi
  vol="$(awk '{print $2}' <<<"$out")"
  awk -v v="$vol" 'BEGIN { printf("%d\n", v*100 + 0.5) }'
}

notify_vol() {
  local p
  p="$(get_percent)"
  if [[ "$p" == "MUTED" ]]; then
    notify-send -a "Audio" \
      -h string:x-canonical-private-synchronous:volume \
      "󰝟 Muted"
  else
    notify-send -a "Audio" \
      -h string:x-canonical-private-synchronous:volume \
      -h int:value:"$p" \
      "󰕾 Volume: ${p}%"
  fi
}

case "$action" in
up) wpctl set-volume -l "$LIMIT" "$SINK" "${step}%+" ;;
down) wpctl set-volume -l "$LIMIT" "$SINK" "${step}%-" ;;
mute) wpctl set-mute "$SINK" toggle ;;
micmute) wpctl set-mute "$SOURCE" toggle ;;
set) wpctl set-volume -l "$LIMIT" "$SINK" "$(awk -v p="${2:-50}" 'BEGIN{printf("%.2f\n", p/100)}')" ;;
*) exit 0 ;;
esac

notify_vol
