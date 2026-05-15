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

- **OS:** CachyOS (Arch-based), kernel linux-cachyos 7.0.6
- **GPU:** NVIDIA RTX 4060 Ti, driver 570.x (also reported working on RTX 5080 with driver 595.58)
- **Desktop:** KDE Plasma 6.6.5, Wayland
- **Sunshine:** 2026.508.45922

## Prerequisites

- Arch Linux or CachyOS
- NVIDIA proprietary driver (`nvidia-dkms` or `nvidia`)
- Sunshine installed (AUR or native package)
- `python3` (for EDID generation)
- A free connector without a physical monitor connected (e.g., `HDMI-A-1`)
- `kscreen-doctor` (part of `kscreen`, usually pre-installed with KDE)

## Step 1 — Find Your Free Connector

```bash
for p in /sys/class/drm/card*-*/status; do
    con=${p%/status}
    echo "$(basename $con): $(cat $p)"
done
```

Look for a connector on your NVIDIA card (`card1` in most systems) that shows `disconnected`. In this guide we use `HDMI-A-1`. Adjust the connector name throughout if yours is different.

## Step 2 — Generate the EDID

Download and run the EDID generator script:

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
for card in /sys/class/drm/card[0-9]; do
    echo "$(basename $card): $(cat $card/device/uevent | grep DRIVER)"
done
```
The card with `DRIVER=nvidia` maps to `renderD128` in most single-GPU setups.

## Step 6 — Install the Connect/Disconnect Scripts

```bash
mkdir -p ~/.config/sunshine/scripts
cp scripts/connect.sh scripts/disconnect.sh ~/.config/sunshine/scripts/
chmod +x ~/.config/sunshine/scripts/*.sh
```

## Step 7 — Install the Autostart Script

Because `HDMI-A-1` is always seen as *connected* at kernel level (the EDID injection makes it permanent), KDE will restore whatever display state was active in the last session. If the machine was shut down while a client was connected, `HDMI-A-1` will come back enabled on next boot, overlapping your primary monitor.

The fix is an autostart script that enforces the correct idle state at login:

```bash
cp scripts/display-init.sh ~/.config/autostart/sunshine-display-init.sh
cp scripts/sunshine-display-init.desktop ~/.config/autostart/
chmod +x ~/.config/autostart/sunshine-display-init.sh
```

This script waits 3 seconds for KWin to finish initializing, then disables `HDMI-A-1` and ensures both physical monitors are active.

## Step 9 — Set Sunshine Capabilities

Required for KMS capture:
```bash
sudo setcap cap_sys_admin+p $(readlink -f $(which sunshine))
```

## Step 10 — Reboot

```bash
sudo reboot
```

## Step 11 — Verify

After reboot, check that `HDMI-A-1` has real modes:
```bash
kscreen-doctor -o | grep -A 5 "HDMI-A-1"
```

You should see a list of resolutions (1080p, 1440p, 4K, etc.) instead of `0x0`. The virtual display is disabled by default and only activates when a Moonlight client connects.

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

Because `HDMI-A-1` is the **only active display** during streaming, all windows open there and the client sees everything.

## Troubleshooting

**HDMI-A-1 shows 0x0 after reboot**
- Verify both kernel parameters are present: `cat /proc/cmdline | grep edid`
- Verify the EDID has the VSDB blocks (run the verification script from Step 2)
- Confirm the EDID is in the initramfs: `lsinitcpio /boot/initramfs-linux.img | grep edid`

**Sunshine error 503 / black screen**
- Confirm `capture = kms` is set in `sunshine.conf`
- Confirm `cap_sys_admin` is set: `getcap $(which sunshine)`
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

## Notes

- **HDR**: Not supported on virtual displays. NVIDIA only creates the required DRM properties (`HDR_OUTPUT_METADATA`, `Colorspace`, `max_bpc`) when it detects a real physical HDMI 2.1 link with SCDC negotiation. This is a driver limitation with no known workaround.
- **Resolution matching**: Sunshine automatically adjusts the virtual display resolution to match the connecting client.
- This setup was derived from [HarryAnkers' gist](https://gist.github.com/HarryAnkers/8dbf551d66f00e8156ef4dd2b2b090a0) with additional research on KDE Wayland integration, connect/disconnect scripting, and the VKMS failure mode on NVIDIA.

## License

MIT
