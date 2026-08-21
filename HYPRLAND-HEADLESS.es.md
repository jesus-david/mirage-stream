# Perfil Hyprland Headless

Este perfil usa un output `MIRAGE` creado por Hyprland y la captura `wlr` de
Sunshine. No usa `kscreen-doctor`, KWin, EDID firmware ni un conector DRM
forzado, por lo que no altera el greeter de `plasmalogin`.

## Instalacion

Desde una terminal dentro de una sesion Hyprland:

```bash
cd ~/dev/mirage-stream
./install.sh --profile hyprland-headless --remote-first
```

El instalador pide la contrasena de `sudo` solo para crear el override de
autologin de `plasmalogin`. Configura `hyprland.desktop` con `Relogin=false`:
el equipo entra automaticamente a Hyprland despues de encender, pero cerrar
sesion sigue mostrando el selector de sesiones.

Las copias previas de los archivos de usuario se guardan en
`~/.local/share/mirage-stream/backups/` y las configuraciones existentes de
autologin se copian junto a su archivo en `/etc/plasmalogin.conf.d/`.

## Flujo de inicio

1. Hyprland ejecuta `start-hyprland-headless.sh` mediante `exec-once`.
2. El script entrega las variables de la sesion al gestor systemd de usuario.
3. `mirage-stream-hyprland.service` crea `MIRAGE` a 2560x1440@60 y lo asigna
   al workspace 21.
4. Sunshine recibe el nombre XDG de ese output (`MIRAGE`) como `output_name`, captura
   por `wlr` y usa NVENC de la RTX 4060 Ti.
5. Cuando Sunshine queda en ejecucion, el servicio solicita el bloqueo de la
   sesion; `hypridle` inicia `hyprlock`.

El servicio se detiene al salir de Hyprland y elimina el output que creo. Al conectar un cliente Moonlight, conserva la resolucion negociada y fuerza escala 1.25 en `MIRAGE`, y redirige temporalmente los workspaces `1-20` a `MIRAGE`, deshabilita `DP-5` y `DP-6`, y enfoca el workspace `1`; Waybar tambien se mueve a `MIRAGE`. Al desconectar, restaura la geometria y restablece explicitamente las reglas y ubicaciones locales de workspace, y la salida anterior de Waybar. `MIRAGE` permanece activo durante toda la transicion.

Para controles tactiles, Sunshine usa `native_pen_touch = enabled` y Hyprland habilita `workspace_swipe_touch`: en Moonlight selecciona el modo de toque directo y desliza horizontalmente desde un borde de la pantalla para cambiar de workspace. Los gestos generales de Hyprland son de touchpad; para abrir Rofi desde una tablet, usa el teclado en pantalla de Moonlight y `Super+R`.

## Verificacion

Despues de volver a iniciar sesion en Hyprland, ejecuta:

```bash
systemctl --user status mirage-stream-hyprland.service
hyprctl monitors all
journalctl --user -u mirage-stream-hyprland.service -b --no-pager
```

Debe aparecer `MIRAGE`, Sunshine debe usar `capture = wlr`, y `DP-5`/`DP-6`
deben permanecer activos. Luego conecta Moonlight y desbloquea `hyprlock`.

## Desinstalacion

```bash
cd ~/dev/mirage-stream
./install.sh uninstall --profile hyprland-headless
```

Esto detiene el servicio y elimina el override de autologin de Mirage Stream.
Las copias de respaldo quedan disponibles para restaurar manualmente cualquier
ajuste previo.
