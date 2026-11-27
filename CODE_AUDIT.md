# AgentStats — Auditoria de código

Gerada a 2026-11-26. Âmbito: 130 ficheiros Swift em `Sources/AgentStats` (cerca de 18 600 linhas), um só alvo SwiftPM, macOS 14+, Swift 6. `.build/` excluído; `Tests/` (80 suites, 365 testes) só consultados para perceber a intenção.

Cada ponto cita `caminho:linha` relativo a `Sources/AgentStats/`, salvo indicação. Cada um tem uma ação recomendada. Nenhum código foi alterado por esta auditoria.

**Estado em 2026-11-27:** todos os pontos foram tratados. Cada um tem por baixo do título o que mudou. Ficaram por fazer, explicados nos respetivos pontos, só partes de §3.3, §3.8, §7.1, §9.14 e §9.17. O §8.4 era um falso positivo. Os números das linhas citadas são os da altura da auditoria: depois das correções, alguns ficheiros mudaram. Testes: 385 em 81 suites, todos a passar.

Ponto de partida: uma compilação completa em modo Swift 6 não dá **nenhum aviso** (só os avisos de caminhos do `ld`, que vêm do ambiente). O padrão do crash da 1.16 (closure `@MainActor` chamada fora da main thread) **não volta a aparecer**: todos os observers usam `queue: .main`, os callbacks de sistema são `@Sendable` ou não isolados, e todos os `MainActor.assumeIsolated` correm de facto na main thread. As três classes `@unchecked Sendable` (`FileDropServer`, `MixerEngine`, `KeyboardLock`) estão bem confinadas. As regras com comandos não entram na importação de definições, e a password do Wi-Fi nunca toca no disco.

---

## 1. Resumo executivo

Por ordem de prioridade:

1. ✅ **[Critical] Qualquer link `agentstats://` com uma chave repetida faz a app ir abaixo** — §5.1 — `App/URLCommands.swift:20-21`. Uma página web ou um documento consegue fechá-la.
2. ✅ **[High] A deteção de "precisa de aprovação" deixa de funcionar para sempre depois de desligar o hook do Claude** — §5.2 — `Agents/Readers/HookEvents.swift:20`.
3. ✅ **[High] Partilhar um segundo ficheiro deixa o primeiro servidor sem controlo: o "Parar" não faz nada** — §5.3 — `Tools/Share/ShareView.swift:27-68`.
4. ✅ **[High] O `ToolRunner` gasta 100% de um núcleo quando se fecha o painel a meio de um comando** — §3.1 — `Tools/ToolRunner.swift:56-66`.
5. **[Medium/Security] O servidor de partilha não fecha as ligações já aceites, nem lhes dá tempo limite** — §6.1 — `Tools/Share/FileDrop.swift:150-228`.
6. **[Medium/Security] Colar rápido envia ⌘V sem confirmar qual é a app da frente** — §6.7 — `Clipboard/QuickPaste.swift:25-44`.
7. **[Medium/Security] Ligar o hook troca um symlink do `~/.claude/settings.json` por um ficheiro e muda as permissões para 0644** — §6.4 — `Agents/ClaudeHook.swift:138-145`.
8. **[Medium] O leitor de limites do Claude pode ficar bloqueado e nunca mais atualizar** — §3.4 — `Agents/Usage/PlanLimits.swift:143-175`.
9. **[Medium] As cópias feitas pela própria app entram no histórico do Clipboard** — §5.8 — `Agents/AgentActions.swift:16-19` e mais 7 sítios.
10. **[Medium] As definições importadas não se aplicam e depois são reescritas com os valores antigos** — §5.6 — `Settings/SettingsFiles.swift:21-31`.

---

## 2. Ganhos rápidos (≤30 min cada)

- **Tolerar chaves repetidas na query dos URLs** — `App/URLCommands.swift:20`. Elimina o único crash que se consegue provocar de fora (§5.1).
- **Sair do ciclo do `ToolRunner` quando a tarefa é cancelada** — `Tools/ToolRunner.swift:65`. Acaba com o CPU a 100% (§3.1).
- **Ignorar no `ShareStore.ended` os fins de servidores que já não são o atual** — `Tools/Share/ShareView.swift:56`. Volta a pôr o "Parar" a funcionar (§5.3).
- **Retomar a continuação do `start()` também em `.cancelled` e `.waiting`** — `Tools/Share/FileDrop.swift:114-128` (§5.4).
- **Juntar `capture.recording.pid` e `capture.recording.file` ao `SettingsTransfer.excluded`** — `Agents/Usage/UsageReports.swift:114` (§6.9).
- **Pôr a pasta `clipboard-images` fora das cópias de segurança** — `Clipboard/ClipboardStore.swift:153-168` (§6.6).
- **Passar `AgentActivityHistory`, `History24h` e `BatteryHistory` para o `PrivateFile`** — permissões 0600 e fora do Time Machine (§6.5).
- **Só atribuir `stuck` quando o valor muda** — `System/Unresponsive.swift:71-76`. Deixa de redesenhar o painel todo de 10 em 10 s (§8.1).
- **Apagar código morto**: `MenuBarLabel.cell`, `TemperatureReader.isAvailable`, os 15 símbolos sem uso de `WindowAction.symbol`, e o ternário redundante em `QuickToggles.swift:94` (§9.1).
- **Usar literais simples nos caminhos do Desinstalar** — `Tools/Uninstall/UninstallTool.swift:55-67` (§5.16).
- **Traduzir o dia da semana no rótulo do VoiceOver** — `Agents/Views/TodayUsage.swift:90` (§5.14).

---

## 3. Concorrência

### 3.1 O `ToolRunner` entra num ciclo sem pausa quando a tarefa é cancelada
> **Corrigido (2026-11-26):** cancelar a tarefa termina o comando como se o prazo tivesse passado, e a pausa de 100 ms já não acaba mais cedo. Teste: `ToolRunnerTests.cancellingStopsTheCommand`.
- **Location:** `Tools/ToolRunner.swift:56-66`. É chamado a partir de `.task {}` em `Tools/Brew/BrewView.swift:18`, `Tools/Cleanup/CleanupView.swift:27`, `Tools/Ports/PortsView.swift:25`, `Tools/Startup/StartupView.swift:30`, `Tools/Uninstall/UninstallView.swift:17`, `Tools/Quick/QuickToggles.swift:106`, `System/SystemView.swift:280-284` e `449-453`.
- **What:** O ciclo `while process.isRunning { … try? await Task.sleep(…) }` engole o `CancellationError`. Depois do cancelamento, o `Task.sleep` regressa logo e o ciclo gira sem parar.
- **Why:** Fechar o painel troca a vista raiz por `EmptyView` e cancela estas tarefas. Um `du` (até 120 s), um `brew info` (90 s) ou um `system_profiler` ainda a correr põe um núcleo a 100% até acabar.
- **Action:** Esperar pelo fim com `terminationHandler` e uma continuação, ou terminar o processo ao detetar `Task.isCancelled`. Os chamadores que percorrem vários alvos (`CleanupStore.refresh`) também devem parar quando a tarefa é cancelada.
- **Severity:** High

### 3.2 `PresentationMode.set(_:)` pode ser reentrado durante o `await`
> **Corrigido (2026-11-27):** as mudanças correm uma de cada vez, numa cadeia de tarefas.
- **Location:** `System/Presentation.swift:34-58`
- **What:** `set(true)` põe `active = true` e fica à espera do `setDesktopIcons` (um `defaults` mais `killall Finder`). Só depois cria a asserção de ecrã e pausa o Clipboard. Um `set(false)` vindo do menu, de uma regra ou de um URL pode correr inteiro dentro dessa espera.
- **Why:** Alternar depressa pode deixar `active == false` com a asserção de ecrã ainda ativa (e o ID perdido), e o histórico do Clipboard pausado indefinidamente.
- **Action:** Fazer as mudanças de estado antes do `await`, ou voltar a verificar `active` depois de cada `await`, ou serializar as chamadas numa só `Task` guardada.
- **Severity:** Medium

### 3.3 Trabalho bloqueante longo no pool cooperativo
> **Corrigido em parte (2026-11-27):** os processos e análises longas (`security`, limites do Claude, análises do disco, menus por Acessibilidade, OCR, ejetar) correm numa thread do GCD (`Blocking.run`). O `ps` do `Sampler` continua no actor, agora com tempo limite de 5 s (é curto e corre de 10 em 10 s).
- **Location:**
  - `System/Sampler.swift:54-90`: o `ps` via `System/Readers/Sys.swift:33-47`, e leitura de transcripts.
  - `System/Monitor.swift:203`
  - `Tools/Share/WiFiQR.swift:63-82`: o `security` fica à espera do diálogo do macOS sem limite.
  - `Tools/Shortcuts/ShortcutsOverlay.swift:69`
  - `Tools/Uninstall/UninstallTool.swift:140`
  - `Tools/Files/LargeFilesTool.swift:99`
- **What:** O actor `Sampler` e vários `Task.detached` fazem chamadas síncronas que podem demorar muito: `readDataToEndOfFile`, `waitUntilExit`, leituras do menu por Acessibilidade e análise da pasta pessoal inteira.
- **Why:** O pool cooperativo só tem tantas threads como núcleos. Algumas destas ao mesmo tempo (diálogo da password aberto, leitura de limites, uma análise) deixam sem thread as outras tarefas async da app.
- **Action:** Correr processos e análises do disco numa `DispatchQueue` ou `Thread` dedicada, ligada por continuações, ou torná-los mesmo async com `terminationHandler` e `FileHandle.bytes`.
- **Severity:** Medium

