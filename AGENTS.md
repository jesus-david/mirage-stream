# mirage-stream — guía para agentes

Punto de entrada para trabajar en este repositorio. El detalle vive en
[`docs/`](docs/) y en las dos notas largas de la raíz; acá está lo que hay que saber
**antes** de escribir código.

## Qué es

Un display virtual para streamear el escritorio con [Sunshine](https://github.com/LizardByte/Sunshine)
en Linux + NVIDIA, sin dummy plug. Son scripts de shell y un generador de EDID en
Python: no hay build, no hay servicio propio, no hay base de datos. Lo que hay es un
instalador que **modifica el sistema del usuario** — parámetros de kernel, initramfs,
autologin del display manager, unidades de systemd y la config de Hyprland.

Ese es el nivel de riesgo: un error acá no rompe un test, deja a alguien sin arrancar
el escritorio o con la sesión desbloqueada expuesta por red. Probá con `--dry-run`
donde exista y leé [`docs/decisions.md`](docs/decisions.md) antes de "simplificar"
algo que se vea raro.

Son **dos perfiles independientes que no se mezclan** en la misma máquina:

| Perfil | Cómo obtiene el display | Compositor | Instalador |
|---|---|---|---|
| `kde-kms` (default) | EDID inyectado por kernel en un conector libre | KDE/KWin, `kscreen-doctor` | `install.sh` |
| `hyprland-headless` | output headless creado por Hyprland | Hyprland (parser Lua), captura `wlr` | `install-hyprland-headless.sh` |

## Cómo verificar un cambio

```bash
./verificar.sh --rapido    # las reglas del repo: no toca el sistema
./verificar.sh             # además compara el repo con lo instalado en esta máquina
```

Corrélo **antes** de tocar nada —para saber que partías de verde— y otra vez al
terminar.

Una tarea no termina porque el cambio se vea bien, termina porque esto sale en verde.

Si cambiás una regla de las de abajo, cambiá su prueba en
[`tests/test_reglas.py`](tests/test_reglas.py) — si no, la regla se queda en prosa y
deja de valer.

Hoy el arnés **nace en rojo** en dos reglas: son hallazgos abiertos, no pruebas mal
escritas. Están en [`docs/pendientes.md`](docs/pendientes.md) con su primer paso.

## Estructura

```
install.sh                      instalador del perfil kde-kms; delega en el otro con --profile
install-hyprland-headless.sh    instalador del perfil hyprland-headless, con subcomando doctor
create-edid.py                  genera el EDID de 256 bytes con los dos VSDB
profiles/hyprland-headless/     plantillas .in; @TARGET_HOME@ y @RENDER_NODE@ se sustituyen al instalar
scripts/                        plantillas del perfil kde-kms para instalación manual en Arch
tests/test_reglas.py            las reglas de este archivo, en forma ejecutable
```

Los `.in` **no se ejecutan desde el repo**: se instalan como copias en
`~/.local/lib/mirage-stream/`. Un commit no llega al sistema hasta reinstalar.

## Convenciones

- Comentarios y mensajes en inglés (el repo es público); `*.es.md` y `docs/` en español.
- Un comentario explica **por qué**, no qué. Los de este repo son casi todos actas de
  un bug que costó encontrar: no los borres al refactorizar.
- Bash con `set -euo pipefail`. Si una línea puede fallar sin que importe, `|| true`
  explícito.
- Sin dependencias nuevas: `bash`, `python3` de stdlib, `jq`, y lo que ya trae el
  escritorio (`hyprctl`, `kscreen-doctor`).

## Lo que hay que entender antes de tocar nada

**Nada de `hyprctl keyword` ni `hyprctl dispatch` con sintaxis clásica.** Con el parser
Lua no-legacy imprimen `keyword can't work with non-legacy parsers` y **devuelven exit
0 igual**. Un script con `set -e` no se entera: MIRAGE se queda en 1920x1080, los
workspaces no se mueven y los monitores físicos no se apagan, sin un solo error. Usar
`hleval` con la API `hl.*`, que es lo único que compara la respuesta con `"ok"`.

**Los conectores se detectan, no se escriben a mano.** `DP-5`/`DP-6` son los monitores
de la máquina donde se desarrolló esto y el repo es público: en otra máquina mandan los
20 workspaces a un monitor que no existe.

**MIRAGE tiene una sola posición en todo el repo.** El `hyprctl reload config-only` de
`stream-stop.sh` relee el config del usuario y pisa cualquier posición puesta en
caliente. Si la regla persistida y la de runtime no coinciden, la de runtime es mentira.

**Los scripts del perfil kde-kms exportan las tres variables**: `WAYLAND_DISPLAY`,
`XDG_RUNTIME_DIR` y `DBUS_SESSION_BUS_ADDRESS`. Sunshine corre `global_prep_cmd` sin el
entorno de la sesión; sin la tercera, `kscreen-doctor` no falla, no imprime nada y no
cambia ningún monitor — pantalla negra sin error en ningún log.

**El EDID lleva los dos VSDB o NVIDIA no activa el CRTC.** Sin el HDMI VSDB (`00-0C-03`)
y el HDMI Forum VSDB (`C4-5D-D8`), el conector queda en 0x0 y Sunshine devuelve 503. El
bloque CTA tiene 127 bytes útiles: agregar VICs o DTDs a `create-edid.py` los empuja
fuera sin que nada avise.

**No uses un archivo Lua sourceado por Hyprland para "arrancar una vez por sesión".**
end-4 re-ejecuta un `custom/*.lua` entero cada vez que cambia su mtime — un `touch`
solo alcanza. El arranque va por `systemctl --user enable`, atado a
`graphical-session.target`.

## Qué no asumir

- **Que el sistema corre lo que dice el repo.** `doctor` no compara contenidos; para
  eso está `./verificar.sh` sin `--rapido`.
- **Que `--dry-run` existe en los dos perfiles.** El de Hyprland lo rechaza a
  propósito: necesita una sesión viva para consultar `hyprctl`.
- **Que el perfil de Hyprland sirve con cualquier dotfiles.** Asume el parser Lua
  no-legacy (end-4/dots-hyprland) y la barra de quickshell.
- **Que `renderD128` es NVIDIA.** Con iGPU AMD presente suele ser `renderD129`.

## Secretos

No hay. El repo no lleva credenciales ni `.env`. Lo que sí es sensible es lo que el
instalador **activa**: `--remote-first` habilita autologin, así que la seguridad de la
máquina pasa a depender de que la pantalla de bloqueo levante. Ver
[`docs/decisions.md`](docs/decisions.md).

## Mapa de la documentación

| Documento | Cuándo leerlo |
|---|---|
| [`docs/decisions.md`](docs/decisions.md) | Antes de cambiar algo que se ve raro: por qué quedó así |
| [`docs/pendientes.md`](docs/pendientes.md) | Al empezar: qué quedó abierto y cuál es su primer paso |
| [`HYPRLAND-HEADLESS.es.md`](HYPRLAND-HEADLESS.es.md) | Para tocar el perfil de Hyprland |
| [`FEDORA-NOTES.md`](FEDORA-NOTES.md) | Para tocar `install.sh` o el EDID |

Mantené esta guía corta. Lo que crezca, va a [`docs/`](docs/).
