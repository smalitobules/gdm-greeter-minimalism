#!/usr/bin/env bash
set -euo pipefail

legacy_theme_target="/usr/share/gnome-shell/gnome-shell-theme.gresource"
legacy_backup="${legacy_theme_target}.ggm-backup-greeter-controls"
legacy_state="${legacy_theme_target}.ggm-backup-greeter-controls.source"
legacy_needle="#panel.login-screen > * {"
lock_file="/run/lock/disable-gdm-greeter-controls.lock"
python_path="/usr/local/lib/python3/dist-packages"
shell_resource=""
overlay_root="/usr/local/share/gnome-shell-overrides/greeter-controls"
user_shell_dropin_dir="/etc/systemd/user/org.gnome.Shell@wayland.service.d"
user_shell_dropin_file="${user_shell_dropin_dir}/90-disable-greeter-controls.conf"
gdm_service_dropin_dir="/etc/systemd/system/gdm.service.d"
gdm_service_dropin_file="${gdm_service_dropin_dir}/90-disable-greeter-controls.conf"
gdm_generate_config=""
greeter_dconf_file="/etc/gdm3/greeter.dconf-defaults"
greeter_input_begin="# ggm-managed-greeter-input-sources begin"
greeter_input_end="# ggm-managed-greeter-input-sources end"
gdm_input_state="/etc/gdm3/.ggm-gdm-input-sources.state"
greeter_background_begin="# ggm-managed-greeter-background begin"
greeter_background_end="# ggm-managed-greeter-background end"
gdm_background_state="/etc/gdm3/.ggm-gdm-background.state"
user_shortcut_state="/etc/gdm3/.ggm-user-shortcut.state"
user_shortcut_path="/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/gdm-greeter-minimalism/"

resolved_target_user=""
resolved_sources=""
resolved_mru_sources=""
resolved_xkb_options=""
resolved_input_origin=""

usage() {
    printf '%s\n' "Nutzung: $0 apply [--restart] | verify | restore [--restart]" >&2
}

die() {
    printf '%s\n' "$1" >&2
    exit 1
}

require_root() {
    [[ "$(id -u)" -eq 0 ]] || die "Dieses Skript muss als root laufen."
}

resolve_shell_resource() {
    if [[ -n "${shell_resource}" ]]; then
        return 0
    fi

    shell_resource="$(
        python3 - <<'PY'
import glob
import os
import re

patterns = [
    "/usr/lib/gnome-shell/libshell-*.so",
    "/usr/lib64/gnome-shell/libshell-*.so",
    "/lib/gnome-shell/libshell-*.so",
    "/lib64/gnome-shell/libshell-*.so",
]

candidates = []
for pattern in patterns:
    candidates.extend(glob.glob(pattern))

unique = sorted({os.path.realpath(path) for path in candidates if os.path.isfile(path)})
if not unique:
    raise SystemExit(1)

def version_key(path: str) -> tuple[int, str]:
    match = re.search(r"libshell-(\d+)\.so$", os.path.basename(path))
    return (int(match.group(1)) if match else -1, path)

print(max(unique, key=version_key))
PY
    )" || die "Keine libshell-*.so gefunden."

    [[ -f "${shell_resource}" ]] || die "Shell-Ressource fehlt: ${shell_resource}"
}

resolve_gdm_generate_config() {
    if [[ -n "${gdm_generate_config}" ]]; then
        return 0
    fi

    local candidate
    for candidate in \
        /usr/share/gdm/generate-config \
        /usr/libexec/gdm/generate-config \
        /usr/lib/gdm/generate-config
    do
        if [[ -x "${candidate}" ]]; then
            gdm_generate_config="${candidate}"
            return 0
        fi
    done

    die "Kein gdm generate-config gefunden."
}

require_tools() {
    command -v chown >/dev/null 2>&1 || die "chown fehlt."
    command -v dconf >/dev/null 2>&1 || die "dconf fehlt."
    command -v dbus-run-session >/dev/null 2>&1 || die "dbus-run-session fehlt."
    command -v flock >/dev/null 2>&1 || die "flock fehlt."
    command -v getent >/dev/null 2>&1 || die "getent fehlt."
    command -v gdmflexiserver >/dev/null 2>&1 || die "gdmflexiserver fehlt."
    command -v gsettings >/dev/null 2>&1 || die "gsettings fehlt."
    command -v gjs >/dev/null 2>&1 || die "gjs fehlt."
    command -v gresource >/dev/null 2>&1 || die "gresource fehlt."
    command -v install >/dev/null 2>&1 || die "install fehlt."
    command -v localectl >/dev/null 2>&1 || die "localectl fehlt."
    command -v python3 >/dev/null 2>&1 || die "python3 fehlt."
    command -v readlink >/dev/null 2>&1 || die "readlink fehlt."
    command -v runuser >/dev/null 2>&1 || die "runuser fehlt."
    command -v systemctl >/dev/null 2>&1 || die "systemctl fehlt."
    [[ -f "${greeter_dconf_file}" ]] || die "Greeter-dconf-Datei fehlt: ${greeter_dconf_file}"
    resolve_shell_resource
    resolve_gdm_generate_config
}

require_gdms() {
    PYTHONPATH="${python_path}${PYTHONPATH:+:${PYTHONPATH}}" python3 - <<'PY' >/dev/null
import gdms
PY
}

ensure_stock_theme() {
    local theme_path="$1"

    PYTHONPATH="${python_path}${PYTHONPATH:+:${PYTHONPATH}}" python3 - "${theme_path}" <<'PY' >/dev/null
import sys
from gdms import gresource

raise SystemExit(0 if gresource.is_unmodified(sys.argv[1]) else 1)
PY
}

active_theme_path() {
    local active_theme="/usr/share/gnome-shell/gdm-theme.gresource"

    if [[ ! -e "${active_theme}" ]]; then
        active_theme="/usr/share/gnome-shell/gdm3-theme.gresource"
    fi

    if [[ -e "${active_theme}" ]]; then
        readlink -f "${active_theme}"
        return 0
    fi

    printf '%s\n' "${legacy_theme_target}"
}

gdm_home() {
    local home
    home="$(getent passwd gdm | awk -F: '{print $6}')"
    [[ -n "${home}" ]] || die "Kein Home-Verzeichnis für den gdm-Benutzer gefunden."
    printf '%s\n' "${home}"
}

gdm_dropin_dir() {
    printf '%s/.config/systemd/user/org.gnome.Shell@wayland.service.d\n' "$(gdm_home)"
}

gdm_dropin_file() {
    printf '%s/90-disable-greeter-controls.conf\n' "$(gdm_dropin_dir)"
}

overlay_env() {
    printf '/org/gnome/shell=%s\n' "${overlay_root}"
}

overlay_session_file() {
    printf '%s/ui/sessionMode.js\n' "${overlay_root}"
}

overlay_panel_file() {
    printf '%s/ui/panel.js\n' "${overlay_root}"
}

