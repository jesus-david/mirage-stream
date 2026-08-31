#!/usr/bin/env bash
# Install or remove the Hyprland-native Mirage Stream profile.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTION=install
REMOTE_FIRST=false
ASSUME_YES=false
TARGET_USER="${SUDO_USER:-${USER}}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
TIMESTAMP="$(date +%Y%m%dT%H%M%SZ)"
BACKUP_ROOT="$TARGET_HOME/.local/share/mirage-stream/backups/hyprland-headless-$TIMESTAMP"
RENDER_NODE=
MONITOR_RULE_MARKER_BEGIN='-- >>> mirage-stream hyprland-headless >>>'
MONITOR_RULE_MARKER_END='-- <<< mirage-stream hyprland-headless <<<'

log() { printf '[*] %s\n' "$*"; }
ok() { printf '[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*"; }
die() { printf '[!] %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage: install-hyprland-headless.sh [install|uninstall|doctor] [--remote-first] [-y]

Installs Sunshine as a Hyprland session service with a 2560x1440@60 headless
output. It never adds a kernel EDID or a forced DRM connector.

  install     (default) Install/update the profile.
  uninstall   Remove it.
  doctor      Read-only health check -- run after installing or after a
              `git pull` to confirm the profile is still wired up correctly.
EOF
}

confirm() {
    $ASSUME_YES && return 0
    local reply
    read -r -p "$1 [Y/n] " reply
    [[ -z "$reply" || "$reply" =~ ^[Yy]$ ]]
}

parse_args() {
    while (( $# )); do
        case "$1" in
            install|uninstall|doctor) ACTION="$1" ;;
            --remote-first) REMOTE_FIRST=true ;;
            -y|--assume-yes) ASSUME_YES=true ;;
            --dry-run) die "--dry-run is not supported for hyprland-headless; it must be run from a live Hyprland session" ;;
            -h|--help) usage; exit 0 ;;
            *) die "Unknown argument: $1" ;;
        esac
        shift
    done
}

backup_path() {
    local path="$1"
    [[ -e "$path" || -L "$path" ]] || return 0
    mkdir -p "$BACKUP_ROOT$(dirname "$path")"
    cp -a -- "$path" "$BACKUP_ROOT$path"
}

detect_render_node() {
    local driver card bdf link
    for driver in /sys/class/drm/card[0-9]/device/driver; do
        [[ -e "$driver" ]] || continue
        [[ "$(basename "$(readlink "$driver")")" == "nvidia" ]] || continue
        card="$(basename "$(dirname "$(dirname "$driver")")")"
        bdf="$(basename "$(readlink "/sys/class/drm/$card/device")")"
        link="/dev/dri/by-path/pci-$bdf-render"
        [[ -L "$link" ]] || continue
        RENDER_NODE="$(readlink -f "$link")"
        return 0
    done
    die "No NVIDIA render node was found"
}

preflight() {
    [[ "$EUID" -ne 0 ]] || die "Run this script as the desktop user, not root"
    [[ -n "$TARGET_HOME" && -d "$TARGET_HOME" ]] || die "Cannot resolve home for $TARGET_USER"
    command -v hyprctl >/dev/null || die "hyprctl is required"
    command -v jq >/dev/null || die "jq is required"
    command -v sunshine >/dev/null || die "Sunshine is required"
    [[ "${XDG_CURRENT_DESKTOP:-}" == "Hyprland" ]] || die "Run this from an active Hyprland session"
    [[ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]] || die "HYPRLAND_INSTANCE_SIGNATURE is missing"
    hyprctl -j monitors all >/dev/null || die "Cannot contact Hyprland"
    if $REMOTE_FIRST; then
        sudo -v || die "sudo authentication is required for --remote-first"
    fi
    if grep -Eq '(^| )drm\.edid_firmware=.*(DP-4|HDMI-A-2):|(^| )video=(DP-4|HDMI-A-2):e' /proc/cmdline; then
        die "A forced virtual connector is still active in the running kernel; remove it before installing this profile"
    fi
    detect_render_node
}

