#!/usr/bin/env bash
set -euo pipefail

DMENU() { walker --dmenu -p "$1"; }
INPUT() { walker --dmenu -I -p "$1"; } # -I = input-only :contentReference[oaicite:1]{index=1}

notify() { notify-send -a "Network" "$1" "${2:-}"; }

wifi_dev="$(nmcli -t -f DEVICE,TYPE,STATE dev status | awk -F: '$2=="wifi"{print $1; exit}')"
eth_dev="$(nmcli -t -f DEVICE,TYPE,STATE dev status | awk -F: '$2=="ethernet"{print $1; exit}')"

wifi_state="$(nmcli -t -f WIFI g 2>/dev/null | head -n1 || echo "unknown")"
net_state="$(nmcli -t -f STATE g 2>/dev/null | head -n1 || echo "unknown")"

active_wifi_ssid=""
if [[ -n "${wifi_dev:-}" ]]; then
  active_wifi_ssid="$(nmcli -t -f ACTIVE,SSID dev wifi | awk -F: '$1=="yes"{print $2; exit}')"
fi

ip4="$(nmcli -t -f IP4.ADDRESS dev show "${wifi_dev:-$eth_dev}" 2>/dev/null | head -n1 | cut -d: -f2 | cut -d/ -f1 || true)"

# “toggle slider” vibe via labels/icons
wifi_toggle=$([[ "$wifi_state" == "enabled" ]] && echo " Wi-Fi: ON  (toggle)" || echo " Wi-Fi: OFF (toggle)")
net_toggle=$([[ "$net_state" == "connected" ]] && echo " Networking: ON  (toggle)" || echo " Networking: OFF (toggle)")

header="Net • ${net_state} • wifi:${wifi_state}"
[[ -n "${active_wifi_ssid:-}" ]] && header+=" • ${active_wifi_ssid}"
[[ -n "${ip4:-}" ]] && header+=" • ${ip4}"

choice="$(
  printf "%s\n" \
    "$wifi_toggle" \
    "$net_toggle" \
    "Rescan Wi-Fi" \
    "Connect to Wi-Fi…" \
    "Disconnect Wi-Fi" \
    "Activate saved connection…" \
    "Deactivate connection…" \
    "Open Connection Editor (nm-connection-editor)" \
    "Open TUI (nmtui)" |
    DMENU "$header"
)"

[[ -z "${choice:-}" ]] && exit 0

toggle_wifi() {
  if [[ "$wifi_state" == "enabled" ]]; then
    nmcli radio wifi off
    notify "Wi-Fi" "Disabled"
  else
    nmcli radio wifi on
    notify "Wi-Fi" "Enabled"
  fi
}

toggle_networking() {
  if [[ "$net_state" == "connected" ]]; then
    nmcli networking off
    notify "Networking" "Disabled"
  else
    nmcli networking on
    notify "Networking" "Enabled"
  fi
}

rescan_wifi() {
  [[ -n "${wifi_dev:-}" ]] || {
    notify "Wi-Fi" "No Wi-Fi device found"
    return
  }
  nmcli dev wifi rescan ifname "$wifi_dev" || true
  notify "Wi-Fi" "Rescanned"
}

connect_wifi() {
  [[ -n "${wifi_dev:-}" ]] || {
    notify "Wi-Fi" "No Wi-Fi device found"
    return
  }

  ssid_line="$(
    nmcli -t -f IN-USE,SSID,SIGNAL,SECURITY dev wifi list ifname "$wifi_dev" --rescan yes |
      awk -F: 'NF>=4 && $2!="" {printf "%s  %s%%  %s  ::  %s\n", ($1=="*"?"★":" "), $3, ($4==""?"open":$4), $2}' |
      DMENU "Select Wi-Fi"
  )"
  [[ -z "${ssid_line:-}" ]] && exit 0
  ssid="${ssid_line##*::  }"

  if nmcli dev wifi connect "$ssid" ifname "$wifi_dev" >/dev/null 2>&1; then
    notify "Connected" "$ssid"
    exit 0
  fi

  pass="$(printf "" | INPUT "Password for ${ssid}")"
  [[ -z "${pass:-}" ]] && {
    notify "Cancelled" "No password entered"
    exit 0
  }

  if nmcli dev wifi connect "$ssid" password "$pass" ifname "$wifi_dev" >/dev/null 2>&1; then
    notify "Connected" "$ssid"
  else
    notify "Failed to connect" "$ssid"
    exit 1
  fi
}

disconnect_wifi() {
  [[ -n "${wifi_dev:-}" ]] || {
    notify "Wi-Fi" "No Wi-Fi device found"
    return
  }
  nmcli dev disconnect "$wifi_dev" >/dev/null 2>&1 || true
  notify "Wi-Fi" "Disconnected"
}

activate_saved() {
  conn="$(
    nmcli -t -f NAME,TYPE,DEVICE connection show |
      awk -F: '{printf "%s  (%s)  ::  %s\n", $1, ($3==""?"down":"up"), $1}' |
      DMENU "Activate connection"
  )"
  [[ -z "${conn:-}" ]] && exit 0
  name="${conn##*::  }"
  nmcli connection up "$name" >/dev/null 2>&1 && notify "Activated" "$name" || notify "Failed" "$name"
}

deactivate_conn() {
  conn="$(
    nmcli -t -f NAME,TYPE,DEVICE connection show --active |
      awk -F: '{printf "%s  ::  %s\n", $1, $1}' |
      DMENU "Deactivate connection"
  )"
  [[ -z "${conn:-}" ]] && exit 0
  name="${conn##*::  }"
  nmcli connection down "$name" >/dev/null 2>&1 && notify "Deactivated" "$name" || notify "Failed" "$name"
}

case "$choice" in
*"Wi-Fi:"*"toggle"*) toggle_wifi ;;
*"Networking:"*"toggle"*) toggle_networking ;;
"Rescan Wi-Fi") rescan_wifi ;;
"Connect to Wi-Fi…") connect_wifi ;;
"Disconnect Wi-Fi") disconnect_wifi ;;
"Activate saved connection…") activate_saved ;;
"Deactivate connection…") deactivate_conn ;;
"Open Connection Editor (nm-connection-editor)") (
  nm-connection-editor &>/dev/null &
  disown
) ;;
"Open TUI (nmtui)") (
  foot -e nmtui &>/dev/null &
  disown
) ;;
esac
