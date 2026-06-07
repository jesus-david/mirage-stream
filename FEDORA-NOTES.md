# Fedora / Nobara setup notes

Working notes for adapting this project from Arch (Limine + mkinitcpio) to
Fedora-based distros (GRUB + BLS + dracut). Verified on **Nobara Linux 43**
and **Fedora 44 KDE** with **NVIDIA RTX 4060 Ti**.

These notes feed into `install.sh` — the automated installer for Fedora-based
distros.

---

## Tested hardware / software

### Fedora 44 KDE

| Component | Value |
|---|---|
| Distro | Fedora 44 (KDE Plasma Desktop Edition) |
| Kernel | 7.0.9-202.fc44.x86_64 |
| DE | KDE Plasma 6 + Hyprland, Wayland |
| CPU / iGPU | AMD Ryzen 5 7600X (Raphael iGPU on `card1`) |
| dGPU | NVIDIA RTX 4060 Ti, akmod-nvidia 595.71 (`card2`) |
| Bootloader | GRUB UEFI + BLS, `grubby` available |
| Initramfs | dracut |
| BLS | enabled (`GRUB_ENABLE_BLSCFG='true'`) |
| Sunshine | LizardByte RPM `Sunshine-2026.516.143833-1.fc44.x86_64` |
| SELinux | **Enforcing** (stock Fedora default) |
| Virtual connector | `HDMI-A-2` (on `card2`) |
| Physical connectors | `DP-5` (2560×1440@144), `DP-6` (2560×1080@90) |
| Render node | `/dev/dri/renderD129` |

**SELinux note**: stock Fedora runs SELinux Enforcing (unlike Nobara which disables it). After install, run `sudo restorecon -Rv /usr/lib/firmware/edid/` to ensure the firmware file gets the correct `lib_t` label. The installer does not do this automatically.

### Nobara 43

| Component | Value |
|---|---|
| Distro | Nobara 43 (Fedora 43 base) |
| Kernel | 7.0.5-200.nobara.fc43.x86_64 |
| DE | KDE Plasma 6, Wayland |
| CPU / iGPU | AMD Ryzen 5 7600X (Raphael iGPU on `card2`) |
| dGPU | NVIDIA RTX 4060 Ti, driver `nvidia` (`card1`) |
| Bootloader | GRUB UEFI, `/boot/grub2/grub.cfg` stub at `/boot/efi/EFI/fedora/grub.cfg` |
| Initramfs | dracut 107 |
| BLS | enabled (`GRUB_ENABLE_BLSCFG='true'`) |
| Sunshine | LizardByte RPM `Sunshine-2026.516.30826-1.fc43.x86_64` |
| SELinux | Disabled on Nobara by default |

---

## Differences from Arch — TL;DR

| Step | Arch (Limine + mkinitcpio) | Fedora / Nobara (GRUB + BLS + dracut) |
|---|---|---|
| Add EDID to initramfs | `FILES=()` in `/etc/mkinitcpio.conf` | drop-in `/etc/dracut.conf.d/edid.conf` with `install_items+=" … "` |
| Rebuild initramfs | `sudo mkinitcpio -P` | `sudo dracut --force --regenerate-all` |
| Inspect initramfs | `lsinitcpio /boot/initramfs-linux.img` | `sudo lsinitrd /boot/initramfs-$(uname -r).img` |
| Set kernel cmdline (existing kernels) | `/etc/default/limine` + `limine-update-cfg` | `sudo grubby --update-kernel=ALL --args="…"` |
| Set kernel cmdline (future kernels) | n/a | also edit `/etc/kernel/cmdline` and `/etc/default/grub` |
| Regenerate bootloader config | `limine-update-cfg` | `sudo grub2-mkconfig -o /boot/grub2/grub.cfg` (mostly cosmetic with BLS) |
| Install Sunshine | AUR `yay -S sunshine` | LizardByte COPR `dnf copr enable lizardbyte/sunshine` **or** RPM from GitHub releases |
| SELinux | n/a | `getenforce` — typically `Disabled` on Nobara, may be `Enforcing` on stock Fedora |
| Connector name (HDMI-A-1?) | NVIDIA was `card2`; HDMI-A-1 was on NVIDIA | NVIDIA is `card1`; HDMI-A-1 is on AMD iGPU. Use `HDMI-A-2` or `DP-4` (free NVIDIA connectors) |

**Critical gotcha**: the order of DRM cards is **not stable** across distros
or even across Fedora versions. On the same hardware: Arch loaded `amdgpu`
first (NVIDIA = card2), Nobara 43 loaded NVIDIA first (NVIDIA = card1),
Fedora 44 loads amdgpu first again (NVIDIA = card2). This shifts every
connector name. The installer **must detect the NVIDIA card and its free
connectors dynamically**, not assume any specific card number.

