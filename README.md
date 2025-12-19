
# Dotfiles (Arch + Hyprland)

Hyprland desktop configuration managed with **GNU Stow**.

<img width="2256" height="1504" alt="Desktop screenshot" src="https://github.com/user-attachments/assets/4e6c239c-3c62-4f43-bc97-b900c9bbd31d" />

---

## What’s Included

**Configs**
- **Hyprland**: `hypr/`
- **Waybar**: `waybar/`
- **Kitty**: `kitty/`
- **Neovim**: `nvim/`
- **Walker**: `walker/`
- **wlogout**: `wlogout/`
- **Thunar + GTK**: `Thunar/`, `gtk-3.0/`, `gtk-4.0/`
- **Scripts**: `scripts/` (audio, network menus, screenshots, power profile, etc.)
- **User commands / wrappers**: `bin/` → `~/.local/bin` (e.g. `setwall`, `pickwall`, `update-hypr-wal`, wrappers for apps)

**Optional**
- **Wallpaper pack repo** (Git + Git LFS): installs into `~/Pictures/wallpapers`

---

## Requirements

- Arch-based distro (**pacman**)
- `git`, `stow` (installer will install these if missing)

---

## During Archinstall (if used) 
I suggest using the 'Minimal' Profile, as this repo has all you need to have a working enviorment. 
Save your network configuration you used on the ISO, the install.sh script will handle getting you to network-manager

## Install

```bash
git clone https://github.com/williamchildres/dotfiles.git ~/dotfiles
cd ~/dotfiles
./install.sh
```

## What the Installer Does
### 1) Network preflight (so pacman + git work)
Ensures basic connectivity + DNS resolution.
Writes a temporary /etc/resolv.conf if DNS is broken (best-effort).

### 2) Mirrors hardening
Refreshes /etc/pacman.d/mirrorlist from Arch mirrorlist endpoint.
Retries pacman operations with a backoff strategy.
Prunes failing mirror hosts from the mirrorlist as it detects them.

### 3) Installs packages
Installs base tools required for setup (git/stow/build tools).
Installs pacman packages from:
packages/pacman.txt
Installs AUR packages from:
packages/aur.txt (via yay, installed automatically if missing)

### 4) Sets up NetworkManager reliably
Installs and enables NetworkManager
Attempts to migrate “ISO Wi-Fi” setup into NetworkManager so it survives reboot
Leaves the old stack alone if NetworkManager takeover doesn’t immediately succeed (to avoid breaking networking)

### 5) Greeter (greetd + tuigreet)
If no display manager/greeter is enabled:
Installs greetd and greetd-tuigreet
Writes /etc/greetd/config.toml
Enables greetd.service

### 6) Symlinks dotfiles via Stow

Backs up existing configs into:
~/.dotfiles-backup/<timestamp>/...
Stows config folders into ~/.config/...
Stows bin/ into ~/.local/bin
Uses --no-folding to prevent ~/.local becoming a symlink (this avoids the “share/state in repo” problem)

### 7) Seeds required “first boot” files
These prevent errors when configs reference generated files that don’t exist yet:
~/.config/hypr/monitors.local.conf (copied from monitors.local.conf.example if missing)
~/.config/hypr/wal-colors.conf (copied from wal-colors.conf.example if missing)
~/.config/hypr/wal-hyprlock.conf (copied from wal-hyprlock.conf.example if missing)
~/.cache/wal/colors-waybar.css (writes a fallback if missing so Waybar can start)

### 8) Patches hardcoded home paths
If any configs still contain /home/william/... style paths, the installer patches a small allow-list of files (CSS/config) to use the current user’s $HOME.

### 9) Optional wallpaper pack
At the end, the installer prompts:
Clone wallpaper repo into: ~/Pictures/wallpapers
Installs git-lfs if needed and runs git lfs pull