overlay_screen_shield_file() {
    printf '%s/ui/screenShield.js\n' "${overlay_root}"
}

overlay_unlock_file() {
    printf '%s/ui/unlockDialog.js\n' "${overlay_root}"
}

overlay_auth_prompt_file() {
    printf '%s/gdm/authPrompt.js\n' "${overlay_root}"
}

overlay_login_file() {
    printf '%s/gdm/loginDialog.js\n' "${overlay_root}"
}

overlay_theme_file() {
    printf '%s/theme/gdm.css\n' "${overlay_root}"
}

resolve_target_user() {
    if [[ -n "${resolved_target_user}" ]]; then
        return 0
    fi

    local target_user="${SUDO_USER:-}"

    if [[ -z "${target_user}" ]] && [[ -n "${PKEXEC_UID:-}" ]]; then
        target_user="$(getent passwd "${PKEXEC_UID}" | awk -F: '{print $1}')"
    fi

    if [[ -z "${target_user}" ]] && [[ -n "${LOGNAME:-}" ]] && [[ "${LOGNAME}" != "root" ]] && id -u "${LOGNAME}" >/dev/null 2>&1; then
        target_user="${LOGNAME}"
    fi

    if [[ -n "${target_user}" ]] && id -u "${target_user}" >/dev/null 2>&1; then
        resolved_target_user="${target_user}"
    fi
}

run_in_user_session() {
    local target_user="$1"
    shift

    if [[ "$(id -u)" -eq 0 ]]; then
        runuser -u "${target_user}" -- dbus-run-session "$@"
    else
        [[ "$(id -un)" == "${target_user}" ]] || die "Benutzerkontext ${target_user} ist ohne root nicht verfuegbar."
        dbus-run-session "$@"
    fi
}

user_gsettings_get() {
    local target_user="$1"
    local schema="$2"
    local key="$3"

    run_in_user_session "${target_user}" gsettings get "${schema}" "${key}"
}

user_gsettings_set() {
    local target_user="$1"
    local schema="$2"
    local key="$3"
    local value="$4"

    run_in_user_session "${target_user}" gsettings set "${schema}" "${key}" "${value}"
}

user_gsettings_reset() {
    local target_user="$1"
    local schema="$2"
    local key="$3"

    run_in_user_session "${target_user}" gsettings reset "${schema}" "${key}"
}

resolve_input_sources() {
    resolve_target_user

    if [[ -n "${resolved_target_user}" ]]; then
        resolved_sources="$(user_gsettings_get "${resolved_target_user}" org.gnome.desktop.input-sources sources)"
        resolved_mru_sources="$(user_gsettings_get "${resolved_target_user}" org.gnome.desktop.input-sources mru-sources)"
        resolved_xkb_options="$(user_gsettings_get "${resolved_target_user}" org.gnome.desktop.input-sources xkb-options)"
        resolved_input_origin="Aufrufender Benutzer ${resolved_target_user}"
    else
        local x11_layout
        x11_layout="$(localectl status | awk -F': ' '/X11 Layout/ {print $2}')"
        if [[ -z "${x11_layout}" ]] || [[ "${x11_layout}" == "(unset)" ]]; then
            die "Kein X11-Layout gefunden."
        fi
        resolved_sources="[('xkb', '${x11_layout}')]"
        resolved_mru_sources="${resolved_sources}"
        resolved_xkb_options="@as []"
        resolved_input_origin="Systemlayout ${x11_layout}"
    fi

    [[ -n "${resolved_sources}" ]] || die "Keine Greeter-Input-Sources ermittelt."
    [[ -n "${resolved_mru_sources}" ]] || die "Keine Greeter-MRU-Sources ermittelt."
    [[ -n "${resolved_xkb_options}" ]] || die "Keine Greeter-XKB-Optionen ermittelt."

    if [[ "${resolved_mru_sources}" == "@a(ss) []" ]]; then
        resolved_mru_sources="${resolved_sources}"
    fi
}

backup_user_shortcut() {
    resolve_target_user
    [[ -n "${resolved_target_user}" ]] || die "Kein aufrufender Benutzer fuer Super+L ermittelt."

    if [[ -f "${user_shortcut_state}" ]]; then
        if ! python3 - "${user_shortcut_state}" "${resolved_target_user}" <<'PY' >/dev/null
import json
import pathlib
import sys

state_path = pathlib.Path(sys.argv[1])
expected_user = sys.argv[2]
state = json.loads(state_path.read_text(encoding="utf-8"))
raise SystemExit(0 if state.get("user") == expected_user else 1)
PY
        then
            die "Shortcut-State gehoert zu einem anderen Benutzer."
        fi
        return 0
    fi

    python3 - "${user_shortcut_state}" "${resolved_target_user}" "${user_shortcut_path}" \
        "$(user_gsettings_get "${resolved_target_user}" org.gnome.settings-daemon.plugins.media-keys screensaver)" \
        "$(user_gsettings_get "${resolved_target_user}" org.gnome.settings-daemon.plugins.media-keys custom-keybindings)" \
        "$(user_gsettings_get "${resolved_target_user}" org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:${user_shortcut_path} name)" \
        "$(user_gsettings_get "${resolved_target_user}" org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:${user_shortcut_path} command)" \
        "$(user_gsettings_get "${resolved_target_user}" org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:${user_shortcut_path} binding)" <<'PY'
import json
import pathlib
import sys

state = {
    "user": sys.argv[2],
    "path": sys.argv[3],
    "screensaver": sys.argv[4],
    "custom_keybindings": sys.argv[5],
    "name": sys.argv[6],
    "command": sys.argv[7],
    "binding": sys.argv[8],
}
pathlib.Path(sys.argv[1]).write_text(json.dumps(state), encoding="utf-8")
PY
}

list_custom_keybinding_paths() {
    local custom_keybindings="$1"

    python3 - "${custom_keybindings}" <<'PY'
import ast
import sys

for path in ast.literal_eval(sys.argv[1]):
    print(path)
PY
}

binding_contains_super_l() {
    local binding="$1"

    python3 - "${binding}" <<'PY' >/dev/null
import ast
import sys

bindings = ast.literal_eval(sys.argv[1])
raise SystemExit(0 if "<Super>l" in bindings else 1)
PY
}

find_super_l_shortcut() {
    local target_user="$1"
    local custom_keybindings
    local current_path
    local binding
    local command

    custom_keybindings="$(user_gsettings_get "${target_user}" org.gnome.settings-daemon.plugins.media-keys custom-keybindings)"

    while IFS= read -r current_path; do
        [[ -n "${current_path}" ]] || continue
        binding="$(user_gsettings_get "${target_user}" "org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:${current_path}" binding)"
        if binding_contains_super_l "${binding}"; then
            command="$(user_gsettings_get "${target_user}" "org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:${current_path}" command)"
            printf '%s\t%s\n' "${current_path}" "${command}"
            return 0
        fi
    done < <(list_custom_keybinding_paths "${custom_keybindings}")

    return 1
}

