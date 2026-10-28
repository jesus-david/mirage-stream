# Decisiones

Por qué el proyecto quedó así y no de otra forma. Casi todo esto salió de romperlo
primero: si algo se ve raro, buscalo acá antes de "arreglarlo".

## Monitor principal de XWayland al entrar y salir del stream

Los juegos X11 pueden elegir MIRAGE por ser el primer output de XWayland aunque
el escritorio local esté en un monitor físico. Mover los workspaces de Hyprland
no actualiza esa elección. `set-primary-output.sh` fija el principal con `xrandr`:
MIRAGE al conectar; un monitor físico activo, preferentemente el enfocado, al
desconectar y al iniciar la sesión. Si sólo existe MIRAGE, usa ese output.
El arranque importa también `DISPLAY` al entorno de systemd. Un error de XWayland
se registra sin impedir que Sunshine siga funcionando.

Las pruebas cubren la selección y los tres hooks; confirmar el mouse en un juego
después de una desconexión real sigue siendo necesario.

## Por qué hay dos perfiles y no uno

El perfil original (`kde-kms`) resuelve el problema desde el kernel: inyecta un EDID en
un conector libre y lo fuerza con `video=<conector>:e`. Funciona en cualquier
compositor, pero el precio es alto — toca initramfs, parámetros de kernel y el greeter,
necesita `sudo` y un reboot, y deja el conector visible como *conectado* para siempre,
lo que obliga a un script de autostart que corrija el estado en cada login.

`hyprland-headless` apareció después, cuando el escritorio pasó a Hyprland: el
compositor puede crear un output headless por sí mismo (`hyprctl output create`). No
hay EDID, ni kernel, ni `sudo` en el uso diario. **No se mezclan**: si el kernel ya
fuerza un conector, el perfil de Hyprland encuentra un monitor fantasma y la lógica de
apagar/prender monitores físicos se confunde. Por eso el instalador de Hyprland aborta
si detecta parámetros del otro perfil.

## Por qué el EDID necesita dos bloques VSDB

Es la razón de existir del perfil `kde-kms`. Los caminos obvios fallan todos con el
driver propietario de NVIDIA:

- **VKMS** crea un dispositivo DRM sin render node, y la captura KMS lo necesita → 503.
- **`drm.edid_firmware` solo** hace que NVIDIA lea el EDID pero no enumere modos.
- **`video=:e` solo** crea un conector con cero modos disponibles.
- **Un EDID genérico** deja el pixel clock topeado en ~165 MHz (límite HDMI 1.4).
- **Un dummy plug barato** linkea a HBR, con el mismo tope.

Lo que destraba el pixel clock es el HDMI VSDB (OUI `00-0C-03`, declara 600 MHz de
TMDS) más el HDMI Forum VSDB (OUI `C4-5D-D8`, declara HDMI 2.1/SCDC). Sin los dos,
nvidia-drm lee el EDID y aun así no activa el CRTC: 0x0 y Sunshine 503.

## Por qué todo el perfil de Hyprland pasa por `hyprctl eval`

Descubierto rompiéndolo (commit `acc1168`): con el parser Lua no-legacy de
end-4/dots-hyprland, `hyprctl keyword` y `hyprctl dispatch` con sintaxis clásica
imprimen `keyword can't work with non-legacy parsers. Use eval.` **y devuelven exit
0**. Todo el perfil estaba escrito así, con `set -e`, y no fallaba: MIRAGE se quedaba
en 1920x1080, los workspaces nunca se movían y los monitores físicos nunca se apagaban
durante el stream. Cero errores en cualquier log.

El reemplazo es `hyprctl eval` con la API `hl.*`, envuelto en un `hleval()` que compara
la respuesta con `"ok"` y loguea a stderr cuando no lo es. La envoltura es la parte que
importa: sin ella se vuelve al mismo silencio.

## Por qué el arranque va por systemd y no por un `exec-once` de Hyprland

Se probaron tres lugares:

1. `UserConfigs/Startup_Apps.conf` — es una ruta de la era JaKooLit; la config
   no-legacy de end-4 nunca la sourcea, así que el `exec-once` no corría jamás.
2. `custom/execs.lua` — end-4 **re-sourcea** un `custom/*.lua` completo cada vez que
   cambia su mtime, re-ejecutando cada `hl.exec_cmd` de nivel superior. Confirmado con
   un `touch` sin cambiar contenido: el servicio se relanzaba solo. Cualquier edición
   futura del archivo, por quien sea, relanzaría el stream sin aviso.
3. `systemctl --user enable`, atado a `graphical-session.target` — que es lo que
   "arrancar una vez por sesión" significa de verdad, y es independiente de que
   Hyprland recargue su config.

La regla de posición de MIRAGE sí vive en `custom/general.lua`, y no se contradice con
lo anterior: `hl.monitor()` es declarativo, reaplicarlo es un no-op. Un `hl.exec_cmd`
tiene efecto secundario; una regla de monitor no.

## Por qué `SuccessExitStatus=143` en la unidad

