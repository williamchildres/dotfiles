#!/usr/bin/env bash
set -euo pipefail

SIGNAL=8 # must match the "signal" value in Waybar config

# Force system python so pyenv/mise/shims can't break powerprofilesctl
PPCTL="/usr/bin/python3 /usr/bin/powerprofilesctl"

get_profile() {
  $PPCTL get 2>/dev/null || echo "balanced"
}

print_json() {
  local p icon label
  p="$(get_profile)"

  case "$p" in
  performance)
    icon="󰓅"
    label="perf"
    ;;
  balanced)
    icon="󰾅"
    label="bal"
    ;;
  power-saver)
    icon="󰌪"
    label="save"
    ;;
  *)
    icon="󰾆"
    label="$p"
    ;;
  esac

  printf '{"text":"%s","tooltip":"Power Profile: %s","class":"%s"}\n' \
    "$icon" "$p" "$p"
}

toggle() {
  local p next
  p="$(get_profile)"

  case "$p" in
  power-saver) next="balanced" ;;
  balanced) next="performance" ;;
  performance) next="power-saver" ;;
  *) next="balanced" ;;
  esac

  $PPCTL set "$next" >/dev/null 2>&1 || true
  pkill -RTMIN+"$SIGNAL" waybar 2>/dev/null 2>&1 || true
}

case "${1:-}" in
toggle) toggle ;;
*) print_json ;;
esac