### 3.4 `ClaudeLimitsFetcher` pode ficar bloqueado para sempre
> **Corrigido (2026-11-27):** `ProcessRun.sync` lê os pipes sem esperar pelo fim deles, mata a árvore de processos no fim do prazo, e `claudeChecking` é reposto num `defer`.
- **Location:** `Agents/Usage/PlanLimits.swift:143-175`; `System/Monitor.swift:199-216`
- **What:** Passados os 15 s, só o filho direto leva `terminate()`. O `readDataToEndOfFile()` espera até que todos os processos com o stdout aberto o fechem, e os netos do `claude` (Node) podem herdá-lo.
- **Why:** A tarefa não regressa e `claudeChecking` fica `true`, por isso os limites do Claude não voltam a atualizar até reiniciar a app.
- **Action:** Ler o pipe de forma assíncrona (`readabilityHandler`) com o prazo, fechar o lado de leitura quando o prazo acaba, e repor `claudeChecking` num `defer`.
- **Severity:** Medium

### 3.5 `Sys.run("ps")` sem tempo limite, dentro do `Sampler`
> **Corrigido (2026-11-27):** `Sys.run` passou a usar `ProcessRun.sync` com tempo limite.
- **Location:** `System/Readers/Sys.swift:33-47`; chamado por `System/Readers/ProcessReader.swift:12` e `:76`; `System/Monitor.swift:171-190`
- **What:** `readDataToEndOfFile` e `waitUntilExit` sem prazo, chamados de forma síncrona a cada amostra. O resto da app usa o `ToolRunner`, que tem tempo limite.
- **Why:** Se o `ps` encravar, `sampling` fica `true` e todas as métricas e o ícone da barra de menus congelam até reiniciar.
- **Action:** Usar um runner com prazo e repor `sampling` se uma amostra demorar de mais. Ver também §9.3.
- **Severity:** Medium

### 3.6 Temporizadores em modo `.default` param durante menus e arrastos
> **Corrigido (2026-11-27):** todos estes timers usam `Timer.common`, no modo `.common`.
- **Location:**
  - `Time/TimeStore.swift:61-66`
  - `System/Monitor.swift:164-169`
  - `System/Unresponsive.swift:46`
  - `Time/Meetings.swift:74`
  - `Time/AppUsage.swift:78`
  - `System/KeepAwake.swift:61-68`
  - `App/UpdateCheck.swift:85`
- **What:** Todos usam `Timer.scheduledTimer`, que só dispara no modo `.default`. O `ClipboardStore`, o `CaptureStore` e o `CleaningModeStore` já usam `.common`, corretamente.
- **Why:** Com o menu do ícone aberto ou um slider a ser arrastado, a contagem do temporizador na barra de menus para, o fim do Pomodoro chega atrasado e a amostragem para.
- **Action:** Criar estes timers com `RunLoop.main.add(_, forMode: .common)`, pelo menos o do `TimerStore` e o do `Monitor`.
- **Severity:** Medium

### 3.7 `ShortcutsOverlay` não cancela um `show()` em curso
> **Corrigido (2026-11-27):** a leitura fica guardada, é cancelada no `close()`, e "a carregar" conta como aberto.
- **Location:** `Tools/Shortcuts/ShortcutsOverlay.swift:57-73`, `97-105`
- **What:** `show()` lança uma `Task` sem a guardar, espera pela leitura do menu por Acessibilidade e depois chama `present()`. O `close()` e o `toggle()` não a cancelam, e `panel == nil` durante a leitura deixa lançar mais leituras.
- **Why:** Carregar duas vezes em ⌃⌥/, ou fechar durante a leitura, faz o painel aparecer na mesma, e as leituras acumulam-se.
- **Action:** Guardar a tarefa, cancelá-la no `close()`, e tratar o estado "a carregar" como aberto no `toggle()`.
- **Severity:** Medium

### 3.8 Chamadas síncronas na main thread que podem congelar a interface
> **Corrigido em parte (2026-11-27):** tempo limite de 1 s na Acessibilidade do `WindowMover`; EventKit e a lista de volumes fora do main thread. O CoreAudio fica síncrono (são chamadas de microssegundos ao coreaudiod, e o silêncio do microfone precisa delas logo).
- **Location:**
  - `Time/Meetings.swift:90-103`: EventKit `events(matching:)` de 30 em 30 s.
  - `Tools/Disks/DisksTool.swift:58-73`: capacidade de volumes, incluindo volumes de rede.
  - `Tools/Windows/WindowMover.swift:44-75`: chamadas de Acessibilidade sem `AXUIElementSetMessagingTimeout`.
  - `Audio/AudioDevices.swift:31-81`: CoreAudio síncrono.
- **What:** Estas chamadas correm no main actor e dependem de outro processo ou de um volume de rede.
- **Why:** Um volume SMB pendurado ou uma app da frente que não responde (o tempo limite da Acessibilidade é de cerca de 6 s) congela o painel. Os atalhos de janelas são usados precisamente em apps que se portam mal.
- **Action:** Pôr um tempo limite curto no `WindowMover`, e tirar a consulta do EventKit e a lista de volumes do main actor, publicando só os resultados.
- **Severity:** Medium

### 3.9 A main thread bloqueia de propósito com semáforo e `usleep`
> **Estado (2026-11-27):** Mantido de propósito, agora com o porquê escrito junto ao código.
- **Location:** `Tools/Cleanup/KeyboardCleaning.swift:106-120`; `Capture/CaptureStore.swift:223-241`
- **What:** `KeyboardLock.start` espera até 2 s num `DispatchSemaphore`, e `CaptureStore.shutdown` faz `usleep` até 8 s dentro do `willTerminate`.
- **Why:** A interface pode mostrar a roda colorida durante esse tempo. É uma troca de segurança aceitável e intencional.
- **Action:** Manter se for intencional; documentar o porquê junto ao código.
- **Severity:** Low

### 3.10 `runModal()` síncrono dentro de funções async do main actor
> **Corrigido (2026-11-27):** `FilePanels` usa `begin(completionHandler:)` numa continuação; já não há `runModal()` de painéis de ficheiros.
- **Location:**
  - `Tools/Share/ShareView.swift:46-52`
  - `Tools/Images/ImagesView.swift:36-43`, `59-65`
  - `Settings/SettingsFiles.swift:11-12`, `25-26`, `38-39`
  - `Capture/QRMaker.swift:82-83`
  - `Clipboard/ClipboardView.swift:272-273`
- **What:** `NSOpenPanel` e `NSSavePanel` correm um run loop encaixado enquanto há uma função async no stack.
- **Why:** Outros trabalhos do main actor (amostras, timers, callbacks `ended()`) correm a meio do chamador, o que torna as invariantes difíceis de garantir.
- **Action:** Usar a forma `begin(completionHandler:)` embrulhada numa continuação. Ver §9.12.
- **Severity:** Low

### 3.11 `MainActor.assumeIsolated` redundante no `AppDelegate`
> **Corrigido (2026-11-27):** `AppDelegate` é `@MainActor` e os embrulhos saíram.
- **Location:** `App/App.swift:130-172`
- **What:** O `AppDelegate` já é inferido `@MainActor` pelo protocolo, mas embrulha os corpos em `assumeIsolated`.
- **Why:** É ruído e esconde de onde vem o isolamento.
- **Action:** Marcar a classe `@MainActor` explicitamente, tirar os embrulhos e manter `nonisolated` os dois métodos de `UNUserNotificationCenterDelegate`.
- **Severity:** Low

### 3.12 `nonisolated(unsafe)` desnecessário num formatter
> **Corrigido (2026-11-27):** `ISODate.shared` em `Shared/Dates.swift`, sem `nonisolated(unsafe)`.
- **Location:** `Agents/Readers/MoreAgentsReaders.swift:43-48`
- **What:** Um `ISO8601DateFormatter` global está marcado `nonisolated(unsafe)`.
- **Why:** A classe é thread-safe; o atalho inseguro só esconde problemas futuros.
- **Action:** Usar um `let` simples, ou o helper comum de §9.16.
- **Severity:** Low

### 3.13 `DispatchQueue.main.asyncAfter` em código do main actor
> **Estado (2026-11-27):** Corrigido em `UpdateCheck` e `App` (`Task.sleep`). O `QuickPaste` foi reescrito (ver §6.7).
- **Location:** `App/UpdateCheck.swift:88`; `App/App.swift:169`; `Clipboard/QuickPaste.swift:31`
- **What:** São atrasos com GCD dentro de contextos `@MainActor`.
- **Why:** Mistura os dois modelos de concorrência e não se pode cancelar.
- **Action:** Usar `Task { try await Task.sleep(for:) … }` no main actor.
- **Severity:** Low

---

## 4. Modernidade de API

### 4.1 `NSApp.activate(ignoringOtherApps:)` (13 ocorrências)
> **Corrigido (2026-11-27):** `NSApp.activate()` em todos os sítios.
- **Location:**
  - `App/StatusController.swift:197`, `275`
  - `Tools/Share/ShareView.swift:49`
  - `Tools/Images/ImagesView.swift:40`, `63`
  - `Tools/Cleanup/KeyboardCleaningView.swift:75`
  - `Settings/SettingsFiles.swift:11`, `25`, `38`
  - `Capture/QRMaker.swift:82`
  - `App/Welcome.swift:32`
  - `Shared/Support.swift:43`
  - `Clipboard/ClipboardView.swift:272`
- **What:** Usa uma API marcada pela Apple como "a ser descontinuada". No macOS 14 o parâmetro é ignorado.
- **Why:** Vai começar a dar avisos num SDK futuro, e o CI corre num SDK diferente do local.
- **Action:** Usar `NSApp.activate()` (macOS 14+) em todos os sítios.
- **Severity:** Low

### 4.2 Atalhos globais com Carbon `RegisterEventHotKey`
> **Estado (2026-11-27):** Mantido (intencional).
- **Location:** `App/GlobalHotKey.swift:56-72`
- **What:** Os atalhos globais usam a API Carbon. É intencional.
- **Why:** Continua a funcionar e não precisa de permissão de Acessibilidade. Não há alternativa moderna equivalente.
- **Action:** Manter. Não é preciso mudar nada.
- **Severity:** Low

