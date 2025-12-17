# Dotfiles (Arch + Hyprland)

Hyprland desktop configuration managed with **GNU Stow**.
<img width="2256" height="1504" alt="image" src="https://github.com/user-attachments/assets/4e6c239c-3c62-4f43-bc97-b900c9bbd31d" />

## Included
- Hyprland: `hypr/`
- Waybar: `waybar/`  (includes a performance drawer group + idle inhibitor)
- Kitty: `kitty/`
- Neovim: `nvim/`
- Walker: `walker/`
- wlogout: `wlogout/`
- swaync: (if you add it later)
- Thunar + GTK: `Thunar/`, `gtk-3.0/`, `gtk-4.0/`
- Scripts: `scripts/` (audio, network, screenshot, power profile, etc.)
- User commands/wrappers: `bin/` → `~/.local/bin` (`setwall`, `pickwall`, `update-hypr-wal`, wrappers:(teams-for-linux, obsidian))

## Requirements
- Arch-based distro (installer uses 'pacman')
- Packages: 'git', 'stow'

## Install (Arch-based)
``` bash
git clone https://github.com/williamchildres/dotfiles.git ~/dotfiles
cd ~/dotfiles
./install.sh
```

## This will: 
1. Install dependencies from packages/pacman.txt and packages/aur.txt
2. Back up conflicting existing configs to ~/.dodtfiles-backup/<timestamp>
3. Symlink configs into place via 'stow'

## Updating
``` bash
cd ~/dotfiles
git pull
stow -R hypr waybar kitty nvim walker wlogout Thunar gtk-3.0 gtk-4.0 scripts bin
```

## Uninstall (remove symlinks)
``` bash
cd ~/dotfiles
stow -D hypr waybar kitty nvim walker wlogout Thunar gtk-3.0 gtk-4.0 scripts bin
```
``

