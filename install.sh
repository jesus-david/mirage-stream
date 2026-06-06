#!/usr/bin/env bash
# install.sh — NVIDIA virtual display + Sunshine on Fedora-based distros.
#
# Usage:
#   ./install.sh                Install (default action).
#   ./install.sh uninstall      Reverse all changes from a prior install.
#   ./install.sh --remote-first Enable Windows-like remote-first boot
#                               (autologin + immediate screen lock +
#                                Sunshine user service on every boot).
#   ./install.sh -y             Skip confirmation prompts.
#   ./install.sh --dry-run      Print actions without applying.
#   ./install.sh -h             Show this help.
#
# v1 supports Fedora-based distros (Nobara, Fedora KDE) only. Arch will be
# added later. See FEDORA-NOTES.md for the detection logic and known issues.

set -euo pipefail

# ============================================================================
# Globals
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"

ACTION=install
REMOTE_FIRST=false
ASSUME_YES=false
DRY_RUN=false

# Detected values (filled by detect_* functions)
DISTRO_ID=
DISTRO_LIKE=
NVIDIA_CARD=                 # e.g. "card1"
NVIDIA_PCI_BDF=              # e.g. "0000:01:00.0"
RENDER_NODE=                 # e.g. "/dev/dri/renderD128"
VIRTUAL_CONNECTOR=           # e.g. "HDMI-A-2"
PHYSICAL_CONNECTORS=()       # e.g. ("DP-5" "DP-6")
INITRAMFS_TOOL=              # "dracut"
BOOTLOADER=                  # "grub-bls"
DISPLAY_MANAGER=             # "plasmalogin" | "sddm" | ...
TARGET_USER="${SUDO_USER:-${USER}}"
TARGET_HOME=

KERNEL_ARGS_FRAGMENT=        # filled once VIRTUAL_CONNECTOR is known
EDID_FIRMWARE_PATH=/usr/lib/firmware/edid/virtual.bin
DRACUT_DROP_IN=/etc/dracut.conf.d/edid.conf
AUTOLOGIN_DROP_IN=/etc/plasmalogin.conf.d/10-autologin.conf
LOCK_AUTOSTART=               # set per user later

# ============================================================================
# Logging
# ============================================================================

if [[ -t 1 ]]; then
    C_RED=$'\033[31m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[34m'
    C_BOLD=$'\033[1m'
    C_OFF=$'\033[0m'
else
    C_RED= C_GREEN= C_YELLOW= C_BLUE= C_BOLD= C_OFF=
fi

log()  { printf "%s[*]%s %s\n" "$C_BLUE"   "$C_OFF" "$*"; }
ok()   { printf "%s[+]%s %s\n" "$C_GREEN"  "$C_OFF" "$*"; }
warn() { printf "%s[!]%s %s\n" "$C_YELLOW" "$C_OFF" "$*" >&2; }
err()  { printf "%s[!]%s %s\n" "$C_RED"    "$C_OFF" "$*" >&2; }
die()  { err "$*"; exit 1; }

confirm() {
    local prompt="${1:-Continue?}"
    if $ASSUME_YES; then
        log "$prompt — auto-yes"
        return 0
    fi
    local reply
    printf "%s%s%s [Y/n] " "$C_BOLD" "$prompt" "$C_OFF"
    read -r reply
    [[ -z "$reply" || "$reply" =~ ^[Yy]$ ]]
}

run_or_print() {
    if $DRY_RUN; then
        printf "%s[dry-run]%s %s\n" "$C_YELLOW" "$C_OFF" "$*"
    else
        eval "$@"
    fi
}

# ============================================================================
# Usage
# ============================================================================

usage() {
    sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

# ============================================================================
# CLI
# ============================================================================

parse_args() {
    while (( $# )); do
        case "$1" in
            install|uninstall) ACTION="$1" ;;
            --remote-first)    REMOTE_FIRST=true ;;
            -y|--assume-yes)   ASSUME_YES=true ;;
            --dry-run)         DRY_RUN=true ;;
            -h|--help)         usage 0 ;;
            *) die "Unknown argument: $1 (use -h for help)" ;;
        esac
        shift
    done
}