### 4.3 Mistura de `ObservableObject` e `@Observable`
> **Corrigido onde custava (2026-11-27):** o `UnresponsiveStore` só publica quando muda (§8.1) e o `TimerStore` deixou de publicar a cada segundo (§8.2). Os outros stores ficam `ObservableObject`.
- **Location:** `System/Monitor.swift` é `@Observable`; a maior parte dos stores (`TimerStore`, `UnresponsiveStore`, `ShareStore`, `ClipboardStore`…) é `ObservableObject`.
- **What:** Há dois modelos de observação na mesma app.
- **Why:** Só causa trabalho a mais onde um store publica com frequência (§8.1, §8.2). Nos outros é inofensivo.
- **Action:** Migrar para `@Observable` só os stores que publicam muitas vezes; os outros podem ficar como estão.
- **Severity:** Low

---

## 5. Bugs / erros de lógica

### 5.1 Crash com qualquer link `agentstats://` que repita uma chave
> **Corrigido (2026-11-26):** com chaves repetidas fica a primeira. Teste: `URLCommandTests.repeatedKeysKeepTheFirst`; confirmado também na app instalada.
- **Location:** `App/URLCommands.swift:20-21`
- **What:** `Dictionary(uniqueKeysWithValues:)` é construído a partir da query com os nomes em minúsculas. Por isso, `agentstats://timer?minutes=5&minutes=6` (ou `?Tab=a&tab=b`) dá um erro fatal em tempo de execução antes de ler o comando.
- **Why:** Qualquer página web, documento, atalho ou outra app consegue fechar a AgentStats com um link. Com ela param o histórico do Clipboard, a gravação de ecrã e o bloqueio do teclado.
- **Action:** Usar `Dictionary(_:uniquingKeysWith:)` a ficar com o primeiro valor, ou ler com `queryItems.first(where:)`. Juntar um teste com uma chave repetida.
- **Severity:** Critical

### 5.2 A deteção de aprovações fica desligada para sempre depois de tirar o hook
> **Corrigido (2026-11-26):** quando o hook está desligado ou aponta para uma app que já não existe, a pasta de eventos é apagada, ao arrancar e ao abrir as Definições. Teste em `AgentFeatureTests`.
- **Location:** `Agents/Readers/HookEvents.swift:20`; `Agents/Readers/AgentReader.swift:237-241`, `266-273`; `Agents/ClaudeHook.swift:127-150`
- **What:** `HookEvents.isActive` só verifica se a pasta `~/.claude/agentstats/events` existe. Desligar o hook (`ClaudeHookStore.set(false)`) nunca a apaga, e o `prune()` só apaga os ficheiros lá dentro.
- **Why:** Depois de a pasta existir, `approvalState` segue sempre o ramo "só hook". Sem eventos novos devolve `nil`, e o plano B por processos nunca mais corre. Os pedidos de Bash ou Edit à espera de aprovação deixam de ser assinalados, e as notificações e regras desse estado nunca disparam.
- **Action:** Decidir "ativo" pelo estado do hook no `settings.json` (`ClaudeHookStore.state == .on`) ou por um evento recente, e apagar a pasta de eventos ao desligar.
- **Severity:** High

### 5.3 Um servidor de partilha antigo apaga o novo, e o "Parar" deixa de funcionar
> **Corrigido (2026-11-26):** cada servidor tem uma geração, e o `ShareStore` ignora os avisos de fim que não são do servidor atual, incluindo um envio ou um Parar a meio do arranque.
- **Location:** `Tools/Share/ShareView.swift:27-44`, `54-68`
- **What:** O `send()` chama `stop()` no servidor atual e cria um novo. O `.stopped` do antigo chega mais tarde por `Task { @MainActor }`, e `ended()` faz `server = nil` e `state = .idle` sem ver qual servidor terminou.
- **Why:** Se se largar um segundo ficheiro enquanto o primeiro está a ser servido, a referência ao novo servidor perde-se, mas ele continua a escutar durante 10 minutos. O "Parar" não faz nada (`server?.stop()` em `nil`), e o ficheiro continua acessível na rede local quando o utilizador julga que parou.
- **Action:** Identificar cada servidor (pelo token ou por um contador) no callback, e ignorar os fins de servidores que já não são o atual. Fazer o mesmo com o resultado do `start()`.
- **Severity:** High

### 5.4 A continuação do `FileDropServer.start()` pode nunca ser retomada
> **Corrigido (2026-11-26):** `.waiting` termina com erro, `close()` retoma a espera com nil, e `start()` depois de parado devolve nil. Teste: `stoppedBeforeStartReturnsNil`.
- **Location:** `Tools/Share/FileDrop.swift:108-134`
- **What:** `ready` só é retomada em `.ready` ou `.failed`. Um listener que fica em `.waiting` (sem rede utilizável), ou que passa a `.cancelled` porque um `stop()` chegou primeiro, nunca a retoma.
- **Why:** O `ShareStore.send` fica suspenso para sempre, a interface não sai do estado anterior, e o runtime regista uma `CheckedContinuation` perdida.
- **Action:** Retomar com `nil` também em `.cancelled` e `.waiting` (ou com um prazo curto), e retomar qualquer `ready` pendente no `close()`.
- **Severity:** Medium

### 5.5 Antigravity: datas que não se leem passam a ser "agora"
> **Corrigido (2026-11-27):** `parseDate` devolve `Date?`, aceita épocas em segundos e milissegundos, e as linhas que não se leem são saltadas.
- **Location:** `Agents/Readers/AntigravityReader.swift:111`, `165-172`, `56-69`
- **What:** `parseDate` devolve `Date()` quando `last_modified_time` não se lê (por exemplo, se vier guardado como época numérica).
- **Why:** As 10 conversas recentes ficam todas com `updated = now`, passam sempre a janela de recentes e aparecem como "a pensar" para sempre.
- **Action:** Devolver `Date?`, aceitar épocas em segundos ou milissegundos (via `sqlite3_column_type`), e saltar as linhas que não se leem.
- **Severity:** Medium

### 5.6 As definições importadas não se aplicam e depois são reescritas
> **Corrigido (2026-11-27):** `Monitor.reloadFromDefaults()` corre depois de importar.
- **Location:** `Settings/SettingsFiles.swift:21-31`; `System/Monitor.swift:61-102`, `386-391`
- **What:** `importSettings` escreve no `UserDefaults`, mas o `Monitor` guarda limiares, intervalo, orçamento e energia em propriedades lidas uma só vez no `init`.
- **Why:** A app diz "N definições importadas" mas nada muda até reiniciar. Mexer em qualquer controlo do `Monitor` reescreve o valor antigo por cima do importado.
- **Action:** Depois de importar, recarregar as propriedades do `Monitor` (um `reloadFromDefaults()`), ou torná-las calculadas sobre o `Pref`.
- **Severity:** Medium

### 5.7 O estado do microfone silenciado só existe em memória
> **Corrigido (2026-11-27):** guarda o aparelho silenciado (também em disco, para o arranque seguinte) e repõe esse; listeners do Core Audio atualizam o estado quando o microfone é ligado por outro lado.
- **Location:** `Audio/MicMute.swift:58-83`; `Audio/AudioDevices.swift:31-38`
- **What:** `muted` é uma variável em memória. `set(false)` tira o silêncio do dispositivo de entrada que for o atual nesse momento, e não há listeners do CoreAudio.
- **Why:** Se os AirPods se ligarem ou a entrada mudar enquanto está silenciado, tira-se o silêncio do dispositivo errado e o anterior fica a volume 0. O indicador na barra de menus também fica desatualizado se o volume for mudado nas Definições do Sistema.
- **Action:** Guardar o ID do dispositivo silenciado e repor esse, e juntar listeners (`AudioObjectAddPropertyListenerBlock` numa fila, `@Sendable`) para a entrada por omissão, o silêncio e o volume.
- **Severity:** Medium

### 5.8 As cópias feitas pela própria app entram no histórico do Clipboard
> **Corrigido (2026-11-27):** todas as cópias passam por `ClipboardStore.copy` / `copy(image:)`. Exceção intencional: o texto lido do ecrã (OCR e cor) entra no histórico, porque é conteúdo que se quer voltar a colar.
- **Location:**
  - `Agents/AgentActions.swift:16-19`
  - `Tools/Startup/StartupView.swift:70-71`
  - `System/ProcessesView.swift:102-103`
  - `App/URLCommands.swift:80-81`
  - `App/UpdateCheck.swift:131-132`
  - `Clipboard/QuickNotes.swift:56-57`
  - `Capture/ScreenTools.swift:144-147`
  - `Capture/QRMaker.swift:72-75`
  - Função certa: `Clipboard/ClipboardStore.swift:222-226`
- **What:** Oito sítios fazem `clearContents()` e `setString` ou `writeObjects` diretamente. Só o `ClipboardStore.copy` atualiza `lastChange` para o histórico ignorar a cópia.
- **Why:** Copiar um PID, um caminho, o uso, o comando do brew ou uma imagem QR cria uma entrada nova no histórico, ou um PNG guardado. O próprio comentário do `copy()` diz que isto não é desejado.
- **Action:** Passar todos por `ClipboardStore.shared.copy(_:)` e juntar um `copy(image:)`.
- **Severity:** Medium

### 5.9 As chaves de dia ("yyyy-MM-dd") não são consistentes
> **Corrigido (2026-11-27):** `DayKey` (gregoriano, ASCII, fuso atual) em toda a app.
- **Location:**
  - `Agents/Usage/UsageReports.swift:53-56`
  - `Agents/Usage/UsageTracker.swift:82-87`
  - `System/BatteryHistory.swift:52-66`
  - `Agents/Views/TodayUsage.swift:122-128`
  - `Capture/CaptureCore.swift:47-49`
  - `App/DemoData.swift:225-226`
