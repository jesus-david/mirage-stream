#!/usr/bin/env bash
#
# El arnes de mirage-stream. Corre esto ANTES de tocar nada y otra vez DESPUES.
#
# Antes, porque trabajar horas sobre un proyecto que ya estaba roto es la forma
# mas cara de perder el tiempo. Despues, porque un agente que dice "listo, ya
# funciona" no es evidencia de nada: lo unico que cierra una tarea es que esto
# salga en verde.
#
#   ./verificar.sh              todo, incluida la instalacion en esta maquina
#   ./verificar.sh --rapido     solo las reglas del repo: sin tocar el sistema
#   ./verificar.sh -v           detalla prueba por prueba
#
# Las pruebas no necesitan instalar nada: son unittest de la stdlib de Python,
# que ya hace falta para generar el EDID. Un arnes que hay que instalar es un
# arnes que nadie corre.

set -uo pipefail
cd "$(dirname "$0")"

RAPIDO=0
PRUEBAS=(python3 -m unittest discover -s tests -p 'test_*.py')

for arg in "$@"; do
  case "$arg" in
    --rapido)     RAPIDO=1 ;;
    -v|--verboso) PRUEBAS+=(-v) ;;
    -h|--help)    sed -n '3,17p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "Opcion desconocida: $arg" >&2; exit 2 ;;
  esac
done

if [ -t 1 ]; then ROJO=$'\e[31m'; VERDE=$'\e[32m'; GRIS=$'\e[90m'; FIN=$'\e[0m'
else ROJO=""; VERDE=""; GRIS=""; FIN=""; fi

FALLOS=0
titulo() { printf '\n%s== %s ==%s\n' "$GRIS" "$1" "$FIN"; }
ok()     { printf '%s  ok%s  %s\n' "$VERDE" "$FIN" "$1"; }
fallo()  { printf '%s  FALLA%s  %s\n' "$ROJO" "$FIN" "$1"; FALLOS=$((FALLOS + 1)); }
omitir() { printf '%s  --%s  %s\n' "$GRIS" "$FIN" "$1"; }

resumir() {
  titulo "resultado"
  if [ "$FALLOS" = 0 ]; then
    ok "todo en verde${1:+ $1}"
    exit 0
  fi
  fallo "$FALLOS comprobacion(es) en rojo — no des la tarea por terminada"
  exit 1
}

# --- 1. Las reglas de AGENTS.md ---------------------------------------------
# `pipefail` sin `-e`: se recorre todo y se reporta junto, en vez de morir en el
# primer problema. Saber que fallan tres cosas vale mas que saber que falla una.

titulo "reglas del repo"
if "${PRUEBAS[@]}" 2>&1 | sed 's/^/  /'; then
  ok "las reglas de AGENTS.md se sostienen"
else
  fallo "hay reglas en rojo (arriba esta cual)"
fi

if [ "$RAPIDO" = 1 ]; then
  resumir "(modo rapido: no se comprobo la instalacion de esta maquina)"
fi

# --- 2. La instalacion, tal como corre de verdad -----------------------------
# El repo puede estar impecable y la maquina correr otra cosa: los scripts se
# instalan como copias en ~/.local/lib/mirage-stream, asi que un commit no
# llega al sistema hasta que se reinstala, y un parche hecho a mano en el
# sistema no vuelve al repo nunca. `doctor` no lo detecta -- solo mira que los
# archivos existan y que sunshine-hyprland.conf apunte a las rutas correctas.
#
# Se omite sola si el perfil no esta instalado: un arnes que falla por no tener
# el entorno montado deja de correrse.

LIB="$HOME/.local/lib/mirage-stream"

titulo "instalacion en esta maquina"
if [ ! -d "$LIB" ]; then
  omitir "el perfil hyprland-headless no esta instalado aca (./install-hyprland-headless.sh install)"
else
  render_node=""
  for driver in /sys/class/drm/card[0-9]/device/driver; do
    [ -e "$driver" ] || continue
    [ "$(basename "$(readlink "$driver")")" = nvidia ] || continue
    card="$(basename "$(dirname "$(dirname "$driver")")")"
    bdf="$(basename "$(readlink "/sys/class/drm/$card/device")")"
    link="/dev/dri/by-path/pci-$bdf-render"
    [ -L "$link" ] && render_node="$(readlink -f "$link")"
  done

  desincronizados=()
  for plantilla in profiles/hyprland-headless/*.sh.in; do
    base="$(basename "$plantilla" .sh.in)"
    # start-from-hyprland.sh.in se instala con otro nombre.
    [ "$base" = "start-from-hyprland" ] && base="start-hyprland-headless"
    instalado="$LIB/$base.sh"
    [ -f "$instalado" ] || { desincronizados+=("$base.sh: no instalado"); continue; }
    if ! sed -e "s|@TARGET_HOME@|$HOME|g" -e "s|@RENDER_NODE@|$render_node|g" \
         "$plantilla" | diff -q - "$instalado" >/dev/null; then
      desincronizados+=("$base.sh")
    fi
  done

  if [ ${#desincronizados[@]} -eq 0 ]; then
    ok "los scripts instalados son los del repo"
  else
    fallo "el sistema corre otra version que el repo: ${desincronizados[*]}"
    printf '%s        diff: sed -e "s|@TARGET_HOME@|$HOME|g" -e "s|@RENDER_NODE@|%s|g" profiles/hyprland-headless/X.sh.in | diff - %s/X.sh%s\n' \
      "$GRIS" "$render_node" "$LIB" "$FIN"
    printf '%s        para alinearlos: ./install-hyprland-headless.sh install -y%s\n' "$GRIS" "$FIN"
  fi

  if [ "${XDG_CURRENT_DESKTOP:-}" != "Hyprland" ] || [ -z "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then
    omitir "sin sesion Hyprland activa; se omite el doctor"
  elif ./install-hyprland-headless.sh doctor >/dev/null 2>&1; then
    ok "doctor: el perfil esta cableado (servicio, regla de MIRAGE, config)"
  else
    fallo "doctor en rojo — corre ./install-hyprland-headless.sh doctor para ver cual"
  fi
fi

resumir
