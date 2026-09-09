#!/usr/bin/env python3
"""Las reglas de mirage-stream, en forma ejecutable.

Esto es AGENTS.md compilado: cada prueba de aca corresponde a una regla de la
seccion "Lo que hay que entender antes de tocar nada". Si cambias una regla
alla, cambia su prueba aca -- si no, la regla vuelve a ser prosa que cualquiera
se salta.

Solo stdlib, para que correr el arnes no necesite instalar nada.
"""

import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

RAIZ = Path(__file__).resolve().parent.parent
PERFIL = RAIZ / "profiles" / "hyprland-headless"

# Los scripts del perfil hyprland: las plantillas .in y el instalador que las
# escribe. Se deriva del directorio en vez de listarse a mano, porque una lista
# a mano se queda vieja en silencio cuando alguien agrega un .in nuevo.
ARCHIVOS_PERFIL = sorted(PERFIL.glob("*.sh.in")) + [RAIZ / "install-hyprland-headless.sh"]


def sin_comentarios(texto: str) -> str:
    """Devuelve solo el codigo de un script de shell, sin sus comentarios.

    Hace falta, y no es paranoia: los comentarios de este repo *explican* las
    reglas, asi que nombran justo lo que las pruebas buscan prohibir. Un grep
    crudo de "hyprctl keyword" da positivo contra el comentario que dice que
    hyprctl keyword no se usa, y seguiria dandolo si alguien metiera la llamada
    y borrara el comentario -- o sea, la respuesta invertida.

    Corta en un '#' solo si esta al inicio de linea o precedido por un espacio,
    y fuera de comillas. Asi no se come `$#` ni `${var#patron}`.
    """
    salida = []
    for linea in texto.splitlines():
        comilla = None
        corte = len(linea)
        for i, c in enumerate(linea):
            if comilla:
                if c == comilla:
                    comilla = None
            elif c in "'\"":
                comilla = c
            elif c == "#" and (i == 0 or linea[i - 1] in " \t"):
                corte = i
                break
        salida.append(linea[:corte])
    return "\n".join(salida)


def sin_literales(texto: str) -> str:
    """Vacia el contenido de los literales de texto, conservando los `$(...)`.

    Segundo nivel de la misma trampa que `sin_comentarios`: los mensajes de
    diagnostico tambien nombran la regla. `warn "... hyprctl keyword/dispatch
    scripts will silently no-op"` no es una llamada a hyprctl, es la
    advertencia de que no hay que llamarlo -- pero un grep no distingue. Las
    sustituciones de comando se conservan porque ahi si hay comandos de verdad
    (`result="$(hyprctl eval "$1")"`).
    """
    salida = []
    i, n = 0, len(texto)
    while i < n:
        c = texto[i]
        if c not in "'\"":
            salida.append(c)
            i += 1
            continue
        comilla, i = c, i + 1
        while i < n and texto[i] != comilla:
            if comilla == '"' and texto[i] == "$" and texto[i + 1:i + 2] == "(":
                nivel, inicio = 0, i
                while i < n:
                    if texto[i] == "(":
                        nivel += 1
                    elif texto[i] == ")":
                        nivel -= 1
                        if nivel == 0:
                            i += 1
                            break
                    i += 1
                salida.append(texto[inicio:i])
                continue
            if comilla == '"' and texto[i] == "\\":
                i += 2
                continue
            i += 1
        i += 1
    return "".join(salida)


def codigo(ruta: Path) -> str:
    """Codigo sin comentarios. Conserva los literales de texto."""
    return sin_comentarios(ruta.read_text(encoding="utf-8"))


def comandos(ruta: Path) -> str:
    """Solo lo que el shell ejecuta: sin comentarios y sin texto literal."""
    return sin_literales(codigo(ruta))