- **What:** Há seis maneiras de fazer a mesma chave. Umas usam `en_US_POSIX`, outras o locale e o calendário do utilizador. O `UsageTracker` também fixa o fuso horário no arranque, enquanto o `Budget.day` usa o atual.
- **Why:** O `Budget.spent` compara estas chaves como texto. Depois de uma viagem com mudança de fuso, ou num calendário não gregoriano, "hoje" no uso e no orçamento discordam. Os avisos de orçamento e o "Hoje" podem mostrar 0.
- **Action:** Um único helper `DayKey` em `Shared/` (POSIX, gregoriano, `autoupdatingCurrent`) usado nos seis sítios.
- **Severity:** Medium

### 5.10 O pedido HTTP da partilha é lido de forma frágil
> **Corrigido (2026-11-27):** a linha do pedido junta-se até `\r\n` (até 8 KB), e pastas são recusadas com uma mensagem.
- **Location:** `Tools/Share/FileDrop.swift:163-164`, `180-187`; `Tools/Share/ShareView.swift:150-153`
- **What:**
  - A linha do pedido vem de um único `receive`, por isso um pedido partido em dois pacotes dá 404.
  - Uma pasta largada sem barra final passa o teste `!hasDirectoryPath` e é enviada como um ficheiro vazio.
- **Why:** O telemóvel pode receber um 404 falso, e o link pode ficar preso a esse telemóvel. Uma pasta aparece como "Enviado" sem conteúdo.
- **Action:** Acumular até `\r\n` (com um limite de tamanho) e verificar `isRegularFileKey` antes de servir.
- **Severity:** Low

### 5.11 O conversor de imagens produz 1 px quando faltam as dimensões
> **Estado (2026-11-27):** Corrigido.
- **Location:** `Tools/Images/ImageConverter.swift:59-65`
- **What:** Sem `PixelWidth`/`PixelHeight`, `side` é 0 e o tamanho máximo fica `max(0, 1) = 1`.
- **Why:** Alguns formatos geram um ficheiro "convertido" de 1×1 sem avisar.
- **Action:** Omitir `kCGImageSourceThumbnailMaxPixelSize` quando as dimensões são desconhecidas.
- **Severity:** Low

### 5.12 `ShortcutsOverlay` assume que o primeiro monitor é o do teclado
> **Corrigido (2026-11-27):** monitor do teclado e dos cliques em propriedades separadas.
- **Location:** `Tools/Shortcuts/ShortcutsOverlay.swift:24-26`, `91-94`, `101-104`
- **What:** `close()` remove `monitors.dropFirst()`. Se o monitor do teclado não foi criado no `start()`, o índice 0 é um monitor de cliques que nunca é removido.
- **Why:** Os monitores de cliques acumulam-se a cada vez que o painel aparece.
- **Action:** Guardar o monitor do teclado e os de cliques em propriedades separadas.
- **Severity:** Low

### 5.13 O ⌘V do Colar rápido depende da disposição do teclado
> **Corrigido (2026-11-27):** `KeyLayout.keyCode(for:)` procura a tecla do "v" na disposição atual.
- **Location:** `Clipboard/QuickPaste.swift:35-44`
- **What:** O keycode 9 é a posição física do "V" em QWERTY. Em Dvorak (sem a variante QWERTY-⌘) produz outro atalho.
- **Why:** O Colar rápido falha sem aviso para esses utilizadores.
- **Action:** Obter o keycode de "v" na disposição atual, ou usar a ação "Colar" por Acessibilidade.
- **Severity:** Low

### 5.14 O VoiceOver lê o dia da semana sempre em português
> **Estado (2026-11-27):** Corrigido.
- **Location:** `Agents/Views/TodayUsage.swift:90` (a função está em `121-128`)
- **What:** O rótulo de acessibilidade usa `Self.weekday(d.day)` sem `L()`, ao contrário do texto visível na linha 86.
- **Why:** Com a interface em inglês, o VoiceOver diz "qui" em vez de "Thu".
- **Action:** Passar o nome do dia por `L()` no rótulo, como no texto visível.
- **Severity:** Low

### 5.15 A posse do hook do Claude é decidida por um pedaço de texto
> **Corrigido (2026-11-27):** é nosso o comando cujo executável termina em `/Contents/MacOS/AgentStats`.
- **Location:** `Agents/ClaudeHook.swift:28-30`, `51-57`, `71-85`
- **What:** "É nosso" significa que o comando contém "AgentStats" e "--hook".
- **Why:** Se o pacote da app mudar de nome, o estado aparece desligado e cada ativação junta um hook duplicado. Um hook do próprio utilizador com as duas palavras seria apagado ao desligar.
- **Action:** Marcar a entrada da AgentStats de forma explícita (comparação exata com o executável, ou uma variável de ambiente marcadora).
- **Severity:** Low

### 5.16 Os caminhos de restos do Desinstalar passam pela tradução
> **Estado (2026-11-27):** Corrigido.
- **Location:** `Tools/Uninstall/UninstallTool.swift:55-67`
- **What:** `"Application Support/\(id)"` e os outros caminhos são construídos com `String(localized:)`.
- **Why:** Uma tradução futura destas chaves mudaria os caminhos que vão para o Lixo. Hoje falha para o lado seguro, mas é frágil numa ferramenta destrutiva.
- **Action:** Usar literais simples nos caminhos e traduzir só o texto mostrado.
- **Severity:** Low

---

## 6. Segurança

### 6.1 O servidor de partilha não fecha nem limita as ligações
> **Corrigido (2026-11-27):** no máximo 8 ligações, 10 s para o pedido chegar, 30 s sem progresso durante o envio, e o `close()` cancela todas as ligações.
- **Location:** `Tools/Share/FileDrop.swift:150-174`, `198-228`
- **What:**
  - O `handle` chama `conn.receive` sem prazo, e não há limite de ligações em simultâneo.
  - O `close()` só cancela o listener, não as ligações já aceites, e o `Transfer` continua a enviar.
  - Um leitor parado mantém o `FileHandle` aberto.
- **Why:**
  - Carregar em "Parar", ou deixar o link expirar a meio de uma transferência, não impede o ficheiro de sair do Mac.
  - Qualquer máquina na rede local pode abrir milhares de ligações paradas durante os 10 minutos. Essas ligações sobrevivem ao fim da partilha e esgotam os descritores de ficheiro da app; a amostragem (`ps`, SQLite) começa então a falhar.
- **Action:** Guardar as ligações num conjunto confinado à fila, limitar o número (por exemplo a 8), dar um prazo para a linha do pedido (10 s) e para paragens durante o envio, e cancelar todas no `close()`.
- **Severity:** Medium

### 6.2 A partilha escuta em todas as interfaces, por HTTP simples
> **Corrigido (2026-11-27):** escuta só no endereço da rede local (`requiredLocalEndpoint`), e a interface avisa que a ligação não é cifrada.
- **Location:** `Tools/Share/FileDrop.swift:111`, `18-21`
- **What:** `NWListener(using: .tcp, on: .any)` escuta em todas as interfaces (VPN `utun`, IPv6, qualquer interface pública), embora o URL só anuncie o IPv4 da rede local. O token e o ficheiro vão em texto simples.
- **Why:** Há mais exposição do que é preciso. Numa rede Wi-Fi aberta, outros podem ver o token e o conteúdo.
- **Action:** Definir `requiredInterface` com a interface escolhida por `localAddress()`, e rejeitar ligações cujo endereço local não seja esse. Avisar na interface que a ligação não é cifrada.
- **Severity:** Low

### 6.3 "Terminar" um processo mata um PID sem verificar se ainda é o mesmo
> **Corrigido (2026-11-27):** a identidade do processo é guardada antes do diálogo e confirmada antes do `kill`; os processos do macOS, de outros utilizadores e da própria app são recusados; a cache de nomes expira ao fim de 1 minuto.
- **Location:** `Shared/Support.swift:12-49`; `System/ProcessesView.swift:58`, `95-97`; `System/Unresponsive.swift:85-89`
- **What:**
  - `ProcessKiller.confirmAndTerminate` faz `kill(pid, …)` depois de um `runModal()` que pode ficar aberto indefinidamente, sem confirmar a identidade nem excluir o próprio PID ou processos do sistema.
  - O `AppInfo.cache` (PID → nome) só é limpo acima de 300 entradas.
  - `UnresponsiveStore.forceQuit` usa um PID com até 10 s.
- **Why:** Se o processo terminar e o PID for reutilizado, o utilizador confirma "Terminar Safari" e outro processo recebe o sinal. O `PortsTool` já se protege disto; estes caminhos não.
- **Action:** Guardar uma `ProcessIdentity` (PID, hora de início, executável) quando o diálogo abre e voltar a verificá-la antes do `kill`, como faz o `PortsStore.terminate`. Reutilizar `PortRules.canTerminate`.
- **Severity:** Medium

### 6.4 Gravar o `~/.claude/settings.json` troca symlinks por ficheiros e muda as permissões
> **Corrigido (2026-11-27):** escreve no destino real do symlink, mantém as permissões, e a cópia de segurança nasce com 0600.
- **Location:** `Agents/ClaudeHook.swift:138-145`
- **What:** `write(to:options: .atomic)` escreve um ficheiro novo e renomeia-o por cima do caminho. A cópia de segurança é gravada da mesma maneira, com as permissões por omissão.
- **Why:**
  - Um symlink para uma pasta de dotfiles é substituído por um ficheiro normal, e a configuração do utilizador fica dividida sem aviso.
  - Um `settings.json` com 0600 (muitas vezes com chaves de API em `env`) passa a 0644, tal como o `.agentstats-backup`.
- **Action:** Resolver o symlink antes de escrever e escrever no destino real. Manter as permissões originais e criar a cópia de segurança com 0600.
- **Severity:** Medium

