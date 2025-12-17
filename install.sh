#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACMAN_LIST="$REPO_DIR/packages/pacman.txt"
AUR_LIST="$REPO_DIR/packages/aur.txt"
BACKUP_DIR="$HOME/.dotfiles-backup/$(date +%Y%m%d-%H%M%S)"

need_cmd() { command -v "$1" >/dev/null 2>&1; }

echo "==> dotfiles installer"
echo "==> repo: $REPO_DIR"

if ! need_cmd pacman; then
  echo "!! Arch-based only (pacman required)."
  exit 1
fi

sudo pacman -Syu --needed --noconfirm git stow base-devel curl

if [[ -f "$PACMAN_LIST" ]]; then
  sudo pacman -S --needed --noconfirm $(grep -vE '^\s*#|^\s*$' "$PACMAN_LIST")
fi

# AUR helper
AUR_HELPER=""
for h in paru yay; do
  if need_cmd "$h"; then
    AUR_HELPER="$h"
    break
  fi
done

if [[ -f "$AUR_LIST" ]] && [[ -n "$(grep -vE '^\s*#|^\s*$' "$AUR_LIST" || true)" ]]; then
  if [[ -z "$AUR_HELPER" ]]; then
    echo "==> installing paru (AUR helper)..."
    tmp="$(mktemp -d)"
    git clone https://aur.archlinux.org/paru.git "$tmp/paru"
    (cd "$tmp/paru" && makepkg -si --noconfirm)
    rm -rf "$tmp"
    AUR_HELPER="paru"
  fi
  "$AUR_HELPER" -S --needed --noconfirm $(grep -vE '^\s*#|^\s*$' "$AUR_LIST")
fi

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

cd "$REPO_DIR"
for pkg in hypr waybar kitty nvim walker wlogout Thunar gtk-3.0 gtk-4.0 scripts bin; do
  [[ -d "$REPO_DIR/$pkg" ]] && stow -v "$pkg"
done

echo "==> done. backup (if any): $BACKUP_DIR"