apply_user_shortcut() {
    resolve_target_user
    [[ -n "${resolved_target_user}" ]] || die "Kein aufrufender Benutzer fuer Super+L ermittelt."
    backup_user_shortcut

    local custom_keybindings
    local merged_custom_keybindings
    local existing_super_l
    local existing_path=""
    local existing_command=""

    custom_keybindings="$(user_gsettings_get "${resolved_target_user}" org.gnome.settings-daemon.plugins.media-keys custom-keybindings)"
    if existing_super_l="$(find_super_l_shortcut "${resolved_target_user}")"; then
        existing_path="${existing_super_l%%$'\t'*}"
        existing_command="${existing_super_l#*$'\t'}"
    fi

    if [[ -n "${existing_path}" ]] && [[ "${existing_path}" != "${user_shortcut_path}" ]] && [[ "${existing_command}" != "'gdmflexiserver'" ]]; then
        die "Super+L ist bereits belegt: ${existing_path} -> ${existing_command}"
    fi

    merged_custom_keybindings="$(python3 - "${custom_keybindings}" "${user_shortcut_path}" "${existing_path}" <<'PY'
import ast
import sys

current = ast.literal_eval(sys.argv[1])
managed = sys.argv[2]
existing = sys.argv[3]
if not existing and managed not in current:
    current.append(managed)
print(repr(current))
PY
)"

    user_gsettings_set "${resolved_target_user}" org.gnome.settings-daemon.plugins.media-keys screensaver "@as []"
    if [[ -z "${existing_path}" ]]; then
        user_gsettings_set "${resolved_target_user}" org.gnome.settings-daemon.plugins.media-keys custom-keybindings "${merged_custom_keybindings}"
        user_gsettings_set "${resolved_target_user}" "org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:${user_shortcut_path}" name "'Lock To Login Screen'"
        user_gsettings_set "${resolved_target_user}" "org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:${user_shortcut_path}" command "'gdmflexiserver'"
        user_gsettings_set "${resolved_target_user}" "org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:${user_shortcut_path}" binding "['<Super>l']"
    elif [[ "${existing_path}" == "${user_shortcut_path}" ]]; then
        user_gsettings_set "${resolved_target_user}" org.gnome.settings-daemon.plugins.media-keys custom-keybindings "${merged_custom_keybindings}"
        user_gsettings_set "${resolved_target_user}" "org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:${user_shortcut_path}" name "'Lock To Login Screen'"
        user_gsettings_set "${resolved_target_user}" "org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:${user_shortcut_path}" command "'gdmflexiserver'"
        user_gsettings_set "${resolved_target_user}" "org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:${user_shortcut_path}" binding "['<Super>l']"
    fi
}

restore_user_shortcut() {
    local state_lines=()

    mapfile -t state_lines < <(python3 - "${user_shortcut_state}" <<'PY'
import json
import pathlib
import sys

state_path = pathlib.Path(sys.argv[1])
if state_path.exists():
    state = json.loads(state_path.read_text(encoding="utf-8"))
else:
    state = {
        "user": None,
        "path": "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/gdm-greeter-minimalism/",
        "screensaver": "@as []",
        "custom_keybindings": "[]",
        "name": "''",
        "command": "''",
        "binding": "@as []",
    }

print(state["user"] or "")
print(state["path"])
print(state["screensaver"])
print(state["custom_keybindings"])
print(state["name"])
print(state["command"])
print(state["binding"])
PY
)

    local target_user="${state_lines[0]}"
    local shortcut_path="${state_lines[1]}"
    local screensaver="${state_lines[2]}"
    local custom_keybindings="${state_lines[3]}"
    local shortcut_name="${state_lines[4]}"
    local shortcut_command="${state_lines[5]}"
    local shortcut_binding="${state_lines[6]}"

    if [[ -n "${target_user}" ]]; then
        user_gsettings_set "${target_user}" org.gnome.settings-daemon.plugins.media-keys screensaver "${screensaver}"
        user_gsettings_set "${target_user}" org.gnome.settings-daemon.plugins.media-keys custom-keybindings "${custom_keybindings}"
        user_gsettings_set "${target_user}" "org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:${shortcut_path}" name "${shortcut_name}"
        user_gsettings_set "${target_user}" "org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:${shortcut_path}" command "${shortcut_command}"
        user_gsettings_set "${target_user}" "org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:${shortcut_path}" binding "${shortcut_binding}"
    fi

    rm -f "${user_shortcut_state}"
}

write_greeter_input_sources() {
    resolve_input_sources

    python3 - "${greeter_dconf_file}" "${greeter_input_begin}" "${greeter_input_end}" "${resolved_sources}" "${resolved_mru_sources}" "${resolved_xkb_options}" <<'PY'
import pathlib
import re
import sys

target = pathlib.Path(sys.argv[1])
begin = sys.argv[2]
end = sys.argv[3]
sources = sys.argv[4]
mru_sources = sys.argv[5]
xkb_options = sys.argv[6]

content = target.read_text(encoding="utf-8")
pattern = re.compile(rf"\n?{re.escape(begin)}\n.*?{re.escape(end)}\n?", re.S)
content = re.sub(pattern, "\n", content).rstrip()
block = (
    f"{begin}\n"
    "[org/gnome/desktop/input-sources]\n"
    f"sources={sources}\n"
    f"mru-sources={mru_sources}\n"
    f"xkb-options={xkb_options}\n"
    f"{end}\n"
)
target.write_text(f"{content}\n\n{block}", encoding="utf-8")
PY

    "${gdm_generate_config}"
}

remove_greeter_input_sources() {
    python3 - "${greeter_dconf_file}" "${greeter_input_begin}" "${greeter_input_end}" <<'PY'
import pathlib
import re
import sys

target = pathlib.Path(sys.argv[1])
begin = sys.argv[2]
end = sys.argv[3]

content = target.read_text(encoding="utf-8")
pattern = re.compile(rf"\n?{re.escape(begin)}\n.*?{re.escape(end)}\n?", re.S)
content = re.sub(pattern, "\n", content).rstrip()
target.write_text(f"{content}\n", encoding="utf-8")
PY

    "${gdm_generate_config}"
}

write_greeter_background() {
    python3 - "${greeter_dconf_file}" "${greeter_background_begin}" "${greeter_background_end}" <<'PY'
import pathlib
import re
import sys

target = pathlib.Path(sys.argv[1])
begin = sys.argv[2]
end = sys.argv[3]

content = target.read_text(encoding="utf-8")
pattern = re.compile(rf"\n?{re.escape(begin)}\n.*?{re.escape(end)}\n?", re.S)
content = re.sub(pattern, "\n", content).rstrip()
block = (
    f"{begin}\n"
    "[org/gnome/desktop/background]\n"
    "picture-options='none'\n"
    "picture-uri=''\n"
    "picture-uri-dark=''\n"
    "primary-color='#000000'\n"
    "secondary-color='#000000'\n"
    "color-shading-type='solid'\n"
    "\n"
    "[com/ubuntu/login-screen]\n"
    "background-color='#000000'\n"
    "background-picture-uri=''\n"
    "background-repeat='default'\n"
    "background-size='default'\n"
    f"{end}\n"
)
target.write_text(f"{content}\n\n{block}", encoding="utf-8")
PY

    "${gdm_generate_config}"
}