### 6.5 Histórico de atividade dos agentes gravado com 0644 e incluído nos backups
> **Corrigido (2026-11-27):** os três históricos usam `PrivateFile` (0600; fora do Time Machine, exceto a bateria, que não tem nada sensível).
- **Location:**
  - `Agents/Usage/AgentActivityHistory.swift:117-135`
  - `System/History24h.swift:47-69`
  - `System/BatteryHistory.swift:47-50`, `85-95`
  - Helper certo: `Clipboard/ClipboardCore.swift:133-174` (`PrivateFile`)
- **What:** Estes três ficheiros são gravados com `JSONEncoder().encode().write(.atomic)` e não com o `PrivateFile`, que aplica 0600 e os põe fora do Time Machine.
- **Why:** O histórico dos agentes tem nomes de projetos e títulos de sessões. Fica legível para outros utilizadores do Mac e vai para as cópias de segurança, ao contrário dos dados do Clipboard e do tempo por app.
- **Action:** Passar os três para `PrivateFile.load/save(backup: false)`. Ver §9.6.
- **Severity:** Medium

### 6.6 As imagens do Clipboard entram nos backups e ficam depois de expirar
> **Corrigido (2026-11-27):** a pasta das imagens fica fora das cópias de segurança e as imagens órfãs saem sempre que o histórico é gravado.
- **Location:** `Clipboard/ClipboardStore.swift:153-168`, `182-187`; `Clipboard/ClipboardCore.swift:72-92`
- **What:** O `clipboard.json` está fora das cópias de segurança, mas a pasta `clipboard-images` não está. As imagens de itens que expiram pelo caminho do texto (`adding()`) ficam no disco, porque `removeOrphanImages()` só corre ao copiar imagem, remover, limpar e arrancar.
- **Why:** Capturas copiadas, que podem ser sensíveis, vão para o Time Machine e ficam para lá dos 7 dias de retenção.
- **Action:** Pôr `isExcludedFromBackup` na pasta e chamar `removeOrphanImages()` sempre que a poda retira uma imagem.
- **Severity:** Low

### 6.7 O Colar rápido envia ⌘V para qualquer app que esteja à frente
> **Corrigido (2026-11-27):** só envia ⌘V quando a app certa está à frente (até ~1 s), e desiste se não estiver.
- **Location:** `Clipboard/QuickPaste.swift:25-44`
- **What:** Depois de `app.activate()` espera 0,18 s fixos e envia ⌘V sem confirmar que a `previousApp` é mesmo a da frente.
- **Why:** Se a ativação for lenta ou outra app ganhar o foco, o conteúdo (por exemplo um snippet sensível) é colado na app errada, como uma janela de chat.
- **Action:** Antes de enviar, confirmar que `frontmostApplication?.processIdentifier` é o da app pretendida (esperar um pouco e desistir se não for).
- **Severity:** Medium

### 6.8 Os comandos `agentstats://` com efeitos podem ser disparados por qualquer página
> **Corrigido (2026-11-27):** no máximo um comando com efeitos a cada 3 s.
- **Location:** `App/URLCommands.swift:39-45`, `76-81`; `Tools/Quick/QuickToggles.swift:59-67`
- **What:** Um link pode, sem confirmação, esconder os ícones da secretária (`defaults write` mais `killall Finder`), mudar o modo escuro, reescrever o Clipboard (`usage/copy`) e mover janelas.
- **Why:** Uma página ou documento pode reiniciar o Finder repetidamente ou estragar o Clipboard do utilizador.
- **Action:** Limitar a frequência, ou pedir confirmação para os comandos com efeitos (reiniciar o Finder, Clipboard) quando a app não está à frente.
- **Severity:** Low

### 6.9 A exportação de definições inclui o PID e o ficheiro da gravação
> **Estado (2026-11-27):** Corrigido.
- **Location:** `Agents/Usage/UsageReports.swift:112-116`; `Capture/CaptureStore.swift:31-34`, `244-258`
- **What:** O prefixo `capture.` apanha `capture.recording.pid` e `capture.recording.file`. No arranque, `stopOrphan()` usa estes valores, embora confirme que o processo é o `screencapture` com esse ficheiro.
- **Why:** O estado interno vai para os ficheiros exportados, e um ficheiro importado pode levar a app a mandar SIGINT a um `screencapture` que coincida.
- **Action:** Juntar as duas chaves ao `SettingsTransfer.excluded`.
- **Severity:** Low

### 6.10 Os tempos limite só matam o filho direto
> **Corrigido (2026-11-27):** `ProcessTree.signal` manda o sinal aos descendentes e depois ao processo.
- **Location:** `Tools/ToolRunner.swift:56-66`; `System/Rules.swift:136-139`
- **What:** O `terminate()` e o `SIGKILL` só chegam ao processo imediato. Os comandos das regras correm como `/bin/zsh -lc cmd`, por isso o que o zsh lança fica órfão e a correr.
- **Why:** Um comando de regra encravado, um filho do brew ou um `du` continuam a correr depois do tempo limite, e acumulam-se se um gatilho oscilar (ecrãs a ligar e desligar).
- **Action:** Arrancar o filho num grupo de processos próprio e matar o grupo inteiro. Considerar um intervalo mínimo entre disparos da mesma regra.
- **Severity:** Low

### 6.11 SQL do OpenCode montado por interpolação
> **Corrigido (2026-11-27):** `SQLiteRead.query(bind:)` com `sqlite3_bind_text`.
- **Location:** `Agents/Readers/MoreAgentsReaders.swift:287`, `294`; `Agents/Usage/UsageTracker.swift:186`
- **What:** O ID da sessão é posto no SQL com o escape manual `'` → `''`.
- **Why:** Não é explorável tal como está, mas é um padrão que se parte facilmente, e lê a base de dados de outra app.
- **Action:** Usar `sqlite3_bind_text` e `sqlite3_bind_int64` com marcadores `?` no `SQLiteRead.query`.
- **Severity:** Low

### 6.12 Ficheiros grandes vai para o Lixo pelo caminho sem confirmar o que lá está
> **Corrigido (2026-11-27):** compara inode e data de modificação antes de mover para o Lixo.
- **Location:** `Tools/Files/LargeFilesTool.swift:104-114`
- **What:** `trash(_:)` move o que estiver agora em `f.path`. Ao contrário do Desinstalar e da Limpeza, não volta a comparar o inode, o tamanho ou a data da análise.
- **Why:** Um ficheiro substituído depois da análise vai para o Lixo sem o utilizador o ter visto. Recupera-se, mas é inconsistente com as outras ferramentas destrutivas.
- **Action:** Guardar a `UninstallRules.Signature` na análise e compará-la antes do `trashItem`.
- **Severity:** Low

---

## 7. Desempenho

### 7.1 Muito trabalho no disco e no SQLite a cada poucos segundos
> **Corrigido em parte (2026-11-27):** a ordenação lê a data de criação uma vez por ficheiro, o título dado à mão só se relê quando o ficheiro muda, e o OpenCode usa uma só consulta para as últimas mensagens. Fica por fazer: a leitura incremental do uso do OpenCode (as mensagens podem ser reescritas enquanto correm, e ler só as novas dava contas erradas) e a cache da lista de pastas.
- **Location:**
  - `Agents/Usage/UsageTracker.swift:149`, `178-206`
  - `Agents/Readers/AgentReader.swift:201-217`, `296-301`
  - `Agents/Readers/MoreAgentsReaders.swift:284-303`
  - `Agents/Readers/CodexReader.swift:37-38`
- **What:**
  - `claudeFiles` ordena chamando `created()` dentro do comparador: são O(n log n) chamadas `stat` de 10 em 10 s.
  - Cada volta lista todas as pastas `~/.claude/projects/*` e faz `stat` a cada `.jsonl`.
  - O `custom-title.json` é relido para cada sessão.
  - O OpenCode abre a base de dados 1+N vezes por volta e relê 7 dias de mensagens sempre que o WAL muda.
- **Why:** O custo de CPU e de disco cresce com o histórico e corre de 2 em 2 ou de 5 em 5 s, mesmo com o painel fechado.
- **Action:**
  - Calcular as datas de criação uma só vez antes de ordenar.
  - Guardar a lista de pastas em cache pela data de modificação da pasta.
  - Guardar os títulos em cache pela data do ficheiro.
  - Usar uma ligação SQLite por volta e ler só o que é novo.
- **Severity:** Medium

### 7.2 O estado do `UsageTracker` e as caches dos leitores crescem sem limite
> **Corrigido (2026-11-27):** o `UsageTracker` poda os ficheiros fora da semana, e as caches dos leitores usam `FileCache`, que tira as entradas sem uso há 10 minutos.
- **Location:** `Agents/Usage/UsageTracker.swift:71-74`, `263-270`, `336-341`. Caches: `AgentReader.tailCache` e `titleCache`, `CopilotReader.headCache`, `CursorReader.titleCache`, `CodexReader.tailCache`.
- **What:** `files[path]` (com um conjunto `seenIDs` em cada um) e `claudeOwner` ganham uma entrada por cada transcript e mensagem alguma vez vistos. Nada é removido quando um ficheiro sai da janela de 7 dias.
- **Why:** Numa app de barra de menus ligada durante semanas, a memória cresce sempre.
- **Action:** No fim de cada `update()`, retirar as entradas dos caminhos que já não estão na lista, e podar as caches dos leitores aos caminhos vistos nessa volta.
- **Severity:** Medium

### 7.3 As imagens do Clipboard são descodificadas na main thread, só com um limite de tamanho comprimido
> **Corrigido (2026-11-27):** limite de 40 MP visto antes de descodificar, e a conversão corre fora do main thread.
- **Location:** `Clipboard/ClipboardStore.swift:110-116`, `153-168`
- **What:** `keepImage` corre na verificação de 0,75 s na main thread e descodifica e recodifica PNG/TIFF com `NSBitmapImageRep`. O único limite é `raw.count <= 15 MB`, que não limita o número de píxeis.
- **Why:** Um PNG muito comprimível com dimensões enormes, ou só uma captura Retina grande, provoca um pico de memória e congela a interface durante a codificação.
- **Action:** Ler as dimensões com `CGImageSourceCopyPropertiesAtIndex` antes de descodificar, limitar largura × altura, e fazer a conversão fora do main actor.
- **Severity:** Medium