---

## Step-by-step (Fedora / Nobara)

### 1. Detect NVIDIA card and a free connector

```bash
# Find which DRM card is the nvidia one
for d in /sys/class/drm/card[0-9]/device/driver; do
    drv=$(basename "$(readlink "$d")")
    card=$(basename "$(dirname "$(dirname "$d")")")
    [ "$drv" = "nvidia" ] && nvidia_card="$card"
done
echo "NVIDIA card: $nvidia_card"

# List its connectors and pick a disconnected one
for p in /sys/class/drm/${nvidia_card}-*/status; do
    name=$(basename "${p%/status}" | sed "s/${nvidia_card}-//")
    echo "$name: $(cat "$p")"
done
```

Prefer HDMI over DP (the generated EDID carries HDMI VSDB blocks).
For this hardware: `HDMI-A-2` on `card1`.

### 2. Generate and install EDID

```bash
python3 create-edid.py virtual.bin

sudo mkdir -p /usr/lib/firmware/edid
sudo cp virtual.bin /usr/lib/firmware/edid/virtual.bin
sudo chmod 644 /usr/lib/firmware/edid/virtual.bin
```

### 3. Embed EDID in initramfs (dracut)

```bash
echo 'install_items+=" /usr/lib/firmware/edid/virtual.bin "' | \
    sudo tee /etc/dracut.conf.d/edid.conf

sudo dracut --force --regenerate-all
```

Verify:
```bash
sudo lsinitrd /boot/initramfs-$(uname -r).img | grep edid
# expect: usr/lib/firmware/edid/virtual.bin
```

Note: the spaces inside the quotes in `install_items+=" … "` are required
by dracut's `+=` syntax. Without them the path concatenates with the
previous list entry.

### 4. Add kernel parameters

Three places, all needed for a robust setup:

**a) Existing kernels (BLS entries) — required:**
```bash
CONNECTOR=HDMI-A-2   # adjust per detected connector
sudo grubby --update-kernel=ALL \
    --args="drm.edid_firmware=${CONNECTOR}:edid/virtual.bin video=${CONNECTOR}:e"
```

**b) Future kernels via `kernel-install`:**
```bash
# Append to /etc/kernel/cmdline (do not duplicate if already present)
sudo sed -i "s|\$| drm.edid_firmware=${CONNECTOR}:edid/virtual.bin video=${CONNECTOR}:e|" \
    /etc/kernel/cmdline
```

**c) `/etc/default/grub` (consistency for `grub2-mkconfig`):**
```bash
sudo sed -i "s|^\(GRUB_CMDLINE_LINUX_DEFAULT='[^']*\)'|\1 drm.edid_firmware=${CONNECTOR}:edid/virtual.bin video=${CONNECTOR}:e'|" \
    /etc/default/grub

sudo grub2-mkconfig -o /boot/grub2/grub.cfg
```

With `GRUB_ENABLE_BLSCFG='true'` (Fedora default) the `grub2-mkconfig` step
does **not** rewrite the kernel cmdlines — those live in BLS entries under
`/boot/loader/entries/` and are managed by `grubby`. Keeping
`/etc/default/grub` in sync is for non-BLS fallback and future Fedora policy
changes.

### 5. Install Sunshine

Either:

```bash
# Option A: LizardByte COPR (rolling)
sudo dnf copr enable lizardbyte/sunshine -y
sudo dnf install sunshine -y
```

```bash
# Option B: direct RPM from GitHub releases (what was used on this host)
# Package shows up as "Sunshine" (capital S) in rpm -q
# Already provides cap_sys_admin+p out of the box
```

The LizardByte RPM already sets:
```
/usr/bin/sunshine cap_sys_admin,cap_sys_nice=p
```
so the manual `setcap` step from the Arch instructions is unnecessary, but
harmless to run.

### 6. Reboot and verify

```bash
sudo reboot
```

After login:
```bash
cat /proc/cmdline | tr ' ' '\n' | grep -E "edid_firmware|video="
# both args present

cat /sys/class/drm/${nvidia_card}-${CONNECTOR}/status
# connected

cat /sys/class/drm/${nvidia_card}-${CONNECTOR}/modes | head
# real resolutions, not empty

sudo dmesg | grep -iE "forcing ${CONNECTOR}|edid"
# expect: [drm] forcing HDMI-A-2 connector on
```

### 7. Sunshine config and toggle scripts

`~/.config/sunshine/sunshine.conf`:
```
global_prep_cmd = [{"do":"/home/USER/.config/sunshine/scripts/connect.sh","undo":"/home/USER/.config/sunshine/scripts/disconnect.sh","elevated":"false"}]
adapter_name = /dev/dri/renderD128
capture = kms
encoder = nvenc
```