remove_greeter_background() {
    python3 - "${greeter_dconf_file}" "${greeter_background_begin}" "${greeter_background_end}" <<'PY'
import pathlib
import re
import sys

target = pathlib.Path(sys.argv[1])
begin = sys.argv[2]
end = sys.argv[3]

content = target.read_text(encoding="utf-8")
pattern = re.compile(rf"\n?{re.escape(begin)}\n.*?{re.escape(end)}\n?", re.S)
content = re.sub(pattern, "\n", content).rstrip()
target.write_text(f"{content}\n", encoding="utf-8")
PY

    "${gdm_generate_config}"
}

backup_gdm_input_sources() {
    [[ -f "${gdm_input_state}" ]] && return 0

    python3 - "${gdm_input_state}" <<'PY'
import json
import pathlib
import subprocess
import sys

state_path = pathlib.Path(sys.argv[1])
keys = {
    "sources": "/org/gnome/desktop/input-sources/sources",
    "mru-sources": "/org/gnome/desktop/input-sources/mru-sources",
    "xkb-options": "/org/gnome/desktop/input-sources/xkb-options",
}
state = {}

for name, key in keys.items():
    proc = subprocess.run(
        ["runuser", "-u", "gdm", "--", "dbus-run-session", "dconf", "read", key],
        text=True,
        capture_output=True,
        check=False,
    )
    if proc.returncode not in (0, 1):
        raise SystemExit(proc.stderr.strip() or f"dconf read fehlgeschlagen: {key}")
    value = proc.stdout.strip()
    state[name] = value if value else None

state_path.write_text(json.dumps(state), encoding="utf-8")
PY
}

apply_gdm_input_sources() {
    backup_gdm_input_sources
    runuser -u gdm -- dbus-run-session dconf write /org/gnome/desktop/input-sources/sources "${resolved_sources}"
    runuser -u gdm -- dbus-run-session dconf write /org/gnome/desktop/input-sources/mru-sources "${resolved_mru_sources}"
    runuser -u gdm -- dbus-run-session dconf write /org/gnome/desktop/input-sources/xkb-options "${resolved_xkb_options}"
}

backup_gdm_background() {
    [[ -f "${gdm_background_state}" ]] && return 0

    python3 - "${gdm_background_state}" <<'PY'
import json
import pathlib
import subprocess
import sys

state_path = pathlib.Path(sys.argv[1])
keys = {
    "picture-options": "/org/gnome/desktop/background/picture-options",
    "picture-uri": "/org/gnome/desktop/background/picture-uri",
    "picture-uri-dark": "/org/gnome/desktop/background/picture-uri-dark",
    "primary-color": "/org/gnome/desktop/background/primary-color",
    "secondary-color": "/org/gnome/desktop/background/secondary-color",
    "color-shading-type": "/org/gnome/desktop/background/color-shading-type",
    "background-color": "/com/ubuntu/login-screen/background-color",
    "background-picture-uri": "/com/ubuntu/login-screen/background-picture-uri",
    "background-repeat": "/com/ubuntu/login-screen/background-repeat",
    "background-size": "/com/ubuntu/login-screen/background-size",
}
state = {}

for name, key in keys.items():
    proc = subprocess.run(
        ["runuser", "-u", "gdm", "--", "dbus-run-session", "dconf", "read", key],
        text=True,
        capture_output=True,
        check=False,
    )
    if proc.returncode not in (0, 1):
        raise SystemExit(proc.stderr.strip() or f"dconf read fehlgeschlagen: {key}")
    value = proc.stdout.strip()
    state[name] = value if value else None

state_path.write_text(json.dumps(state), encoding="utf-8")
PY
}

apply_gdm_background() {
    backup_gdm_background
    runuser -u gdm -- dbus-run-session dconf write /org/gnome/desktop/background/picture-options "'none'"
    runuser -u gdm -- dbus-run-session dconf write /org/gnome/desktop/background/picture-uri "''"
    runuser -u gdm -- dbus-run-session dconf write /org/gnome/desktop/background/picture-uri-dark "''"
    runuser -u gdm -- dbus-run-session dconf write /org/gnome/desktop/background/primary-color "'#000000'"
    runuser -u gdm -- dbus-run-session dconf write /org/gnome/desktop/background/secondary-color "'#000000'"
    runuser -u gdm -- dbus-run-session dconf write /org/gnome/desktop/background/color-shading-type "'solid'"
    runuser -u gdm -- dbus-run-session dconf write /com/ubuntu/login-screen/background-color "'#000000'"
    runuser -u gdm -- dbus-run-session dconf write /com/ubuntu/login-screen/background-picture-uri "''"
    runuser -u gdm -- dbus-run-session dconf write /com/ubuntu/login-screen/background-repeat "'default'"
    runuser -u gdm -- dbus-run-session dconf write /com/ubuntu/login-screen/background-size "'default'"
}

restore_gdm_input_sources() {
    python3 - "${gdm_input_state}" <<'PY'
import json
import pathlib
import subprocess
import sys

state_path = pathlib.Path(sys.argv[1])
keys = {
    "sources": "/org/gnome/desktop/input-sources/sources",
    "mru-sources": "/org/gnome/desktop/input-sources/mru-sources",
    "xkb-options": "/org/gnome/desktop/input-sources/xkb-options",
}

if state_path.exists():
    state = json.loads(state_path.read_text(encoding="utf-8"))
else:
    state = {name: None for name in keys}

for name, key in keys.items():
    value = state.get(name)
    if value is None:
        command = ["runuser", "-u", "gdm", "--", "dbus-run-session", "dconf", "reset", key]
    else:
        command = ["runuser", "-u", "gdm", "--", "dbus-run-session", "dconf", "write", key, value]
    subprocess.run(command, check=True)
PY

    rm -f "${gdm_input_state}"
}