class ReglasDelPerfilHyprland(unittest.TestCase):
    def test_no_se_usa_hyprctl_keyword_ni_dispatch_clasico(self):
        """«Solo hyprctl eval + la API hl.*.»

        hyprctl keyword y hyprctl dispatch con sintaxis clasica imprimen
        "keyword can't work with non-legacy parsers. Use eval." y devuelven
        exit 0 igual. Un script con `set -e` no se entera de nada: MIRAGE se
        queda en 1920x1080, los workspaces nunca se mueven y los monitores
        fisicos nunca se apagan durante el stream, sin un solo error. Ya paso
        una vez con el perfil entero (commit acc1168).
        """
        prohibido = re.compile(r"hyprctl\s+(keyword|dispatch)\b")
        for ruta in ARCHIVOS_PERFIL:
            with self.subTest(archivo=ruta.name):
                encontrado = [
                    linea.strip()
                    for linea in comandos(ruta).splitlines()
                    if prohibido.search(linea)
                ]
                self.assertEqual(
                    encontrado, [],
                    f"{ruta.name} llama a hyprctl keyword/dispatch: no aplica nada "
                    f"y devuelve 0. Usar hleval con la API hl.*",
                )

    def test_toda_llamada_a_hyprctl_eval_pasa_por_hleval(self):
        """«hyprctl eval se llama desde hleval(), nunca suelto.»

        hleval() es lo unico que compara la respuesta con "ok" y avisa por
        stderr cuando no lo es. Una llamada suelta vuelve al mismo fallo
        silencioso que motivo todo el cambio: la Lua tira un error, hyprctl
        devuelve 0 igual y el script sigue como si hubiera aplicado la regla.
        """
        for ruta in ARCHIVOS_PERFIL:
            if ruta.name == "install-hyprland-headless.sh":
                continue  # doctor sondea con `hyprctl eval` a proposito
            with self.subTest(archivo=ruta.name):
                lineas = [
                    linea.strip()
                    for linea in comandos(ruta).splitlines()
                    if "hyprctl eval" in linea
                ]
                # Un script del perfil puede no usar hyprctl en absoluto
                # (start-from-hyprland.sh solo importa el entorno); lo que no
                # puede es llamarlo por fuera de hleval.
                self.assertLessEqual(
                    set(lineas), {'result=$(hyprctl eval "$1")'},
                    f"{ruta.name} llama a hyprctl eval fuera de hleval(): "
                    f"un error de la Lua pasaria desapercibido",
                )

    def test_la_posicion_de_mirage_es_una_sola_en_todo_el_repo(self):
        """«MIRAGE tiene una posicion, no dos.»

        La regla persistida en el config del usuario y la que aplican los
        scripts en caliente tienen que ser el mismo valor. Si difieren, el
        `hyprctl reload config-only` de stream-stop.sh relee el config y
        MIRAGE salta a la otra posicion -- las de runtime son mentira y el
        comentario que las explica tambien.

        Las posiciones de los monitores fisicos no entran: se restauran desde
        el state file y son variables, no literales.
        """
        literal = re.compile(r'position\s*=\s*\\?"(\d+x\d+)\\?"')
        posiciones = {}
        for ruta in ARCHIVOS_PERFIL:
            for encontrada in literal.findall(codigo(ruta)):
                posiciones.setdefault(encontrada, []).append(ruta.name)
        self.assertEqual(
            len(posiciones), 1,
            f"MIRAGE tiene {len(posiciones)} posiciones distintas: "
            + "; ".join(f"{pos} en {', '.join(a)}" for pos, a in sorted(posiciones.items())),
        )

    def test_ningun_conector_fisico_hardcodeado(self):
        """«Los conectores se detectan, no se escriben a mano.»

        DP-5/DP-6 son los monitores del equipo donde se desarrollo esto, y el
        repo es publico. En cualquier otra maquina, un `hl.workspace_rule` que
        apunta a DP-5 manda los 20 workspaces a un monitor que no existe. Lo
        mismo el preflight que solo reconoce DP-4/HDMI-A-2 como conector
        virtual forzado: en una maquina con HDMI-A-1 no detecta el conflicto
        entre perfiles que existe para detectar.

        install.sh queda fuera: ahi los nombres estan solo en comentarios de
        ejemplo, que esta prueba ya descarta.
        """
        conector = re.compile(r"\b(?:DP|HDMI-A)-\d+\b")
        for ruta in ARCHIVOS_PERFIL:
            with self.subTest(archivo=ruta.name):
                encontrados = sorted({
                    m for linea in codigo(ruta).splitlines()
                    for m in conector.findall(linea)
                })
                self.assertEqual(
                    encontrados, [],
                    f"{ruta.name} tiene conectores fijos {encontrados}: son los del "
                    f"equipo del autor, no los de quien clone el repo",
                )


