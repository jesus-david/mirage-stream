# Display Virtual para Sunshine en Linux — NVIDIA + KDE Wayland (Sin Dummy Plug)

> **English version:** [README.md](README.md)

Guía completa para configurar un display virtual headless para [Sunshine](https://github.com/LizardByte/Sunshine) en Linux, sin dummy plug físico, usando drivers propietarios de NVIDIA y KDE Plasma 6 en Wayland.

## El Problema

Al hacer streaming del escritorio con Sunshine/Moonlight, se necesita un **display virtual dedicado** que:
- Solo exista mientras hay un cliente conectado
- Use automáticamente la resolución nativa del cliente
- No interfiera con los monitores físicos (sin ventanas abriéndose en pantallas invisibles)

## Por Qué los Enfoques Comunes Fallan con NVIDIA

| Método | Por qué falla |
|---|---|
| **VKMS** | Crea un dispositivo DRM sin nodo render (`/dev/dri/renderD*`). KMS capture de NVIDIA requiere un nodo render → error 503 en Sunshine |
| **EDID injection simple** (solo `drm.edid_firmware`) | NVIDIA lee el EDID pero no enumera modos sin el flag `video=:e` |
| **Solo `video=:e`** | Crea el conector pero sin modos disponibles |
| **EDID genérico** | NVIDIA limita el pixel clock a ~165 MHz (ancho de banda HDMI 1.4) si el EDID no tiene los bloques VSDB de HDMI |
| **Dummy plug barato** | Entrena el enlace a HBR únicamente, mismo límite de ~150 MHz |

## La Solución

Usar **inyección de EDID firmware con un EDID correctamente construido** que incluya los bloques VSDB de HDMI que NVIDIA requiere, combinado con el parámetro de kernel `video=:e` para forzar la activación del conector.

Los dos parámetros de kernel deben usarse **juntos**:
```
drm.edid_firmware=HDMI-A-1:edid/virtual.bin video=HDMI-A-1:e
```

El EDID debe contener:
- **HDMI Vendor Specific Data Block** (OUI `00-0C-03`) — indica a NVIDIA el reloj TMDS máximo (600 MHz)
- **HDMI Forum VSDB** (OUI `C4-5D-D8`) — declara soporte HDMI 2.1 / SCDC

Sin estos dos bloques, NVIDIA no activa el CRTC, resultando en resolución 0x0 y error 503 en Sunshine.

## Probado En

| SO | Kernel | GPU / Driver | Escritorio | Sunshine |
|---|---|---|---|---|
| CachyOS (Arch) | linux-cachyos 7.0.6 | RTX 4060 Ti, driver 570.x | KDE Plasma 6.6.5, Wayland | 2026.508.45922 |
| Fedora 44 KDE | 7.0.9-202.fc44 | RTX 4060 Ti, akmod-nvidia 595.71 | KDE Plasma 6 + Hyprland, Wayland | 2026.516.143833 |
| Nobara 43 (base Fedora) | 7.0.5-200.nobara.fc43 | RTX 4060 Ti, driver 570.x | KDE Plasma 6, Wayland | 2026.516.30826 |

También reportado funcionando en RTX 5080 con driver 595.58.

## Requisitos

- Arch/CachyOS **o** cualquier distro basada en Fedora (Fedora, Nobara)
- Driver propietario de NVIDIA (`nvidia-dkms` / `nvidia` / `akmod-nvidia`)
- Sunshine instalado (AUR, COPR de LizardByte, o RPM desde GitHub releases)
- `python3` (para generar el EDID)
- Un conector libre sin monitor físico conectado (ej. `HDMI-A-1`, `HDMI-A-2`)
- `kscreen-doctor` (parte de `kscreen`, normalmente pre-instalado con KDE)

## Instalación

### Automatizada — Fedora / Nobara

El installer detecta automáticamente la tarjeta NVIDIA, el conector libre, el nodo render, la herramienta de initramfs, el bootloader y el gestor de pantalla, y configura todo:

```bash
./install.sh
```

Flags opcionales:
- `--remote-first` — autologin + bloqueo de pantalla inmediato + servicio Sunshine al arranque (equivalente a Windows AutoLogon)
- `--dry-run` — muestra todas las acciones sin aplicarlas
- `-y` — omite las confirmaciones
- `uninstall` — revierte todos los cambios

Ver [FEDORA-NOTES.md](FEDORA-NOTES.md) para notas detalladas sobre Fedora y el diseño del installer.

Para el perfil nativo de Hyprland sin EDID, consulta [HYPRLAND-HEADLESS.es.md](HYPRLAND-HEADLESS.es.md).

### Manual — Arch / CachyOS

Sigue los Pasos 1–10 a continuación.

---

## Paso 1 — Encontrar el Conector Libre

```bash
for p in /sys/class/drm/card*-*/status; do
    con=${p%/status}
    echo "$(basename $con): $(cat $p)"
done
```

Primero identifica cuál tarjeta es la NVIDIA:

```bash
for d in /sys/class/drm/card[0-9]/device/driver; do
    drv=$(basename "$(readlink "$d")")
    card=$(basename "$(dirname "$(dirname "$d")")")
    echo "$card: $drv"
done
```

En esta guía usamos `HDMI-A-1`. Ajusta el nombre del conector si el tuyo es diferente (en sistemas multi-GPU es común `HDMI-A-2`, `DP-4`, etc.).

## Paso 2 — Generar el EDID

```bash
python3 create-edid.py virtual.bin
```

Verifica el resultado:
```bash
python3 - <<'EOF'
data = open('virtual.bin','rb').read()
print(f'Tamaño: {len(data)} bytes (esperado 256)')
print(f'Checksum base: {"OK" if sum(data[:128]) % 256 == 0 else "FALLO"}')
print(f'Checksum ext:  {"OK" if sum(data[128:]) % 256 == 0 else "FALLO"}')
print(f'HDMI VSDB:     {"PRESENTE" if b"\x03\x0C\x00" in data else "AUSENTE"}')
print(f'HDMI Forum VSDB: {"PRESENTE" if b"\xD8\x5D\xC4" in data else "AUSENTE"}')
EOF
```

Ambos VSDBs deben aparecer como `PRESENTE`.

## Paso 3 — Instalar el Firmware EDID

```bash
sudo mkdir -p /usr/lib/firmware/edid
sudo cp virtual.bin /usr/lib/firmware/edid/virtual.bin
```

Añadirlo al initramfs. Edita `/etc/mkinitcpio.conf`:

```
FILES=(/usr/lib/firmware/edid/virtual.bin)
```

Reconstruir el initramfs:
```bash
sudo mkinitcpio -P
```

## Paso 4 — Añadir Parámetros de Kernel

**CachyOS / Limine** — edita `/etc/default/limine`:
```
KERNEL_CMDLINE[default]+="drm.edid_firmware=HDMI-A-1:edid/virtual.bin video=HDMI-A-1:e"
```
Luego ejecuta:
```bash
sudo limine-update-cfg
```

**Arch Linux / GRUB** — edita `/etc/default/grub`:
```
GRUB_CMDLINE_LINUX_DEFAULT="... drm.edid_firmware=HDMI-A-1:edid/virtual.bin video=HDMI-A-1:e"
```
Luego ejecuta:
```bash
sudo grub-mkconfig -o /boot/grub/grub.cfg
```

**systemd-boot** — edita tu entrada en `/boot/loader/entries/*.conf`:
```
options ... drm.edid_firmware=HDMI-A-1:edid/virtual.bin video=HDMI-A-1:e
```

## Paso 5 — Configurar Sunshine

Edita `~/.config/sunshine/sunshine.conf`:

```ini
global_prep_cmd = [{"do":"/home/USUARIO/.config/sunshine/scripts/connect.sh","undo":"/home/USUARIO/.config/sunshine/scripts/disconnect.sh","elevated":"false"}]
adapter_name = /dev/dri/renderD128
capture = kms
encoder = nvenc
```

Sustituye `USUARIO` por tu nombre de usuario. Para encontrar tu nodo render de NVIDIA:
```bash
ls -la /dev/dri/by-path/ | grep render
```
En sistemas con una sola GPU el nodo render de NVIDIA suele ser `renderD128`. En sistemas con iGPU AMD + dGPU NVIDIA puede ser `renderD129` — comprueba `by-path/pci-<BDF>-render` donde `<BDF>` es la dirección PCI de la tarjeta NVIDIA.

## Paso 6 — Instalar los Scripts de Conexión/Desconexión

```bash
mkdir -p ~/.config/sunshine/scripts
cp scripts/connect.sh scripts/disconnect.sh ~/.config/sunshine/scripts/
chmod +x ~/.config/sunshine/scripts/*.sh
```

Edita los scripts y sustituye los nombres de conector (`HDMI-A-1`, `DP-2`, `DP-3`) por tus conectores reales.

## Paso 7 — Instalar el Script de Autostart

Como el conector virtual siempre aparece como *connected* a nivel de kernel (la inyección de EDID es permanente), KDE restaura el estado de pantallas de la última sesión al arrancar. Si el equipo se apagó con un cliente conectado, el conector virtual arrancará activo y solapado con el monitor principal.

El fix es un script de autostart que fuerza el estado correcto en cada inicio de sesión:

```bash
cp scripts/display-init.sh ~/.config/autostart/sunshine-display-init.sh
cp scripts/sunshine-display-init.desktop ~/.config/autostart/
chmod +x ~/.config/autostart/sunshine-display-init.sh
```

Edita `~/.config/autostart/sunshine-display-init.sh` con tus nombres de conector reales.
Edita `~/.config/autostart/sunshine-display-init.desktop` y actualiza la ruta `Exec` con tu nombre de usuario.

Este script espera 3 segundos a que KWin termine de inicializar, luego desactiva el conector virtual y asegura que los monitores físicos estén activos.

## Paso 8 — Configurar Capabilities de Sunshine

Necesario para KMS capture:
```bash
sudo setcap cap_sys_admin+p $(readlink -f $(which sunshine))
```

Nota: el RPM de LizardByte para Fedora ya establece `cap_sys_admin,cap_sys_nice=p` — este paso solo es necesario en instalaciones de Arch/AUR.

## Paso 9 — Reiniciar

```bash
sudo reboot
```

## Paso 10 — Verificar

Tras el reinicio, comprueba que el conector virtual tiene modos reales:
```bash
kscreen-doctor -o | grep -A 5 "HDMI-A-1"
```

Deberías ver una lista de resoluciones (1080p, 1440p, 4K, etc.) en lugar de `0x0`. El display virtual está desactivado por defecto y solo se activa cuando conecta un cliente Moonlight.

---

## Cómo Funciona

```
Uso normal del escritorio:
  DP-2 (físico) ──┐
  DP-3 (físico) ──┤── Activos
  HDMI-A-1      ──┘── Desactivado

Cliente conecta por Moonlight:
  connect.sh ejecuta:
    DP-2, DP-3 ── Desactivados
    HDMI-A-1   ── Activado  ──► Sunshine lo captura ──► Cliente Moonlight
  
Cliente desconecta:
  disconnect.sh ejecuta:
    HDMI-A-1   ── Desactivado
    DP-2, DP-3 ── Restaurados
```

Como el conector virtual es la **única pantalla activa** durante el streaming, todas las ventanas se abren ahí y el cliente lo ve todo.

## Solución de Problemas

**El conector virtual muestra 0x0 tras el reinicio**
- Verifica que ambos parámetros de kernel están presentes: `cat /proc/cmdline | grep edid`
- Verifica que el EDID tiene los bloques VSDB (ejecuta el script de verificación del Paso 2)
- Arch: confirma que el EDID está en el initramfs: `lsinitcpio /boot/initramfs-linux.img | grep edid`
- Fedora: confirma que el EDID está en el initramfs: `sudo lsinitrd /boot/initramfs-$(uname -r).img | grep edid`
- Fedora con SELinux Enforcing: comprueba que el archivo tiene la etiqueta correcta: `ls -lZ /usr/lib/firmware/edid/virtual.bin` — debe mostrar `lib_t`. Corrige con: `sudo restorecon -Rv /usr/lib/firmware/edid/`

**Error 503 en Sunshine / pantalla negra**
- Confirma que `capture = kms` está en `sunshine.conf`
- Confirma que `cap_sys_admin` está configurado: `getcap $(which sunshine)`
- Confirma que `adapter_name` apunta al nodo render de NVIDIA (no al de la iGPU)
- Revisa logs: `journalctl --user -u app-dev.lizardbyte.app.Sunshine.service -n 100`

**connect.sh no hace nada / los monitores no cambian / kscreen-doctor falla silenciosamente**
- Sunshine ejecuta los scripts sin el entorno completo de la sesión de usuario. El script debe exportar las tres variables:
  ```bash
  export WAYLAND_DISPLAY=wayland-0
  export XDG_RUNTIME_DIR=/run/user/$(id -u)
  export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus
  ```
- `DBUS_SESSION_BUS_ADDRESS` es la que más frecuentemente falta — kscreen-doctor la usa para comunicarse con KWin y falla silenciosamente sin ella.

**Aparece Virtual-1 u otros displays virtuales extra**
- Puede que el módulo `vkms` se esté cargando al arranque. Elimínalo:
  ```bash
  sudo rm /etc/modules-load.d/vkms.conf
  sudo reboot
  ```

**El conector virtual solapa los monitores físicos en la pantalla de login (Fedora)**
- plasmalogin (gestor de sesión de KDE) guarda su propia configuración de pantallas. Edita `/var/lib/plasmalogin/.config/kwinoutputconfig.json` para desactivar el conector virtual en la configuración del greeter, o vuelve a ejecutar `./install.sh --remote-first` tras el primer arranque con el conector virtual activo.

## Notas

- **HDR**: No funciona en displays virtuales. NVIDIA solo crea las propiedades DRM necesarias (`HDR_OUTPUT_METADATA`, `Colorspace`, `max_bpc`) cuando detecta un enlace físico HDMI 2.1 real con negociación SCDC. Es una limitación del driver sin solución conocida.
- **Resolución**: Sunshine ajusta automáticamente la resolución del display virtual para que coincida con el cliente que se conecta.
- **Desinstalar (Fedora)**: `./install.sh uninstall` revierte todos los cambios (kernel args, initramfs, firmware, autologin, scripts).
- Este setup está basado en el [gist de HarryAnkers](https://gist.github.com/HarryAnkers/8dbf551d66f00e8156ef4dd2b2b090a0) con investigación adicional sobre integración con KDE Wayland, scripts de conexión/desconexión, y el fallo de VKMS con NVIDIA.

## Licencia

MIT
