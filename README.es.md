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

- **SO:** CachyOS (basado en Arch), kernel linux-cachyos 7.0.6
- **GPU:** NVIDIA RTX 4060 Ti, driver 570.x (también funciona en RTX 5080 con driver 595.58)
- **Escritorio:** KDE Plasma 6.6.5, Wayland
- **Sunshine:** 2026.508.45922

## Requisitos

- Arch Linux o CachyOS
- Driver propietario de NVIDIA (`nvidia-dkms` o `nvidia`)
- Sunshine instalado (AUR o paquete nativo)
- `python3` (para generar el EDID)
- Un conector libre sin monitor físico conectado (ej. `HDMI-A-1`)
- `kscreen-doctor` (parte de `kscreen`, normalmente pre-instalado con KDE)

## Paso 1 — Encontrar el Conector Libre

```bash
for p in /sys/class/drm/card*-*/status; do
    con=${p%/status}
    echo "$(basename $con): $(cat $p)"
done
```

Busca un conector en la tarjeta NVIDIA (`card1` en la mayoría de sistemas) que muestre `disconnected`. En esta guía usamos `HDMI-A-1`. Ajusta el nombre del conector si el tuyo es diferente.

## Paso 2 — Generar el EDID

Descarga y ejecuta el script generador de EDID:

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
for card in /sys/class/drm/card[0-9]; do
    echo "$(basename $card): $(cat $card/device/uevent | grep DRIVER)"
done
```
La tarjeta con `DRIVER=nvidia` mapea a `renderD128` en la mayoría de sistemas con una sola GPU discreta.

## Paso 6 — Instalar los Scripts de Conexión/Desconexión

```bash
mkdir -p ~/.config/sunshine/scripts
cp scripts/connect.sh scripts/disconnect.sh ~/.config/sunshine/scripts/
chmod +x ~/.config/sunshine/scripts/*.sh
```

## Paso 7 — Configurar Capabilities de Sunshine

Necesario para KMS capture:
```bash
sudo setcap cap_sys_admin+p $(readlink -f $(which sunshine))
```

## Paso 8 — Reiniciar

```bash
sudo reboot
```

## Paso 9 — Verificar

Tras el reinicio, comprueba que `HDMI-A-1` tiene modos reales:
```bash
kscreen-doctor -o | grep -A 5 "HDMI-A-1"
```

Deberías ver una lista de resoluciones (1080p, 1440p, 4K, etc.) en lugar de `0x0`. El display virtual está desactivado por defecto y solo se activa cuando conecta un cliente Moonlight.

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

Como `HDMI-A-1` es la **única pantalla activa** durante el streaming, todas las ventanas se abren ahí y el cliente lo ve todo.

## Solución de Problemas

**HDMI-A-1 muestra 0x0 tras el reinicio**
- Verifica que ambos parámetros de kernel están presentes: `cat /proc/cmdline | grep edid`
- Verifica que el EDID tiene los bloques VSDB (ejecuta el script de verificación del Paso 2)
- Confirma que el EDID está en el initramfs: `lsinitcpio /boot/initramfs-linux.img | grep edid`

**Error 503 en Sunshine / pantalla negra**
- Confirma que `capture = kms` está en `sunshine.conf`
- Confirma que `cap_sys_admin` está configurado: `getcap $(which sunshine)`
- Revisa logs: `journalctl --user -u app-dev.lizardbyte.app.Sunshine.service -n 100`

**connect.sh no hace nada / kscreen-doctor falla silenciosamente**
- El script necesita las variables de entorno de Wayland. Verifica que estas líneas están en el script:
  ```bash
  export WAYLAND_DISPLAY=wayland-0
  export XDG_RUNTIME_DIR=/run/user/$(id -u)
  ```

**Aparece Virtual-1 u otros displays virtuales extra**
- Puede que el módulo `vkms` se esté cargando al arranque. Elimínalo:
  ```bash
  sudo rm /etc/modules-load.d/vkms.conf
  sudo reboot
  ```

## Notas

- **HDR**: No funciona en displays virtuales. NVIDIA solo crea las propiedades DRM necesarias (`HDR_OUTPUT_METADATA`, `Colorspace`, `max_bpc`) cuando detecta un enlace físico HDMI 2.1 real con negociación SCDC. Es una limitación del driver sin solución conocida.
- **Resolución**: Sunshine ajusta automáticamente la resolución del display virtual para que coincida con el cliente que se conecta.
- Este setup está basado en el [gist de HarryAnkers](https://gist.github.com/HarryAnkers/8dbf551d66f00e8156ef4dd2b2b090a0) con investigación adicional sobre integración con KDE Wayland, scripts de conexión/desconexión, y el fallo de VKMS con NVIDIA.

## Licencia

MIT
