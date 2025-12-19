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
```


What the installer does
1) Network + DNS hardening (preflight)

Fresh installs often fail to pacman / git clone because DNS or networking isn’t actually up yet.

The installer:

Verifies basic internet (e.g., can reach 1.1.1.1)

Verifies DNS works (can resolve domains)

Starts/ensures the network stack is running

If NetworkManager is installed, enables it and prefers it

2) Mirror refresh + package retries

Package downloads fail frequently when you get a bad mirror.

The installer:

Refreshes the Arch mirrorlist (country-based)

Removes known-bad mirror hosts when they fail

Retries pacman operations multiple times instead of dying immediately

You can set a mirror country during install:

MIRROR_COUNTRY=US ./install.sh

3) Installs packages

Installs base build/runtime dependencies first (git, stow, base-devel, etc.)

Installs packages from packages/pacman.txt

Installs yay if missing, then installs packages/aur.txt

4) Enables core services

If present, the installer enables and starts:

NetworkManager.service

power-profiles-daemon.service (if installed)

5) Installs a greeter if none exists

If no display manager/greeter is enabled, it installs and configures:

greetd

greetd-tuigreet

It then writes /etc/greetd/config.toml so tuigreet launches Hyprland.

6) Backs up conflicts

Before symlinking, it moves any existing real configs (non-symlink dirs/files) into:

~/.dotfiles-backup/<timestamp>/...

7) Stows configs (symlinks into place)

The installer uses Stow to link modules into:

~/.config/...

~/.local/bin

Important detail:

It uses stow --no-folding bin so your system never ends up with ~/.local -> ~/dotfiles/... (the “share/state folded into the repo” issue).

8) Seeds first-boot defaults (so nothing crashes)

On a fresh install, some things fail because generated files don’t exist yet.

The installer seeds these if missing:

~/.config/hypr/monitors.local.conf from monitors.local.conf.example

~/.config/hypr/wal-colors.conf from wal-colors.conf.example

~/.config/hypr/wal-hyprlock.conf from wal-hyprlock.conf.example

~/.cache/wal/colors-waybar.css fallback so Waybar can start before wal runs

9) Optional wallpapers install

At the end it prompts you to install wallpapers into:

~/Pictures/wallpapers

This is required for the wallpaper picker keybind (Super+W) to work as intended.

Monitors (per-machine display setup)

Hyprland display configs vary by machine, especially for external monitors.

This repo supports a local override file:

~/.config/hypr/monitors.local.conf

On first install, the installer copies:

hypr/.config/hypr/monitors.local.conf.example → ~/.config/hypr/monitors.local.conf

Edit monitors.local.conf on each machine to set resolution/position/refresh rate.

Wallpapers + pywal theming
Wallpaper picker

Super + W opens the wallpaper picker.

It expects wallpapers at:

~/Pictures/wallpapers

Theme pipeline

Picking a wallpaper triggers:

swww img ... (sets wallpaper)

wal -i ... -n (generates theme colors)

update-hypr-wal (writes wal-colors.conf + wal-hyprlock.conf)

Restarts Waybar

Reloads Hyprland

First boot note

Waybar imports ~/.cache/wal/colors-waybar.css.
If it doesn’t exist, Waybar may fail to start. The installer seeds a fallback file to avoid that.

Keybinds (basics)

Review: hypr/.config/hypr/hyprland.conf for the full list.

Super + Return: Terminal (Kitty)

Super + E: File manager (Thunar)

Super + B: Browser (Zen, if installed)

Super + M: Launcher (Walker)

Super + W: Wallpaper picker (requires ~/Pictures/wallpapers)

Super + L: Lock (hyprlock)

Print / Shift+Print / Ctrl+Print: Screenshot scripts

Updating
``` bash
cd ~/dotfiles
git pull
stow -R hypr waybar kitty nvim walker wlogout Thunar gtk-3.0 gtk-4.0 scripts
stow -R --no-folding bin
```

Using --no-folding for bin prevents ~/.local from turning into a symlink.

Uninstall (remove symlinks)
``` bash
cd ~/dotfiles
stow -D hypr waybar kitty nvim walker wlogout Thunar gtk-3.0 gtk-4.0 scripts
stow -D --no-folding bin
```

Notes / Troubleshooting
Waybar doesn’t appear

Common causes:

~/.cache/wal/colors-waybar.css missing

Waybar not installed

Hyprland exec-once = waybar missing

Check:
``` bash
waybar -l debug
ls -la ~/.cache/wal/colors-waybar.css
```
Walker opens but shows “no results”

Walker needs .desktop entries from installed apps and sometimes needs its cache built.
Try:

Install some apps first

Restart walker (or log out/in)