restore_gdm_background() {
    python3 - "${gdm_background_state}" <<'PY'
import json
import pathlib
import subprocess
import sys

state_path = pathlib.Path(sys.argv[1])
keys = {
    "picture-options": "/org/gnome/desktop/background/picture-options",
    "picture-uri": "/org/gnome/desktop/background/picture-uri",
    "picture-uri-dark": "/org/gnome/desktop/background/picture-uri-dark",
    "primary-color": "/org/gnome/desktop/background/primary-color",
    "secondary-color": "/org/gnome/desktop/background/secondary-color",
    "color-shading-type": "/org/gnome/desktop/background/color-shading-type",
    "background-color": "/com/ubuntu/login-screen/background-color",
    "background-picture-uri": "/com/ubuntu/login-screen/background-picture-uri",
    "background-repeat": "/com/ubuntu/login-screen/background-repeat",
    "background-size": "/com/ubuntu/login-screen/background-size",
}

if state_path.exists():
    state = json.loads(state_path.read_text(encoding="utf-8"))
else:
    state = {name: None for name in keys}

for name, key in keys.items():
    value = state.get(name)
    if value is None:
        command = ["runuser", "-u", "gdm", "--", "dbus-run-session", "dconf", "reset", key]
    else:
        command = ["runuser", "-u", "gdm", "--", "dbus-run-session", "dconf", "write", key, value]
    subprocess.run(command, check=True)
PY

    rm -f "${gdm_background_state}"
}

acquire_lock() {
    exec 9>"${lock_file}"
    flock 9
}

legacy_override_active() {
    local active_theme
    active_theme="$(active_theme_path)"

    gresource extract "${active_theme}" /org/gnome/shell/theme/gdm.css | grep -F "${legacy_needle}" >/dev/null
}

restore_legacy_override_if_needed() {
    if ! legacy_override_active; then
        return 0
    fi

    require_gdms || die "Das Python-Modul gdms fehlt. Installiere zuerst gdm-settings."
    [[ -f "${legacy_backup}" ]] || die "Legacy-Backup fehlt: ${legacy_backup}"
    ensure_stock_theme "${legacy_backup}" || die "Legacy-Backup ist kein sauberes Standard-Theme: ${legacy_backup}"

    install -m644 "${legacy_backup}" "${legacy_theme_target}"

    if [[ -f "${legacy_state}" ]]; then
        local original_theme
        original_theme="$(head -n 1 "${legacy_state}")"

        if [[ -n "${original_theme}" ]]; then
            PYTHONPATH="${python_path}${PYTHONPATH:+:${PYTHONPATH}}" python3 - "${original_theme}" <<'PY'
import os
import subprocess
import sys

from gdms import gresource

original_theme = sys.argv[1]

if gresource.UbuntuGdmGresourceFile and os.path.isfile(original_theme):
    name = os.path.basename(gresource.UbuntuGdmGresourceFile)
    subprocess.run(
        [
            "update-alternatives",
            "--quiet",
            "--install",
            gresource.UbuntuGdmGresourceFile,
            name,
            original_theme,
            "0",
        ],
        check=True,
    )
    subprocess.run(
        [
            "update-alternatives",
            "--quiet",
            "--set",
            name,
            original_theme,
        ],
        check=True,
    )
PY
        fi
    fi

    rm -f "${legacy_state}"
}

