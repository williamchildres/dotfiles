#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACMAN_LIST="$REPO_DIR/packages/pacman.txt"
AUR_LIST="$REPO_DIR/packages/aur.txt"
BACKUP_DIR="$HOME/.dotfiles-backup/$(date +%Y%m%d-%H%M%S)"

need_cmd() { command -v "$1" >/dev/null 2>&1; }

read_pkg_list() {
  # Reads a list file into array name passed as $1
  # Strips blank lines and comments.
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

echo "==> dotfiles installer"
echo "==> repo: $REPO_DIR"

if ! need_cmd pacman; then
  echo "!! Arch-based only (pacman required)."
  exit 1
fi

# Base deps (needed for building yay + stow)
sudo pacman -Syu --needed --noconfirm git stow base-devel curl

# Pacman packages
read_pkg_list PAC_PKGS "$PACMAN_LIST"
if ((${#PAC_PKGS[@]} > 0)); then
  sudo pacman -S --needed --noconfirm "${PAC_PKGS[@]}"
fi

# AUR packages via yay
read_pkg_list AUR_PKGS "$AUR_LIST"
if ((${#AUR_PKGS[@]} > 0)); then
  if ! need_cmd yay; then
    echo "==> installing yay (AUR helper)..."
    tmp="$(mktemp -d)"
    git clone https://aur.archlinux.org/yay.git "$tmp/yay"
    (cd "$tmp/yay" && makepkg -si --noconfirm)
    rm -rf "$tmp"
  fi

  echo "==> installing AUR packages with yay..."
  yay -S --needed --noconfirm "${AUR_PKGS[@]}"
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
  sudo pacman -S --needed --noconfirm greetd tuigreet
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

# ---- Stow packages ----
cd "$REPO_DIR"
for pkg in hypr waybar kitty nvim walker wlogout Thunar gtk-3.0 gtk-4.0 scripts bin; do
  [[ -d "$REPO_DIR/$pkg" ]] && stow -v "$pkg"
done

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

echo "==> done. backup (if any): $BACKUP_DIR"
