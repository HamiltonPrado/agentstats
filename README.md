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
  <img src="Resources/screenshots/agents-dark.png" alt="Agentes, limites e custos" width="260">
  <img src="Resources/screenshots/system-dark.png" alt="Métricas do sistema" width="260">
  <img src="Resources/screenshots/audio-dark.png" alt="Mixer de volume" width="260">
</p>

<p align="center">
  <img src="Resources/screenshots/clipboard-dark.png" alt="Clipboard e snippets" width="260">
  <img src="Resources/screenshots/capture-dark.png" alt="Captura e gravação" width="260">
  <img src="Resources/screenshots/tools-dark.png" alt="Ferramentas" width="260">
</p>

<p align="center"><sub>Capturas com dados de demonstração.</sub></p>

## O que podes acompanhar

### Agentes de IA

- Sessões com projeto, modelo, subagentes e estado: a trabalhar, à tua espera ou a precisar de aprovação. Clica numa para voltar à app onde corre.
- Reconhece Claude Code, Codex, Copilot, Cursor Agent, OpenCode, Antigravity, Aider, Goose, Gemini CLI e Amp. O detalhe varia com o que cada um regista no Mac.
- **Limites do plano** do Claude e do Codex, com a hora de renovação, aviso aos 75% (ou o valor que escolheres), aos 90% e quando renova, e quando acabam se continuares a este ritmo.
- **Ligação ao Claude Code num clique** (Definições → Geral): os pedidos de aprovação chegam logo, em vez de serem adivinhados pelos processos.
- **Tokens e custo estimado em API** por sessão, dia e projeto, para Claude Code, Codex, Copilot e OpenCode. O custo só aparece para modelos com preço conhecido e não é o que pagas com um plano.
- Aviso quando uma tarefa longa termina ou um agente precisa de ti, com lembretes se continuar à espera.
- **Orçamento de custo** por dia ou por semana, com aviso aos 80% e aos 100%, **resumo semanal** por notificação e **exportar o uso para CSV**.

### Sistema e processos

- CPU, memória, GPU, temperaturas, rede, disco e bateria, com histórico até 7 dias e alertas.
- Os 5 processos que mais gastam CPU e memória, que se terminam com o botão direito. Na bateria: as apps que mais gastaram desde que saiu da corrente, e a saúde e os ciclos ao longo dos meses.
- Apps que gastam mais energia, processos mais pesados e pastas que ocupam mais espaço.
- Disco por categorias, com as cores e as unidades do macOS. Mede-se por pastas ao abrir o cartão, por isso é aproximado.
- Teste de velocidade manual pelo Cloudflare: cerca de **32 MB por teste**; as medições podem ser recolhidas de forma agregada.
- Wi-Fi: qualidade do sinal, ruído, velocidade da ligação e canal. O nome da rede só aparece se deres acesso à Localização, que o macOS exige para isso; a app não pede a tua posição.
- IP público (só quando carregas em “Ver”, pelo Cloudflare) e VPN ativa. Bateria dos AirPods, rato, teclado e outros acessórios Bluetooth.
- Aviso de versão nova no painel e por notificação, com o comando do Homebrew se a instalaste por lá. Consulta o GitHub uma vez por dia e desliga-se nas Definições.
- Não controla ventoinhas.
- Avisa quando uma app **deixa de responder** e deixa forçar a saída sem abrir o Monitor de Atividade.

### Áudio

- Escolhe saída e microfone e ajusta o volume.
- **Mixer por app**, de 0 a 150% (macOS 14.2+). Só mexe nas apps que ajustares e volta a 100% ao fechar o AgentStats.
- **Silenciar o microfone** com um atalho global (⌃⌥M por defeito), para chamadas, com um ícone vermelho na barra de menus enquanto está calado.

### Clipboard

- Histórico de texto, **desligado até o ligares**: 100 itens, 7 dias, com itens fixos e snippets.
- Ignora o que os gestores de passwords marcam como secreto e formatos conhecidos de chaves de API. O histórico fica neste Mac, **sem cifra**.
- **Colar rápido:** 1–9, ou ↑↓ e Enter, colam um item na app onde estavas (precisa da Acessibilidade; sem ela, fica copiado).
- **Imagens no histórico** (opcional, desligado por defeito): capturas e imagens copiadas, até 30, com “Guardar como PNG…”.
- **Notas rápidas** no painel, guardadas só neste Mac.