write_overlay_sources() {
    local active_theme
    active_theme="$(active_theme_path)"

    install -d -m755 "${overlay_root}/ui" "${overlay_root}/gdm" "${overlay_root}/theme"

    python3 - "${shell_resource}" "${active_theme}" "${overlay_root}" <<'PY'
import pathlib
import subprocess
import sys

shell_resource = sys.argv[1]
theme_resource = sys.argv[2]
overlay_root = pathlib.Path(sys.argv[3])


def extract(resource: str) -> str:
    return subprocess.check_output(
        ["gresource", "extract", shell_resource, resource],
        text=True,
    )


def replace_once(content: str, old: str, new: str, label: str) -> str:
    if old not in content:
        raise SystemExit(f"Patch-Block nicht gefunden: {label}")
    return content.replace(old, new, 1)


session_mode = extract("/org/gnome/shell/ui/sessionMode.js")
session_mode = replace_once(
    session_mode,
    """    'gdm': {\n        hasNotifications: true,\n        stylesheetName: 'gdm.css',\n        themeResourceName: 'gdm-theme.gresource',\n        isGreeter: true,\n        isPrimary: true,\n        unlockDialog: LoginDialog,\n        components: Config.HAVE_NETWORKMANAGER\n            ? ['networkAgent', 'polkitAgent']\n            : ['polkitAgent'],\n        panel: {\n            left: [],\n            center: ['dateMenu'],\n            right: ['dwellClick', 'keyboard', 'quickSettings'],\n        },\n        panelStyle: 'login-screen',\n    },\n""",
    """    'gdm': {\n        hasNotifications: true,\n        stylesheetName: 'gdm.css',\n        themeResourceName: 'gdm-theme.gresource',\n        isGreeter: true,\n        isPrimary: true,\n        unlockDialog: LoginDialog,\n        components: Config.HAVE_NETWORKMANAGER\n            ? ['networkAgent', 'polkitAgent']\n            : ['polkitAgent'],\n        panel: {\n            left: [],\n            center: [],\n            right: ['keyboard'],\n        },\n        panelStyle: null,\n    },\n""",
    "sessionMode.js:gdm",
)
session_mode = replace_once(
    session_mode,
    """    'unlock-dialog': {\n        isLocked: true,\n        unlockDialog: undefined,\n        components: ['polkitAgent'],\n        panel: {\n            left: [],\n            center: [],\n            right: ['dwellClick', 'a11y', 'keyboard', 'quickSettings'],\n        },\n        panelStyle: 'unlock-screen',\n    },\n""",
    """    'unlock-dialog': {\n        isLocked: true,\n        unlockDialog: undefined,\n        components: ['polkitAgent'],\n        panel: {\n            left: [],\n            center: [],\n            right: ['keyboard'],\n        },\n        panelStyle: null,\n    },\n""",
    "sessionMode.js:unlock-dialog",
)

panel = extract("/org/gnome/shell/ui/panel.js")
panel = replace_once(
    panel,
    """    _updatePanel() {\n        let panel = Main.sessionMode.panel;\n        this._hideIndicators();\n        this._updateBox(panel.left, this._leftBox);\n        this._updateBox(panel.center, this._centerBox);\n        this._updateBox(panel.right, this._rightBox);\n\n        if (panel.left.includes('dateMenu'))\n            Main.messageTray.bannerAlignment = Clutter.ActorAlign.START;\n        else if (panel.right.includes('dateMenu'))\n            Main.messageTray.bannerAlignment = Clutter.ActorAlign.END;\n        // Default to center if there is no dateMenu\n        else\n            Main.messageTray.bannerAlignment = Clutter.ActorAlign.CENTER;\n\n        if (this._sessionStyle)\n            this.remove_style_class_name(this._sessionStyle);\n\n        this._sessionStyle = Main.sessionMode.panelStyle;\n        if (this._sessionStyle)\n            this.add_style_class_name(this._sessionStyle);\n    }\n""",
    """    _updatePanel() {\n        let panel = Main.sessionMode.panel;\n\n        this._hideIndicators();\n        this._updateBox(panel.left, this._leftBox);\n        this._updateBox(panel.center, this._centerBox);\n        this._updateBox(panel.right, this._rightBox);\n\n        if (Main.sessionMode.isGreeter || Main.sessionMode.isLocked) {\n            this.hide();\n            Main.layoutManager.panelBox.hide();\n        } else {\n            Main.layoutManager.panelBox.show();\n            this.show();\n        }\n\n        if (panel.left.includes('dateMenu'))\n            Main.messageTray.bannerAlignment = Clutter.ActorAlign.START;\n        else if (panel.right.includes('dateMenu'))\n            Main.messageTray.bannerAlignment = Clutter.ActorAlign.END;\n        else\n            Main.messageTray.bannerAlignment = Clutter.ActorAlign.CENTER;\n\n        if (this._sessionStyle)\n            this.remove_style_class_name(this._sessionStyle);\n\n        this._sessionStyle = Main.sessionMode.panelStyle;\n        if (this._sessionStyle)\n            this.add_style_class_name(this._sessionStyle);\n    }\n""",
    "panel.js:_updatePanel",
)

screen_shield = extract("/org/gnome/shell/ui/screenShield.js")
screen_shield = replace_once(
    screen_shield,
    """import * as Main from './main.js';\nimport * as Overview from './overview.js';\nimport * as MessageTray from './messageTray.js';\nimport * as ShellDBus from './shellDBus.js';\nimport * as SmartcardManager from '../misc/smartcardManager.js';\n\nimport {adjustAnimationTime} from '../misc/animationUtils.js';\n""",
    """import * as Main from './main.js';\nimport * as Overview from './overview.js';\nimport * as MessageTray from './messageTray.js';\nimport * as ShellDBus from './shellDBus.js';\nimport * as SmartcardManager from '../misc/smartcardManager.js';\nimport * as Util from '../misc/util.js';\n\nimport {adjustAnimationTime} from '../misc/animationUtils.js';\n""",
    "screenShield.js:imports",
)
screen_shield = replace_once(
    screen_shield,
    "        this.activate(animate);\n",
    "        this.activate(false);\n",
    "screenShield.js:lock",
)
screen_shield = replace_once(
    screen_shield,
    """    _prepareForSleep(loginManager, aboutToSuspend) {\n        if (aboutToSuspend) {\n            if (this._settings.get_boolean(SUSPEND_LOCK_ENABLED_KEY))\n                this.lock(true);\n        } else {\n            this._wakeUpScreen();\n        }\n    }\n""",
    """    _prepareForSleep(loginManager, aboutToSuspend) {\n        if (aboutToSuspend) {\n            if (this._settings.get_boolean(SUSPEND_LOCK_ENABLED_KEY))\n                Util.spawn(['gdmflexiserver']);\n        } else {\n            this._wakeUpScreen();\n        }\n    }\n""",
    "screenShield.js:prepareForSleep",
)

unlock_dialog = extract("/org/gnome/shell/ui/unlockDialog.js")
unlock_dialog = replace_once(
    unlock_dialog,
    """        this._clock = new Clock();\n        this._clock.set_pivot_point(0.5, 0.5);\n        this._stack.add_child(this._clock);\n        this._showClock();\n""",
    """        this._clock = new Clock();\n        this._clock.set_pivot_point(0.5, 0.5);\n        this._stack.add_child(this._clock);\n""",
    "unlockDialog.js:initialClock",
)
unlock_dialog = replace_once(
    unlock_dialog,
    "        this._updateUserSwitchVisibility();\n",
    """        this._updateUserSwitchVisibility();\n\n        this._ensureAuthPrompt();\n        this._activePage = this._promptBox;\n        this._adjustment.value = 1;\n        this._setTransitionProgress(1);\n""",
    "unlockDialog.js:initialPrompt",
)
unlock_dialog = replace_once(
    unlock_dialog,
    """    _fail() {\n        this._showClock();\n        this.emit('failed');\n    }\n""",
    """    _fail() {\n        this._showPrompt();\n        this.emit('failed');\n    }\n""",
    "unlockDialog.js:fail",
)

auth_prompt = extract("/org/gnome/shell/gdm/authPrompt.js")
auth_prompt = replace_once(
    auth_prompt,
    """        this._userWell = new St.Bin({\n            x_expand: true,\n            y_expand: true,\n        });\n        this.add_child(this._userWell);\n""",
    """        this._userWell = new St.Bin({\n            visible: false,\n        });\n        this.add_child(this._userWell);\n""",
    "authPrompt.js:userWell",
)
auth_prompt = replace_once(
    auth_prompt,
    """        let userWidget = new UserWidget.UserWidget(user, Clutter.Orientation.VERTICAL);\n        this._userWell.set_child(userWidget);\n\n        if (!user)\n            this._updateEntry(false);\n""",
    """        this._userWell.set_child(null);\n\n        if (!user)\n            this._updateEntry(false);\n""",
    "authPrompt.js:setUser",
)

login_dialog = extract("/org/gnome/shell/gdm/loginDialog.js")
login_dialog = replace_once(
    login_dialog,
    """        this._createLoginOptionsButton();\n        this._createSessionMenuButton();\n\n        this._a11yMenuButton = new A11yMenuButton();\n        this._bottomButtonGroup.add_child(this._a11yMenuButton);\n""",
    """        this._createLoginOptionsButton();\n        this._createSessionMenuButton();\n\n        this._a11yMenuButton = null;\n        this._bottomButtonGroup.hide();\n""",
    "loginDialog.js:bottomButtons",
)
login_dialog = replace_once(
    login_dialog,
    "        this._bottomButtonGroup.add_child(this._loginOptionsButton);\n",
    "",
    "loginDialog.js:loginOptionsButton",
)
login_dialog = replace_once(
    login_dialog,
    "        this._bottomButtonGroup.add_child(this._sessionMenuButton);\n",
    "",
    "loginDialog.js:sessionMenuButton",
)

gdm_css = extract("/org/gnome/shell/theme/gdm.css") if theme_resource == shell_resource else subprocess.check_output(
    ["gresource", "extract", theme_resource, "/org/gnome/shell/theme/gdm.css"],
    text=True,
)
gdm_css = replace_once(
    gdm_css,
    "#lockDialogGroup {\n  background-color: #222226; }\n",
    "#lockDialogGroup {\n  background-color: #000000; }\n",
    "gdm.css:lockDialogGroup",
)

(overlay_root / "ui" / "sessionMode.js").write_text(session_mode, encoding="utf-8")
(overlay_root / "ui" / "panel.js").write_text(panel, encoding="utf-8")
(overlay_root / "ui" / "screenShield.js").write_text(screen_shield, encoding="utf-8")
(overlay_root / "ui" / "unlockDialog.js").write_text(unlock_dialog, encoding="utf-8")
(overlay_root / "gdm" / "authPrompt.js").write_text(auth_prompt, encoding="utf-8")
(overlay_root / "gdm" / "loginDialog.js").write_text(login_dialog, encoding="utf-8")
(overlay_root / "theme" / "gdm.css").write_text(gdm_css, encoding="utf-8")
PY
}

