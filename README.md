# AgentStats

[Português](README.md) · [English](README.en.md) · [Español](README.es.md) · [Français](README.fr.md)

![CI](https://github.com/HamiltonPrado/agentstats/actions/workflows/ci.yml/badge.svg)
![Última versão](https://img.shields.io/github/v/release/HamiltonPrado/agentstats?color=blue)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black)
![Swift 6](https://img.shields.io/badge/Swift-6.0-F05138?logo=swift&logoColor=white)

**Agentes de IA e métricas do Mac, num só painel.** O AgentStats vive na barra de menus e mostra o que está a correr, o que precisa da tua atenção e como estão os recursos do sistema.

**[Descarregar a versão mais recente](https://github.com/HamiltonPrado/agentstats/releases/latest)** · [Website](https://hamiltonprado.github.io/agentstats) · [Reportar um problema](https://github.com/HamiltonPrado/agentstats/issues)

<p align="center">
  <img src="Resources/screenshots/menubar.png" alt="Métricas e agentes na barra de menus" width="600">
</p>

<p align="center">
  <img src="Resources/screenshots/agents-dark.png" alt="Painel de agentes" width="340">
  &nbsp;&nbsp;
  <img src="Resources/screenshots/system-dark.png" alt="Painel de métricas do sistema" width="340">
</p>

## O que podes acompanhar

### Agentes de IA

Vê sessões ativas, projeto, modelo, consumo de CPU e memória, subprocessos e estado — a trabalhar, à espera ou a pedir a tua atenção. Filtra sessões por estado. O AgentStats reconhece Claude Code, Codex, Antigravity, Aider, Goose, Gemini CLI, Cursor Agent, OpenCode e Amp. Clica numa sessão para voltar à app onde está a correr.

### Saúde do Mac

CPU, memória, GPU, temperaturas, rede, disco e bateria. O painel inclui gráficos e histórico de até 7 dias, incluindo bateria, alertas configuráveis e um teste manual de download, upload e latência. Também podes ver as pastas principais que ocupam mais espaço, mediante análise manual.

### Para o teu fluxo de trabalho

- Notificações quando um agente termina ou precisa de ti.
- Lembretes configuráveis se um agente continuar à espera da tua resposta ou aprovação.
- Histórico por sessão com estados, duração observada e tokens usados.
- Tokens usados hoje, por sessão e por projeto, para Claude Code e Codex.
- Atalho global configurável para abrir o painel.
- Reordena os indicadores da barra de menus e escolhe que secções aparecem no painel.
- Ajusta a densidade, o tema e a cor de destaque; aplica e guarda configurações nos perfis Trabalho e Monitorização.
- Escolhe a largura do painel e o tamanho do texto, e o estilo da barra de menus: com rótulos, compacto ou mini-gráficos, com o ponto dos agentes a cores opcional.
- Configura alertas para CPU, temperatura, memória, espaço em disco e bateria fraca.
- Mantém o Mac acordado por um período escolhido e permite selecionar dispositivos de áudio do sistema, ajustar volume e mute quando suportados pelo dispositivo.
- Indicadores acessíveis por cor, forma e VoiceOver; respeita a opção “Reduzir movimento”.
- Início de sessão automático opcional.

O teste de velocidade usa os endpoints públicos do Cloudflare e transfere cerca de **32 MB por execução**. As medições podem ser recolhidas de forma agregada.

## Instalar

Com o [Homebrew](https://brew.sh):

```bash
brew tap hamiltonprado/agentstats https://github.com/HamiltonPrado/agentstats
brew trust hamiltonprado/agentstats
brew install --cask agentstats
```

Para atualizar, `brew upgrade --cask agentstats`. Para remover, `brew uninstall --cask agentstats` (junta `--zap` para apagar também as definições e o histórico). A app não é notarizada pela Apple: o cask tira a quarentena ao instalar, por isso abre sem o aviso do macOS.

Ou à mão:

1. Descarrega **AgentStats.zip** na [página de releases](https://github.com/HamiltonPrado/agentstats/releases/latest).
2. Descomprime o ficheiro e move `AgentStats.app` para a pasta Aplicações.
3. Abre a app. Se o macOS bloquear a primeira abertura, vai a **Definições do Sistema → Privacidade e Segurança → Abrir mesmo assim**. A app é assinada localmente e não tem assinatura de programador Apple.

Também podes instalar pela linha de comandos com o [GitHub CLI](https://cli.github.com):

```bash
tmp=$(mktemp -d) && gh release download --repo HamiltonPrado/agentstats --pattern AgentStats.zip --dir "$tmp" && ditto -x -k "$tmp/AgentStats.zip" "$tmp" && { pkill -x AgentStats 2>/dev/null || true; ditto "$tmp/AgentStats.app" /Applications/AgentStats.app && open /Applications/AgentStats.app; }
```

## Contribuir

Requer macOS 14 ou superior e as Command Line Tools do Xcode.

```bash
./build.sh
open build/AgentStats.app
```

Para executar os testes:

```bash
./test.sh
```

As contribuições são bem-vindas. Abre uma [issue](https://github.com/HamiltonPrado/agentstats/issues) para reportar um problema ou sugerir uma melhoria.

## Licença

O AgentStats é distribuído sob a [licença MIT](LICENSE). Podes usar, modificar e redistribuir o código nos termos dessa licença.

<details>
<summary>Detalhes de desenvolvimento</summary>

### Criar uma release

Atualiza `VERSION` e envia uma tag com a mesma versão, por exemplo:

```bash
git tag v1.16.1
git push origin v1.16.1
```

O GitHub Actions valida a versão, executa os testes, compila a app e publica `AgentStats.zip` na release.

### Diagnóstico

- `AgentStats --dump` — métricas e agentes detetados.
- `AgentStats --bench` — tempo de execução dos leitores.
- `AgentStats --snapshot <pasta>` — capturas do painel em PNG.
- `AGENTSTATS_DISABLE=icon,temps,procs,sessions,usage,gpu,disk` — desativa leitores para medir consumo.

### Arquitetura

O `Sampler` (actor) coordena as leituras e devolve uma amostra imutável. O `Monitor` aplica os dados no main actor; as vistas SwiftUI observam apenas o estado que utilizam. O projeto usa Swift 6 com verificação de concorrência.

</details>
