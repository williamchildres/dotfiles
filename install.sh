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
# NETWORK + DNS (TCP-first)
# ---------------------------

have_route() {
  ip route show default >/dev/null 2>&1
}

have_internet_basic() {
  # TCP checks (what pacman needs). Prefer IPv4.
  curl -4 -fsI --connect-timeout 2 --max-time 6 https://geo.mirror.pkgbuild.com >/dev/null 2>&1 && return 0
  # fallback to ICMP
  ping -c 1 -W 1 8.8.8.8 >/dev/null 2>&1 && return 0
  ping -c 1 -W 1 1.1.1.1 >/dev/null 2>&1 && return 0
  return 1
}

have_dns() {
  getent hosts archlinux.org >/dev/null 2>&1
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

prefer_ipv4_best_effort() {
  # Helps when IPv6 exists but is broken (common in VMs / some wifi).
  if [[ -f /etc/gai.conf ]]; then
    sudo sed -i 's/^[# ]*precedence ::ffff:0:0\/96.*/precedence ::ffff:0:0\/96  100/' /etc/gai.conf || true
    if ! grep -q '^precedence ::ffff:0:0/96' /etc/gai.conf; then
      echo 'precedence ::ffff:0:0/96  100' | sudo tee -a /etc/gai.conf >/dev/null
    fi
  fi
}

preflight_network_or_die() {
  echo "==> network preflight..."

  if need_cmd timedatectl; then
    sudo timedatectl set-ntp true >/dev/null 2>&1 || true
  fi

  if need_cmd systemctl; then
    # Start resolver first, then network (best effort)
    sudo systemctl start systemd-resolved.service >/dev/null 2>&1 || true
    sudo systemctl start NetworkManager.service >/dev/null 2>&1 || true
    sudo systemctl start iwd.service >/dev/null 2>&1 || true
    sudo systemctl start systemd-networkd.service >/dev/null 2>&1 || true
  fi

  sleep 2

  if ! have_route; then
    echo "!! No default route detected."
    echo "   Fix network first (Wi-Fi/NAT/bridge), then rerun."
    exit 1
  fi

  if ! have_internet_basic; then
    echo "!! No internet detected (TCP/ICMP checks failed)."
    echo "   Fix network first, then rerun."
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

  prefer_ipv4_best_effort

  echo "==> network OK (route + internet + DNS)."
}

# ---------------------------
# MIRRORS + PACMAN RETRIES
# ---------------------------

refresh_mirrors_reflector_first() {
  local country="${MIRROR_COUNTRY:-US}"
  local bak="/etc/pacman.d/mirrorlist.bak.$(date +%Y%m%d-%H%M%S)"

  echo "==> refreshing pacman mirrors (reflector preferred, country=${country})..."
  sudo cp -f /etc/pacman.d/mirrorlist "$bak" 2>/dev/null || true

  # ensure reflector exists (from official repos)
  if ! need_cmd reflector; then
    # don't use pacman_retry yet (it depends on mirrorlist); use plain pacman best effort
    sudo pacman -Sy --needed --noconfirm reflector >/dev/null 2>&1 || true
  fi

  if need_cmd reflector; then
    # HTTPS only, recent, fast
    if sudo reflector \
      --country "$country" \
      --protocol https \
      --age 24 \
      --latest 30 \
      --sort rate \
      --save /etc/pacman.d/mirrorlist; then
      return 0
    fi
  fi

  # Fallback: archlinux.org mirrorlist generator
  if need_cmd curl; then
    local url="https://archlinux.org/mirrorlist/?country=${country}&protocol=https&ip_version=4&use_mirror_status=on"
    if sudo curl -fsSL "$url" -o /etc/pacman.d/mirrorlist; then
      sudo sed -i 's/^#Server/Server/' /etc/pacman.d/mirrorlist || true
      return 0
    fi
  fi

  echo "!! mirror refresh failed; keeping existing mirrorlist."
  return 0
}

extract_failed_mirror_host() {
  sed -nE "s/.*failed retrieving file '.*' from ([^ ]+).*/\1/p" | tail -n 1
}

prune_bad_mirrors_best_effort() {
  # Remove mirrors you’ve hit repeatedly (and ftp).
  sudo sed -i \
    -e '/^Server = ftp:\/\//d' \
    -e '/osuosl/d' \
    -e '/rackspace/d' \
    -e '/dfw\.mirror\.rackspace/d' \
    -e '/osouos1/d' \
    /etc/pacman.d/mirrorlist 2>/dev/null || true
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

    # DNS-looking errors: only repair if DNS is actually failing NOW.
    if grep -qiE 'could not resolve host|name or service not known|temporary failure in name resolution' <<<"$out"; then
      if have_dns; then
        echo "!! pacman printed DNS-looking error, but DNS currently works."
        echo "   Treating as transient mirror/network hiccup; rebuilding mirrorlist and retrying..."
      else
        echo "!! Detected real DNS failure during pacman; attempting repair..."
        force_temp_resolv_conf
        sleep 1
        if ! have_dns; then
          preflight_network_or_die
        fi
      fi
    fi

    host="$(printf "%s\n" "$out" | extract_failed_mirror_host || true)"
    echo "!! pacman failed. Refreshing mirrors and pruning host: ${host:-unknown}" >&2

    refresh_mirrors_reflector_first
    prune_bad_mirrors_best_effort

    if [[ -n "${host:-}" ]]; then
      sudo sed -i "\#${host}#d" /etc/pacman.d/mirrorlist || true
    fi

    ((n++))
    sleep 2
  done

  echo "!! pacman failed after $tries attempts." >&2
  return 1
}

# ---------------------------
# STOW FOLDING FIX
# ---------------------------

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
# PATCH /home/william PATHS
# ---------------------------

patch_home_paths() {
  local from="/home/william"
  local to="$HOME"

  local files=(
    "$HOME/.config/waybar/style.css"
    "$HOME/.config/walker/themes/pywall/style.css"
    "$HOME/.config/gtk-3.0/gtk.css"
    "$HOME/.config/gtk-4.0/gtk.css"
    "$HOME/.config/wlogout/style.css"
  )

  for f in "${files[@]}"; do
    [[ -f "$f" ]] || continue
    sed -i \
      -e "s|file:///home/william|file://$to|g" \
      -e "s|$from|$to|g" \
      "$f" || true
  done
}

# ---------------------------
# MAIN
# ---------------------------

echo "==> dotfiles installer"
echo "==> repo: $REPO_DIR"

if ! need_cmd pacman; then
  echo "!! Arch-based only (pacman required)."
  exit 1
fi

# 0) Network must be good BEFORE touching mirrors/pacman
preflight_network_or_die

# 1) Mirror refresh (reflector preferred)
refresh_mirrors_reflector_first
prune_bad_mirrors_best_effort

# 2) Base deps
pacman_retry -Syyu --needed --noconfirm git stow base-devel curl

# 3) Ensure critical runtime tools (these are used by your scripts)
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

# 6) Greeter install (DO THIS BEFORE any network takeover/restarts)
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
  pacman_retry -S --needed --noconfirm greetd-tuigreet

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

# 7) Enable key services (NOW it is safe to touch NM)
if need_cmd systemctl; then
  if pacman -Qi networkmanager >/dev/null 2>&1; then
    sudo systemctl enable --now NetworkManager.service >/dev/null 2>&1 || true
  fi

  if pacman -Qi power-profiles-daemon >/dev/null 2>&1; then
    sudo systemctl enable --now power-profiles-daemon.service >/dev/null 2>&1 || true
  fi
fi

# 8) Backups (non-symlinks)
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

# 9) Unfold ~/.local if broken from prior runs
unfold_local_if_broken

# 10) Stow packages
cd "$REPO_DIR"
for pkg in hypr waybar kitty nvim walker wlogout Thunar gtk-3.0 gtk-4.0 scripts; do
  [[ -d "$REPO_DIR/$pkg" ]] && stow -v "$pkg"
done
[[ -d "$REPO_DIR/bin" ]] && stow --no-folding -v bin

# 11) Seed monitors override if missing
if [[ ! -f "$HOME/.config/hypr/monitors.local.conf" ]] && [[ -f "$REPO_DIR/hypr/.config/hypr/monitors.local.conf.example" ]]; then
  cp "$REPO_DIR/hypr/.config/hypr/monitors.local.conf.example" "$HOME/.config/hypr/monitors.local.conf"
fi

# 12) Seed wal-generated configs if missing
if [[ ! -f "$HOME/.config/hypr/wal-colors.conf" ]] && [[ -f "$REPO_DIR/hypr/.config/hypr/wal-colors.conf.example" ]]; then
  cp "$REPO_DIR/hypr/.config/hypr/wal-colors.conf.example" "$HOME/.config/hypr/wal-colors.conf"
fi
if [[ ! -f "$HOME/.config/hypr/wal-hyprlock.conf" ]] && [[ -f "$REPO_DIR/hypr/.config/hypr/wal-hyprlock.conf.example" ]]; then
  cp "$REPO_DIR/hypr/.config/hypr/wal-hyprlock.conf.example" "$HOME/.config/hypr/wal-hyprlock.conf"
fi

# 13) Patch hardcoded /home/william paths
patch_home_paths

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
