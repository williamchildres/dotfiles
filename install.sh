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
  # Reads a list file into array name passed as $1; strips comments/blank lines.
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

prompt_yes_no() {
  # Usage: prompt_yes_no "Question?" "y|n"
  local q="${1:?}"
  local def="${2:-n}"
  local ans

  # Non-interactive runs default to "no"
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

refresh_pacman_mirrors_every_time() {
  local country="${MIRROR_COUNTRY:-US}"
  local bak="/etc/pacman.d/mirrorlist.bak.$(date +%Y%m%d-%H%M%S)"

  echo "==> refreshing pacman mirrors (reflector: country=${country}, https)..."

  sudo cp -f /etc/pacman.d/mirrorlist "$bak" 2>/dev/null || true

  # Ensure time sync (TLS failures can happen with bad clocks)
  if need_cmd timedatectl; then
    sudo timedatectl set-ntp true >/dev/null 2>&1 || true
  fi

  # Install reflector if missing (small, worth it)
  if ! need_cmd reflector; then
    sudo pacman -Sy --needed --noconfirm reflector
  fi

  # Generate a fast, reliable mirrorlist (HTTPS only)
  sudo reflector \
    --country "$country" \
    --protocol https \
    --age 24 \
    --latest 25 \
    --sort rate \
    --save /etc/pacman.d/mirrorlist
}

# ---- Fix bad stow folding of ~/.local (prevents share/state landing in repo) ----
unfold_local_if_broken() {
  if [[ -L "$HOME/.local" ]]; then
    local target
    target="$(readlink -f "$HOME/.local" || true)"

    # Only unfold if it points into our repo (common failure mode)
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

# ---- Always refresh mirrors first ----
refresh_pacman_mirrors_every_time

# Base deps (needed for building yay + stow).
sudo pacman -Syyu --needed --noconfirm git stow base-devel curl

# Pacman packages
read_pkg_list PAC_PKGS "$PACMAN_LIST"
if ((${#PAC_PKGS[@]} > 0)); then
  sudo pacman -S --needed --noconfirm "${PAC_PKGS[@]}"
fi

# AUR packages via yay
read_pkg_list AUR_PKGS "$AUR_LIST"
if ((${#AUR_PKGS[@]} > 0)); then
  install_yay_if_missing
  echo "==> installing AUR packages with yay..."
  yay -S --needed --noconfirm "${AUR_PKGS[@]}"
fi

# ---- Enable key services if present ----
if need_cmd systemctl; then
  # Networking: prefer NetworkManager if installed
  if pacman -Qi networkmanager >/dev/null 2>&1; then
    sudo systemctl enable --now NetworkManager.service
    sudo systemctl disable --now systemd-networkd.service 2>/dev/null || true
    sudo systemctl disable --now dhcpcd.service 2>/dev/null || true
  fi

  # Power profiles
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
  sudo pacman -S --needed --noconfirm greetd

  # Arch commonly ships tuigreet as greetd-tuigreet
  if pacman -Si greetd-tuigreet >/dev/null 2>&1; then
    sudo pacman -S --needed --noconfirm greetd-tuigreet
  else
    if pacman -Si tuigreet >/dev/null 2>&1; then
      sudo pacman -S --needed --noconfirm tuigreet
    else
      install_yay_if_missing
      yay -S --needed --noconfirm tuigreet
    fi
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

# NOTE: do NOT back up ~/.local as a whole; only ~/.local/bin when it's a real dir
backup_if_exists "$HOME/.local/bin"

# ---- Unfold ~/.local if a previous run caused stow folding ----
unfold_local_if_broken

# ---- Stow packages ----
cd "$REPO_DIR"

# stow ~/.config packages normally
for pkg in hypr waybar kitty nvim walker wlogout Thunar gtk-3.0 gtk-4.0 scripts; do
  [[ -d "$REPO_DIR/$pkg" ]] && stow -v "$pkg"
done

# stow bin WITHOUT folding so ~/.local never becomes a symlink
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
    sudo pacman -S --needed --noconfirm git-lfs
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