Important: `renderD128` corresponds to the NVIDIA card on this host
(verified by `ls -la /dev/dri/by-path/`). On systems where NVIDIA is `card2`,
the render node is usually `renderD129`. The installer must check
`/sys/class/drm/<card>/device` against the NVIDIA driver and pick the
matching render node from `/dev/dri/by-path/`.

`connect.sh` / `disconnect.sh` / `autostart/sunshine-display-init.sh`: replace
all connector names in the repo's templates with the detected connector and
the physical-monitor connector names. On this host:

- repo template: `HDMI-A-1` → `HDMI-A-2`
- repo template: `DP-2`, `DP-3` → `DP-5`, `DP-6` (whatever the physical
  connectors are; the user must provide these, or the installer can record
  the connectors that were `connected` on the NVIDIA card at install time)

### 8. End-to-end test

1. Sunshine running, `~/.config/sunshine/sunshine.log` confirms config loaded.
2. Connect from Moonlight → log shows `Executing Do Cmd: …/connect.sh` and
   `CLIENT CONNECTED`.
3. Disconnect → `disconnect.sh` runs, physical monitors come back.

---

## Display manager: `plasmalogin` vs SDDM

Nobara 43 / Plasma 6.6+ ships **`plasmalogin`** (package
`plasma-login-manager`) as the display manager — KDE's native replacement
for SDDM, configured via:

- `/etc/plasmalogin.conf` (main, package-managed)
- `/etc/plasmalogin.conf.d/*.conf` (drop-ins, user-managed)
- `/var/lib/plasmalogin/.config/` (per-greeter state, including KWin
  output config)

INI syntax is SDDM-compatible (`[Autologin]`, `[Wayland]`, …).
Stock Fedora KDE spin still uses SDDM. The installer should detect:

```bash
systemctl status display-manager.service --no-pager | head -2 | grep -oE "plasmalogin|sddm|gdm"
```

…and branch.

## Lockscreen overlap at boot — fixed

**Root cause**: when the kernel forces `HDMI-A-2` on via
`drm.edid_firmware=…` + `video=…:e`, the greeter's KWin sees three valid
outputs (DP-5, DP-6, HDMI-A-2) and applies a saved 3-output layout where
all three are enabled with overlapping positions. Result: SDDM/plasmalogin
clock duplicated, password input flashing.

**Fix on plasmalogin** (Nobara 43): edit
`/var/lib/plasmalogin/.config/kwinoutputconfig.json` (owned
`plasmalogin:plasmalogin`, mode 644). In the `setups` array's 3-output
entry, set the HDMI-A-2 output to `enabled: false` (and demote its
priority). Preserve ownership when writing back (`install -o plasmalogin
-g plasmalogin -m 644`). Verified on Nobara 43 / Plasma 6.6.4 — greeter
shows only on physical monitors after reboot.

**Fix on SDDM** (untested here): same approach against
`/var/lib/sddm/.config/kwinoutputconfig.json` (Wayland greeter) or an
`Xsetup` script that calls `xrandr --output HDMI-A-2 --off` (X11 greeter).

**Risk**: KWin (both greeter's and user's) overwrites
`kwinoutputconfig.json` when display config changes via Plasma settings.
If the fix is reverted by a future user action, re-apply. The installer
should keep a backup at `kwinoutputconfig.json.bak.<ts>`.

## Boot-time Sunshine + pre-login Moonlight access

Goal: power on the PC, leave physical monitors untouched, connect from
Moonlight before any local input, see the login/lock screen on the
virtual display, type the password remotely. Equivalent to Windows
AutoLogon + immediate WinLock.

Three pieces:

### 1. Sunshine as a user systemd service at boot

The LizardByte RPM **already ships**
`/usr/lib/systemd/user/app-dev.lizardbyte.app.Sunshine.service` with
`Alias=sunshine.service` and `WantedBy=graphical-session.target`. It is
shipped **disabled** even though it may appear `active` because of the
companion XDG autostart `.desktop` file. Enable it explicitly:

```bash
systemctl --user enable app-dev.lizardbyte.app.Sunshine.service
```

The Arch README's instruction to start Sunshine manually does not apply
on the Fedora RPM. Do not write a custom `~/.config/systemd/user/sunshine.service`
— it will alias-clash with the shipped one.

### 2. plasmalogin autologin

Drop-in `/etc/plasmalogin.conf.d/10-autologin.conf`:

```ini
[Autologin]
User=<username>
Session=plasma.desktop
Relogin=true
```

`Relogin=true` so plasmalogin re-auto-logs after explicit user logout —
keeps the box "always logged in but locked", matching Windows AutoLogon
semantics. The session file `plasma.desktop` lives at
`/usr/share/wayland-sessions/plasma.desktop`; the installer should verify
it exists (some Plasma spins may ship `plasmawayland.desktop` instead).

