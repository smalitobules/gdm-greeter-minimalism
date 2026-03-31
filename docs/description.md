# GDM Greeter Minimalism

This project provides a single shell script that strips the Ubuntu GNOME greeter down to the essential login flow.

## Scope

- removes the top panel, quick settings, calendar, tray, and accessibility button from the greeter
- auto-detects the installed GNOME Shell resource library instead of pinning a single `libshell-*` version
- keeps the keyboard layout initialization intact
- forces a black greeter background
- applies the same minimal flow to the lock shortcut path so the auth prompt appears immediately
- configures `Super+L` for the calling user to switch straight to `gdmflexiserver`
- restores the original state on demand

## Script

The main entry point is `scripts/gdm-greeter-minimalism.sh`.

## Requirements

- Ubuntu with GDM and GNOME Shell
- `bash`, `python3`, `gjs`, `gresource`, `dconf`, `dbus-run-session`, `systemctl`
- `gsettings`, `gdmflexiserver`
- the Python package `gdms`
- root privileges for `apply` and `restore`

## Usage

```bash
sudo ./scripts/gdm-greeter-minimalism.sh apply
sudo ./scripts/gdm-greeter-minimalism.sh verify
sudo ./scripts/gdm-greeter-minimalism.sh restore
```

Use `--restart` with `apply` or `restore` to restart `gdm` immediately.

`apply` also manages the calling user's `Super+L` shortcut so the lock action goes straight to the fast login-screen path.

## Result

The greeter is reduced to a fast, black, minimal login surface focused on manual username and password entry, and the lock shortcut follows the same minimal path.
