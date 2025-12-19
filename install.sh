#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACMAN_LIST="$REPO_DIR/packages/pacman.txt"
AUR_LIST="$REPO_DIR/packages/aur.txt"
BACKUP_DIR="$HOME/.dotfiles-backup/$(date +%Y%m%d-%H%M%S)"
USER_NAME="${SUDO_USER:-$USER}"

# Public wallpapers repo (HTTPS so users don't need SSH keys)
WALLPAPER_REPO_URL="https://github.com/williamchildres/wallpapers.git"
WALLPAPER_DIR="$HOME/Pictures/wallpapers"

need_cmd() { command -v "$1" >/dev/null 2>&1; }

read_pkg_list() {
  local __arr_name="$1"
  local __file="$2"
  local __tmp=()
  if [[ -f "$__file" ]]; then
    while IFS= read -r line; do
      line="${line%%#*}"
      line="$(echo "$line" | xargs || true)"
      [[ -z "$line" ]] && continue
      __tmp+=("$line")
    done <"$__file"
  fi
  eval "$__arr_name=(\"\${__tmp[@]}\")"
}

prompt_yes_no() {
  local q="${1:?}"
  local def="${2:-n}"
  local ans

  if [[ ! -t 0 ]]; then
    [[ "$def" == "y" ]] && return 0 || return 1
  fi

  while true; do
    if [[ "$def" == "y" ]]; then
      read -rp "$q [Y/n]: " ans </dev/tty || ans=""
      ans="${ans:-y}"
    else
      read -rp "$q [y/N]: " ans </dev/tty || ans=""
      ans="${ans:-n}"
    fi

    case "${ans,,}" in
    y | yes) return 0 ;;
    n | no) return 1 ;;
    *) echo "Please answer y or n." ;;
    esac
  done
}

install_yay_if_missing() {
  if ! need_cmd yay; then
    echo "==> installing yay (AUR helper)..."
    local tmp
    tmp="$(mktemp -d)"
    git clone https://aur.archlinux.org/yay.git "$tmp/yay"
    (cd "$tmp/yay" && makepkg -si --noconfirm)
    rm -rf "$tmp"
  fi
}

# ---------------------------
# NETWORK + DNS PREFLIGHT
# ---------------------------

have_internet_basic() { ping -c 1 -W 1 1.1.1.1 >/dev/null 2>&1; }
have_dns() { getent hosts archlinux.org >/dev/null 2>&1; }

force_temp_resolv_conf() {
  echo "==> DNS appears broken. Writing temporary /etc/resolv.conf (1.1.1.1, 8.8.8.8)..."
  sudo rm -f /etc/resolv.conf || true
  sudo tee /etc/resolv.conf >/dev/null <<'EOF'
nameserver 1.1.1.1
nameserver 8.8.8.8
options timeout:1 attempts:2 rotate
EOF
}

preflight_network_or_die() {
  echo "==> network preflight..."

  # Try to start common stacks (best effort)
  if need_cmd systemctl; then
    sudo systemctl start systemd-resolved.service >/dev/null 2>&1 || true
    sudo systemctl start systemd-networkd.service >/dev/null 2>&1 || true
    sudo systemctl start iwd.service >/dev/null 2>&1 || true
    sudo systemctl start NetworkManager.service >/dev/null 2>&1 || true
  fi

  sleep 1

  if ! have_internet_basic; then
    echo "!! No basic internet connectivity (cannot ping 1.1.1.1)."
    echo "   Fix network first (VM NAT/bridge, Wi-Fi, etc.), then rerun."
    exit 1
  fi

  if ! have_dns; then
    force_temp_resolv_conf
  fi

  if ! have_dns; then
    echo "!! DNS still failing (cannot resolve archlinux.org)."
    echo "   Check: cat /etc/resolv.conf ; systemctl status systemd-resolved NetworkManager iwd"
    exit 1
  fi

  echo "==> network OK (internet + DNS)."
}

# ---------------------------
# MIRRORS + PACMAN WITH RETRIES
# ---------------------------

