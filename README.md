
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

## Install

```bash
git clone https://github.com/williamchildres/dotfiles.git ~/dotfiles
cd ~/dotfiles
./install.sh
