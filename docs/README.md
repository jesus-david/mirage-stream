# Documentación

Material técnico del proyecto, para personas y para agentes. La guía corta de entrada
es [`../AGENTS.md`](../AGENTS.md); acá está el detalle.

| Documento | Contenido |
|---|---|
| [decisions.md](decisions.md) | Por qué el proyecto quedó así y no de otra forma. Lo primero a leer antes de cambiar algo que se ve raro. |
| [pendientes.md](pendientes.md) | Lo que quedó abierto, cada uno con su primer paso concreto. |

Las dos notas largas viven en la raíz porque son anteriores a esta carpeta y hay links
externos apuntándoles:

| Documento | Contenido |
|---|---|
| [`../FEDORA-NOTES.md`](../FEDORA-NOTES.md) | Perfil `kde-kms` en Fedora/Nobara: detección, dracut, kernel cmdline, y el diseño de `install.sh`. |
| [`../HYPRLAND-HEADLESS.es.md`](../HYPRLAND-HEADLESS.es.md) | Perfil `hyprland-headless`: flujo de inicio, verificación y problemas conocidos del parser Lua. |

## Cómo mantener esto

Actualizá cuando cambie una **decisión** —de arquitectura, de perfil, de compromiso de
seguridad—, no por cambios menores de código.

Cuando documentes un arreglo, escribí también **qué síntoma tenía el bug y por qué la
solución es la que es**. Buena parte del valor de estos documentos está en evitar que
alguien "simplifique" algo que se ve raro pero es deliberado: en este repo eso ya pasó
una vez y costó un perfil entero que no aplicaba nada sin dar un solo error.