refresh_pacman_mirrors_every_time() {
  local country="${MIRROR_COUNTRY:-US}"
  local url="https://archlinux.org/mirrorlist/?country=${country}&protocol=https&ip_version=4&use_mirror_status=on"
  local bak="/etc/pacman.d/mirrorlist.bak.$(date +%Y%m%d-%H%M%S)"

  echo "==> refreshing pacman mirrors (country=${country}, https, ipv4)..."
  sudo cp -f /etc/pacman.d/mirrorlist "$bak" 2>/dev/null || true

  if need_cmd timedatectl; then
    sudo timedatectl set-ntp true >/dev/null 2>&1 || true
  fi

  if ! need_cmd curl; then
    echo "!! curl missing; cannot refresh mirrors. Continuing with existing mirrorlist."
    return 0
  fi

  if ! sudo curl -fsSL "$url" -o /etc/pacman.d/mirrorlist; then
    echo "!! mirror refresh failed: keeping existing mirrorlist"
    return 0
  fi

  sudo sed -i 's/^#Server/Server/' /etc/pacman.d/mirrorlist || true
  # prune some common bad actors you hit (best effort)
  sudo sed -i '/osuosl/d;/osouos1/d;/ftp\./d' /etc/pacman.d/mirrorlist || true
}

extract_failed_mirror_host() {
  sed -nE "s/.*failed retrieving file '.*' from ([^ ]+).*/\1/p" | tail -n 1
}

pacman_retry() {
  local tries=6
  local n=1
  local out host rc

  while ((n <= tries)); do
    echo "==> pacman attempt $n/$tries: pacman $*"
    set +e
    out="$(sudo pacman "$@" 2>&1)"
    rc=$?
    set -e

    if ((rc == 0)); then
      return 0
    fi

    echo "$out" >&2

    if grep -qiE 'could not resolve host|name or service not known|temporary failure in name resolution' <<<"$out"; then
      echo "!! Detected DNS resolution failure during pacman."
      preflight_network_or_die
    fi

    host="$(printf "%s\n" "$out" | extract_failed_mirror_host || true)"
    echo "!! pacman failed. Refreshing mirrors and pruning host: ${host:-unknown}" >&2

    refresh_pacman_mirrors_every_time
    if [[ -n "${host:-}" ]]; then
      sudo sed -i "\#${host}#d" /etc/pacman.d/mirrorlist || true
    fi

    ((n++))
    sleep 1
  done

  echo "!! pacman failed after $tries attempts." >&2
  return 1
}

# ---------------------------
# NETWORKMANAGER MIGRATION
# ---------------------------

get_wifi_dev() {
  # Prefer nmcli if present; fallback to iw
  if need_cmd nmcli; then
    nmcli -t -f DEVICE,TYPE dev status | awk -F: '$2=="wifi"{print $1; exit}'
    return 0
  fi
  if need_cmd iw; then
    iw dev 2>/dev/null | awk '$1=="Interface"{print $2; exit}'
    return 0
  fi
  echo ""
}

get_active_ssid() {
  if need_cmd iwgetid; then
    iwgetid -r 2>/dev/null || true
    return 0
  fi
  local dev
  dev="$(get_wifi_dev)"
  [[ -z "$dev" ]] && {
    echo ""
    return 0
  }
  if need_cmd iw; then
    iw dev "$dev" link 2>/dev/null | sed -nE 's/^\s*SSID:\s*(.*)$/\1/p' | head -n1 || true
  else
    echo ""
  fi
}

iwd_read_passphrase_for_ssid() {
  # prints passphrase if found, else nothing
  local ssid="$1"
  local f="/var/lib/iwd/${ssid}.psk"
  [[ -f "$f" ]] || return 0

  # iwd may store either Passphrase= or PreSharedKey=
  local pass
  pass="$(sudo sed -nE 's/^\s*Passphrase=(.*)$/\1/p' "$f" | head -n1 || true)"
  if [[ -z "$pass" ]]; then
    pass="$(sudo sed -nE 's/^\s*PreSharedKey=(.*)$/\1/p' "$f" | head -n1 || true)"
  fi
  printf "%s" "$pass"
}