### 7.4 O criador de GIF guarda todas as imagens em memória até ao fim
> **Corrigido (2026-11-27):** `GifMaker.frameSize` limita a altura das imagens para o total caber em ~400 MB (não foi medido com um vídeo real).
- **Location:** `Tools/Images/GifMaker.swift:47-63`
- **What:** Até 300 imagens (30 s × 10 fps, 720 px de largura) vão para um só `CGImageDestination`, que as guarda até ao `Finalize`.
- **Why:** Provavelmente várias centenas de MB de pico num vídeo longo ou alto. Não foi medido.
- **Action:** Medir primeiro. Se se confirmar, baixar automaticamente a resolução ou os fps para vídeos longos.
- **Severity:** Low

### 7.5 Formatters criados a cada chamada
> **Corrigido (2026-11-27):** `Fmt.hm`, `DayKey`, `ISODate` e `FormatStyle` no lugar dos formatters criados a cada chamada.
- **Location:**
  - `Shared/Charts.swift:102`
  - `Agents/Views/TodayUsage.swift:122` (uma vez por barra, a cada render)
  - `Agents/Views/PlanLimitsCard.swift:68`
  - `Shared/Format.swift:51` (`Fmt.usd`)
  - `Time/TimeCore.swift:81`
  - `System/BatteryHistory.swift:52`, `59`
  - `Agents/Usage/PlanLimits.swift:116`
  - `Agents/Readers/MoreAgentsReaders.swift:50`
- **What:** São criados `DateFormatter`, `NumberFormatter` e `ISO8601DateFormatter` novos em funções chamadas dentro de `body` ou a cada amostra.
- **Why:** Os formatters são caros de criar. O efeito aqui é pequeno, mas evitável.
- **Action:** Usar formatters estáticos (ou `FormatStyle`), em conjunto com os helpers de §5.9 e §9.16.
- **Severity:** Low

---

## 8. SwiftUI / UI

### 8.1 O `UnresponsiveStore` republica de 10 em 10 s e invalida o painel inteiro
> **Estado (2026-11-27):** Corrigido.
- **Location:** `System/Unresponsive.swift:71-76`; `App/PanelView.swift:39`
- **What:** `apply` atribui sempre `stuck = …`, mesmo quando o valor não mudou, e o `PanelView` observa o store como `ObservableObject`.
- **Why:** O `objectWillChange` dispara de 10 em 10 s e recalcula o `body` da raiz do painel e de tudo o que está por baixo, enquanto o painel está aberto.
- **Action:** Só atribuir quando o valor muda (como já faz `AppMixer.rebuild`), ou passar o store para `@Observable`.
- **Severity:** Medium

### 8.2 O `TimerStore` publica `now` a cada segundo e redesenha o separador Tempo todo
> **Corrigido (2026-11-27):** `now` deixou de ser publicado; a contagem tem o seu próprio `TimelineView`.
- **Location:** `Time/TimeStore.swift:13`, `63-72`; `Time/TimeView.swift:4`
- **What:** `@Published now` muda a cada segundo, por isso o `body` inteiro do `TimeView` (relógio mundial e pesquisa incluídos) é recalculado enquanto um temporizador corre.
- **Why:** São redesenhos desnecessários.
- **Action:** Passar o `TimerStore` para `@Observable`, ou isolar a contagem num `TimelineView` próprio.
- **Severity:** Low

### 8.3 A linha do histórico de atividade abre com toque mas não se anuncia como botão
> **Corrigido (2026-11-27):** `.isButton` e `accessibilityAction`.
- **Location:** `Agents/Views/ActivityHistoryRow.swift:41-51`
- **What:** Usa `.onTapGesture` com `.accessibilityElement(children: .combine)`, mas sem `.isButton` nem `accessibilityAction`. O `SessionCard.swift:108-124` faz isto bem.
- **Why:** O VoiceOver não diz que a linha se pode abrir, e o teclado não chega lá.
- **Action:** Usar um `Button` com `.buttonStyle(.plain)`, ou juntar `.accessibilityAddTraits(.isButton)` e `accessibilityAction`, como no `SessionCard`.
- **Severity:** Low

### 8.4 As animações ignoram "Reduzir movimento"
> _REMOVED: falso positivo. Todas as animações passam por `Motion.ease`, que já devolve nil com "Reduzir movimento" ligado (`Shared/DesignSystem.swift`)._
- **Location:** 11 usos de `withAnimation` e `.animation(`, e 0 usos de `accessibilityReduceMotion`, em `Sources/AgentStats`.
- **What:** Nenhuma animação verifica a preferência do sistema.
- **Why:** As animações são pequenas, mas quem ativa "Reduzir movimento" espera que a app o respeite.
- **Action:** Ler `@Environment(\.accessibilityReduceMotion)` nas vistas com animação e usar uma transição simples ou nenhuma.
- **Severity:** Low

### 8.5 Tamanhos de letra fixos
> **Estado (2026-11-27):** Corrigido nos textos do painel (Tempo, Agentes, Hoje). Ficam fixos de propósito a barra de menus e o ecrã de limpeza do teclado.
- **Location:** 17 usos de `.font(.system(size:))`, por exemplo `Time/TimeView.swift:109`.
- **What:** Os tamanhos não seguem o tipo dinâmico. A app tem a sua própria escala (`TextSize`), mas estes 17 sítios não a usam todos.
- **Why:** Com a escala de texto da app aumentada, estes textos ficam do mesmo tamanho.
- **Action:** Verificar cada um e passá-lo pela escala `TextSize`, ou documentar porque fica fixo (números grandes do relógio, por exemplo).
- **Severity:** Low

### 8.6 `SettingsView` com um `body` enorme
> **Estado (2026-11-27):** Ver §9.17.
- **Location:** `Settings/SettingsView.swift:1-719`
- **What:** Uma só estrutura tem 35 propriedades `@AppStorage`/`@StateObject` e todas as secções.
- **Why:** Qualquer mudança recalcula o `body` inteiro, e é difícil de rever.
- **Action:** Ver a divisão proposta em §9.17.
- **Severity:** Low

---

## 9. Código morto / duplicação / refatoração

Não foram encontrados blocos `#if false`, código comentado, nem marcadores TODO/FIXME/HACK/XXX. A remoção do "Não incomodar" ficou limpa (só sobra o "Foco" do Pomodoro, que é legítimo), e todas as notificações passam pelo `Notify.add`.

### 9.1 Código morto a apagar
> **Estado (2026-11-27):** Corrigido; os invólucros só para testes ficam em `#if DEBUG`.
- `App/MenuBarLabel.swift:24-30`: `private func cell(_:_:)` nunca é chamado.
- `App/MenuBarLabel.swift:3-5`: imports `ServiceManagement`, `Combine` e `UserNotifications` sem uso. `Combine` também não é usado em `App/App.swift:4` e `System/KeepAwake.swift`.
- `System/Readers/TemperatureReader.swift:72`: `isAvailable` sem referências.
- `Tools/Windows/WindowLayout.swift:36-56`: 17 símbolos definidos e só `.nextDisplay` usado (`WindowsView.swift:80`).
- `Tools/Quick/QuickToggles.swift:94`: `store.iconsShown ? "Ícones" : "Ícones"` tem os dois ramos iguais.
- `Agents/Usage/UsageTracker.swift:211-231`: `copilotUsage(ofFile:)` só é usado nos testes, e os outros invólucros "usados nos testes" vão no binário de produção.
- **Severity:** Low (algumas dezenas de linhas)

### 9.2 Leitura do fim dos transcripts com cache repetida em 4 leitores
> **Corrigido (2026-11-27):** `FileCache` e `TextTail.lines` em todos os leitores.
- **Locations:**
  - `Agents/Readers/AgentReader.swift:328-343`
  - `Agents/Readers/CodexReader.swift:180-193`
  - `Agents/Readers/AntigravityReader.swift:192-207`
  - `Agents/Readers/OtherAIsReader.swift:115-130`
  - Helper que já existe: `Agents/Readers/MoreAgentsReaders.swift:9-33` (`TextTail.lines`)
- **What:** Os quatro repetem os mesmos passos: cache por data e tamanho, `seek`, ler até ao fim, partir por linhas e deitar fora a linha incompleta. Só muda o tamanho do bloco lido.
- **Action:** Criar um `TailCache<Info>` genérico sobre o `TextTail.lines` e usá-lo nos quatro.
- **Severity:** Medium

### 9.3 Dois executores de processos: `Sys.run` e `ToolRunner`
> **Corrigido (2026-11-27):** `ProcessRun.sync` substitui o `Sys.run` sem prazo; o `ToolRunner` continua para os comandos das ferramentas (saída para ficheiros). O executor do `screencapture` no `CaptureStore` fica, porque é uma gravação longa que se interrompe com sinais.
- **Locations:** `System/Readers/Sys.swift:33-47` e `Tools/ToolRunner.swift:19-73`. Também `Capture/ScreenTools.swift:87` usa o `ToolRunner`, enquanto `Capture/CaptureStore.swift:115-130` tem o seu próprio executor para o mesmo `screencapture`.
- **What:** Há várias maneiras de correr um processo, e o `Sys.run` não tem tempo limite.
- **Action:** Dar ao `ToolRunner` uma variante síncrona com prazo e apagar o `Sys.run`. Juntar também os dois executores do `screencapture`. Ver §3.5.
- **Severity:** Medium

### 9.4 Seis implementações da chave de dia
> **Estado (2026-11-27):** Corrigido (`DayKey`).
- **Locations:** ver §5.9.
- **Action:** Um `DayKey` em `Shared/`.
- **Severity:** Medium