install_template() {
    local source="$1" destination="$2" mode="$3"
    local temporary
    temporary="$(mktemp)"
    sed \
        -e "s|@TARGET_HOME@|$TARGET_HOME|g" \
        -e "s|@RENDER_NODE@|$RENDER_NODE|g" \
        "$source" >"$temporary"
    install -D -m "$mode" "$temporary" "$destination"
    rm -f "$temporary"
}

add_hyprland_startup() {
    # dots-hyprland/end-4's non-legacy Lua config never sources
    # UserConfigs/Startup_Apps.conf (that's a JaKooLit-era include path), so
    # an exec-once written there is silently never run.
    #
    # custom/execs.lua looked like the natural replacement, but it is NOT
    # exec-once semantics: end-4 re-sources every custom/*.lua file (running
    # every top-level hl.exec_cmd() call again) whenever that file's mtime
    # changes -- confirmed by a bare `touch` on the file alone restarting
    # this service with no content change at all. Any future edit to
    # execs.lua (by this installer, by hand, by anything) would silently
    # relaunch mirage-stream-hyprland.service. systemd's own [Install]
    # WantedBy=graphical-session.target is what "start once per session"
    # actually means, and it's completely decoupled from Hyprland's config
    # file watching.
    systemctl --user enable mirage-stream-hyprland.service
}

remove_hyprland_startup() {
    systemctl --user disable mirage-stream-hyprland.service 2>/dev/null || true
}

add_hyprland_monitor_rule() {
    # MIRAGE gets created and stays enabled for the whole time the service
    # runs, not just during an active stream, so with Hyprland's default
    # `position = "auto"` it lands snugly adjacent to a real monitor -- the
    # mouse cursor can wander onto it and "disappear" (nothing is physically
    # displayed there). A one-off `hyprctl eval` fix doesn't stick either:
    # stream-stop.sh runs `hyprctl reload config-only` on every disconnect,
    # which re-reads this file from disk and overwrites anything set only at
    # runtime back to the wildcard default. This rule has to live in the
    # user's actual Hyprland config.
    #
    # Unlike the old custom/execs.lua approach for auto-start (see
    # add_hyprland_startup above), this is safe to have end-4 re-source on
    # every file-watch reload: hl.monitor() is a declarative rule, not a
    # command with a side effect like launching a process, so re-applying it
    # is a no-op.
    local target="$TARGET_HOME/.config/hypr/custom/general.lua"
    mkdir -p "$(dirname "$target")"
    touch "$target"
    grep -qF -- "$MONITOR_RULE_MARKER_BEGIN" "$target" && return 0
    cat >>"$target" <<EOF

$MONITOR_RULE_MARKER_BEGIN
hl.monitor({ output = "MIRAGE", mode = "2560x1440@60", position = "100000x0", scale = 1 })
$MONITOR_RULE_MARKER_END
EOF
}

remove_hyprland_monitor_rule() {
    local target="$TARGET_HOME/.config/hypr/custom/general.lua"
    [[ -f "$target" ]] || return 0
    sed -i "/$(printf '%s' "$MONITOR_RULE_MARKER_BEGIN" | sed 's/[.[\*^$]/\\&/g')/,/$(printf '%s' "$MONITOR_RULE_MARKER_END" | sed 's/[.[\*^$]/\\&/g')/d" "$target"
}

write_compatibility_scripts() {
    local scripts="$TARGET_HOME/.config/sunshine/scripts"
    mkdir -p "$scripts"
    cat >"$scripts/connect.sh" <<'EOF'
#!/usr/bin/env bash
exec systemctl --user start mirage-stream-hyprland.service
EOF
    cat >"$scripts/disconnect.sh" <<'EOF'
#!/usr/bin/env bash
exec systemctl --user stop mirage-stream-hyprland.service
EOF
    chmod 0755 "$scripts/connect.sh" "$scripts/disconnect.sh"
}