write_dropin_file() {
    local file="$1"

    python3 - "${file}" "$(overlay_env)" <<'PY'
import pathlib
import sys

dropin_file = pathlib.Path(sys.argv[1])
overlay = sys.argv[2]
content = f"""[Service]\nEnvironment=G_RESOURCE_OVERLAYS={overlay}\n"""
dropin_file.write_text(content, encoding="utf-8")
PY
}

write_dropins() {
    local gdm_dir
    gdm_dir="$(gdm_dropin_dir)"

    install -d -m755 "${user_shell_dropin_dir}" "${gdm_service_dropin_dir}" "${gdm_dir}"
    write_dropin_file "${user_shell_dropin_file}"
    write_dropin_file "${gdm_service_dropin_file}"
    write_dropin_file "$(gdm_dropin_file)"
    chown -R gdm:gdm "${gdm_dir}"
    systemctl daemon-reload
}

verify_overlay_resources() {
    local env_value
    env_value="$(overlay_env)"

    [[ -f "${user_shell_dropin_file}" ]] || die "User-Shell-Drop-in fehlt: ${user_shell_dropin_file}"
    grep -F "Environment=G_RESOURCE_OVERLAYS=${env_value}" "${user_shell_dropin_file}" >/dev/null || die "User-Shell-Drop-in enthält kein G_RESOURCE_OVERLAYS."
    [[ -f "${gdm_service_dropin_file}" ]] || die "GDM-Service-Drop-in fehlt: ${gdm_service_dropin_file}"
    grep -F "Environment=G_RESOURCE_OVERLAYS=${env_value}" "${gdm_service_dropin_file}" >/dev/null || die "GDM-Service-Drop-in enthält kein G_RESOURCE_OVERLAYS."
    [[ -f "$(gdm_dropin_file)" ]] || die "GDM-Drop-in fehlt: $(gdm_dropin_file)"
    grep -F "Environment=G_RESOURCE_OVERLAYS=${env_value}" "$(gdm_dropin_file)" >/dev/null || die "GDM-Drop-in enthält kein G_RESOURCE_OVERLAYS."
    [[ -f "$(overlay_session_file)" ]] || die "Overlay-Datei fehlt: $(overlay_session_file)"
    [[ -f "$(overlay_panel_file)" ]] || die "Overlay-Datei fehlt: $(overlay_panel_file)"
    [[ -f "$(overlay_screen_shield_file)" ]] || die "Overlay-Datei fehlt: $(overlay_screen_shield_file)"
    [[ -f "$(overlay_unlock_file)" ]] || die "Overlay-Datei fehlt: $(overlay_unlock_file)"
    [[ -f "$(overlay_auth_prompt_file)" ]] || die "Overlay-Datei fehlt: $(overlay_auth_prompt_file)"
    [[ -f "$(overlay_login_file)" ]] || die "Overlay-Datei fehlt: $(overlay_login_file)"
    [[ -f "$(overlay_theme_file)" ]] || die "Overlay-Datei fehlt: $(overlay_theme_file)"

    grep -F "'unlock-dialog': {" "$(overlay_session_file)" >/dev/null || die "unlock-dialog-Override fehlt."
    grep -F "'gdm': {" "$(overlay_session_file)" >/dev/null || die "gdm-Override fehlt."
    grep -F "Main.sessionMode.isLocked" "$(overlay_panel_file)" >/dev/null || die "panel-Override für unlock-dialog fehlt."
    grep -F "this.activate(false);" "$(overlay_screen_shield_file)" >/dev/null || die "screenShield-Override fehlt."
    grep -F "Util.spawn(['gdmflexiserver']);" "$(overlay_screen_shield_file)" >/dev/null || die "screenShield-Suspend-Override fehlt."
    grep -F "this._activePage = this._promptBox;" "$(overlay_unlock_file)" >/dev/null || die "unlockDialog-Prompt-Override fehlt."
    grep -F "this._showPrompt();" "$(overlay_unlock_file)" >/dev/null || die "unlockDialog-Fail-Override fehlt."
    grep -F "this._userWell.set_child(null);" "$(overlay_auth_prompt_file)" >/dev/null || die "authPrompt-Avatar-Override fehlt."
    grep -F "this._bottomButtonGroup.hide();" "$(overlay_login_file)" >/dev/null || die "loginDialog-Override fehlt."
    grep -F "background-color: #000000;" "$(overlay_theme_file)" >/dev/null || die "Theme-Override ist nicht schwarz."
    [[ -f "${gdm_input_state}" ]] || die "GDM-Input-State fehlt."
    [[ -f "${gdm_background_state}" ]] || die "GDM-Background-State fehlt."
    grep -F "${greeter_background_begin}" "${greeter_dconf_file}" >/dev/null || die "Greeter-Background-Override fehlt."
    grep -F "background-color='#000000'" "${greeter_dconf_file}" >/dev/null || die "Greeter-Background ist nicht schwarz."
    grep -F "${greeter_input_begin}" "${greeter_dconf_file}" >/dev/null || die "Greeter-Input-Override fehlt."
    grep -F "sources=" "${greeter_dconf_file}" >/dev/null || die "Greeter-Sources fehlen."

    G_RESOURCE_OVERLAYS="${env_value}" gjs -c "const Gio = imports.gi.Gio; const ByteArray = imports.byteArray; const data = Gio.resources_lookup_data('/org/gnome/shell/ui/sessionMode.js', 0); const text = ByteArray.toString(data.toArray()); if (!text.includes(\"'gdm': {\") || !text.includes(\"'unlock-dialog': {\") || !text.includes(\"panelStyle: null,\") || !text.includes(\"right: ['keyboard'],\")) throw new Error('sessionMode lookup fehlgeschlagen');"
    G_RESOURCE_OVERLAYS="${env_value}" gjs -c "const Gio = imports.gi.Gio; const ByteArray = imports.byteArray; const data = Gio.resources_lookup_data('/org/gnome/shell/ui/panel.js', 0); const text = ByteArray.toString(data.toArray()); if (!text.includes('Main.layoutManager.panelBox.hide();') || !text.includes('Main.sessionMode.isLocked') || text.includes('const hasVisibleItems =')) throw new Error('panel lookup fehlgeschlagen');"
    G_RESOURCE_OVERLAYS="${env_value}" gjs -c "const Gio = imports.gi.Gio; const ByteArray = imports.byteArray; const data = Gio.resources_lookup_data('/org/gnome/shell/ui/screenShield.js', 0); const text = ByteArray.toString(data.toArray()); if (!text.includes('this.activate(false);') || !text.includes(\"Util.spawn(['gdmflexiserver']);\")) throw new Error('screenShield lookup fehlgeschlagen');"
    G_RESOURCE_OVERLAYS="${env_value}" gjs -c "const Gio = imports.gi.Gio; const ByteArray = imports.byteArray; const data = Gio.resources_lookup_data('/org/gnome/shell/ui/unlockDialog.js', 0); const text = ByteArray.toString(data.toArray()); if (!text.includes('this._activePage = this._promptBox;') || !text.includes('this._adjustment.value = 1;') || text.includes('this._showClock();\\n\\n        this.allowCancel = false;')) throw new Error('unlockDialog lookup fehlgeschlagen');"
    G_RESOURCE_OVERLAYS="${env_value}" gjs -c "const Gio = imports.gi.Gio; const ByteArray = imports.byteArray; const data = Gio.resources_lookup_data('/org/gnome/shell/gdm/authPrompt.js', 0); const text = ByteArray.toString(data.toArray()); if (!text.includes('this._userWell.set_child(null);') || !text.includes('visible: false,')) throw new Error('authPrompt lookup fehlgeschlagen');"
    G_RESOURCE_OVERLAYS="${env_value}" gjs -c "const Gio = imports.gi.Gio; const ByteArray = imports.byteArray; const data = Gio.resources_lookup_data('/org/gnome/shell/gdm/loginDialog.js', 0); const text = ByteArray.toString(data.toArray()); if (!text.includes('this._bottomButtonGroup.hide();') || !text.includes('this._a11yMenuButton = null;')) throw new Error('loginDialog lookup fehlgeschlagen');"
    G_RESOURCE_OVERLAYS="${env_value}" gjs -c "const Gio = imports.gi.Gio; const ByteArray = imports.byteArray; const data = Gio.resources_lookup_data('/org/gnome/shell/theme/gdm.css', 0); const text = ByteArray.toString(data.toArray()); if (!text.includes('#lockDialogGroup {') || !text.includes('background-color: #000000;')) throw new Error('theme lookup fehlgeschlagen');"
}