class ReglasDelPerfilKdeKms(unittest.TestCase):
    def test_el_edid_generado_tiene_los_dos_vsdb(self):
        """«El EDID lleva los dos VSDB, o NVIDIA no activa el CRTC.»

        Es la tesis entera del perfil kde-kms: sin el HDMI VSDB (00-0C-03) y el
        HDMI Forum VSDB (C4-5D-D8), nvidia-drm lee el EDID pero deja el
        conector en 0x0 y Sunshine devuelve error 503. El bloque CTA tiene 127
        bytes utiles: agregar VICs o DTDs a create-edid.py empuja los VSDB
        fuera sin que nada avise.
        """
        with tempfile.TemporaryDirectory() as tmp:
            destino = Path(tmp) / "virtual.bin"
            subprocess.run(
                [sys.executable, str(RAIZ / "create-edid.py"), str(destino)],
                check=True, capture_output=True,
            )
            edid = destino.read_bytes()
        self.assertEqual(len(edid), 256, "el EDID tiene que ser de 256 bytes")
        self.assertEqual(sum(edid[:128]) % 256, 0, "checksum del bloque base")
        self.assertEqual(sum(edid[128:]) % 256, 0, "checksum del bloque de extension")
        self.assertIn(bytes([0x03, 0x0C, 0x00]), edid, "falta el HDMI VSDB")
        self.assertIn(bytes([0xD8, 0x5D, 0xC4]), edid, "falta el HDMI Forum VSDB")

    def test_los_scripts_de_sunshine_exportan_las_tres_variables(self):
        """«Los tres export, siempre los tres.»

        Sunshine corre global_prep_cmd sin el entorno de la sesion.
        kscreen-doctor habla con KWin por D-Bus: sin DBUS_SESSION_BUS_ADDRESS
        no falla, no imprime nada y no cambia ningun monitor -- el cliente ve
        una pantalla negra y no hay error en ningun log. Ya paso (commit
        866fb86). Solo aplica al perfil kde-kms: los scripts del perfil
        hyprland corren dentro de systemd --user y heredan el entorno.
        """
        requeridas = ("WAYLAND_DISPLAY", "XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS")
        for ruta in sorted((RAIZ / "scripts").glob("*.sh")):
            with self.subTest(archivo=ruta.name):
                texto = codigo(ruta)
                faltan = [v for v in requeridas if f"export {v}=" not in texto]
                self.assertEqual(faltan, [], f"{ruta.name} no exporta {faltan}")

        # El instalador escribe esos mismos scripts en la maquina del usuario:
        # si la cabecera que genera pierde una variable, los scripts del repo
        # siguen bien y los instalados no.
        generador = codigo(RAIZ / "install.sh")
        faltan = [v for v in requeridas if f"export {v}=" not in generador]
        self.assertEqual(faltan, [], f"install.sh genera scripts sin {faltan}")