# ============================================================================
# Preflight
# ============================================================================

preflight() {
    [[ $EUID -ne 0 ]] || die "Do not run as root. The script will use sudo when needed."

    if [[ -n "${SUDO_USER:-}" ]]; then
        die "Do not run via sudo. Run as your normal user."
    fi

    TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
    [[ -d "$TARGET_HOME" ]] || die "Cannot resolve home directory for user $TARGET_USER"
    LOCK_AUTOSTART="$TARGET_HOME/.config/autostart/lock-on-start.desktop"

    sudo -n true 2>/dev/null || {
        log "Requesting sudo privileges (you may be prompted once)..."
        sudo -v || die "sudo unavailable; cannot proceed."
    }

    for cmd in python3 sudo systemctl getent install; do
        command -v "$cmd" >/dev/null || die "Required command missing: $cmd"
    done
}

# ============================================================================
# Detection
# ============================================================================

detect_distro() {
    [[ -f /etc/os-release ]] || die "/etc/os-release missing — cannot detect distro."
    # shellcheck disable=SC1091
    . /etc/os-release
    DISTRO_ID="${ID:-}"
    DISTRO_LIKE="${ID_LIKE:-}"
    case "$DISTRO_ID $DISTRO_LIKE" in
        *fedora*|*rhel*|*centos*)
            ok "Distro: $DISTRO_ID (Fedora-based)"
            ;;
        *)
            die "v1 supports Fedora-based distros only. Detected: $DISTRO_ID ($DISTRO_LIKE)"
            ;;
    esac
}

detect_nvidia_card() {
    local d card drv
    for d in /sys/class/drm/card[0-9]/device/driver; do
        [[ -e "$d" ]] || continue
        drv="$(basename "$(readlink "$d")")"
        if [[ "$drv" == nvidia ]]; then
            card="$(basename "$(dirname "$(dirname "$d")")")"
            NVIDIA_CARD="$card"
            NVIDIA_PCI_BDF="$(basename "$(readlink "/sys/class/drm/${card}/device")")"
            ok "NVIDIA card: ${NVIDIA_CARD} (PCI ${NVIDIA_PCI_BDF})"
            return
        fi
    done
    die "No DRM card driven by 'nvidia' found. Is the proprietary driver loaded?"
}

detect_render_node() {
    local link
    link="/dev/dri/by-path/pci-${NVIDIA_PCI_BDF}-render"
    [[ -L "$link" ]] || die "Render-node symlink missing: $link"
    RENDER_NODE="$(readlink -f "$link")"
    ok "NVIDIA render node: ${RENDER_NODE}"
}

