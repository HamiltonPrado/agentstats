# AgentStats

[Português](README.md) · [English](README.en.md) · [Español](README.es.md) · [Français](README.fr.md)

![CI](https://github.com/HamiltonPrado/agentstats/actions/workflows/ci.yml/badge.svg)
![Dernière version](https://img.shields.io/github/v/release/HamiltonPrado/agentstats?color=blue)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black)
![Swift 6](https://img.shields.io/badge/Swift-6.0-F05138?logo=swift&logoColor=white)

**Agents IA et indicateurs du Mac dans un seul panneau.** AgentStats se trouve dans la barre des menus de macOS et indique ce qui fonctionne, ce qui demande votre attention et l’état des ressources système.

**[Télécharger la dernière version](https://github.com/HamiltonPrado/agentstats/releases/latest)** · [Site web](https://hamiltonprado.github.io/agentstats) · [Signaler un problème](https://github.com/HamiltonPrado/agentstats/issues)

<p align="center">
  <img src="Resources/screenshots/menubar.png" alt="Agents et indicateurs dans la barre des menus" width="600">
</p>

<p align="center">
  <img src="Resources/screenshots/agents-dark.png" alt="Panneau des agents" width="340">
  &nbsp;&nbsp;
  <img src="Resources/screenshots/system-dark.png" alt="Panneau des indicateurs système" width="340">
</p>

## Ce que vous pouvez surveiller

### Agents IA

Consultez les sessions actives, le projet, le modèle, l’utilisation du processeur et de la mémoire, les processus enfants et l’état : en cours, en attente ou en demande d’attention. Filtrez les sessions par état. AgentStats reconnaît Claude Code, Codex, Antigravity, Aider, Goose, Gemini CLI, Cursor Agent, OpenCode et Amp. Cliquez sur une session pour revenir à l’application où elle s’exécute.

### État du Mac

Processeur, mémoire, GPU, températures, réseau, disque et batterie. Le panneau propose des graphiques et un historique sur 24 heures, des alertes configurables et un test manuel de téléchargement, d’envoi et de latence.

### Pour votre flux de travail

- Notifications lorsqu’un agent termine ou a besoin de votre attention.
- Rappels configurables lorsqu’un agent attend toujours votre réponse ou votre approbation.
- Historique par session avec changements d’état, durée observée et utilisation des tokens.
- Utilisation des tokens du jour, par session et par projet, pour Claude Code et Codex.
- Raccourci global configurable pour ouvrir le panneau.
- Réorganisez les indicateurs de la barre des menus et choisissez les sections visibles du panneau.
- Ajustez la densité, le thème et la couleur d’accentuation ; appliquez et enregistrez les réglages dans les profils Travail et Surveillance.
- Indicateurs accessibles par la couleur, la forme et VoiceOver ; respect de l’option « Réduire les animations ».
- Lancement automatique à l’ouverture de session, en option.

Le test de débit utilise les points d’accès publics de Cloudflare et transfère environ **32 Mo par test**. Les mesures peuvent être collectées sous forme agrégée.

## Installation

1. Téléchargez **AgentStats.zip** depuis la [dernière version](https://github.com/HamiltonPrado/agentstats/releases/latest).
2. Décompressez l’archive et déplacez `AgentStats.app` dans le dossier Applications.
3. Ouvrez l’app. Si macOS bloque le premier lancement, allez dans **Réglages Système → Confidentialité et sécurité → Ouvrir quand même**. L’app est signée localement et ne possède pas de signature de développeur Apple.

Vous pouvez aussi installer l’app en ligne de commande avec [GitHub CLI](https://cli.github.com) :

```bash
tmp=$(mktemp -d) && gh release download --repo HamiltonPrado/agentstats --pattern AgentStats.zip --dir "$tmp" && ditto -x -k "$tmp/AgentStats.zip" "$tmp" && { pkill -x AgentStats 2>/dev/null || true; ditto "$tmp/AgentStats.app" /Applications/AgentStats.app && open /Applications/AgentStats.app; }
```

## Contribuer

Nécessite macOS 14 ou une version ultérieure et les outils de ligne de commande Xcode.

```bash
./build.sh
open build/AgentStats.app
```

Pour lancer les tests :

```bash
./test.sh
```

Les contributions sont les bienvenues. Ouvrez une [issue](https://github.com/HamiltonPrado/agentstats/issues) pour signaler un problème ou proposer une amélioration.

## Licence

AgentStats est distribué sous la [licence MIT](LICENSE). Vous pouvez utiliser, modifier et redistribuer le code selon ses conditions.

<details>
<summary>Détails de développement</summary>

### Créer une version

Mettez à jour `VERSION`, puis envoyez un tag portant le même numéro, par exemple :

```bash
git tag v1.15
git push origin v1.15
```

GitHub Actions vérifie la version, exécute les tests, compile l’app et publie `AgentStats.zip` dans la release.

### Diagnostic

- `AgentStats --dump` — indicateurs système et agents détectés.
- `AgentStats --bench` — temps d’exécution des lecteurs.
- `AgentStats --snapshot <dossier>` — génère des captures du panneau au format PNG.
- `AGENTSTATS_DISABLE=icon,temps,procs,sessions,usage,gpu,disk` — désactive des lecteurs pour mesurer les performances.

### Architecture

L’acteur `Sampler` coordonne les lectures et renvoie un échantillon immuable. `Monitor` applique cet échantillon sur l’acteur principal ; les vues SwiftUI n’observent que l’état dont elles ont besoin. Le projet utilise la vérification de concurrence de Swift 6.

</details>