configure_remote_first() {
    $REMOTE_FIRST || return 0
    systemctl is-enabled plasmalogin.service >/dev/null 2>&1 || die "plasmalogin.service is not enabled"

    local cfg=/etc/plasmalogin.conf.d/99-mirage-hyprland-autologin.conf
    if sudo test -e "$cfg"; then
        sudo cp -a "$cfg" "$cfg.bak.$TIMESTAMP"
    fi
    sudo install -d -m 0755 /etc/plasmalogin.conf.d
    sudo tee "$cfg" >/dev/null <<EOF
[Autologin]
User=$TARGET_USER
Session=hyprland.desktop
Relogin=false
EOF
    ok "Configured plasmalogin autologin for Hyprland"
}

install_profile() {
    preflight
    log "NVIDIA render node: $RENDER_NODE"
    log "Backups will be stored in $BACKUP_ROOT"
    confirm "Install the Hyprland headless profile?" || exit 0

    local sunshine_dir="$TARGET_HOME/.config/sunshine"
    local autostart_dir="$TARGET_HOME/.config/autostart"
    local unit_dir="$TARGET_HOME/.config/systemd/user"
    local lib_dir="$TARGET_HOME/.local/lib/mirage-stream"

    mkdir -p "$BACKUP_ROOT" "$sunshine_dir" "$autostart_dir" "$unit_dir" "$lib_dir"
    backup_path "$sunshine_dir/sunshine.conf"
    backup_path "$sunshine_dir/apps.json"
    backup_path "$sunshine_dir/scripts/connect.sh"
    backup_path "$sunshine_dir/scripts/disconnect.sh"
    backup_path "$autostart_dir/sunshine-display-init.desktop"
    backup_path "$autostart_dir/sunshine-display-init.sh"
    backup_path "$autostart_dir/lock-on-start.desktop"
    backup_path "$unit_dir/mirage-stream-hyprland.service"
    backup_path "$lib_dir/start-hyprland-headless.sh"
    backup_path "$lib_dir/hyprland-headless-session.sh"
    backup_path "$lib_dir/stream-start.sh"
    backup_path "$lib_dir/stream-stop.sh"
    backup_path "$TARGET_HOME/.config/hypr/custom/general.lua"

    install_template "$SCRIPT_DIR/profiles/hyprland-headless/mirage-stream-hyprland.service.in" \
        "$unit_dir/mirage-stream-hyprland.service" 0644
    install_template "$SCRIPT_DIR/profiles/hyprland-headless/start-from-hyprland.sh.in" \
        "$lib_dir/start-hyprland-headless.sh" 0755
    install_template "$SCRIPT_DIR/profiles/hyprland-headless/hyprland-headless-session.sh.in" \
        "$lib_dir/hyprland-headless-session.sh" 0755
    install_template "$SCRIPT_DIR/profiles/hyprland-headless/stream-start.sh.in" \
        "$lib_dir/stream-start.sh" 0755
    install_template "$SCRIPT_DIR/profiles/hyprland-headless/stream-stop.sh.in" \
        "$lib_dir/stream-stop.sh" 0755

    cat >"$sunshine_dir/sunshine.conf" <<EOF
# Mirage Stream uses sunshine-hyprland.conf, generated for the MIRAGE output.
adapter_name = $RENDER_NODE
capture = wlr
encoder = nvenc
EOF
    if [[ -f "$sunshine_dir/apps.json" ]]; then
        temporary="$(mktemp)"
        jq '.apps |= map(select(.name != "Low Res Desktop"))' "$sunshine_dir/apps.json" >"$temporary"
        mv "$temporary" "$sunshine_dir/apps.json"
    fi
    write_compatibility_scripts

    [[ -f "$autostart_dir/sunshine-display-init.desktop" ]] && \
        mv "$autostart_dir/sunshine-display-init.desktop" "$autostart_dir/sunshine-display-init.desktop.disabled-mirage-stream-$TIMESTAMP"
    [[ -f "$autostart_dir/lock-on-start.desktop" ]] && \
        mv "$autostart_dir/lock-on-start.desktop" "$autostart_dir/lock-on-start.desktop.disabled-mirage-stream-$TIMESTAMP"
    add_hyprland_startup
    add_hyprland_monitor_rule

    systemctl --user disable --now app-dev.lizardbyte.app.Sunshine.service
    systemctl --user daemon-reload
    configure_remote_first
    ok "Hyprland profile installed. It will start on the next Hyprland session."
}