detect_connectors() {
    local p name status
    local -a disc=() conn=()
    for p in /sys/class/drm/${NVIDIA_CARD}-*/status; do
        [[ -e "$p" ]] || continue
        name="$(basename "${p%/status}")"
        name="${name#${NVIDIA_CARD}-}"
        [[ "$name" == Writeback-* ]] && continue
        status="$(cat "$p")"
        if [[ "$status" == disconnected ]]; then
            disc+=("$name")
        elif [[ "$status" == connected ]]; then
            conn+=("$name")
        fi
    done

    # If a previous install already wired a virtual connector via
    # drm.edid_firmware= on the running kernel, reuse it (idempotency).
    # /proc/cmdline reflects what's actually booted; /etc/kernel/cmdline
    # reflects what's configured for the next boot.
    local existing
    existing="$(grep -oE 'drm\.edid_firmware=[^: ]+:[^ ]+' /proc/cmdline /etc/kernel/cmdline 2>/dev/null \
                | head -1 | sed -E 's|.*drm\.edid_firmware=([^:]+):.*|\1|' || true)"
    if [[ -n "$existing" ]]; then
        VIRTUAL_CONNECTOR="$existing"
        log "Detected existing virtual connector from kernel cmdline: ${VIRTUAL_CONNECTOR}"
        # Drop it from physical list — it shows up as 'connected' because
        # the kernel forced it on with the virtual EDID, not because a
        # real monitor is plugged in there.
        local -a filtered=()
        for name in "${conn[@]}"; do
            [[ "$name" == "$VIRTUAL_CONNECTOR" ]] || filtered+=("$name")
        done
        conn=("${filtered[@]}")
    else
        # No existing config. Pick a disconnected connector: prefer HDMI > DP.
        local v
        for v in "${disc[@]}"; do
            [[ "$v" == HDMI-* ]] && { VIRTUAL_CONNECTOR="$v"; break; }
        done
        if [[ -z "$VIRTUAL_CONNECTOR" ]]; then
            for v in "${disc[@]}"; do
                [[ "$v" == DP-* ]] && { VIRTUAL_CONNECTOR="$v"; break; }
            done
        fi
        [[ -n "$VIRTUAL_CONNECTOR" ]] || \
            die "No disconnected connector on ${NVIDIA_CARD} to use for virtual display."
    fi

    PHYSICAL_CONNECTORS=("${conn[@]}")
    if (( ${#PHYSICAL_CONNECTORS[@]} == 0 )); then
        warn "No physical monitor detected on ${NVIDIA_CARD}. connect/disconnect scripts will only toggle the virtual display."
    fi

    ok "Virtual display connector: ${VIRTUAL_CONNECTOR}"
    ok "Physical monitor connectors: ${PHYSICAL_CONNECTORS[*]:-(none)}"

    KERNEL_ARGS_FRAGMENT="drm.edid_firmware=${VIRTUAL_CONNECTOR}:edid/virtual.bin video=${VIRTUAL_CONNECTOR}:e"
}

detect_initramfs() {
    if command -v dracut >/dev/null; then
        INITRAMFS_TOOL=dracut
        ok "Initramfs tool: dracut"
    else
        die "dracut not found. v1 expects Fedora-based dracut."
    fi
}

detect_bootloader() {
    if [[ -f /etc/default/grub ]] && command -v grubby >/dev/null; then
        BOOTLOADER=grub-bls
        ok "Bootloader: GRUB + BLS (grubby-managed)"
    elif [[ -f /etc/default/grub ]]; then
        BOOTLOADER=grub
        warn "Bootloader: GRUB without grubby — installer may not handle this correctly."
    else
        die "Unsupported bootloader (no /etc/default/grub). v1 expects GRUB."
    fi
}

detect_dm() {
    local svc
    svc="$(systemctl status display-manager.service --no-pager 2>/dev/null | \
           head -2 | grep -oE 'plasmalogin|sddm|gdm|lightdm' | head -1)"
    DISPLAY_MANAGER="${svc:-unknown}"
    ok "Display manager: ${DISPLAY_MANAGER}"
}

# ============================================================================
# Detection summary + confirmation
# ============================================================================

print_summary() {
    cat <<EOF

${C_BOLD}== Detection summary ==${C_OFF}
  Distro              : ${DISTRO_ID}
  NVIDIA card         : ${NVIDIA_CARD} (PCI ${NVIDIA_PCI_BDF})
  Render node         : ${RENDER_NODE}
  Virtual connector   : ${VIRTUAL_CONNECTOR}
  Physical monitor(s) : ${PHYSICAL_CONNECTORS[*]:-(none)}
  Initramfs tool      : ${INITRAMFS_TOOL}
  Bootloader          : ${BOOTLOADER}
  Display manager     : ${DISPLAY_MANAGER}
  Target user         : ${TARGET_USER} (home: ${TARGET_HOME})
  Kernel args         : ${KERNEL_ARGS_FRAGMENT}
  Remote-first mode   : ${REMOTE_FIRST}
  Dry-run             : ${DRY_RUN}

EOF
}

# ============================================================================
# Install actions — virtual display
# ============================================================================

generate_edid() {
    log "Generating EDID firmware blob…"
    local out="${SCRIPT_DIR}/virtual.bin"
    run_or_print "python3 '${SCRIPT_DIR}/create-edid.py' '${out}'"
    if ! $DRY_RUN; then
        python3 - "$out" <<'PY'
import sys
d = open(sys.argv[1],'rb').read()
assert len(d) == 256, f"EDID must be 256 bytes, got {len(d)}"
assert bytes([0x03,0x0c,0x00]) in d, "HDMI VSDB missing"
assert bytes([0xd8,0x5d,0xc4]) in d, "HDMI Forum VSDB missing"
assert sum(d[:128]) % 256 == 0, "base block checksum mismatch"
assert sum(d[128:]) % 256 == 0, "extension block checksum mismatch"
print("EDID validated OK")
PY
    fi
    ok "EDID at ${out}"
}

install_edid_firmware() {
    log "Installing EDID at ${EDID_FIRMWARE_PATH}…"
    run_or_print "sudo install -D -m 0644 '${SCRIPT_DIR}/virtual.bin' '${EDID_FIRMWARE_PATH}'"
    ok "EDID firmware installed"
}

configure_initramfs() {
    log "Configuring dracut to embed EDID in initramfs…"
    local content='install_items+=" /usr/lib/firmware/edid/virtual.bin "'
    if [[ -f "$DRACUT_DROP_IN" ]] && sudo grep -qF "$content" "$DRACUT_DROP_IN"; then
        ok "Dracut drop-in already configured (${DRACUT_DROP_IN})"
    else
        run_or_print "echo '${content}' | sudo tee '${DRACUT_DROP_IN}' >/dev/null"
        ok "Wrote ${DRACUT_DROP_IN}"
    fi
    log "Regenerating all initramfs (this takes a couple of minutes)…"
    run_or_print "sudo dracut --force --regenerate-all"
    ok "Initramfs regenerated"
}

configure_kernel_params() {
    log "Adding kernel command-line parameters…"

    # 1) Existing kernels via grubby
    run_or_print "sudo grubby --update-kernel=ALL --args=\"${KERNEL_ARGS_FRAGMENT}\""

    # 2) /etc/kernel/cmdline (kernel-install template)
    if [[ -f /etc/kernel/cmdline ]]; then
        if grep -qF "drm.edid_firmware=${VIRTUAL_CONNECTOR}" /etc/kernel/cmdline; then
            ok "/etc/kernel/cmdline already has params"
        else
            run_or_print "sudo cp /etc/kernel/cmdline /etc/kernel/cmdline.bak.$(date +%s)"
            run_or_print "sudo sed -i \"s|\\\$| ${KERNEL_ARGS_FRAGMENT}|\" /etc/kernel/cmdline"
            ok "Updated /etc/kernel/cmdline"
        fi
    fi

    # 3) /etc/default/grub for consistency on future grub2-mkconfig
    if grep -qF "drm.edid_firmware=${VIRTUAL_CONNECTOR}" /etc/default/grub; then
        ok "/etc/default/grub already has params"
    else
        run_or_print "sudo cp /etc/default/grub /etc/default/grub.bak.$(date +%s)"
        run_or_print "sudo sed -i \"s|^\\(GRUB_CMDLINE_LINUX_DEFAULT=['\\\"]\\)\\([^'\\\"]*\\)\\(['\\\"]\\)$|\\1\\2 ${KERNEL_ARGS_FRAGMENT}\\3|\" /etc/default/grub"
        ok "Updated /etc/default/grub"
    fi

    if [[ -f /boot/grub2/grub.cfg ]]; then
        run_or_print "sudo grub2-mkconfig -o /boot/grub2/grub.cfg >/dev/null 2>&1 || true"
        ok "Regenerated /boot/grub2/grub.cfg"
    fi
}

# ============================================================================
# Install actions — Sunshine config
# ============================================================================

write_sunshine_config() {
    log "Writing Sunshine config…"
    local cfg_dir="${TARGET_HOME}/.config/sunshine"
    local cfg="${cfg_dir}/sunshine.conf"
    run_or_print "mkdir -p '${cfg_dir}/scripts'"

    if [[ -s "$cfg" ]] && ! $DRY_RUN; then
        cp "$cfg" "${cfg}.bak.$(date +%s)"
        log "Backed up existing sunshine.conf"
    fi

    local connect="${cfg_dir}/scripts/connect.sh"
    local disconnect="${cfg_dir}/scripts/disconnect.sh"
    run_or_print "cat > '${cfg}' <<EOF
global_prep_cmd = [{\"do\":\"${connect}\",\"undo\":\"${disconnect}\",\"elevated\":\"false\"}]
adapter_name = ${RENDER_NODE}
capture = kms
encoder = nvenc
EOF"
    ok "Wrote ${cfg}"
}

# Build a kscreen-doctor argument list from connector names.
# Args: <enable_or_disable> <connector...>
ks_args() {
    local action="$1"; shift
    local c out=
    for c in "$@"; do
        out+="output.${c}.${action} "
    done
    printf "%s" "${out%% }"
}

write_user_scripts() {
    log "Writing connect/disconnect/display-init scripts…"
    local s_dir="${TARGET_HOME}/.config/sunshine/scripts"
    local a_dir="${TARGET_HOME}/.config/autostart"
    run_or_print "mkdir -p '${s_dir}' '${a_dir}'"

    local disable_phys enable_phys enable_virt disable_virt
    disable_phys="$(ks_args disable "${PHYSICAL_CONNECTORS[@]}")"
    enable_phys="$(ks_args enable "${PHYSICAL_CONNECTORS[@]}")"
    enable_virt="output.${VIRTUAL_CONNECTOR}.enable"
    disable_virt="output.${VIRTUAL_CONNECTOR}.disable"

    local hdr='#!/bin/bash
export WAYLAND_DISPLAY=wayland-0
export XDG_RUNTIME_DIR=/run/user/$(id -u)
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus'

    # connect.sh: physical OFF, virtual ON
    local cargs
    if [[ -n "$disable_phys" ]]; then
        cargs="kscreen-doctor ${disable_phys} ${enable_virt}"
    else
        cargs="kscreen-doctor ${enable_virt}"
    fi
    run_or_print "cat > '${s_dir}/connect.sh' <<EOF
${hdr}
${cargs}
sleep 3
EOF"
    run_or_print "chmod +x '${s_dir}/connect.sh'"

    # disconnect.sh: virtual OFF, physical ON
    local dargs="kscreen-doctor ${disable_virt}"
    [[ -n "$enable_phys" ]] && dargs+=" ${enable_phys}"
    run_or_print "cat > '${s_dir}/disconnect.sh' <<EOF
${hdr}
${dargs}
EOF"
    run_or_print "chmod +x '${s_dir}/disconnect.sh'"

    # display-init.sh: post-login state (same as disconnect)
    run_or_print "cat > '${a_dir}/sunshine-display-init.sh' <<EOF
${hdr}

sleep 3  # wait for KWin to finish initializing outputs
${dargs}
EOF"
    run_or_print "chmod +x '${a_dir}/sunshine-display-init.sh'"

    # display-init.desktop
    run_or_print "cat > '${a_dir}/sunshine-display-init.desktop' <<EOF
[Desktop Entry]
Type=Application
Name=Sunshine Display Init
Exec=${a_dir}/sunshine-display-init.sh
Hidden=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
EOF"

    ok "User scripts installed under ${s_dir} and ${a_dir}"
}

enable_sunshine_service() {
    log "Enabling Sunshine user service…"
    local unit=app-dev.lizardbyte.app.Sunshine.service
    if [[ ! -f "/usr/lib/systemd/user/${unit}" ]]; then
        warn "Shipped unit ${unit} not found — is the LizardByte Sunshine RPM installed?"
        return
    fi
    if systemctl --user is-enabled "$unit" >/dev/null 2>&1; then
        ok "Already enabled"
    else
        run_or_print "systemctl --user enable '${unit}'"
        ok "Enabled ${unit}"
    fi
}

# ============================================================================
# Install actions — remote-first (autologin + lock + always-on Sunshine)
# ============================================================================

configure_autologin() {
    log "Configuring plasmalogin autologin for user ${TARGET_USER}…"
    [[ "$DISPLAY_MANAGER" == "plasmalogin" ]] || {
        warn "Display manager is '${DISPLAY_MANAGER}', not plasmalogin — autologin step skipped."
        return
    }
    run_or_print "sudo mkdir -p /etc/plasmalogin.conf.d"
    run_or_print "sudo tee '${AUTOLOGIN_DROP_IN}' >/dev/null <<EOF
[Autologin]
User=${TARGET_USER}
Session=plasma.desktop
Relogin=true
EOF"
    ok "Wrote ${AUTOLOGIN_DROP_IN}"
}

configure_lock_on_start() {
    log "Configuring lock-on-session-start autostart…"
    run_or_print "mkdir -p '$(dirname "${LOCK_AUTOSTART}")'"
    run_or_print "cat > '${LOCK_AUTOSTART}' <<EOF
[Desktop Entry]
Type=Application
Name=Lock on session start
Exec=sh -c 'sleep 3 && loginctl lock-session'
X-KDE-autostart-phase=2
X-GNOME-Autostart-enabled=true
NoDisplay=true
EOF"
    ok "Wrote ${LOCK_AUTOSTART}"
}

configure_dm_display_profile() {
    log "Disabling virtual connector in plasmalogin's KWin output config…"
    [[ "$DISPLAY_MANAGER" == "plasmalogin" ]] || return
    local cfg=/var/lib/plasmalogin/.config/kwinoutputconfig.json
    if ! sudo test -f "$cfg"; then
        warn "${cfg} not found yet — plasmalogin probably needs to start once after the virtual connector appears. Re-run this step after first boot with virtual display."
        return
    fi
    run_or_print "sudo cp -a '${cfg}' '${cfg}.bak.$(date +%s)'"
    local virt="$VIRTUAL_CONNECTOR"
    if $DRY_RUN; then
        printf "%s[dry-run]%s edit %s: set %s enabled=false in 3-output setup\n" \
            "$C_YELLOW" "$C_OFF" "$cfg" "$virt"
        return
    fi
    sudo python3 - "$cfg" "$virt" <<'PY'
import json, sys, os, tempfile
cfg, virt = sys.argv[1], sys.argv[2]
with open(cfg) as f:
    data = json.load(f)
outs = next(s for s in data if s['name']=='outputs')
idx = next((i for i,o in enumerate(outs['data']) if o['connectorName']==virt), None)
if idx is None:
    sys.exit(0)  # connector not in greeter's output history yet
setups = next(s for s in data if s['name']=='setups')
changed = 0
for setup in setups['data']:
    for o in setup['outputs']:
        if o['outputIndex'] == idx and o.get('enabled'):
            o['enabled'] = False
            o['priority'] = max(o.get('priority',0), 2)
            changed += 1
fd, tmp = tempfile.mkstemp(suffix='.json', dir='/tmp')
with os.fdopen(fd, 'w') as f:
    json.dump(data, f, indent=4)
os.chmod(tmp, 0o644)
print(f"changed={changed} tmp={tmp}")
PY
    local tmp
    tmp="$(ls -t /tmp/tmp*.json 2>/dev/null | head -1 || true)"
    if [[ -n "$tmp" ]]; then
        run_or_print "sudo install -o plasmalogin -g plasmalogin -m 644 '${tmp}' '${cfg}'"
        run_or_print "sudo rm -f '${tmp}'"
        ok "Updated ${cfg}"
    fi
}

# ============================================================================
# Uninstall
# ============================================================================

uninstall_action() {
    log "Reverting changes…"

    # Try to recover detection without dying on missing pieces.
    DISTRO_ID="$(. /etc/os-release 2>/dev/null; echo "${ID:-}")"
    NVIDIA_CARD=
    for d in /sys/class/drm/card[0-9]/device/driver; do
        [[ -e "$d" ]] || continue
        [[ "$(basename "$(readlink "$d")")" == nvidia ]] && \
            NVIDIA_CARD="$(basename "$(dirname "$(dirname "$d")")")"
    done

    # Remove dracut drop-in + regenerate
    if [[ -f "$DRACUT_DROP_IN" ]]; then
        run_or_print "sudo rm -f '${DRACUT_DROP_IN}'"
        run_or_print "sudo dracut --force --regenerate-all"
        ok "Removed dracut drop-in and regenerated initramfs"
    fi

    # Remove kernel args (try common connector names from /proc/cmdline)
    local args
    args="$(grep -oE 'drm\.edid_firmware=[^ ]+ video=[^ ]+' /proc/cmdline | head -1 || true)"
    if [[ -n "$args" ]]; then
        run_or_print "sudo grubby --update-kernel=ALL --remove-args=\"${args}\""
        ok "Removed kernel args from BLS entries"
    fi

    # Restore latest backups
    local latest
    latest="$(ls -t /etc/kernel/cmdline.bak.* 2>/dev/null | head -1 || true)"
    [[ -n "$latest" ]] && run_or_print "sudo mv '${latest}' /etc/kernel/cmdline"
    latest="$(ls -t /etc/default/grub.bak.* 2>/dev/null | head -1 || true)"
    [[ -n "$latest" ]] && run_or_print "sudo mv '${latest}' /etc/default/grub"

    [[ -f /boot/grub2/grub.cfg ]] && \
        run_or_print "sudo grub2-mkconfig -o /boot/grub2/grub.cfg >/dev/null 2>&1 || true"

    # Remove firmware
    run_or_print "sudo rm -f '${EDID_FIRMWARE_PATH}'"

    # Disable shipped sunshine service if enabled
    systemctl --user is-enabled app-dev.lizardbyte.app.Sunshine.service >/dev/null 2>&1 && \
        run_or_print "systemctl --user disable app-dev.lizardbyte.app.Sunshine.service"

    # Remote-first artifacts
    [[ -f "$AUTOLOGIN_DROP_IN" ]] && run_or_print "sudo rm -f '${AUTOLOGIN_DROP_IN}'"
    [[ -f "$LOCK_AUTOSTART" ]] && run_or_print "rm -f '${LOCK_AUTOSTART}'"

    # Restore latest plasmalogin display config backup
    latest="$(sudo bash -c 'ls -t /var/lib/plasmalogin/.config/kwinoutputconfig.json.bak.* 2>/dev/null | head -1')"
    [[ -n "$latest" ]] && run_or_print "sudo mv '${latest}' /var/lib/plasmalogin/.config/kwinoutputconfig.json"

    warn "User-level configs left in place: ${TARGET_HOME}/.config/sunshine/, ${TARGET_HOME}/.config/autostart/sunshine-display-init.*"
    warn "Delete them manually if you want a fully clean uninstall."

    ok "Uninstall complete. Reboot for kernel/initramfs changes to take effect."
}

# ============================================================================
# Main
# ============================================================================

install_action() {
    detect_distro
    detect_nvidia_card
    detect_render_node
    detect_connectors
    detect_initramfs
    detect_bootloader
    detect_dm

    print_summary

    if ! confirm "Apply install with the above settings?"; then
        die "Aborted by user."
    fi

    generate_edid
    install_edid_firmware
    configure_initramfs
    configure_kernel_params
    write_sunshine_config
    write_user_scripts
    enable_sunshine_service

    if $REMOTE_FIRST; then
        echo
        log "Applying --remote-first configuration"
        if confirm "Enable autologin for ${TARGET_USER} + immediate screen lock + virtual connector hidden in greeter?"; then
            configure_autologin
            configure_lock_on_start
            configure_dm_display_profile
        else
            warn "Skipped --remote-first steps"
        fi
    fi

    echo
    ok "Install complete."
    log "Reboot required for kernel / initramfs changes to take effect:"
    printf "    sudo reboot\n"
}

main() {
    parse_args "$@"
    preflight
    case "$ACTION" in
        install)   install_action ;;
        uninstall) uninstall_action ;;
        *) die "Unknown action: $ACTION" ;;
    esac
}

main "$@"