### Captura

- Captura uma área, uma janela ou o ecrã, e grava o ecrã inteiro com microfone e cliques opcionais. Para gravar uma área abre a ferramenta do macOS.
- **Ler o ecrã:** copia o texto de uma área (OCR), lê códigos QR e apanha a cor de qualquer ponto em HEX ou RGB. Tudo neste Mac, sem rede.
- **Gerar código QR** de um link ou texto, para abrir no telemóvel, e **converter a última gravação em GIF** leve para PRs e mensagens.

### Tempo

- Temporizador e **Pomodoro** (25 + 5 min, pausa longa a cada 4), com o tempo na barra de menus e aviso no fim.
- **Relógio mundial** com as cidades que escolheres, a diferença horária e se lá já é amanhã.
- **Próxima reunião** do Calendário, com botão para entrar no Zoom, Meet ou Teams e contagem na barra de menus nos últimos 15 minutos (opcional).
- **Tempo por app hoje**, contado só enquanto usas o Mac e guardado neste Mac.

### Ferramentas

- **Janelas:** põe a janela da frente em metades, terços, dois terços, cantos, ecrã inteiro ou ao centro, e passa-a para o outro monitor, com atalhos globais (⌃⌥ + setas e letras, como no Rectangle) que se podem desligar. Carregar outra vez na metade esquerda ou direita alterna entre ½, ⅔ e ⅓. Precisa da Acessibilidade.
- **Partilhar:** envia um ficheiro para o telemóvel por código QR, pela rede local (o link tem um código secreto, serve uma vez e expira em 10 minutos), e gera o QR do Wi-Fi para os convidados.
- **Modo apresentação** nos atalhos rápidos: esconde os ícones, mantém o ecrã ligado, pausa o Clipboard e cala as notificações da app.
- **Atalhos rápidos:** modo escuro e esconder os ícones da secretária (o Finder reinicia).
- **Rede:** vê as portas à escuta e termina processos teus, com confirmação, e limpa a cache de DNS (pede a password de administrador no diálogo do macOS).
- **Discos:** ejeta discos externos, imagens de disco e volumes de rede, e diz que app está a impedir a ejeção.
- **Arranque:** o que arranca sozinho (LaunchAgents e LaunchDaemons). Os teus podem desligar-se e voltar a ligar-se; os outros só se veem.
- **Ficheiros:** os ficheiros maiores da tua pasta pessoal, com a data da última abertura e um filtro para os que estão sem uso há mais de 6 meses. Move para o Lixo com confirmação.
- **Homebrew:** atualiza e remove pacotes.
- **Desinstalar:** move apps para o Lixo, com os restos que escolheres.
- **Limpeza:** move para o Lixo caches de uma lista fechada (Homebrew, pip e npm; Brave, Playwright, Hugging Face e npx são opcionais), com confirmação e sem tocar no que detetar em uso. O espaço fica livre quando esvaziares o Lixo.
- **Teclado e ecrã:** bloqueia o teclado e põe o ecrã preto para os limpares. Sai com um botão, com as duas teclas ⌘ ou sozinho após 1, 2 ou 5 minutos. O botão de ligar e o Touch ID não se bloqueiam.
- **Imagens:** arrasta fotos para converter HEIC, PNG ou JPG para JPG ou PNG, reduzir o tamanho e comprimir, sem a localização das fotos. E vídeo para GIF.

### À tua medida

Barra de menus configurável, separadores à tua escolha (quais, por que ordem e em qual abre), atalhos ⌥⌘1 a ⌥⌘8 para cada um, limites de alerta com qualquer valor, atalho global, perfis, tema, cor, largura, tamanho do texto, manter o Mac acordado (por tempo ou enquanto houver agentes a trabalhar), início de sessão automático e suporte a VoiceOver e “Reduzir movimento”. A interface está em português e em inglês: segue o idioma do Mac, ou escolhe-o nas Definições → Geral.

Comporta-se como os outros ícones da barra de menus: o botão direito abre um menu com os separadores, os atalhos rápidos, as Definições e Sair, e clicar fora do painel, incluindo na secretária, fecha-o.

Dentro do painel: ⌘1–8 mudam de separador, ⌘[ e ⌘] vão para o anterior e o seguinte, ⌘, abre as Definições (numa janela própria, com exportar e importar para outro Mac) e ⌘W fecha.