uninstall_profile() {
    systemctl --user stop mirage-stream-hyprland.service 2>/dev/null || true
    systemctl --user disable mirage-stream-hyprland.service 2>/dev/null || true
    rm -f "$TARGET_HOME/.config/systemd/user/mirage-stream-hyprland.service"
    rm -f "$TARGET_HOME/.local/lib/mirage-stream/start-hyprland-headless.sh"
    rm -f "$TARGET_HOME/.local/lib/mirage-stream/hyprland-headless-session.sh"
    rm -f "$TARGET_HOME/.local/lib/mirage-stream/stream-start.sh"
    rm -f "$TARGET_HOME/.local/lib/mirage-stream/stream-stop.sh"
    remove_hyprland_startup
    remove_hyprland_monitor_rule
    systemctl --user daemon-reload
    if sudo test -e /etc/plasmalogin.conf.d/99-mirage-hyprland-autologin.conf; then
        sudo rm /etc/plasmalogin.conf.d/99-mirage-hyprland-autologin.conf
    fi
    ok "Hyprland profile disabled. User-config backups remain under $TARGET_HOME/.local/share/mirage-stream/backups/."
}

check_hl_eval() {
    local result
    result="$(hyprctl eval 'hl.get_active_workspace()' 2>&1)" || true
    if [[ "$result" == "ok" ]]; then
        ok "hyprctl eval + the hl.* Lua API responds (non-legacy Hyprland config detected)"
        return 0
    fi
    warn "hyprctl eval did not return 'ok' (got: '$result') -- this profile requires a non-legacy (Lua) Hyprland config such as end-4/dots-hyprland; hyprctl keyword/dispatch-based scripts will silently no-op otherwise"
    return 1
}

doctor_action() {
    [[ "${XDG_CURRENT_DESKTOP:-}" == "Hyprland" && -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]] || \
        die "Run this from an active Hyprland session"

    local pass=0 total=4

    check_hl_eval && pass=$((pass + 1))

    if systemctl --user is-enabled mirage-stream-hyprland.service >/dev/null 2>&1; then
        ok "mirage-stream-hyprland.service is enabled (auto-starts with graphical-session.target)"
        pass=$((pass + 1))
    else
        warn "mirage-stream-hyprland.service is not enabled -- it won't auto-start next session. Run: $0 install"
    fi

    local general_lua="$TARGET_HOME/.config/hypr/custom/general.lua"
    if [[ -f "$general_lua" ]] && grep -qF -- "$MONITOR_RULE_MARKER_BEGIN" "$general_lua"; then
        ok "MIRAGE position rule is persisted in custom/general.lua"
        pass=$((pass + 1))
    else
        warn "MIRAGE position rule is missing from $general_lua -- MIRAGE may end up placed next to a real monitor (mouse can wander onto it) after any hyprctl reload. Run: $0 install"
    fi

    local sunshine_conf="$TARGET_HOME/.config/sunshine/sunshine-hyprland.conf"
    local lib_dir="$TARGET_HOME/.local/lib/mirage-stream"
    if [[ -f "$sunshine_conf" ]] && grep -qF "$lib_dir/stream-start.sh" "$sunshine_conf" && grep -qF "$lib_dir/stream-stop.sh" "$sunshine_conf"; then
        ok "sunshine-hyprland.conf points at the current stream-start.sh/stream-stop.sh"
        pass=$((pass + 1))
    else
        warn "$sunshine_conf is missing or doesn't reference $lib_dir/stream-start.sh + stream-stop.sh. Run: $0 install"
    fi

    echo
    log "$pass/$total checks OK"
    [[ "$pass" -eq "$total" ]]
}

parse_args "$@"
case "$ACTION" in
    install) install_profile ;;
    uninstall) uninstall_profile ;;
    doctor) doctor_action ;;
esac
