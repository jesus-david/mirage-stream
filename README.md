# Sunshine Virtual Display on Linux — NVIDIA + KDE Wayland (No Dummy Plug)

> **Spanish version:** [README.es.md](README.es.md)

A complete guide to set up a headless virtual display for [Sunshine](https://github.com/LizardByte/Sunshine) game streaming on Linux, without a physical dummy plug, using NVIDIA proprietary drivers and KDE Plasma 6 on Wayland.

## The Problem

When streaming your desktop via Sunshine/Moonlight, you want a **dedicated virtual display** that:
- Only exists while a client is connected
- Uses the client's native resolution automatically
- Doesn't conflict with your physical monitors (no windows appearing on invisible screens)

## Why Common Approaches Fail on NVIDIA

| Method | Why it fails |
|---|---|
| **VKMS** | Creates a DRM device with no render node (`/dev/dri/renderD*`). NVIDIA KMS capture requires a render node → Sunshine error 503 |
| **Simple EDID injection** (`drm.edid_firmware` alone) | NVIDIA reads the EDID metadata but doesn't enumerate modes without the `video=:e` force-enable flag |
| **`video=:e` alone** | Creates a connector with zero available modes |
| **Generic EDID file** | NVIDIA caps pixel clock at ~165 MHz (HDMI 1.4 bandwidth) unless the EDID contains HDMI Vendor Specific Data Blocks |
| **Cheap dummy plug** | Links at HBR only, same ~150 MHz pixel clock cap |

## The Solution

Use **EDID firmware injection with a properly crafted EDID** that includes the HDMI VSDB blocks NVIDIA requires, combined with the `video=:e` kernel parameter to force-enable the connector.

The two kernel parameters must be used **together**:
```
drm.edid_firmware=HDMI-A-1:edid/virtual.bin video=HDMI-A-1:e
```

The EDID must contain:
- **HDMI Vendor Specific Data Block** (OUI `00-0C-03`) — tells NVIDIA the max TMDS clock (600 MHz)
- **HDMI Forum VSDB** (OUI `C4-5D-D8`) — declares HDMI 2.1 / SCDC support

Without these two blocks, NVIDIA will not activate the CRTC, resulting in 0x0 resolution and Sunshine error 503.

## Tested On

| OS | Kernel | GPU / Driver | Desktop | Sunshine |
|---|---|---|---|---|
| CachyOS (Arch) | linux-cachyos 7.0.6 | RTX 4060 Ti, driver 570.x | KDE Plasma 6.6.5, Wayland | 2026.508.45922 |
| Fedora 44 KDE | 7.0.9-202.fc44 | RTX 4060 Ti, akmod-nvidia 595.71 | KDE Plasma 6 + Hyprland, Wayland | 2026.516.143833 |
| Nobara 43 (Fedora base) | 7.0.5-200.nobara.fc43 | RTX 4060 Ti, driver 570.x | KDE Plasma 6, Wayland | 2026.516.30826 |

Also reported working on RTX 5080 with driver 595.58.

## Prerequisites

- Arch/CachyOS **or** any Fedora-based distro (Fedora, Nobara)
- NVIDIA proprietary driver (`nvidia-dkms` / `nvidia` / `akmod-nvidia`)
- Sunshine installed (AUR, LizardByte COPR, or RPM from GitHub releases)
- `python3` (for EDID generation)
- A free connector without a physical monitor connected (e.g., `HDMI-A-1`, `HDMI-A-2`)
- `kscreen-doctor` (part of `kscreen`, usually pre-installed with KDE)

## Installation

### Automated — Fedora / Nobara

The installer auto-detects your NVIDIA card, free connector, render node, initramfs tool, bootloader, and display manager, then configures everything:

```bash
./install.sh
```

Optional flags:
- `--remote-first` — autologin + immediate screen lock + Sunshine user service at boot (Windows AutoLogon equivalent)
- `--dry-run` — print all actions without applying
- `-y` — skip confirmation prompts
- `uninstall` — revert all changes

See [FEDORA-NOTES.md](FEDORA-NOTES.md) for detailed Fedora-specific notes and the design of the installer.

### Manual — Arch / CachyOS

Follow Steps 1–10 below.

---

## Step 1 — Find Your Free Connector

```bash
for p in /sys/class/drm/card*-*/status; do
    con=${p%/status}
    echo "$(basename $con): $(cat $p)"
done
```

Look for a connector on your NVIDIA card that shows `disconnected`. First find which card is NVIDIA:

```bash
for d in /sys/class/drm/card[0-9]/device/driver; do
    drv=$(basename "$(readlink "$d")")
    card=$(basename "$(dirname "$(dirname "$d")")")
    echo "$card: $drv"
done
```

In this guide we use `HDMI-A-1`. Adjust the connector name throughout if yours is different (common on multi-GPU setups: `HDMI-A-2`, `DP-4`, etc.).

## Step 2 — Generate the EDID

```bash
python3 create-edid.py virtual.bin
```

Verify the output:
```bash
python3 - <<'EOF'
data = open('virtual.bin','rb').read()
print(f'Size: {len(data)} bytes (expected 256)')
print(f'Base checksum: {"OK" if sum(data[:128]) % 256 == 0 else "FAIL"}')
print(f'Ext  checksum: {"OK" if sum(data[128:]) % 256 == 0 else "FAIL"}')
print(f'HDMI VSDB:     {"PRESENT" if b"\x03\x0C\x00" in data else "MISSING"}')
print(f'HDMI Forum VSDB: {"PRESENT" if b"\xD8\x5D\xC4" in data else "MISSING"}')
EOF
```

Both VSDBs must show `PRESENT`.

## Step 3 — Install the EDID Firmware

```bash
sudo mkdir -p /usr/lib/firmware/edid
sudo cp virtual.bin /usr/lib/firmware/edid/virtual.bin
```

Add it to the initramfs. Edit `/etc/mkinitcpio.conf`:

```
FILES=(/usr/lib/firmware/edid/virtual.bin)
```

Rebuild initramfs:
```bash
sudo mkinitcpio -P
```

## Step 4 — Add Kernel Parameters

**CachyOS / Limine** — edit `/etc/default/limine`:
```
KERNEL_CMDLINE[default]+="drm.edid_firmware=HDMI-A-1:edid/virtual.bin video=HDMI-A-1:e"
```
Then run:
```bash
sudo limine-update-cfg
```

**Arch Linux / GRUB** — edit `/etc/default/grub`:
```
GRUB_CMDLINE_LINUX_DEFAULT="... drm.edid_firmware=HDMI-A-1:edid/virtual.bin video=HDMI-A-1:e"
```
Then run:
```bash
sudo grub-mkconfig -o /boot/grub/grub.cfg
```

**systemd-boot** — edit your entry in `/boot/loader/entries/*.conf`:
```
options ... drm.edid_firmware=HDMI-A-1:edid/virtual.bin video=HDMI-A-1:e
```

## Step 5 — Configure Sunshine

Edit `~/.config/sunshine/sunshine.conf`:

```ini
global_prep_cmd = [{"do":"/home/USER/.config/sunshine/scripts/connect.sh","undo":"/home/USER/.config/sunshine/scripts/disconnect.sh","elevated":"false"}]
adapter_name = /dev/dri/renderD128
capture = kms
encoder = nvenc
```

Replace `USER` with your username. To find your NVIDIA render node:
```bash
ls -la /dev/dri/by-path/ | grep nvidia
# or
ls -la /dev/dri/by-path/ | grep render
```
On single-GPU systems the NVIDIA render node is typically `renderD128`. On multi-GPU setups (e.g., AMD iGPU + NVIDIA dGPU) it may be `renderD129` — check `by-path/pci-<BDF>-render` where `<BDF>` is the PCI address of your NVIDIA card.

## Step 6 — Install the Connect/Disconnect Scripts

```bash
mkdir -p ~/.config/sunshine/scripts
cp scripts/connect.sh scripts/disconnect.sh ~/.config/sunshine/scripts/
chmod +x ~/.config/sunshine/scripts/*.sh
```

Edit the scripts and replace the connector names (`HDMI-A-1`, `DP-2`, `DP-3`) with your actual virtual and physical connector names.

## Step 7 — Install the Autostart Script

Because the virtual connector is always seen as *connected* at kernel level (the EDID injection makes it permanent), KDE will restore whatever display state was active in the last session. If the machine was shut down while a client was connected, the virtual connector will come back enabled on next boot, overlapping your primary monitor.

The fix is an autostart script that enforces the correct idle state at login:

```bash
cp scripts/display-init.sh ~/.config/autostart/sunshine-display-init.sh
cp scripts/sunshine-display-init.desktop ~/.config/autostart/
chmod +x ~/.config/autostart/sunshine-display-init.sh
```

Edit `~/.config/autostart/sunshine-display-init.sh` with your actual connector names.
Edit `~/.config/autostart/sunshine-display-init.desktop` and update the `Exec` path to your username.

This script waits 3 seconds for KWin to finish initializing, then disables the virtual connector and ensures both physical monitors are active.

## Step 8 — Set Sunshine Capabilities

Required for KMS capture:
```bash
sudo setcap cap_sys_admin+p $(readlink -f $(which sunshine))
```

Note: the LizardByte RPM for Fedora already sets `cap_sys_admin,cap_sys_nice=p` — this step is only needed on Arch/AUR installs.

## Step 9 — Reboot

```bash
sudo reboot
```

## Step 10 — Verify

After reboot, check that the virtual connector has real modes:
```bash
kscreen-doctor -o | grep -A 5 "HDMI-A-1"
```

You should see a list of resolutions (1080p, 1440p, 4K, etc.) instead of `0x0`. The virtual display is disabled by default and only activates when a Moonlight client connects.

---

## How It Works

```
Normal desktop use:
  DP-2 (physical) ──┐
  DP-3 (physical) ──┤── Active
  HDMI-A-1        ──┘── Disabled

Client connects via Moonlight:
  connect.sh runs:
    DP-2, DP-3 ── Disabled
    HDMI-A-1   ── Enabled  ──► Sunshine captures this ──► Moonlight client
  
Client disconnects:
  disconnect.sh runs:
    HDMI-A-1   ── Disabled
    DP-2, DP-3 ── Restored
```

Because the virtual connector is the **only active display** during streaming, all windows open there and the client sees everything.

## Troubleshooting

**Virtual connector shows 0x0 after reboot**
- Verify both kernel parameters are present: `cat /proc/cmdline | grep edid`
- Verify the EDID has the VSDB blocks (run the verification script from Step 2)
- Arch: confirm the EDID is in the initramfs: `lsinitcpio /boot/initramfs-linux.img | grep edid`
- Fedora: confirm the EDID is in the initramfs: `sudo lsinitrd /boot/initramfs-$(uname -r).img | grep edid`
- Fedora with SELinux Enforcing: check the EDID file has the correct label: `ls -lZ /usr/lib/firmware/edid/virtual.bin` — should show `lib_t`. Fix with: `sudo restorecon -Rv /usr/lib/firmware/edid/`

**Sunshine error 503 / black screen**
- Confirm `capture = kms` is set in `sunshine.conf`
- Confirm `cap_sys_admin` is set: `getcap $(which sunshine)`
- Confirm `adapter_name` points to the NVIDIA render node (not the iGPU)
- Check logs: `journalctl --user -u app-dev.lizardbyte.app.Sunshine.service -n 100`

**connect.sh does nothing / monitors don't switch / kscreen-doctor fails silently**
- Sunshine runs scripts without the full user session environment. The script must export all three variables:
  ```bash
  export WAYLAND_DISPLAY=wayland-0
  export XDG_RUNTIME_DIR=/run/user/$(id -u)
  export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus
  ```
- `DBUS_SESSION_BUS_ADDRESS` is the most commonly missing one — kscreen-doctor uses D-Bus to talk to KWin and fails silently without it.

**Extra virtual displays (Virtual-1) appear in display settings**
- You may have the `vkms` module loading at boot. Remove it:
  ```bash
  sudo rm /etc/modules-load.d/vkms.conf
  sudo reboot
  ```

**Virtual connector overlaps physical monitors at the login screen (Fedora)**
- plasmalogin (KDE's display manager) saves its own output configuration. Edit `/var/lib/plasmalogin/.config/kwinoutputconfig.json` to disable the virtual connector in the greeter's output setup, or re-run `./install.sh --remote-first` after the first boot with the virtual connector active.

## Notes

- **HDR**: Not supported on virtual displays. NVIDIA only creates the required DRM properties (`HDR_OUTPUT_METADATA`, `Colorspace`, `max_bpc`) when it detects a real physical HDMI 2.1 link with SCDC negotiation. This is a driver limitation with no known workaround.
- **Resolution matching**: Sunshine automatically adjusts the virtual display resolution to match the connecting client.
- **Uninstall (Fedora)**: `./install.sh uninstall` reverts all changes (kernel args, initramfs, firmware, autologin, scripts).
- This setup was derived from [HarryAnkers' gist](https://gist.github.com/HarryAnkers/8dbf551d66f00e8156ef4dd2b2b090a0) with additional research on KDE Wayland integration, connect/disconnect scripting, and the VKMS failure mode on NVIDIA.

## License

MIT