`systemctl stop` manda SIGTERM, así que el script envuelto sale con 143 y systemd lo
marca `failed` en vez de `inactive`. Combinado con `Restart=on-failure`, un
`daemon-reload` posterior —por ejemplo al reinstalar— revivía el servicio sin que nadie
pidiera un `start`.

## Por qué MIRAGE se coloca lejísimos y no en `auto`

El output existe mientras corre el servicio, no sólo durante el stream. Con
`position = "auto"` Hyprland lo pega al monitor real más cercano y el cursor se puede
"perder" ahí: no hay nada renderizado físicamente. Un rectángulo separado del resto es
inalcanzable con el mouse, y a la captura `wlr` de Sunshine le da igual en qué
coordenadas esté.

La posición tiene que estar **persistida en el config del usuario**, no puesta en
caliente: `stream-stop.sh` corre `hyprctl reload config-only` al desconectar, que relee
los archivos y descarta cualquier cosa seteada sólo en runtime.

## Por qué el estado de los monitores se guarda en disco y no en memoria

`stream-start.sh` escribe los monitores físicos en
`~/.local/state/mirage-stream/physical-monitors.json` —persistente, no tmpfs— antes de
apagarlos. Si la máquina se corta a mitad de un stream, `stream-stop.sh` nunca corre y
la sesión queda con los monitores físicos apagados y la barra apuntando a MIRAGE. Al
arrancar, `hyprland-headless-session.sh` reproduce `stream-stop.sh` sin condiciones: es
idempotente y no hace nada si no hay estado que restaurar.

## El compromiso de seguridad de `--remote-first`

`--remote-first` habilita autologin en el display manager, para que la máquina llegue
sola a una sesión gráfica con Sunshine corriendo después de un corte de luz — el
equivalente al AutoLogon de Windows. A partir de ahí **la seguridad de la máquina
depende por completo de que la pantalla de bloqueo levante**: si el bloqueo falla,
queda una sesión abierta, accesible por red y sin contraseña.

Por eso el arranque no confía en la cadena `hypridle`→lock del escritorio (el
`lock_cmd` que trae dots-hyprland chequea `pidof qs quickshell hyprlock`, y `qs` está
siempre corriendo, así que su fallback nunca dispara): pide `loginctl lock-session` y
un segundo después comprueba que algo esté efectivamente manejando el bloqueo. Es una
decisión con contrapartida: lanzar `hyprlock` de más apila dos pantallas de bloqueo y
obliga a desbloquear dos veces, y por eso la comprobación mira también si quickshell ya
se hizo cargo.

No actives `--remote-first` en una máquina que no esté en una red de confianza.

## Por qué MIRAGE refresca a lo que pide el cliente

MIRAGE se creaba y se fijaba siempre a `2560x1440@60`. Con Moonlight pidiendo 90 o 120
fps el stream salía igual a 60: el output virtual es lo que Sunshine captura, y un
compositor a 60 Hz no le entrega más cuadros aunque el juego los renderice.

`stream-start.sh` ahora toma el refresco de `SUNSHINE_CLIENT_FPS`, que Sunshine exporta
a `global_prep_cmd`, y cae a 60 si falta o sale de 30-240. Hyprland acepta cualquier
refresco en un output headless: probado el 2026-09-19 con 90 y 120, que quedaron
exactos. La creación del output en `hyprland-headless-session.sh` sigue en 60 a
propósito, es el valor por defecto entre sesiones, y `stream-stop.sh` vuelve a él al
recargar el config.

El script deja en el journal lo que Sunshine le pasó (`client WxH@FPS host_audio=…`).
Sirve para comprobar que la variable llega de verdad: en el momento de escribir esto
sólo se conocía por la documentación de Sunshine, no por una sesión real.

## Por qué un reinicio por fallo no bloquea la sesión

`hyprland-headless-session.sh` bloqueaba el escritorio en cada arranque. Sunshine 2026.516
se cae con SIGSEGV al terminar una app (tres veces el 2026-09-19, en `nvhttp::cancel →
proc_t::terminate`), systemd lo reinicia (`Restart=on-failure`) y cada reinicio dejaba al
usuario frente a la pantalla de bloqueo de Quickshell sin haber hecho nada.

Ahora `should_lock_session` bloquea sólo si `NRestarts` es 0: un arranque de la máquina, un
inicio manual o una instalación siguen bloqueando, y un reinicio automático tras una caída
deja la sesión como estaba, abierta o bloqueada. Si el contador no se puede leer se bloquea:
ante la duda, el lado seguro. Es una contrapartida de seguridad y por eso la decidió el
usuario: tras una caída de Sunshine con la sesión abierta, esta queda abierta hasta que algo
la bloquee. No arregla la caída, sólo que no arrastre al escritorio.

Un `systemctl --user restart` a mano pone el contador en 0 y vuelve a bloquear. Probado con un
`systemctl` falso (0, 1, 7, vacío, no numérico y con error) y con el real; no con una caída
real de Sunshine.
