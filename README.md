# AgentStats

App de barra de menus para macOS (estilo Stats) que mostra as métricas do sistema e os agentes de IA a trabalhar.

## Funcionalidades
- **Barra de menus:** agentes a trabalhar/total, CPU, RAM, temperatura, GPU, rede e bateria (configurável)
- **Agentes:** sessões do Claude Code e do Codex (CLI e app ChatGPT, via `~/.codex`) com estado em tempo real (a executar ferramenta, a pensar, à espera), projeto, modelo, CPU/RAM, subprocessos e subagentes. Deteta também Codex, Gemini CLI, Aider, Cursor Agent, OpenCode, Goose e Amp. Notificação quando um agente termina.
- **Temperaturas:** CPU (média e máx.), chip, SSD e bateria via sensores HID do Apple Silicon — sem precisar do Xcode
- **Sistema:** CPU (total, por núcleo, carga, estado térmico), memória (apps, wired, comprimida, cache, swap, pressão), GPU, rede, disco e bateria
- **Processos:** top por CPU
- Abrir ao iniciar sessão

## Compilar
Requer macOS 14+ e as Command Line Tools (`xcode-select --install`).

```bash
./build.sh
open build/AgentStats.app
```

Diagnóstico sem interface: `build/AgentStats.app/Contents/MacOS/AgentStats --dump`

## Ícone
Gerado por código em `Scripts/make-icon.swift` → `Resources/AppIcon-1024.png`; o `build.sh` converte-o em `.icns`.

```bash
swiftc -O Scripts/make-icon.swift -o /tmp/make-icon && /tmp/make-icon Resources/AppIcon-1024.png
```