nm_add_wifi_connection_keyfile() {
  local dev="$1"
  local ssid="$2"
  local pass="$3"

  # avoid duplicates
  if nmcli -t -f NAME con show | grep -Fxq "$ssid"; then
    return 0
  fi

  nmcli con add type wifi ifname "$dev" con-name "$ssid" ssid "$ssid" >/dev/null
  nmcli con modify "$ssid" wifi-sec.key-mgmt wpa-psk
  nmcli con modify "$ssid" wifi-sec.psk "$pass"
  nmcli con modify "$ssid" connection.autoconnect yes
}

import_iwd_profiles_into_nm() {
  # Imports known iwd networks into NM so reboot auto-connect works.
  # Only handles WPA-PSK profiles (.psk). Enterprise/WEP are ignored.
  local dev
  dev="$(get_wifi_dev)"
  [[ -z "$dev" ]] && {
    echo "==> no wifi device detected; skipping iwd import."
    return 0
  }

  [[ -d /var/lib/iwd ]] || {
    echo "==> no /var/lib/iwd profiles found; skipping iwd import."
    return 0
  }

  echo "==> importing iwd Wi-Fi profiles into NetworkManager..."

  # 1) Prefer currently connected SSID first
  local ssid pass
  ssid="$(get_active_ssid)"
  if [[ -n "$ssid" ]]; then
    pass="$(iwd_read_passphrase_for_ssid "$ssid" || true)"
    if [[ -n "$pass" ]]; then
      echo "==> importing active SSID: $ssid"
      nm_add_wifi_connection_keyfile "$dev" "$ssid" "$pass" || true
    else
      echo "==> active SSID '$ssid' has no readable passphrase in iwd (skipping)."
    fi
  fi

  # 2) Import all .psk profiles with passphrases
  while IFS= read -r -d '' file; do
    local name
    name="$(basename "$file")"
    ssid="${name%.psk}"

    pass="$(sudo sed -nE 's/^\s*Passphrase=(.*)$/\1/p' "$file" | head -n1 || true)"
    if [[ -z "$pass" ]]; then
      pass="$(sudo sed -nE 's/^\s*PreSharedKey=(.*)$/\1/p' "$file" | head -n1 || true)"
    fi
    [[ -z "$pass" ]] && continue

    nm_add_wifi_connection_keyfile "$dev" "$ssid" "$pass" || true
  done < <(sudo find /var/lib/iwd -maxdepth 1 -type f -name '*.psk' -print0 2>/dev/null)

  echo "==> iwd import complete."
}

enable_nm_and_takeover_network() {
  if ! need_cmd systemctl; then
    return 0
  fi

  # Make sure NM is installed + running
  if ! pacman -Qi networkmanager >/dev/null 2>&1; then
    echo "==> installing NetworkManager..."
    pacman_retry -S --needed --noconfirm networkmanager
  fi

  echo "==> enabling NetworkManager..."
  sudo systemctl enable --now NetworkManager.service >/dev/null 2>&1 || true
  sudo systemctl restart NetworkManager.service >/dev/null 2>&1 || true

  # Import iwd profiles into NM (so reboot works)
  import_iwd_profiles_into_nm

  # Try to bring up the “best” connection immediately
  nmcli networking on >/dev/null 2>&1 || true
  nmcli radio wifi on >/dev/null 2>&1 || true

  # If any connection exists, bring it up (autoconnect handles most cases)
  local any_conn
  any_conn="$(nmcli -t -f NAME con show 2>/dev/null | head -n1 || true)"
  if [[ -n "$any_conn" ]]; then
    nmcli con up "$any_conn" >/dev/null 2>&1 || true
  fi

  # If we still don’t have connectivity, don’t kill the old stack yet.
  if have_internet_basic && have_dns; then
    echo "==> NetworkManager has working connectivity. Disabling old network stack..."

    sudo systemctl disable --now systemd-networkd.service 2>/dev/null || true
    sudo systemctl disable --now dhcpcd.service 2>/dev/null || true

    # If iwd was used by the installer, turn it off to avoid conflicts
    sudo systemctl disable --now iwd.service 2>/dev/null || true
  else
    echo "!! NetworkManager takeover didn’t achieve connectivity yet."
    echo "   Leaving existing services enabled to avoid breaking network."
    echo "   You can connect via: nmcli dev wifi connect <SSID> password <PASS>"
  fi
}