### 3. Lock screen on session start

`~/.config/autostart/lock-on-start.desktop`:

```ini
[Desktop Entry]
Type=Application
Name=Lock on session start
Exec=sh -c 'sleep 3 && loginctl lock-session'
X-KDE-autostart-phase=2
X-GNOME-Autostart-enabled=true
NoDisplay=true
```

`sleep 3` lets KWin and Plasma panels finish initializing before the
lock screen overlay paints; without it the lock can fire while the
wallpaper is still loading. Phase 2 autostart = "after Plasma is up".

### Security tradeoff

Autologin + immediate lock means anyone with physical access can boot
the box and reach the lock screen (cannot unlock without credentials).
This is the same threat model as Windows AutoLogon + WinLock and matches
the desired UX (remote-first usage). Don't enable on shared/public
hardware.

### sunshine.conf written by hand

The LizardByte web UI at `https://localhost:47990` can write `sunshine.conf`
too, but the version on this host left the file empty after the user
configured it via UI. Possibly a permissions issue or different config
storage path. Writing the file directly works and is what the installer
should do.

### Sunshine "different GPU" warning

`Using NVENC with your display connected to a different GPU may not work
properly!` appears in the log because Sunshine sees the active connector
(virtual on NVIDIA) but the heuristic may be looking at the AMD iGPU's
present outputs. Benign — streaming works.

---

## install.sh design notes

Detection logic the installer needs:

1. **Distro family**: `/etc/os-release` `ID_LIKE` includes `fedora` →
   Fedora branch; `ID=arch` or `ID_LIKE` includes `arch` → Arch branch.
2. **NVIDIA card**: scan `/sys/class/drm/card[0-9]/device/driver` for
   `nvidia`. Bail if not found.
3. **Render node**: read `/dev/dri/by-path/pci-<bdf>-render` symlink,
   resolve to `renderD12X`.
4. **Free connector on NVIDIA card**: list `card<N>-*/status`, pick
   `disconnected`. Prefer HDMI > DP.
5. **Active connectors on NVIDIA card** (= physical monitors): list
   `connected` ones; these go into `disconnect.sh`'s enable list and
   `connect.sh`'s disable list.
6. **Initramfs tool**: `command -v dracut` vs `command -v mkinitcpio`.
7. **Bootloader**: check `/etc/default/limine` vs `/etc/default/grub` vs
   `/boot/loader/loader.conf` (systemd-boot). For each, the path to
   regenerate config differs.
8. **Display manager**: `systemctl status display-manager.service` →
   plasmalogin vs sddm vs gdm. Determines the path for the greeter
   `kwinoutputconfig.json` and the autologin config syntax.

Steps the installer needs to be idempotent on:

- `dracut.conf.d/edid.conf` — skip if already correct
- `grubby --update-kernel` — `grubby` is naturally idempotent for `--args`
  but should detect dup args
- `/etc/kernel/cmdline` — `grep -F` before appending
- `/etc/default/grub` — same
- `sunshine.conf` — back up before writing if it already exists with content
- scripts in `~/.config/sunshine/scripts/` — overwrite or back up?
- greeter `kwinoutputconfig.json` — JSON-aware edit (detect existing
  `enabled: false` on virtual output before re-writing); always back up
- `~/.config/systemd/user/`-shipped sunshine units — `systemctl --user
  is-enabled` first, only `enable` if disabled
- `/etc/plasmalogin.conf.d/10-autologin.conf` — overwrite OK (drop-in
  owned by the installer); never edit `/etc/plasmalogin.conf` directly

Optional `--remote-first` flag enables the "Windows-like" UX:
- autologin drop-in
- `lock-on-start.desktop` autostart
- enable shipped sunshine user service

Without `--remote-first`, the installer leaves login/autologin behavior
untouched.

Rollback steps the installer should provide as `install.sh --uninstall`:

- `sudo rm /etc/dracut.conf.d/edid.conf && sudo dracut --force --regenerate-all`
- `sudo grubby --update-kernel=ALL --remove-args="drm.edid_firmware=… video=…"`
- restore `/etc/kernel/cmdline.bak.<ts>` and `/etc/default/grub.bak.<ts>`
- `sudo rm -rf /usr/lib/firmware/edid/virtual.bin`
- `sudo rm /etc/plasmalogin.conf.d/10-autologin.conf`
- restore `/var/lib/plasmalogin/.config/kwinoutputconfig.json.bak.<ts>`
- `systemctl --user disable app-dev.lizardbyte.app.Sunshine.service` (only
  if we enabled it)
- `rm ~/.config/autostart/lock-on-start.desktop`
- prompt before removing user's `~/.config/sunshine/sunshine.conf` and scripts