**Atalhos da app da frente:** segura ⌘ um segundo (ou ⌃⌥/) e vê os atalhos de teclado da app que estás a usar.

**Regras “quando… então…”** (Definições → Regras): quando um agente termina, a bateria desce de um valor, ligas a corrente ou um monitor, toca um som, mostra um aviso, corre um comando, liga o modo apresentação, silencia o microfone ou organiza a janela. Não entram no exportar das definições.

### Comandos `agentstats://`

Para a app Atalhos (ação “Abrir URL”) ou o Terminal (`open "agentstats://…"`):

| Comando | Faz |
| --- | --- |
| `agentstats://open/system` | Abre o painel num separador (`agents`, `system`, `processes`, `audio`, `clipboard`, `capture`, `time`, `tools`) |
| `agentstats://settings` | Abre as Definições |
| `agentstats://timer?minutes=25` · `agentstats://pomodoro` · `agentstats://timer/stop` | Temporizador |
| `agentstats://read/text` · `read/qr` · `read/color` | Ler o ecrã |
| `agentstats://toggle/dark-mode` · `toggle/desktop-icons` | Atalhos rápidos |
| `agentstats://usage/copy` | Copia os tokens e o custo de hoje e da semana |
| `agentstats://window/leftHalf` | Organiza a janela da frente (`leftHalf`, `rightHalf`, `maximize`, `center`, `nextDisplay`…) |

## Permissões e privacidade

| Funcionalidade | Permissão que o macOS pode pedir |
| --- | --- |
| Avisos e alertas | Notificações |
| Mixer por app | Gravação de áudio do sistema |
| Captura e gravação | Gravação de ecrã |
| Gravar com microfone | Microfone |
| Limpeza do teclado e do ecrã, colar rápido, organizar janelas, atalhos da app e apps que não respondem | Acessibilidade |
| Histórico do clipboard | Colar de outras apps (macOS 15.4+) |
| Categorias do Disco, medidas ao abrir o cartão | Pastas pessoais (Secretária, Documentos, Descargas, Música, Fotografias) |
| Nome da rede Wi-Fi (opcional) | Localização |
| Modo escuro nos atalhos rápidos | Automação (System Events) |
| Próxima reunião (opcional) | Calendários |

Não há conta nem telemetria. O AgentStats lê os registos dos agentes no Mac e não os envia. Só há rede no teste de velocidade, no Homebrew quando o usas, na consulta periódica dos limites, feita pelo teu Claude Code, na procura diária de versões novas no GitHub, que podes desligar, e no IP público, só quando o pedes. Ao enviar um ficheiro para o telemóvel, a app serve-o na rede local só até ser descarregado ou até passarem 10 minutos.

A partir da 1.18.1 a app tem uma assinatura fixa, para **as permissões se manterem entre atualizações**. Ao vires de uma versão anterior tens de as dar uma última vez: se alguma aparecer ligada e não funcionar, tira o AgentStats dessa lista com − e volta a juntá-lo.

## Requisitos

Mac com Apple Silicon e macOS 14 ou superior. Testada no macOS 27.2.

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
3. Abre a app. Se o macOS bloquear a primeira abertura, vai a **Definições do Sistema → Privacidade e Segurança → Abrir mesmo assim**. A app tem certificado próprio, não uma assinatura de programador Apple.

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

Só na primeira vez, o dono do repositório corre `Scripts/setup-signing.sh` para criar a chave de assinatura. Depois atualiza `VERSION` e envia uma tag com a mesma versão, por exemplo:

```bash
git tag v1.20
git push origin v1.20
```

O GitHub Actions valida a versão, executa os testes, compila a app e publica `AgentStats.zip` na release.

### Diagnóstico

- `AgentStats --dump` — métricas e agentes detetados.
- `AgentStats --bench` — tempo de execução dos leitores.
- `AgentStats --snapshot <pasta>` — capturas do painel em PNG, só com dados inventados.
- `AgentStats --smoke` — teste de arranque, com os leitores reais.
- `AGENTSTATS_DISABLE=icon,temps,procs,sessions,usage,energy,limits,gpu,disk` — desativa leitores para medir consumo.

### Arquitetura

O `Sampler` (actor) coordena as leituras e devolve uma amostra imutável. O `Monitor` aplica os dados no main actor; as vistas SwiftUI observam apenas o estado que utilizam. O projeto usa Swift 6 com verificação de concorrência.

</details>