# ---- Fix bad stow folding of ~/.local (prevents share/state landing in repo) ----
unfold_local_if_broken() {
  if [[ -L "$HOME/.local" ]]; then
    local target
    target="$(readlink -f "$HOME/.local" || true)"
    if [[ -n "$target" && "$target" == "$REPO_DIR/"* ]]; then
      echo "==> Detected folded ~/.local -> $target"
      echo "==> Unfolding ~/.local back to a real directory..."
      rm -f "$HOME/.local"
      mkdir -p "$HOME/.local/bin" "$HOME/.local/share" "$HOME/.local/state"
      for d in share state; do
        if [[ -d "$target/$d" ]]; then
          echo "==> Moving $target/$d -> $HOME/.local/$d"
          mv "$target/$d" "$HOME/.local/" || true
        fi
      done
    fi
  fi
}

echo "==> dotfiles installer"
echo "==> repo: $REPO_DIR"

if ! need_cmd pacman; then
  echo "!! Arch-based only (pacman required)."
  exit 1
fi

# 0) Ensure network works for pacman/git
preflight_network_or_die

# 1) Mirrors
refresh_pacman_mirrors_every_time

# 2) Base deps
pacman_retry -Syyu --needed --noconfirm git stow base-devel curl

# 3) Ensure a few “critical” runtime tools exist even if lists are missing
#    - swww: wallpapers
#    - NetworkManager: stable network after reboot
pacman_retry -S --needed --noconfirm swww networkmanager

