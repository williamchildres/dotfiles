# Dotfiles (Arch + Hyprland)

Hyprland desktop configuration managed with **GNU Stow**, built to be **portable** (no hardcoded usernames) and friendly on fresh installs.

<img width="2256" height="1504" alt="image" src="https://github.com/user-attachments/assets/4e6c239c-3c62-4f43-bc97-b900c9bbd31d" />

---

## What’s included

- **Hyprland**: `hypr/`
  - Supports `pywal`-driven colors via `wal-colors.conf`
  - Supports hyprlock theming via `wal-hyprlock.conf`
  - Supports per-machine display config override via `monitors.local.conf`
- **Waybar**: `waybar/`
- **Kitty**: `kitty/`
- **Neovim**: `nvim/`
- **Walker launcher**: `walker/`
- **wlogout**: `wlogout/`
- **Thunar + GTK**: `Thunar/`, `gtk-3.0/`, `gtk-4.0/`
- **Scripts**: `scripts/`
  - audio, network menu, screenshot, power profile, etc.
- **User commands**: `bin/` → `~/.local/bin`
  - `setwall`, `pickwall`, `update-hypr-wal`, wrappers (teams-for-linux, obsidian, etc.)

---

## Requirements

- **Arch-based** distro (installer uses `pacman`)
- Base tools: `git`, `stow`

Everything else is installed by the installer using:
- `packages/pacman.txt`
- `packages/aur.txt` (via `yay`)

---

## Install (Arch-based)

```bash
git clone https://github.com/williamchildres/dotfiles.git ~/dotfiles
cd ~/dotfiles
./install.sh