class ContratoDeDocumentacion(unittest.TestCase):
    LARGO_MAXIMO_AGENTS = 130

    def test_agents_md_no_crece(self):
        """«AGENTS.md se lee entero en cada sesion.»

        Cada linea de mas es contexto que el agente arrastra en todos los
        prompts de todas las sesiones. Lo que crece va a docs/ con un puntero.
        """
        lineas = (RAIZ / "AGENTS.md").read_text(encoding="utf-8").splitlines()
        self.assertLessEqual(
            len(lineas), self.LARGO_MAXIMO_AGENTS,
            f"AGENTS.md tiene {len(lineas)} lineas (maximo {self.LARGO_MAXIMO_AGENTS}): "
            f"mover a docs/ lo que crecio",
        )

    def test_claude_md_no_duplica_las_reglas_de_agents(self):
        """«CLAUDE.md delega, no copia.»

        Dos copias de la misma regla se contradicen en cuanto una cambia, y no
        hay forma de saber cual manda.
        """
        claude = (RAIZ / "CLAUDE.md").read_text(encoding="utf-8")
        self.assertIn("AGENTS.md", claude, "CLAUDE.md tiene que delegar en AGENTS.md")

        def negritas(texto):
            return {t.strip().lower() for t in re.findall(r"\*\*(.+?)\*\*", texto, re.S)}

        repetidas = negritas(claude) & negritas((RAIZ / "AGENTS.md").read_text(encoding="utf-8"))
        self.assertEqual(
            repetidas, set(),
            f"CLAUDE.md repite reglas de AGENTS.md: {repetidas}",
        )

    def test_todos_los_links_relativos_resuelven(self):
        """«Un link roto en la doc manda a alguien a un archivo que no existe.»"""
        link = re.compile(r"\[[^\]]*\]\(([^)]+)\)")
        rotos = []
        for md in sorted(RAIZ.rglob("*.md")):
            if ".git" in md.parts:
                continue
            for destino in link.findall(md.read_text(encoding="utf-8")):
                if destino.startswith(("http://", "https://", "#", "mailto:")):
                    continue
                ruta = (md.parent / destino.split("#")[0]).resolve()
                if not ruta.exists():
                    rotos.append(f"{md.relative_to(RAIZ)} -> {destino}")
        self.assertEqual(rotos, [], f"links rotos: {rotos}")

    def test_docs_readme_lista_todo_lo_que_hay_en_docs(self):
        """«El indice de docs/ es el indice, no una muestra.»

        Un documento que no esta en el indice no lo encuentra nadie, y el
        proximo que busque ese tema escribe uno nuevo al lado.
        """
        indice = (RAIZ / "docs" / "README.md").read_text(encoding="utf-8")
        faltan = [
            md.name for md in sorted((RAIZ / "docs").glob("*.md"))
            if md.name != "README.md" and md.name not in indice
        ]
        self.assertEqual(faltan, [], f"docs/README.md no lista {faltan}")

    def test_los_pendientes_estan_en_el_repo_y_no_sueltos_en_el_codigo(self):
        """«docs/pendientes.md es la lista, no hay otra.»

        Un TODO suelto en un script lo encuentra solo quien abra ese archivo.
        """
        pendientes = RAIZ / "docs" / "pendientes.md"
        self.assertTrue(pendientes.exists(), "falta docs/pendientes.md")
        self.assertIn("## Abiertos", pendientes.read_text(encoding="utf-8"))

        marca = re.compile(r"\b(TODO|FIXME|XXX|HACK)\b")
        sueltos = []
        for patron in ("*.sh", "*.py", "*.in"):
            for ruta in sorted(RAIZ.rglob(patron)):
                # Este archivo queda fuera por la misma razon que
                # `sin_comentarios` existe: es el que *define* la regla, asi
                # que contiene la palabra que la regla prohibe.
                if ".git" in ruta.parts or ruta == Path(__file__).resolve():
                    continue
                for n, linea in enumerate(ruta.read_text(encoding="utf-8").splitlines(), 1):
                    if marca.search(linea):
                        sueltos.append(f"{ruta.relative_to(RAIZ)}:{n}")
        self.assertEqual(
            sueltos, [], f"hay pendientes fuera de docs/pendientes.md: {sueltos}"
        )


if __name__ == "__main__":
    unittest.main()