# 4) Pacman packages from list
read_pkg_list PAC_PKGS "$PACMAN_LIST"
if ((${#PAC_PKGS[@]} > 0)); then
  pacman_retry -S --needed --noconfirm "${PAC_PKGS[@]}"
fi

# 5) AUR packages from list
read_pkg_list AUR_PKGS "$AUR_LIST"
if ((${#AUR_PKGS[@]} > 0)); then
  install_yay_if_missing
  echo "==> installing AUR packages with yay..."
  yay -S --needed --noconfirm "${AUR_PKGS[@]}"
fi

# 6) Enable NetworkManager + migrate ISO Wi-Fi to NM so reboot works
enable_nm_and_takeover_network

# 7) Enable key services if present
if need_cmd systemctl; then
  if pacman -Qi power-profiles-daemon >/dev/null 2>&1; then
    sudo systemctl enable --now power-profiles-daemon.service 2>/dev/null || true
  fi
fi

# 8) Greeter (greetd) install if none detected/enabled
has_greeter=false
if need_cmd systemctl; then
  systemctl is-enabled --quiet display-manager.service && has_greeter=true || true
  for s in greetd sddm gdm lightdm ly; do
    systemctl is-enabled --quiet "$s.service" 2>/dev/null && has_greeter=true || true
  done
fi

if [[ "$has_greeter" == "false" ]]; then
  echo "==> No greeter detected. Installing greetd + greetd-tuigreet..."
  pacman_retry -S --needed --noconfirm greetd

  # Arch package name
  if pacman -Si greetd-tuigreet >/dev/null 2>&1; then
    pacman_retry -S --needed --noconfirm greetd-tuigreet
  else
    pacman_retry -S --needed --noconfirm tuigreet
  fi

  echo "==> Configuring /etc/greetd/config.toml ..."
  sudo install -d -m 0755 /etc/greetd
  sudo tee /etc/greetd/config.toml >/dev/null <<EOF
[terminal]
vt = 1

[default_session]
command = "/usr/bin/tuigreet --time --remember --cmd /usr/bin/Hyprland"
user = "$USER_NAME"
EOF

  sudo systemctl enable greetd.service
fi

# 9) Backups (non-symlinks)
mkdir -p "$BACKUP_DIR/.config" "$BACKUP_DIR/.local"

backup_if_exists() {
  local src="$1"
  if [[ -e "$src" && ! -L "$src" ]]; then
    mkdir -p "$(dirname "$BACKUP_DIR/$src")"
    mv "$src" "$BACKUP_DIR/$src"
  fi
}

for d in hypr waybar kitty nvim walker wlogout Thunar gtk-3.0 gtk-4.0 scripts; do
  backup_if_exists "$HOME/.config/$d"
done
backup_if_exists "$HOME/.local/bin"

# 10) Unfold ~/.local if broken from prior runs
unfold_local_if_broken

# 11) Stow packages
cd "$REPO_DIR"
for pkg in hypr waybar kitty nvim walker wlogout Thunar gtk-3.0 gtk-4.0 scripts; do
  [[ -d "$REPO_DIR/$pkg" ]] && stow -v "$pkg"
done
[[ -d "$REPO_DIR/bin" ]] && stow --no-folding -v bin

# 12) Seed monitors override if missing
if [[ ! -f "$HOME/.config/hypr/monitors.local.conf" ]] && [[ -f "$REPO_DIR/hypr/.config/hypr/monitors.local.conf.example" ]]; then
  cp "$REPO_DIR/hypr/.config/hypr/monitors.local.conf.example" "$HOME/.config/hypr/monitors.local.conf"
fi

# 13) Seed wal-generated configs if missing
if [[ ! -f "$HOME/.config/hypr/wal-colors.conf" ]] && [[ -f "$REPO_DIR/hypr/.config/hypr/wal-colors.conf.example" ]]; then
  cp "$REPO_DIR/hypr/.config/hypr/wal-colors.conf.example" "$HOME/.config/hypr/wal-colors.conf"
fi
if [[ ! -f "$HOME/.config/hypr/wal-hyprlock.conf" ]] && [[ -f "$REPO_DIR/hypr/.config/hypr/wal-hyprlock.conf.example" ]]; then
  cp "$REPO_DIR/hypr/.config/hypr/wal-hyprlock.conf.example" "$HOME/.config/hypr/wal-hyprlock.conf"
fi

# 14) Seed pywal cache for Waybar if missing
mkdir -p "$HOME/.cache/wal"
if [[ ! -f "$HOME/.cache/wal/colors-waybar.css" ]]; then
  cat >"$HOME/.cache/wal/colors-waybar.css" <<'EOF'
@define-color background #171821;
@define-color foreground #b1bccf;
@define-color cursor #b1bccf;

@define-color color0 #171821;
@define-color color1 #A93939;
@define-color color2 #9A5263;
@define-color color3 #E76262;
@define-color color4 #3C5B84;
@define-color color5 #5A6D91;
@define-color color6 #C87986;
@define-color color7 #b1bccf;
@define-color color8 #7b8390;
@define-color color9 #A93939;
@define-color color10 #9A5263;
@define-color color11 #E76262;
@define-color color12 #3C5B84;
@define-color color13 #5A6D91;
@define-color color14 #C87986;
@define-color color15 #b1bccf;
EOF
fi

echo "==> done. backup (if any): $BACKUP_DIR"
if [[ "$has_greeter" == "false" ]]; then
  echo "==> greetd enabled. Reboot to use the greeter: sudo reboot"
fi

# 15) Prompt: optionally install wallpapers
echo
echo "==> Wallpaper picker note:"
echo "    Super+W expects wallpapers in: $HOME/Pictures/wallpapers"
echo

if prompt_yes_no "Would you like to download William's wallpaper pack now?" "n"; then
  echo "==> Installing wallpapers into: $WALLPAPER_DIR"

  if ! need_cmd git-lfs; then
    echo "==> Installing git-lfs (required for high-res wallpapers)..."
    pacman_retry -S --needed --noconfirm git-lfs
    git lfs install --skip-repo >/dev/null 2>&1 || true
  fi

  mkdir -p "$HOME/Pictures"

  if [[ -d "$WALLPAPER_DIR/.git" ]]; then
    echo "==> wallpapers repo already exists; pulling latest..."
    (cd "$WALLPAPER_DIR" && git pull --ff-only) || true
    (cd "$WALLPAPER_DIR" && git lfs pull) || true
  elif [[ -e "$WALLPAPER_DIR" ]]; then
    echo "!! $WALLPAPER_DIR exists but is not a git repo. Skipping clone."
    echo "   Move it aside and re-run if you want the wallpaper pack."
  else
    git clone "$WALLPAPER_REPO_URL" "$WALLPAPER_DIR"
    (cd "$WALLPAPER_DIR" && git lfs pull) || true
  fi

  echo "==> Wallpapers installed."
else
  echo "==> Skipping wallpapers."
fi