apply_override() {
    restore_legacy_override_if_needed
    write_overlay_sources
    write_greeter_background
    write_greeter_input_sources
    apply_gdm_background
    apply_gdm_input_sources
    apply_user_shortcut
    write_dropins
    verify_overlay
}

verify_overlay() {
    resolve_input_sources
    verify_overlay_resources
    if legacy_override_active; then
        die "Legacy-CSS-Override noch aktiv."
    fi

    resolve_target_user
    if [[ -n "${resolved_target_user}" ]]; then
        local screensaver_binding
        local shortcut
        local shortcut_path
        local shortcut_command

        screensaver_binding="$(user_gsettings_get "${resolved_target_user}" org.gnome.settings-daemon.plugins.media-keys screensaver)"
        [[ "${screensaver_binding}" == "@as []" ]] || die "Screensaver-Keybind ist nicht deaktiviert: ${screensaver_binding}"

        shortcut="$(find_super_l_shortcut "${resolved_target_user}" || true)"
        [[ -n "${shortcut}" ]] || die "Kein Super+L-Shortcut aktiv."
        shortcut_path="${shortcut%%$'\t'*}"
        shortcut_command="${shortcut#*$'\t'}"
        [[ "${shortcut_command}" == "'gdmflexiserver'" ]] || die "Super+L zeigt nicht auf gdmflexiserver: ${shortcut_path} -> ${shortcut_command}"

        printf 'Hard-Override installiert.\nUser-Shell-Drop-in: %s\nGDM-Service-Drop-in: %s\nGDM-Drop-in: %s\nGreeter-Hintergrund: schwarz\nGreeter-Layout: %s\nShortcut: <Super>l -> gdmflexiserver (%s)\nOverlay: %s\n' "${user_shell_dropin_file}" "${gdm_service_dropin_file}" "$(gdm_dropin_file)" "${resolved_input_origin}" "${resolved_target_user}" "${overlay_root}"
        return 0
    fi

    printf 'Hard-Override installiert.\nUser-Shell-Drop-in: %s\nGDM-Service-Drop-in: %s\nGDM-Drop-in: %s\nGreeter-Hintergrund: schwarz\nGreeter-Layout: %s\nOverlay: %s\n' "${user_shell_dropin_file}" "${gdm_service_dropin_file}" "$(gdm_dropin_file)" "${resolved_input_origin}" "${overlay_root}"
}

restore_override() {
    rm -f "${user_shell_dropin_file}" "${gdm_service_dropin_file}" "$(gdm_dropin_file)"
    systemctl daemon-reload
    remove_greeter_background
    remove_greeter_input_sources
    restore_gdm_background
    restore_gdm_input_sources
    restore_user_shortcut
    restore_legacy_override_if_needed

    if [[ -f "${user_shell_dropin_file}" ]] || [[ -f "${gdm_service_dropin_file}" ]] || [[ -f "$(gdm_dropin_file)" ]]; then
        die "Hard-Override konnte nicht deaktiviert werden."
    fi
    if legacy_override_active; then
        die "Legacy-CSS-Override ist weiterhin aktiv."
    fi
    if [[ -f "${gdm_input_state}" ]]; then
        die "GDM-Input-State ist weiterhin aktiv."
    fi
    if [[ -f "${gdm_background_state}" ]]; then
        die "GDM-Background-State ist weiterhin aktiv."
    fi
    if [[ -f "${user_shortcut_state}" ]]; then
        die "Shortcut-State ist weiterhin aktiv."
    fi
    if grep -F "${greeter_background_begin}" "${greeter_dconf_file}" >/dev/null; then
        die "Greeter-Background-Override ist weiterhin aktiv."
    fi
    if grep -F "${greeter_input_begin}" "${greeter_dconf_file}" >/dev/null; then
        die "Greeter-Input-Override ist weiterhin aktiv."
    fi

    printf 'Hard-Override deaktiviert.\nUser-Shell-Drop-in entfernt: %s\nGDM-Service-Drop-in entfernt: %s\nGDM-Drop-in entfernt: %s\n' "${user_shell_dropin_file}" "${gdm_service_dropin_file}" "$(gdm_dropin_file)"
}

maybe_restart() {
    local restart_flag="$1"

    if [[ "${restart_flag}" == "1" ]]; then
        systemctl restart gdm
    fi
}

main() {
    local command="${1:-}"
    local restart_flag="0"

    [[ -n "${command}" ]] || {
        usage
        exit 1
    }

    shift || true

    if [[ "${1:-}" == "--restart" ]]; then
        restart_flag="1"
        shift
    fi

    [[ "$#" -eq 0 ]] || {
        usage
        exit 1
    }

    require_tools

    case "${command}" in
        apply)
            require_root
            acquire_lock
            apply_override
            maybe_restart "${restart_flag}"
            ;;
        verify)
            verify_overlay
            ;;
        restore)
            require_root
            acquire_lock
            restore_override
            maybe_restart "${restart_flag}"
            ;;
        *)
            usage
            exit 1
            ;;
    esac
}

main "$@"
