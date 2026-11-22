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
  <img src="Resources/screenshots/agents-dark.png" alt="Agents, limites et coûts" width="260">
  <img src="Resources/screenshots/system-dark.png" alt="Indicateurs système" width="260">
  <img src="Resources/screenshots/audio-dark.png" alt="Mixeur de volume" width="260">
</p>

<p align="center">
  <img src="Resources/screenshots/clipboard-dark.png" alt="Presse-papiers et extraits" width="260">
  <img src="Resources/screenshots/capture-dark.png" alt="Capture et enregistrement" width="260">
  <img src="Resources/screenshots/tools-dark.png" alt="Outils" width="260">
</p>

<p align="center"><sub>Captures avec des données de démonstration. L’interface est en portugais.</sub></p>

## Ce que vous pouvez surveiller

### Agents IA

- Sessions avec projet, modèle, sous-agents et état : en cours, en attente ou en attente d’approbation. Cliquez sur une session pour revenir à son application.
- Reconnaît Claude Code, Codex, Copilot, Cursor Agent, OpenCode, Antigravity, Aider, Goose, Gemini CLI et Amp. Le détail dépend de ce que chacun enregistre sur le Mac.
- **Limites du forfait** Claude et Codex, avec l’heure de renouvellement.
- **Tokens et coût API estimé** par session, jour et projet pour Claude Code, Codex, Copilot et OpenCode. Le coût n’apparaît que pour les modèles au prix connu et ne correspond pas au prix d’un abonnement.
- Notifications à la fin d’une tâche longue ou quand un agent a besoin de vous, avec rappels s’il attend encore.

### Système et processus

- Processeur, mémoire, GPU, températures, réseau, disque et batterie, avec historique jusqu’à 7 jours et alertes.
- Applications les plus énergivores, processus les plus lourds et dossiers les plus volumineux.
- Test de débit manuel via Cloudflare : environ **32 Mo par test** ; les mesures peuvent être collectées sous forme agrégée.
- Ne contrôle pas les ventilateurs.

### Audio

- Choisissez la sortie et le micro et réglez leur volume.
- **Mixeur par application**, de 0 à 150 % (macOS 14.2+). Il ne modifie que les applications réglées et revient à 100 % à la fermeture d’AgentStats.

### Presse-papiers

- Historique de texte, **désactivé tant que vous ne l’activez pas** : 100 éléments, 7 jours, avec épingles et extraits.
- Ignore ce que les gestionnaires de mots de passe marquent comme secret et les formats connus de clés API. L’historique reste sur ce Mac, **non chiffré**.

### Capture

- Capturez une zone, une fenêtre ou l’écran et enregistrez l’écran entier, avec micro et clics en option. L’enregistrement d’une zone ouvre l’outil de macOS.

### Outils

- **Ports :** affiche ce qui est à l’écoute et arrête vos processus, après confirmation.
- **Homebrew :** met à jour et supprime des paquets.
- **Désinstaller :** place les applications dans la Corbeille, avec les restes choisis.

### À votre mesure

Barre des menus configurable, raccourci global, profils, thème, couleur, largeur, taille du texte, maintien en éveil, lancement automatique et prise en charge de VoiceOver et de « Réduire les animations ».

## Autorisations et confidentialité

| Fonction | Autorisation que macOS peut demander |
| --- | --- |
| Notifications et alertes | Notifications |
| Mixeur par application | Enregistrement de l’audio du système |
| Capture et enregistrement | Enregistrement de l’écran |
| Enregistrer avec le micro | Micro |
| Historique du presse-papiers | Coller depuis d’autres apps (macOS 15.4+) |

Ni compte ni télémétrie. AgentStats lit les journaux des agents sur le Mac et ne les envoie pas. Le réseau ne sert qu’au test de débit, à Homebrew quand vous l’utilisez et à la consultation périodique des limites par votre Claude Code.

L’application n’a pas de Developer ID : **macOS peut redemander ces autorisations après chaque mise à jour**.

## Configuration requise

Mac Apple Silicon avec macOS 14 ou ultérieur. Testée sur macOS 27.2.

## Installation

Avec [Homebrew](https://brew.sh) :

```bash
brew tap hamiltonprado/agentstats https://github.com/HamiltonPrado/agentstats
brew trust hamiltonprado/agentstats
brew install --cask agentstats
```

Pour mettre à jour : `brew upgrade --cask agentstats`. Pour supprimer : `brew uninstall --cask agentstats` (ajoutez `--zap` pour effacer aussi les réglages et l’historique). L’app n’est pas notarisée par Apple : le cask retire la quarantaine à l’installation, elle s’ouvre donc sans l’avertissement de macOS.

Ou à la main :

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
git tag v1.17
git push origin v1.17
```

GitHub Actions vérifie la version, exécute les tests, compile l’app et publie `AgentStats.zip` dans la release.

### Diagnostic

- `AgentStats --dump` — indicateurs système et agents détectés.
- `AgentStats --bench` — temps d’exécution des lecteurs.
- `AgentStats --snapshot <dossier>` — génère des captures PNG du panneau, uniquement avec des données de démonstration.
- `AgentStats --smoke` — test de lancement avec les lecteurs réels.
- `AGENTSTATS_DISABLE=icon,temps,procs,sessions,usage,energy,limits,gpu,disk` — désactive des lecteurs pour mesurer les performances.

### Architecture

L’acteur `Sampler` coordonne les lectures et renvoie un échantillon immuable. `Monitor` applique cet échantillon sur l’acteur principal ; les vues SwiftUI n’observent que l’état dont elles ont besoin. Le projet utilise la vérification de concurrence de Swift 6.

</details>