### 9.5 Três ciclos `getifaddrs` para endereços IPv4
> **Corrigido (2026-11-27):** `Interfaces.ipv4()`.
- **Locations:** `Tools/Share/FileDrop.swift:57-75`; `System/NetworkExtras.swift:45-62`; `System/Readers/NetworkReader.swift:19-41`
- **What:** São três cópias de código com ponteiros inseguros, e já diferem entre si: só o `FileDrop` ignora o loopback.
- **Action:** Criar `Interfaces.ipv4()` em `Shared/` e construir os três em cima dele.
- **Severity:** Medium

### 9.6 Persistência JSON: três stores não usam o `PrivateFile`, e a pasta de suporte é montada em 7 sítios
> **Corrigido (2026-11-27):** `AppPaths.support` e o `PrivateFile` em `Shared/Storage.swift`.
- **Locations:**
  - Stores: `Agents/Usage/AgentActivityHistory.swift:117-135`, `System/History24h.swift:47-69`, `System/BatteryHistory.swift:47-50`, `85-95`.
  - Pasta `Application Support/AgentStats` montada também em `Time/AppUsage.swift:44`, `System/DiskStorage.swift:142`, `Clipboard/QuickNotes.swift:6` e `Clipboard/ClipboardStore.swift:19`.
- **Action:** Usar o `PrivateFile` nos três stores (§6.5), criar `AppPaths.support(_:)` e mover o `PrivateFile` de `Clipboard/` para `Shared/`.
- **Severity:** Medium

### 9.7 Chaves e valores por omissão das preferências da barra de menus repetidos em 4 ficheiros
> **Corrigido (2026-11-27):** `MenuBarMetric` e `PrefKey`; `flag` e `on` saíram.
- **Locations:**
  - Chaves da barra de menus: `Settings/SettingsView.swift:6-13`, `689-701`; `App/MenuBarLabel.swift:9-15`; `App/MenuBarDrawer.swift:46-54`; `App/StatusController.swift:108`, `118-137`.
  - `"appearance.accentHex"`: `SettingsView.swift:21`, `SettingsWindow.swift:6`, `PanelView.swift:43`.
  - `"panel.showLimits"`: `SettingsView.swift:15`, `AgentsView.swift:8`, `Monitor.swift:183`.
  - `"tools.section"`: `ToolsView.swift:47`, `DiskStorage.swift:303`, `ShareView.swift:91`.
- **What:** As chaves `bar.*`, os valores por omissão e a ordem `"agents,cpu,ram,gpu,temp,net,battery"` estão escritos como literais em cada ficheiro. `MenuBarDrawer.flag` e `StatusController.on` são cópias do `Pref.bool`.
- **Why:** Mudar um valor por omissão num só sítio faz o ícone, a pré-visualização e as Definições discordarem.
- **Action:** Criar um enum `MenuBarMetric` (id, chave, valor por omissão, ícone, título), usar constantes nomeadas para as outras chaves, e substituir `flag` e `on` pelo `Pref.bool`.
- **Severity:** Medium

### 9.8 Zona de largar ficheiros duplicada
> **Corrigido (2026-11-27):** `DropZone` em `Shared/Components.swift`.
- **Locations:** `Tools/Images/ImagesView.swift:126-148`; `Tools/Share/ShareView.swift:137-155`
- **Action:** Extrair um `DropZone(symbol:text:busy:onPick:onDrop:)` para `Shared/`.
- **Severity:** Low

### 9.9 Apresentação do código QR repetida 3 vezes
> **Corrigido (2026-11-27):** `QRImage`.
- **Locations:** `Capture/QRMaker.swift:48-49`; `Tools/Share/ShareView.swift:159-162`, `207-213`
- **Action:** Criar uma `QRCodeView(text:size:)` junto ao `QRMaker`.
- **Severity:** Low

### 9.10 Seletor segmentado construído 3 vezes, com aspetos ligeiramente diferentes
> **Corrigido (2026-11-27):** `segmentFill` e `segmentTrack` no `DesignSystem` (o aspeto de cada um ficou igual).
- **Locations:** `App/PanelView.swift:187-220`; `Tools/ToolsView.swift:52-60`, `81-99`; `Settings/SettingsView.swift:98-117`
- **Action:** Criar um `SegmentedBar` em `Shared/DesignSystem.swift`.
- **Severity:** Low

### 9.11 Botões em mosaico e em pílula repetidos
> **Corrigido (2026-11-27):** `raisedTile(height:radius:)`.
- **Locations:**
  - `Tools/Quick/QuickToggles.swift:109-123`
  - `Capture/CaptureView.swift:169-184`
  - `Tools/Windows/WindowsView.swift:57-75`
  - O fundo `fill(DS.raised)` repete-se em mais 8 sítios: `PanelView.swift:318`, `BrewView.swift:51`, `SessionCard.swift:13` e `83`, `AgentsView.swift:116`, `OtherAgentRow.swift:24`, `QuickNotes.swift:66`, `ClipboardView.swift:253`.
- **Action:** Criar um `ButtonStyle` `RaisedTileStyle(height:radius:)` e um modificador `.raisedBackground(radius:)` no `DesignSystem.swift`.
- **Severity:** Low

### 9.12 Código repetido para abrir e gravar ficheiros (8 cópias) e erros de gravação ignorados
> **Corrigido (2026-11-27):** `FilePanels`, e as gravações que falham mostram um aviso.
- **Locations:**
  - `Settings/SettingsFiles.swift:8-12`, `22-26`, `35-40`
  - `Capture/QRMaker.swift:79-84`
  - `Tools/Images/ImagesView.swift:37-42`, `61-65`
  - `Tools/Share/ShareView.swift:47-51`
  - `Clipboard/ClipboardView.swift:269-275`
- **What:** Cada sítio repete criar o painel, `activate`, `runModal`. O `exportCSV` e o `saveImage` ignoram erros de gravação sem dizer nada.
- **Action:** Criar `FilePanels.save` e `FilePanels.open`, que resolvem também §3.10 e §4.1, e mostrar os erros de gravação como já faz o `QRMaker`.
- **Severity:** Low

### 9.13 "Mostrar no Finder" e os URLs das Definições do Sistema espalhados
> **Corrigido (2026-11-27):** `Finder.reveal` e `SystemSettings.open`.
- **Locations:**
  - Mostrar no Finder: `Tools/Images/ImagesView.swift:68`, `Agents/AgentActions.swift:27-29`, `Capture/CaptureView.swift:154`, `Tools/Disks/DisksView.swift:44`, `Tools/Files/LargeFilesTool.swift:117`, `Tools/Startup/StartupTool.swift:139`.
  - Definições do Sistema: `Capture/CaptureView.swift:33`, `194-196`; `Audio/MixerView.swift:149`; `Clipboard/ClipboardView.swift:116`; `System/Readers/WiFiReader.swift:72`; `Tools/Startup/StartupTool.swift:143`.
- **Action:** Criar `Finder.reveal(_:)` e `SystemSettings.open(.screenCapture / .location / …)`.
- **Severity:** Low

### 9.14 Pedido de permissão de Acessibilidade repetido 3 vezes
> **Corrigido em parte (2026-11-27):** `AX.ensureTrusted` nos três sítios. As leituras de atributos ficam onde estão: as do `WindowMover` confirmam o tipo CF, as do `AppShortcuts` são genéricas e privadas.
- **Locations:** `Tools/Windows/WindowMover.swift:12-16`; `Tools/Shortcuts/ShortcutsOverlay.swift:60-61`; `Tools/Cleanup/KeyboardCleaning.swift:212-214`. A leitura genérica de atributos está em `Tools/Shortcuts/AppShortcuts.swift:77-82`, e o `WindowMover.swift:44-66` faz as mesmas leituras à mão.
- **Action:** Criar `Shared/AX.swift` com `ensureTrusted`, `attribute<T>` e `frame(of:)`.
- **Severity:** Low

### 9.15 Três formatadores de relógio mm:ss
> **Corrigido (2026-11-27):** `Fmt.clock`.
- **Locations:** `Capture/CaptureCore.swift:63-68`; `Time/TimeCore.swift:40-43`; `Tools/Cleanup/KeyboardCleaningView.swift:136-139`. Além disso, o `ShareView.swift:166` usa o relógio do Pomodoro.
- **Action:** Criar `Fmt.clock(_:)`.
- **Severity:** Low

### 9.16 Formatter ISO 8601 configurado em 6 sítios
> **Corrigido (2026-11-27):** `ISODate`.
- **Locations:** `Agents/Readers/AgentReader.swift:90-94`; `CodexReader.swift:29-33`; `AntigravityReader.swift:30-40`; `Agents/Usage/UsageTracker.swift:77-81`; `MoreAgentsReaders.swift:43-52`; `Agents/Usage/PlanLimits.swift:115-121`
- **What:** O alternativo para datas sem frações de segundo está escrito de três maneiras diferentes, e alguns leitores nem o têm.
- **Action:** Criar um `ISODate.parse(_:)` (com frações, e depois sem) em `Shared/`.
- **Severity:** Low

