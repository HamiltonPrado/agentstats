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
  <img src="Resources/screenshots/agents-dark.png" alt="Panel de agentes" width="340">
  &nbsp;&nbsp;
  <img src="Resources/screenshots/system-dark.png" alt="Panel de métricas del sistema" width="340">
</p>

## Qué puedes supervisar

### Agentes de IA

Consulta las sesiones activas, el proyecto, el modelo, el uso de CPU y memoria, los subprocesos y el estado: trabajando, esperando o solicitando tu atención. Busca y filtra por agente, proyecto y estado. AgentStats reconoce Claude Code, Codex, Antigravity, Aider, Goose, Gemini CLI, Cursor Agent, OpenCode y Amp. Haz clic en una sesión para volver a la aplicación donde se está ejecutando.

### Estado del Mac

CPU, memoria, GPU, temperaturas, red, disco y batería. El panel incluye gráficos e historial de 24 horas, alertas configurables y una prueba manual de descarga, subida y latencia.

### Para tu flujo de trabajo

- Notificaciones cuando un agente termina o necesita tu atención.
- Recordatorios configurables si un agente sigue esperando tu respuesta o aprobación.
- Historial por sesión con cambios de estado, duración observada y uso de tokens.
- Uso de tokens de hoy, por sesión y por proyecto, para Claude Code y Codex.
- Atajo global configurable para abrir el panel.
- Indicadores accesibles mediante color, forma y VoiceOver; respeta “Reducir movimiento”.
- Inicio de sesión automático opcional.

La prueba de velocidad usa los endpoints públicos de Cloudflare y transfiere unos **32 MB por ejecución**. Las mediciones pueden recopilarse de forma agregada.

## Instalación

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
git tag v1.13
git push origin v1.13
```

GitHub Actions comprueba la versión, ejecuta las pruebas, compila la app y publica `AgentStats.zip` en la versión.

### Diagnóstico

- `AgentStats --dump` — métricas del sistema y agentes detectados.
- `AgentStats --bench` — tiempos de ejecución de los lectores.
- `AgentStats --snapshot <carpeta>` — genera capturas del panel en PNG.
- `AGENTSTATS_DISABLE=icon,temps,procs,sessions,usage,gpu,disk` — desactiva lectores para medir el rendimiento.

### Arquitectura

El actor `Sampler` coordina las lecturas y devuelve una muestra inmutable. `Monitor` aplica la muestra en el actor principal; las vistas de SwiftUI solo observan el estado que utilizan. El proyecto usa la comprobación de concurrencia de Swift 6.

</details>
