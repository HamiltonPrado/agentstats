# AgentStats

[Português](README.md) · [English](README.en.md) · [Español](README.es.md) · [Français](README.fr.md)

![CI](https://github.com/HamiltonPrado/agentstats/actions/workflows/ci.yml/badge.svg)
![Última versión](https://img.shields.io/github/v/release/HamiltonPrado/agentstats?color=blue)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black)
![Swift 6](https://img.shields.io/badge/Swift-6.0-F05138?logo=swift&logoColor=white)

**Agentes de IA y métricas del Mac en un solo panel.** AgentStats vive en la barra de menús de macOS y muestra qué se está ejecutando, qué requiere tu atención y cómo están los recursos del sistema.

**[Descargar la última versión](https://github.com/HamiltonPrado/agentstats/releases/latest)** · [Sitio web](https://hamiltonprado.github.io/agentstats) · [Informar de un problema](https://github.com/HamiltonPrado/agentstats/issues)

<p align="center">
  <img src="Resources/screenshots/menubar.png" alt="Agentes y métricas en la barra de menús" width="600">
</p>

<p align="center">
  <img src="Resources/screenshots/agents-dark.png" alt="Agentes, límites y costes" width="260">
  <img src="Resources/screenshots/system-dark.png" alt="Métricas del sistema" width="260">
  <img src="Resources/screenshots/audio-dark.png" alt="Mezclador de volumen" width="260">
</p>

<p align="center">
  <img src="Resources/screenshots/clipboard-dark.png" alt="Portapapeles y fragmentos" width="260">
  <img src="Resources/screenshots/capture-dark.png" alt="Captura y grabación" width="260">
  <img src="Resources/screenshots/tools-dark.png" alt="Herramientas" width="260">
</p>

<p align="center"><sub>Capturas con datos de demostración. La interfaz está en portugués.</sub></p>

## Qué puedes supervisar

### Agentes de IA

- Sesiones con proyecto, modelo, subagentes y estado: trabajando, esperando o pendiente de aprobación. Haz clic en una para volver a la app donde se ejecuta.
- Reconoce Claude Code, Codex, Copilot, Cursor Agent, OpenCode, Antigravity, Aider, Goose, Gemini CLI y Amp. El detalle depende de lo que registre cada uno en el Mac.
- **Límites del plan** de Claude y Codex, con la hora de renovación.
- **Tokens y coste estimado de API** por sesión, día y proyecto para Claude Code, Codex, Copilot y OpenCode. El coste solo aparece con modelos de precio conocido y no es lo que pagas con una suscripción.
- Avisos cuando termina una tarea larga o un agente te necesita, con recordatorios si sigue esperando.

### Sistema y procesos

- CPU, memoria, GPU, temperaturas, red, disco y batería, con historial de hasta 7 días y alertas.
- Apps que más energía gastan, procesos más pesados y carpetas más grandes.
- Prueba de velocidad manual con Cloudflare: unos **32 MB por prueba**; las mediciones pueden recopilarse de forma agregada.
- No controla los ventiladores.

### Audio

- Elige la salida y el micrófono y ajusta su volumen.
- **Mezclador por app**, de 0 a 150% (macOS 14.2+). Solo modifica las apps que ajustes y vuelve al 100% al cerrar AgentStats.

### Portapapeles

- Historial de texto, **desactivado hasta que lo actives**: 100 elementos, 7 días, con fijados y fragmentos.
- Ignora lo que los gestores de contraseñas marcan como secreto y los formatos conocidos de claves de API. El historial se queda en este Mac, **sin cifrar**.

### Captura

- Captura un área, una ventana o la pantalla, y graba la pantalla completa con micrófono y clics opcionales. Para grabar un área se abre la herramienta de macOS.

### Herramientas

- **Puertos:** muestra lo que está a la escucha y termina procesos tuyos, con confirmación.
- **Homebrew:** actualiza y elimina paquetes.
- **Desinstalar:** mueve apps a la Papelera, con los restos que elijas.
- **Limpieza:** mueve a la Papelera cachés de una lista cerrada (Homebrew, pip y npm; Brave, Playwright, Hugging Face y npx son opcionales), con confirmación y sin tocar lo que detecte en uso. El espacio se libera al vaciar la Papelera.

### A tu medida

Barra de menús configurable, atajo global, perfiles, tema, color, ancho, tamaño del texto, mantener el Mac activo, inicio automático y compatibilidad con VoiceOver y “Reducir movimiento”.

## Permisos y privacidad

| Función | Permiso que puede pedir macOS |
| --- | --- |
| Avisos y alertas | Notificaciones |
| Mezclador por app | Grabación del audio del sistema |
| Captura y grabación | Grabación de pantalla |
| Grabar con micrófono | Micrófono |
| Historial del portapapeles | Pegar desde otras apps (macOS 15.4+) |
| Categorías del disco, medidas al abrir la tarjeta | Carpetas personales (Escritorio, Documentos, Descargas, Música, Imágenes) |

No hay cuenta ni telemetría. AgentStats lee los registros de los agentes en el Mac y no los envía. Solo usan la red la prueba de velocidad, Homebrew cuando lo utilizas y la consulta periódica de límites mediante tu Claude Code.

La app no tiene Developer ID, por lo que **macOS puede volver a pedir estos permisos tras cada actualización**.

## Requisitos

Mac con Apple Silicon y macOS 14 o posterior. Probada en macOS 27.2.

## Instalación

Con [Homebrew](https://brew.sh):

```bash
brew tap hamiltonprado/agentstats https://github.com/HamiltonPrado/agentstats
brew trust hamiltonprado/agentstats
brew install --cask agentstats
```

Para actualizar, `brew upgrade --cask agentstats`. Para eliminarla, `brew uninstall --cask agentstats` (añade `--zap` para borrar también los ajustes y el historial). La app no está notarizada por Apple: el cask quita la cuarentena al instalar, así que se abre sin el aviso de macOS.

O a mano:

1. Descarga **AgentStats.zip** desde la [última versión](https://github.com/HamiltonPrado/agentstats/releases/latest).
2. Descomprímelo y mueve `AgentStats.app` a la carpeta Aplicaciones.
3. Abre la app. Si macOS bloquea el primer inicio, ve a **Ajustes del Sistema → Privacidad y seguridad → Abrir igualmente**. La app está firmada localmente y no tiene una firma de desarrollador de Apple.

También puedes instalarla desde la línea de comandos con [GitHub CLI](https://cli.github.com):

```bash
tmp=$(mktemp -d) && gh release download --repo HamiltonPrado/agentstats --pattern AgentStats.zip --dir "$tmp" && ditto -x -k "$tmp/AgentStats.zip" "$tmp" && { pkill -x AgentStats 2>/dev/null || true; ditto "$tmp/AgentStats.app" /Applications/AgentStats.app && open /Applications/AgentStats.app; }
```

## Contribuir

Requiere macOS 14 o posterior y las herramientas de línea de comandos de Xcode.

```bash
./build.sh
open build/AgentStats.app
```

Ejecuta las pruebas con:

```bash
./test.sh
```

Las contribuciones son bienvenidas. Abre una [incidencia](https://github.com/HamiltonPrado/agentstats/issues) para informar de un problema o proponer una mejora.

## Licencia

AgentStats se distribuye bajo la [licencia MIT](LICENSE). Puedes usar, modificar y redistribuir el código según sus términos.

<details>
<summary>Detalles de desarrollo</summary>

### Crear una versión

Actualiza `VERSION` y envía una etiqueta con la misma versión, por ejemplo:

```bash
git tag v1.17
git push origin v1.17
```

GitHub Actions comprueba la versión, ejecuta las pruebas, compila la app y publica `AgentStats.zip` en la versión.

### Diagnóstico

- `AgentStats --dump` — métricas del sistema y agentes detectados.
- `AgentStats --bench` — tiempos de ejecución de los lectores.
- `AgentStats --snapshot <carpeta>` — genera capturas del panel en PNG, solo con datos de demostración.
- `AgentStats --smoke` — prueba de arranque con los lectores reales.
- `AGENTSTATS_DISABLE=icon,temps,procs,sessions,usage,energy,limits,gpu,disk` — desactiva lectores para medir el rendimiento.

### Arquitectura

El actor `Sampler` coordina las lecturas y devuelve una muestra inmutable. `Monitor` aplica la muestra en el actor principal; las vistas de SwiftUI solo observan el estado que utilizan. El proyecto usa la comprobación de concurrencia de Swift 6.

</details>
