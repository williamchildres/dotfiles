#!/usr/bin/env bash
set -euo pipefail

DMENU() { walker --dmenu -p "Audio"; }

def_sink="$(pactl get-default-sink 2>/dev/null || true)"
def_src="$(pactl get-default-source 2>/dev/null || true)"

notify() { notify-send -a "Audio" "$1" "${2:-}"; }

move_all_to_default_sink() {
  local new_sink="$1"
  # Move all current sink-input streams (apps) to the new sink
  pactl list short sink-inputs | awk '{print $1}' | while read -r id; do
    pactl move-sink-input "$id" "$new_sink" || true
  done
}

pick_output() {
  local line name choice
  choice="$(
    pactl -f json list sinks | jq -r --arg def "$def_sink" '
      .[] | (" " + (if .name==$def then "★" else " " end) + " " + .description + "  ::  " + .name)
    ' | DMENU
  )"
  [[ -z "${choice:-}" ]] && exit 0
  name="${choice##*::  }"

  # Second prompt: just set default, or set+move streams
  line="$(
    printf "%s\n" \
      "Set default output" \
      "Set default + move playing apps" |
      walker --dmenu -p "Output action"
  )"
  [[ -z "${line:-}" ]] && exit 0

  pactl set-default-sink "$name"
  if [[ "$line" == "Set default + move playing apps" ]]; then
    move_all_to_default_sink "$name"
    notify "Output changed" "Default + moved apps"
  else
    notify "Output changed" "Default set"
  fi
}

pick_input() {
  local choice name
  choice="$(
    pactl -f json list sources | jq -r --arg def "$def_src" '
      .[]
      | select(.monitor_of_sink == null)
      | (" " + (if .name==$def then "★" else " " end) + " " + .description + "  ::  " + .name)
    ' | walker --dmenu -p "Input"
  )"
  [[ -z "${choice:-}" ]] && exit 0
  name="${choice##*::  }"
  pactl set-default-source "$name"
  notify "Input changed" "Default set"
}

main() {
  local vol out muted choice
  local sink_line src_line sink_muted src_muted
  local mute_item mic_item

  # Sink (speaker) state
  sink_line="$(wpctl get-volume @DEFAULT_AUDIO_SINK@)"
  sink_muted="$(grep -qi 'MUTED' <<<"$sink_line" && echo 1 || echo 0)"
  vol="$(awk '{print int($2*100+0.5)}' <<<"$sink_line" 2>/dev/null || echo "?")"
  muted="$([[ "$sink_muted" == "1" ]] && echo " (muted)" || true)"

  # Source (mic) state
  src_line="$(wpctl get-volume @DEFAULT_AUDIO_SOURCE@ 2>/dev/null || true)"
  src_muted="$(grep -qi 'MUTED' <<<"$src_line" && echo 1 || echo 0)"

  # “Toggle slider” style labels
  if [[ "$sink_muted" == "1" ]]; then
    mute_item="󰝟 Speaker: OFF  ⟪ toggle ⟫"
  else
    mute_item="󰕾 Speaker: ON   ⟪ toggle ⟫"
  fi

  if [[ "$src_muted" == "1" ]]; then
    mic_item="󰍭 Mic: OFF      ⟪ toggle ⟫"
  else
    mic_item="󰍬 Mic: ON       ⟪ toggle ⟫"
  fi

  choice="$(
    printf "%s\n" \
      "Output device…" \
      "Input device…" \
      "$mute_item" \
      "$mic_item" \
      "Set volume: 25%" \
      "Set volume: 50%" \
      "Set volume: 75%" \
      "Set volume: 100%" \
      "Open mixer (pavucontrol)" \
      "Open patchbay (helvum)" |
      DMENU "Audio • ${vol}%${muted}"
  )"

  case "$choice" in
  "Output device…") pick_output ;;
  "Input device…") pick_input ;;
  *"Speaker:"*) ~/.config/scripts/audio/volume.sh mute ;;
  *"Mic:"*) ~/.config/scripts/audio/volume.sh micmute ;;
  "Set volume: 25%") ~/.config/scripts/audio/volume.sh set 25 ;;
  "Set volume: 50%") ~/.config/scripts/audio/volume.sh set 50 ;;
  "Set volume: 75%") ~/.config/scripts/audio/volume.sh set 75 ;;
  "Set volume: 100%") ~/.config/scripts/audio/volume.sh set 100 ;;
  "Open mixer (pavucontrol)") pavucontrol & ;;
  "Open patchbay (helvum)") helvum & ;;
  *) exit 0 ;;
  esac
}
main
