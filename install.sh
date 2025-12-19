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

start_network_stack_best_effort() {
  if ! need_cmd systemctl; then return 0; fi

  # If NetworkManager is installed, enable it (desired end state).
  if pacman -Qi networkmanager >/dev/null 2>&1; then
    sudo systemctl enable --now NetworkManager.service >/dev/null 2>&1 || true
  fi

  # If systemd-networkd/resolved exist, start them (helps on minimal installs).
  sudo systemctl start systemd-networkd.service >/dev/null 2>&1 || true
  sudo systemctl start systemd-resolved.service >/dev/null 2>&1 || true
}

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
  start_network_stack_best_effort
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
    echo "   Check:"
    echo "     - systemctl status NetworkManager systemd-resolved"
    echo "     - cat /etc/resolv.conf"
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

  # Prune common bad/blocked mirrors + ftp
  sudo sed -i '/^Server = ftp:\/\//d;/osuosl/d;/osouos1/d' /etc/pacman.d/mirrorlist || true
}

extract_failed_mirror_host() {
  sed -nE "s/.*failed retrieving file '.*' from ([^ ]+).*/\1/p" | tail -n 1
}

pacman_retry() {
  local tries=5
  local n=1
  local out host rc=0

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
  done

  echo "!! pacman failed after $tries attempts." >&2
  return 1
}

# ---------------------------
# NetworkManager adoption (don’t cut over until connected)
# ---------------------------

wait_for_nm_connected() {
  local i
  for i in {1..20}; do
    nmcli -t -f STATE general status 2>/dev/null | grep -q '^connected$' && return 0
    sleep 1
  done
  return 1
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

# ---------------------------
# Patch hardcoded /home/william -> current $HOME (for cloned systems)
# ---------------------------

patch_home_paths_in_configs() {
  # Only patch if files contain /home/william (your build username)
  local old="/home/william"
  local new="$HOME"
  local files=(
    "$HOME/.config/waybar/style.css"
    "$HOME/.config/hypr/hyprland.conf"
    "$HOME/.config/hypr/hyprlock.conf"
    "$HOME/.config/hypr/hypridle.conf"
    "$HOME/.config/kitty/kitty.conf"
    "$HOME/.config/scripts/powerprofile.sh"
    "$HOME/.config/scripts/screenshot.sh"
  )

  local f
  for f in "${files[@]}"; do
    [[ -f "$f" ]] || continue
    if grep -q "$old" "$f"; then
      echo "==> Patching home path in: $f"
      sed -i "s#${old}#${new}#g" "$f" || true
    fi
  done

  # Additionally, patch any file:// import that points at /home/william/.cache/wal
  local wb="$HOME/.config/waybar/style.css"
  if [[ -f "$wb" ]]; then
    sed -i "s#file:///home/william/#file://$HOME/#g" "$wb" 2>/dev/null || true
  fi
}

echo "==> dotfiles installer"
echo "==> repo: $REPO_DIR"

if ! need_cmd pacman; then
  echo "!! Arch-based only (pacman required)."
  exit 1
fi

# 0) Preflight network + DNS
preflight_network_or_die

# 1) Refresh mirrors (DNS ok)
refresh_pacman_mirrors_every_time

# 2) Base deps
pacman_retry -Syyu --needed --noconfirm git stow base-devel curl

# 3) Pacman packages
read_pkg_list PAC_PKGS "$PACMAN_LIST"
if ((${#PAC_PKGS[@]} > 0)); then
  pacman_retry -S --needed --noconfirm "${PAC_PKGS[@]}"
fi

# 4) AUR packages via yay
read_pkg_list AUR_PKGS "$AUR_LIST"
if ((${#AUR_PKGS[@]} > 0)); then
  install_yay_if_missing
  echo "==> installing AUR packages with yay..."
  yay -S --needed --noconfirm "${AUR_PKGS[@]}"
fi

# ---- Enable/adopt key services ----
if need_cmd systemctl; then
  # Networking: prefer NetworkManager if installed; don't disable others until connected.
  if pacman -Qi networkmanager >/dev/null 2>&1; then
    sudo systemctl enable --now NetworkManager.service

    if need_cmd nmcli && wait_for_nm_connected; then
      sudo systemctl disable --now systemd-networkd.service 2>/dev/null || true
      sudo systemctl disable --now dhcpcd.service 2>/dev/null || true
    else
      echo "!! NetworkManager enabled but not connected yet."
      echo "   Not disabling systemd-networkd/dhcpcd to avoid losing networking."
      echo "   If you're on Wi-Fi, run: nmtui  (or: nmcli dev wifi connect ...)"
    fi
  fi

  # Power profiles daemon
  if pacman -Qi power-profiles-daemon >/dev/null 2>&1; then
    sudo systemctl enable --now power-profiles-daemon.service 2>/dev/null || true
  fi
fi

# ---- Greeter (greetd) install if none detected/enabled ----
has_greeter=false
if need_cmd systemctl; then
  systemctl is-enabled --quiet display-manager.service && has_greeter=true || true
  for s in greetd sddm gdm lightdm ly; do
    systemctl is-enabled --quiet "$s.service" 2>/dev/null && has_greeter=true || true
  done
fi

if [[ "$has_greeter" == "false" ]]; then
  echo "==> No greeter detected. Installing greetd + tuigreet..."
  pacman_retry -S --needed --noconfirm greetd

  # Arch commonly ships tuigreet as greetd-tuigreet
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

# ---- Backups of existing real dirs/files (non-symlinks) ----
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

# ---- Unfold ~/.local if a previous run caused stow folding ----
unfold_local_if_broken

# ---- Stow packages ----
cd "$REPO_DIR"
for pkg in hypr waybar kitty nvim walker wlogout Thunar gtk-3.0 gtk-4.0 scripts; do
  [[ -d "$REPO_DIR/$pkg" ]] && stow -v "$pkg"
done
[[ -d "$REPO_DIR/bin" ]] && stow --no-folding -v bin

# ---- Seed monitors override if missing ----
if [[ ! -f "$HOME/.config/hypr/monitors.local.conf" ]] && [[ -f "$REPO_DIR/hypr/.config/hypr/monitors.local.conf.example" ]]; then
  cp "$REPO_DIR/hypr/.config/hypr/monitors.local.conf.example" "$HOME/.config/hypr/monitors.local.conf"
fi

# ---- Seed wal-generated configs if missing ----
if [[ ! -f "$HOME/.config/hypr/wal-colors.conf" ]] && [[ -f "$REPO_DIR/hypr/.config/hypr/wal-colors.conf.example" ]]; then
  cp "$REPO_DIR/hypr/.config/hypr/wal-colors.conf.example" "$HOME/.config/hypr/wal-colors.conf"
fi
if [[ ! -f "$HOME/.config/hypr/wal-hyprlock.conf" ]] && [[ -f "$REPO_DIR/hypr/.config/hypr/wal-hyprlock.conf.example" ]]; then
  cp "$REPO_DIR/hypr/.config/hypr/wal-hyprlock.conf.example" "$HOME/.config/hypr/wal-hyprlock.conf"
fi

# ---- Seed pywal cache for Waybar if missing (prevents Waybar failing on first boot) ----
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

# ---- Patch /home/william -> $HOME anywhere it exists (fixes new username installs) ----
patch_home_paths_in_configs

echo "==> done. backup (if any): $BACKUP_DIR"
if [[ "$has_greeter" == "false" ]]; then
  echo "==> greetd enabled. Reboot to use the greeter: sudo reboot"
fi

# ---- Prompt: optionally install wallpapers ----
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
