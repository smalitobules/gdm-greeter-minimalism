# gdm-greeter-minimalism

`gdm-greeter-minimalism` reduces the Ubuntu GDM greeter to a fast black login flow without the panel, quick settings, calendar, tray, accessibility menu, or user avatar.

## Scope

- removes the visible GNOME Shell greeter controls and user avatar
- forces a black greeter background
- preserves keyboard layout initialization
- sends the lock-screen path straight to the authentication dialog
- sets `Super+L` to `gdmflexiserver` for the calling user
- restores the original state on demand

## Requirements

- Ubuntu with GDM and GNOME Shell
- `bash`
- `python3`
- `gjs`
- `gresource`
- `dconf`
- `dbus-run-session`
- `systemctl`
- `gsettings`
- `gdmflexiserver`
- Python package `gdms`
- root privileges for `apply` and `restore`

## Usage

```bash
sudo ./scripts/gdm-greeter-minimalism.sh apply
sudo ./scripts/gdm-greeter-minimalism.sh verify
sudo ./scripts/gdm-greeter-minimalism.sh restore
```

Use `--restart` with `apply` or `restore` to restart `gdm` immediately.

## Files

- `scripts/gdm-greeter-minimalism.sh`: main script
- `docs/description.md`: short project description

## License

GPL-3.0-only. See `LICENSE`.
