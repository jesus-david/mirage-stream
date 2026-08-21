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

log() { printf '[*] %s\n' "$*"; }
ok() { printf '[+] %s\n' "$*"; }
die() { printf '[!] %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage: install-hyprland-headless.sh [uninstall] [--remote-first] [-y]

Installs Sunshine as a Hyprland session service with a 2560x1440@60 headless
output. It never adds a kernel EDID or a forced DRM connector.
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
            install|uninstall) ACTION="$1" ;;
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
    local startup="$TARGET_HOME/.config/hypr/UserConfigs/Startup_Apps.conf"
    local marker='# >>> mirage-stream hyprland-headless >>>'
    mkdir -p "$(dirname "$startup")"
    touch "$startup"
    grep -qF "$marker" "$startup" && return 0
    cat >>"$startup" <<'EOF'

# >>> mirage-stream hyprland-headless >>>
exec-once = $HOME/.local/lib/mirage-stream/start-hyprland-headless.sh
# <<< mirage-stream hyprland-headless <<<
EOF
}

remove_hyprland_startup() {
    local startup="$TARGET_HOME/.config/hypr/UserConfigs/Startup_Apps.conf"
    [[ -f "$startup" ]] || return 0
    sed -i '/# >>> mirage-stream hyprland-headless >>>/,/# <<< mirage-stream hyprland-headless <<</d' "$startup"
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
    backup_path "$TARGET_HOME/.config/waybar/configs/TOP-Codex-Minimal-Transparent"
    backup_path "$TARGET_HOME/.config/hypr/UserConfigs/Startup_Apps.conf"

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
    systemctl --user daemon-reload
    if sudo test -e /etc/plasmalogin.conf.d/99-mirage-hyprland-autologin.conf; then
        sudo rm /etc/plasmalogin.conf.d/99-mirage-hyprland-autologin.conf
    fi
    ok "Hyprland profile disabled. User-config backups remain under $TARGET_HOME/.local/share/mirage-stream/backups/."
}

parse_args "$@"
case "$ACTION" in
    install) install_profile ;;
    uninstall) uninstall_profile ;;
esac
