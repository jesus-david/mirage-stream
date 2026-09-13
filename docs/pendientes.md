# Pendientes

Lo que quedó abierto en mirage-stream. **Esta es la lista, no hay otra**: un pendiente
anotado en otro lado —una herramienta externa, un `TODO:` suelto en el código, la
memoria de una sesión que se cerró— lo encuentra solo quien ya sabía que existía.

Cada pendiente lleva su **primer paso concreto**. Sin primer paso no es un pendiente,
es una intención — y no entra.

## Abiertos

### Reglas del arnés en rojo

- [ ] **`stream-stop.sh.in` tiene DP-5/DP-6 hardcodeados.** Son los monitores del autor,
  en un repo público: en otra máquina los 20 workspaces van a un monitor inexistente.
  Primer paso: `stream-start.sh` ya guarda los monitores en
  `~/.local/state/mirage-stream/physical-monitors.json`; derivar de ahí el mapeo
  workspace→monitor en `restore_local_workspace_rules`
  (`profiles/hyprland-headless/stream-stop.sh.in:41`) en vez de la lista fija. Falta
  decidir de dónde sale la asignación 9/10→segundo monitor, que hoy no está en el
  state file. — 2026-09-08

- [ ] **MIRAGE tiene dos posiciones distintas.** `100000x0` en la regla que el
  instalador persiste y `10000x0` en los scripts de runtime; el `hyprctl reload
  config-only` de `stream-stop.sh` hace ganar a la primera. Primer paso: elegir un
  valor y usarlo en `install-hyprland-headless.sh:145`,
  `hyprland-headless-session.sh.in:84` y `stream-start.sh.in:37`. — 2026-09-08

### Bugs encontrados, sin arreglar

- [ ] **`install.sh` instala como config del greeter el primer `/tmp/tmp*.json` que
  encuentre.** `configure_dm_display_profile` no lee la ruta que su propio Python
  imprime: la adivina con `ls -t /tmp/tmp*.json | head -1`. Si ese Python no llegó a
  escribir nada (sale por `sys.exit(0)` cuando el conector no está en el historial del
  greeter), instala con `sudo` un archivo temporal de cualquier otro proceso; y como
  `/tmp` es compartido, otro usuario local puede plantarlo. Primer paso: capturar la
  salida del heredoc y parsear el `tmp=` que ya imprime (`install.sh:560`), o escribir
  directo al destino desde el propio Python. — 2026-09-08

- [ ] **`install-hyprland-headless.sh` aborta a mitad si Sunshine no vino del RPM de
  LizardByte.** `systemctl --user disable --now app-dev.lizardbyte.app.Sunshine.service`
  (línea 255) devuelve 1 si la unidad no existe, y con `set -e` mata el instalador
  después de haber escrito los archivos y movido los autostart. Primer paso: agregarle
  `|| true`, como ya tienen las llamadas equivalentes de `uninstall_profile`. — 2026-09-08

- [ ] **El preflight anti-conflicto entre perfiles sólo reconoce DP-4 y HDMI-A-2.**
  `install-hyprland-headless.sh:91` busca esos dos nombres literales en `/proc/cmdline`,
  así que en una máquina donde `kde-kms` forzó HDMI-A-1 no detecta el conflicto que
  existe para detectar. Primer paso: hacer el patrón genérico
  (`drm\.edid_firmware=[^ ]*virtual\.bin`). — 2026-09-08

- [ ] **`hyprland-headless-session.sh` lanza `/usr/bin/sunshine` con ruta absoluta**
  aunque el preflight lo buscó con `command -v`. Falla con Sunshine en
  `/usr/local/bin` o Flatpak. Primer paso: sustituir un `@SUNSHINE@` en la plantilla,
  resuelto por el instalador. — 2026-09-08

- [ ] **El bucle de espera tras crear el output headless no espera nada.**
  `hyprland-headless-session.sh.in:71-75` corta en la primera iteración porque el output
  ya existe justo después de `hyprctl output create`; lo que hay que esperar —que
  Hyprland acepte una regla `hl.monitor` sobre él, punto 2 de las notas técnicas— nunca
  se comprueba. Primer paso: reemplazar la condición por una que verifique que la regla
  se aplicó (leer `mode` de `hyprctl -j monitors` hasta que sea 2560x1440). — 2026-09-08

- [ ] **Con MIRAGE siempre creado, los juegos X11 entran a pantalla completa en él y
  pierden el mouse.** XWayland lista MIRAGE como monitor 0 sin primary, y Valheim
  (`UnitySelectMonitor=0`) queda en un output al que el cursor no llega. Workaround
  verificado a mano: `xrandr --output DP-5 --primary`. No persiste, y probablemente se
  pierde cuando `stream-start.sh` deshabilita DP-5. Primer paso: después del
  `hyprctl output create headless` (`hyprland-headless-session.sh.in:66`) y al final de
  `restore_physical_monitors` (`stream-stop.sh.in`), marcar como primary el monitor
  físico sacado de `physical-monitors.json`, no DP-5 fijo (ver el pendiente de
  hardcodeo). Verificar con `xrandr --listmonitors` antes y después de una sesión
  Moonlight. — 2026-09-12

### Cobertura

- [ ] **El perfil `kde-kms` no tiene ninguna prueba de comportamiento.** El arnés sólo
  comprueba el EDID y los `export` de los scripts; el resto del instalador (detección
  de conectores, edición de `/etc/default/grub`, uninstall) no se ejerce. Primer paso:
  probar si `./install.sh --dry-run` es ejecutable dentro de una prueba sin sudo, y si
  lo es, aserciones sobre su salida. — 2026-09-08

- [ ] **Confirmar si el perfil de Hyprland funciona fuera de end-4/dots-hyprland**
  (JaKooLit u otros con parser legacy, donde `hyprctl eval` no existe y `keyword` sí).
  Venía del TODO de `HYPRLAND-HEADLESS.es.md`. Primer paso: correr
  `hyprctl eval 'hl.get_active_workspace()'` en una config legacy y ver qué devuelve.
  — 2026-09-08

## Cerrados

- [x] **El repo y la máquina corrían versiones distintas de
  `hyprland-headless-session.sh`.** El arreglo del doble lock screen (no lanzar
  `hyprlock` si quickshell ya maneja el bloqueo) vivía sólo en el archivo instalado.
  Se llevó a la plantilla del repo; `./verificar.sh` ahora detecta este tipo de drift,
  que `doctor` no veía. — 2026-09-08