### 9.17 Ficheiros grandes (>400 linhas)
> **Corrigido em parte (2026-11-27):** `AgentModels.swift`, `Sequence+Unique.swift`, `TemperatureCard.swift`, `Monitor+Alerts.swift` (Monitor 583 → 439 linhas), `SettingsView+Helpers.swift` e `SettingsProfiles.swift` (SettingsView 718 → 529); o `SettingsSnapshot` passou a incluir `panel.showLimits`. Fica por fazer: separar cada secção das Definições e os painéis de detalhe do Sistema em vistas próprias.
- **`Settings/SettingsView.swift` (719):** dividir por secção (`SettingsGeneral`, `SettingsMenuBar`, `SettingsPanel`, `SettingsAppearance`, `SettingsAlerts`), cada uma com o seu `@AppStorage`. Mover os perfis (`SettingsSnapshot`, 564-607 e 674-704) para `SettingsProfiles.swift` e as linhas comuns (530-663) para `SettingsRows.swift`. Nota: `SettingsSnapshot` não inclui `panel.showLimits`. Severity: Medium.
- **`System/Monitor.swift` (542):** extensões `Monitor+Alerts` (476-541), `Monitor+Notifications` (334-474, com um helper que substitui os seis blocos de notificação repetidos), `Monitor+ClaudeLimits` (192-227) e `MonitorSettings` para as cerca de 25 propriedades de preferência. Severity: Medium.
- **`System/SystemView.swift` (528):** mover `TemperatureCard` (487-528) para um ficheiro próprio e os painéis de rede, disco, memória e acessórios para `View`s separadas. Severity: Low.
- **`Agents/Readers/AgentReader.swift` (455):** mover os modelos partilhados (3-72) para `AgentModels.swift`, a deteção de processos (96-197) para `AgentProcessDetector.swift` e `Sequence.uniqued` (449-455) para `Shared/`. Severity: Low.

### 9.18 TODOs / FIXMEs por resolver
_Nenhum encontrado._

### 9.19 Constantes mágicas
> **Corrigido (2026-11-27):** `AgentSession.recentWindow`, `staleAfter`, `ShareStore.passwordLifetime` (e os minutos interpolados nos textos), `Monitor.claudeRetry(after:)`, e as constantes do servidor de partilha. Os tempos limite do `ToolRunner` ficam escritos junto de cada comando, onde se leem melhor.
- `recentWindow = 20 * 60` repetido em `AgentReader.swift:201`, `CodexReader.swift:35`, `AntigravityReader.swift:42` e `MoreAgentsReaders.swift:72`, `178`, `284`.
- Os 10 minutos da partilha estão em `FileDrop.lifetime` (`FileDrop.swift:8`), mas também no "esquecer a password" (`ShareView.swift:74`) e escritos no texto da interface (`ShareView.swift:64`, `132`, `215`).
- A espera entre tentativas dos limites do Claude (`6 * 3600`, `15 * 60`, `10 * 60`) está em `System/Monitor.swift:212`.
- O limiar de sessão parada (`10 * 60`) está em `MoreAgentsReaders.swift:38`.
- Os tempos limite do `ToolRunner` são literais: 10 s em 7 sítios, 15 s em 5, e ainda 20, 30, 120…
- **Action:** Dar-lhes nome uma vez e interpolar o valor nos textos da interface.
- **Severity:** Low

### 9.20 Entradas antigas no `Localizable.strings`
> **Corrigido (2026-11-27):** 21 chaves apagadas; `Scripts/check-translations.sh` lista também as traduções sem uso e as frases do `L("…")` sem tradução.
- **Location:** `Resources/en.lproj/Localizable.strings` (raiz do repositório), por exemplo nas linhas 602, 620, 684 e 941.
- **What:** Cerca de 20 chaves já não correspondem a nenhum texto no código. São sobretudo pedaços antigos com espaço no fim ("Trabalhou ", "Renova ", "às "…), substituídos por chaves interpoladas, e a nota antiga do Wi-Fi na linha 941.
- **Action:** Apagá-las e juntar ao `Scripts/check-translations.sh` a verificação inversa (chaves sem uso).
- **Severity:** Low

### 9.21 Diagnósticos com `print()` incluídos no binário de produção
> **Estado (2026-11-27):** Mantido na versão de produção de propósito (o README documenta `--dump` e `--bench`); movido para `App/Diagnostics.swift`.
- **Location:** `App/App.swift:28-29`, `50`, `57`, `79-81`, `95-119`; `App/Snapshot.swift:43`
- **What:** Todos os `print` só correm com uma opção na linha de comandos (`--dump`, `--bench`, `--smoke`, `--snapshot`), por isso não há saída solta. Mas `--dump` e `--bench` (cerca de 70 linhas) vão no binário de produção, e `--dump` imprime títulos de sessões e pastas.
- **Action:** Se o CI não usa `--bench` nem `--dump` na versão de produção, metê-los em `#if DEBUG` e num `App/Diagnostics.swift`. Manter `--hook` e `--smoke`, que o CI usa.
- **Severity:** Low

### 9.22 `Sys.number` é um invólucro trivial
> **Corrigido (2026-11-27):** `as? NSNumber` direto, e `fixedCString` em `Sys`.
- **Location:** `System/Readers/Sys.swift:60`. Usado em `BatteryReader.swift:8-43`, `DiskReader.swift:30-31` e `GPUReader.swift:15`.
- **What:** `Sys.number` só faz `as? NSNumber`. O `ProcessReader.fixedCString` (`ProcessReader.swift:135-137`) também repete o `Sys.string`.
- **Action:** Usar `as? NSNumber` diretamente, ou transformá-lo num acessor tipado que se justifique. Juntar o `fixedCString` ao `Sys`.
- **Severity:** Low

---

## 10. Recomendações transversais

1. **Um único executor de processos, com prazo, cancelamento e grupo de processos.** Isto resolve de uma vez §3.1, §3.3, §3.4, §3.5, §6.10 e §9.3. Deve esperar pelo fim do processo com `terminationHandler`, ler os pipes de forma assíncrona, matar o grupo de processos inteiro no fim do prazo e correr fora do pool cooperativo.
2. **O servidor de partilha precisa de um dono claro do seu ciclo de vida.** §5.3, §5.4, §5.10, §6.1 e §6.2 vêm todos de um servidor que não sabe que ligações tem nem quem é "o atual". O padrão é: uma geração por servidor, um conjunto de ligações confinado à fila, prazos, e um `close()` que fecha tudo e retoma o que está pendente.
3. **Os dados de "estado" e de "preferência" precisam de uma só fonte de verdade.** §5.6 (o `Monitor` guarda cópias das preferências), §9.7 (chaves e valores por omissão repetidos) e §6.9 (estado interno com prefixo de preferência) vêm do mesmo sítio. A proposta é um catálogo central de chaves com valores por omissão, e prefixos diferentes para estado interno e para preferências.
4. **Tudo o que a app grava em disco deve usar o `PrivateFile`.** §6.5, §6.6 e §9.6: 0600 e fora do Time Machine por omissão, e só fora disso quando houver uma razão escrita.
5. **Helpers comuns de datas.** `DayKey`, `ISODate` e `Fmt.clock` (§5.9, §7.5, §9.15, §9.16) eliminam formatters criados a cada chamada e uma classe inteira de bugs de fuso horário e de calendário.
6. **Os pontos de entrada externos são superfícies de ataque.** Os URLs `agentstats://` (§5.1, §6.8), a rede local (§6.1, §6.2) e os ficheiros de outras apps (§5.5, §6.11) devem ser tratados como dados não confiáveis: sem interrupções fatais, com limites e com confirmação para efeitos visíveis. Vale a pena juntar testes com entradas malformadas para cada um.
7. **Os stores que publicam com frequência devem passar a `@Observable`.** §8.1 e §8.2. Os outros podem ficar `ObservableObject` sem custo real.

---

## 11. O que NÃO foi auditado

- `.build/` e tudo o que é gerado.
- `Tests/`: só uma leitura rápida para perceber a intenção, sem análise de cobertura.
- A correção dos preços e das contas de tokens e custo de cada modelo (`Agents/Usage/*`): verificou-se a lógica, não os valores.
- O formato real dos ficheiros de cada agente (Claude, Codex, Antigravity, OpenCode, Cursor, Copilot…), que muda com as versões deles.
- `Scripts/`, `build.sh`, `test.sh`, a assinatura, o CI (`.github/workflows`), o cask do Homebrew e `docs/`.
- A qualidade das traduções (`Resources/en.lproj`): só se assinalaram chaves sem uso.
- A experiência real com VoiceOver e com o teclado: só se leu o código. Não houve testes com o VoiceOver.
- Medição de desempenho com Instruments: os pontos de §7 são potenciais, não medidos (exceto o que já tinha sido medido antes: cerca de 1% de CPU e 99–147 MB em uso normal).
- O comportamento em macOS 14 e 15 (a app só foi usada no macOS 27).
- A bateria dos acessórios Bluetooth com aparelhos reais.

---

## 12. Verificação

Cada ponto Critical e High foi confirmado abrindo as linhas citadas:

- **§5.1** — abrir `Sources/AgentStats/App/URLCommands.swift`, linhas 20-21. `Dictionary(uniqueKeysWithValues:)` sobre os `queryItems` com `name.lowercased()`. O inicializador interrompe a execução com chaves repetidas, e `parse` corre para qualquer URL com o esquema `agentstats`.
- **§5.2** — abrir `Sources/AgentStats/Agents/Readers/HookEvents.swift`, linha 20 (`isActive` é só `fileExists` da pasta), depois `Agents/Readers/AgentReader.swift`, linhas 266-273 (com `hookActive`, sem evento recente, devolve `nil` antes do plano B), e `Agents/ClaudeHook.swift`, linhas 127-150 (`set(false)` nunca apaga a pasta).
- **§5.3** — abrir `Sources/AgentStats/Tools/Share/ShareView.swift`, linhas 27-44 (`stop()` e depois `self.server = server`) e 56-57 (`ended` faz `server = nil` sem comparar). Em `Tools/Share/FileDrop.swift`, linha 135, `stop()` é assíncrono na fila do servidor, por isso o fim do antigo chega depois de o novo estar atribuído.
- **§3.1** — abrir `Sources/AgentStats/Tools/ToolRunner.swift`, linhas 58-66. `try? await Task.sleep(for: .milliseconds(100))` dentro de `while process.isRunning`. Numa tarefa cancelada, `Task.sleep` lança logo, o `try?` engole o erro e o ciclo não tem pausa.

Se algum ponto não se confirmar ao abrir a linha, diz-me a referência (por exemplo "§6.4") e volto a investigar.
