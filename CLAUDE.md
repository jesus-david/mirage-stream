# CLAUDE.md

Las instrucciones de este repositorio están en **[AGENTS.md](AGENTS.md)**, que sirve
para cualquier agente. Leelo primero; no se duplica acá para que no queden dos
versiones que se contradigan.

Lo específico de trabajar con Claude Code en este proyecto, además de las instrucciones
globales del usuario (`~/.claude/CLAUDE.md`):

- **Reinstalar interrumpe la sesión que estás usando.**
  `./install-hyprland-headless.sh install` reinicia `mirage-stream-hyprland.service`,
  que relanza Sunshine y bloquea la pantalla. No lo corras por tu cuenta para "dejar
  el sistema alineado": proponelo y esperá el OK.

- **Verde en `doctor` no significa que el sistema corra el código del repo.** Sólo
  comprueba que los archivos existan y que la config apunte a las rutas correctas.
  Para saber si hay drift, `./verificar.sh` sin `--rapido`.

- **El perfil `kde-kms` no se puede probar en esta máquina sin reiniciar.** Depende de
  parámetros de kernel e initramfs. Lo verificable sin reboot es
  `python3 create-edid.py` y `./install.sh --dry-run`; el resto es lectura de código.

- **Las pruebas que tocan Hyprland necesitan la sesión viva.** `hyprctl` requiere
  `HYPRLAND_INSTANCE_SIGNATURE` en el entorno: un subagente o una sesión sin
  escritorio no puede correrlas, y `verificar.sh` las omite sola en ese caso.

- **Los scripts de diagnóstico de un solo uso van al scratchpad**, no al repo. Acá
  sólo entra lo que alguien más va a correr.
