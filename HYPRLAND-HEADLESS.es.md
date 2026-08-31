# Perfil Hyprland Headless

Este perfil usa un output `MIRAGE` creado por Hyprland y la captura `wlr` de
Sunshine. No usa `kscreen-doctor`, KWin, EDID firmware ni un conector DRM
forzado, por lo que no altera el greeter de `plasmalogin`.

**Requisito importante:** este perfil asume una config de Hyprland con el
parser **no-legacy** (Lua), como la de
[dots-hyprland/end-4](https://github.com/end-4/dots-hyprland) ("illogical
impulse"). Ver la sección de "Notas técnicas" más abajo — es el punto que más
dolores de cabeza dio durante el desarrollo.

## Instalacion

Desde una terminal dentro de una sesion Hyprland, cualquiera de las dos
formas es equivalente (la primera delega en la segunda):

```bash
cd ~/dev/mirage-stream
./install.sh --profile hyprland-headless
# o directamente:
./install-hyprland-headless.sh install
```

Agregar `-y` (o `--assume-yes`) salta la confirmacion interactiva, util para
reinstalar/actualizar sin intervencion. `--remote-first` es opcional y solo
hace falta si querés autologin de `plasmalogin` en `Hyprland` + bloqueo
inmediato (pide `sudo` una vez, solo para eso). En el uso normal del dia a
dia **no hace falta `sudo` en ningun momento** — solo el perfil `kde-kms`
(el default de `install.sh` sin `--profile`) lo necesita, para el EDID
firmware y el kernel cmdline. No mezclar los dos perfiles en la misma
maquina: si alguna vez instalaste `kde-kms` por error, correr
`./install.sh uninstall` (sin `--profile`) antes de instalar este.

Las copias previas de los archivos de usuario se guardan en
`~/.local/share/mirage-stream/backups/`.

## Flujo de inicio

1. `mirage-stream-hyprland.service` (systemd --user, `enable`d por el
   instalador — arranca solo con `graphical-session.target`, no con un
   `exec-once` de Hyprland) ejecuta `hyprland-headless-session.sh`.
2. Ese script crea el output headless `MIRAGE` a 2560x1440@60 y lo asigna al
   workspace 21.
3. Lanza Sunshine con `~/.config/sunshine/sunshine-hyprland.conf`
   (`output_name = MIRAGE`, `capture = wlr`, encoder `nvenc`).
4. Bloquea la sesion: pide `loginctl lock-session` y, un segundo despues, si
   `hyprlock` todavia no quedo corriendo (la cadena `hypridle`→`quickshell`
   puede estar rota segun la config, ver "Problemas conocidos"), lo lanza
   directo el propio script como garantia.

Al conectar un cliente Moonlight (via `global_prep_cmd` de Sunshine,
`stream-start.sh`/`stream-stop.sh`):

- **Conectar:** fuerza escala 1.25 en `MIRAGE`, redirige temporalmente los
  workspaces `1-20` ahi, deshabilita los monitores fisicos guardados
  previamente, mueve la barra (`bar.screenList` en
  `~/.config/illogical-impulse/config.json`, hot-reload de quickshell — *no*
  Waybar) a `MIRAGE`, y enfoca el workspace `1`.
- **Desconectar:** restaura la geometria de los monitores fisicos, vuelve a
  aplicar las reglas locales de workspace (`hyprctl reload config-only` +
  reglas explicitas), mueve el workspace `21` de vuelta a `MIRAGE`, y
  restaura la barra a su monitor original.

`MIRAGE` permanece creado y activo durante todo el ciclo (arranque del
servicio → conexion → desconexion), no solo durante el streaming — por eso
necesita una posicion fija fuera del layout real (ver mas abajo), y no
"auto".

## Verificacion

Despues de (re)instalar o volver a iniciar sesion en Hyprland:

```bash
systemctl --user status mirage-stream-hyprland.service
hyprctl monitors all
journalctl --user -u mirage-stream-hyprland.service -b --no-pager
```

Debe aparecer `MIRAGE` a 2560x1440, Sunshine debe usar `capture = wlr`, y
los monitores fisicos deben permanecer activos y sin cambios. Conectar por
Moonlight, verificar que se ve el escritorio remoto, desconectar, y
verificar que los monitores fisicos y `MIRAGE` volvieron a su estado previo
(`hyprctl monitors all` de nuevo).

## Actualizar

```bash
cd ~/dev/mirage-stream
git pull
./install-hyprland-headless.sh install -y
./install-hyprland-headless.sh doctor
```

Reinstalar encima de una instalacion existente es seguro — todo lo que este
instalador toca es idempotente (marcadores para los bloques que agrega en
`custom/execs.lua`-equivalentes, `install -D` para los archivos generados,
etc.), confirmado corriendolo varias veces seguidas durante el desarrollo.

`doctor` es un chequeo de solo lectura (no pide `sudo`, no cambia nada) que
confirma: que `hyprctl eval` responde (parser no-legacy presente), que el
servicio esta `enabled`, que la regla de posicion de `MIRAGE` esta persistida
en la config de Hyprland, y que `sunshine-hyprland.conf` apunta a los
scripts actuales. Util para correr despues de cualquier `git pull` +
reinstalacion, antes de confiar en que Moonlight va a conectar sin
sorpresas.

## Desinstalacion

```bash
cd ~/dev/mirage-stream
./install.sh uninstall --profile hyprland-headless
# o:
./install-hyprland-headless.sh uninstall
```

Esto para y deshabilita `mirage-stream-hyprland.service`, y borra los
scripts en `~/.local/lib/mirage-stream/`. Las copias de respaldo en
`~/.local/share/mirage-stream/backups/` quedan disponibles para restaurar
manualmente cualquier ajuste previo (`sunshine.conf`, scripts de
connect/disconnect, etc.).

## Notas tecnicas / problemas conocidos

Todo lo de esta seccion salio de depurar el perfil en una instalacion real
de end-4/dots-hyprland (Fedora, RTX 4060 Ti). Si el proyecto se prueba
contra otro dotfiles de Hyprland (JaKooLit, hyprland.conf plano, etc.),
revisar cada punto — varios son especificos del parser Lua no-legacy.

**1. `hyprctl keyword` / `hyprctl dispatch <sintaxis clasica>` no funcionan
con el parser Lua no-legacy.** Imprimen `keyword can't work with non-legacy
parsers. Use eval.` en stdout — pero devuelven **codigo de salida 0**, asi
que un script con `set -e` no detecta el fallo y sigue como si nada
funcionara, pero sin que nada se haya aplicado. Todos los scripts de este
perfil (`hyprland-headless-session.sh.in`, `stream-start.sh.in`,
`stream-stop.sh.in`) usan `hyprctl eval` con la API `hl.*` documentada en
`~/.config/hypr/hl.meta.lua` de una instalacion end-4 (namespaces:
`hl.monitor({...})`, `hl.workspace_rule({...})`,
`hl.dispatch(hl.dsp.workspace.move({...}))`, `hl.dispatch(hl.dsp.focus({...}))`).
La funcion `hleval()` en cada script loguea a stderr cuando la respuesta de
`hyprctl eval` no es `"ok"`, para no repetir el mismo error silencioso.

**2. Un output headless recien creado no acepta una regla `hl.monitor`
inmediatamente.** Justo despues de `hyprctl output create headless
MIRAGE`, el primer `hl.monitor({output="MIRAGE", ...})` puede no aplicarse
(queda en el modo por defecto, 1920x1080). `hyprland-headless-session.sh.in`
reintenta unos cientos de ms antes de aplicar la regla de resolucion.

**3. No usar `custom/execs.lua` (u otro archivo Lua sourceado por Hyprland)
para "arrancar una vez por sesion".** En end-4, Hyprland re-lee y
re-ejecuta un `custom/*.lua` completo (incluyendo cualquier `hl.exec_cmd`
de nivel superior) cada vez que el archivo cambia de fecha de modificacion
— confirmado con un `touch` sin cambiar contenido. Esto significa que
cualquier edicion futura de ese archivo (por este instalador, a mano, por
cualquier herramienta) puede relanzar comandos "exec-once" sin aviso. Este
perfil usa `systemctl --user enable mirage-stream-hyprland.service`
(activacion nativa de systemd atada a `graphical-session.target`,
completamente independiente de que Hyprland recargue su config).

**4. `systemctl stop` deja el servicio en estado `failed`, no `inactive`,
si no se maneja el codigo de salida.** El `ExecStart` termina con SIGTERM
(exit 143) al pararlo; sin `SuccessExitStatus=143` en la unit, systemd lo
marca como fallo. Combinado con `Restart=on-failure`, esto puede hacer que
un `daemon-reload` posterior (p. ej. al reinstalar) reviva el servicio sin
que nadie haya pedido un `start`. La unit ya incluye
`SuccessExitStatus=143`.

**5. `MIRAGE` necesita una posicion fija y persistida, no solo un
`hyprctl eval` en caliente.** Con `position = "auto"`, Hyprland lo coloca
pegado al monitor real mas cercano — el mouse puede "perderse" ahi (nada se
renderiza visualmente en un output sin pantalla fisica). Ademas,
`stream-stop.sh` llama a `hyprctl reload config-only` al desconectar, lo
cual **relee los archivos de config desde disco y pisa cualquier posicion
puesta solo en runtime**, volviendo al default `auto`. **Resuelto:** el
instalador agrega una regla `hl.monitor({output="MIRAGE", position="100000x0",
...})` persistida en `~/.config/hypr/custom/general.lua` (marcador
`>>> mirage-stream hyprland-headless >>>`, mismo mecanismo idempotente que
`add_hyprland_startup`), asi que sobrevive a cualquier `hyprctl reload`. Es
seguro que Hyprland re-lea ese bloque en cada cambio de archivo: a
diferencia de un `hl.exec_cmd` (ver punto 3), una regla de monitor no tiene
efecto secundario al reaplicarse.

**6. El bloqueo de sesion (`loginctl lock-session`) no dispara `hyprlock`
en esta config de end-4.** El `$lock_cmd` que trae `hypridle.conf` por
defecto es:
```
$lock_cmd = hyprctl dispatch 'hl.dsp.global("quickshell:lock")' & pidof qs quickshell hyprlock || hyprlock
```
El `pidof qs quickshell hyprlock` siempre encuentra `qs` (la shell de
escritorio, que corre todo el tiempo), asi que el fallback `|| hyprlock`
nunca se ejecuta, y todo depende de que quickshell efectivamente muestre su
propia pantalla de bloqueo al recibir la señal `quickshell:lock` — cosa que
no esta pasando. Esto es un bug preexistente del `hypridle.conf` base de
dots-hyprland, no algo que este perfil rompa. **Mitigado:**
`hyprland-headless-session.sh` ya no depende solo de esa cadena — sigue
pidiendo `loginctl lock-session` (por si algo mas lo escucha), pero un
segundo despues chequea si `hyprlock` quedo corriendo y, si no, lo lanza
directo. La causa raiz en `hypridle.conf` sigue sin arreglarse (es config
del usuario/de dots-hyprland, no de este proyecto).

### TODO / mejoras pendientes

- Confirmar si los puntos 1-4 aplican igual en dotfiles de Hyprland no
  basados en end-4 (JaKooLit u otros con `hyprland.conf` plano/parser
  legacy) — probablemente el perfil completo necesite una rama de
  compatibilidad si se usa el parser legacy, ya que ahi `hyprctl keyword`/
  `dispatch` clasico si funcionan y `hyprctl eval` no existe.
