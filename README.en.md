# AgentStats

[Português](README.md) · [English](README.en.md) · [Español](README.es.md) · [Français](README.fr.md)

![CI](https://github.com/HamiltonPrado/agentstats/actions/workflows/ci.yml/badge.svg)
![Latest release](https://img.shields.io/github/v/release/HamiltonPrado/agentstats?color=blue)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black)
![Swift 6](https://img.shields.io/badge/Swift-6.0-F05138?logo=swift&logoColor=white)

**AI agents and Mac metrics in one panel.** AgentStats lives in the macOS menu bar and shows what is running, what needs your attention, and how your system resources are doing.

**[Download the latest release](https://github.com/HamiltonPrado/agentstats/releases/latest)** · [Website](https://hamiltonprado.github.io/agentstats) · [Report an issue](https://github.com/HamiltonPrado/agentstats/issues)

<p align="center">
  <img src="Resources/screenshots/menubar.png" alt="Agents and metrics in the menu bar" width="600">
</p>

<p align="center">
  <img src="Resources/screenshots/agents-dark.png" alt="Agent dashboard" width="340">
  &nbsp;&nbsp;
  <img src="Resources/screenshots/system-dark.png" alt="System metrics dashboard" width="340">
</p>

## What you can monitor

### AI agents

See active sessions, project, model, CPU and memory use, subprocesses, and status: working, waiting, or asking for your attention. AgentStats recognizes Claude Code, Codex, Antigravity, Aider, Goose, Gemini CLI, Cursor Agent, OpenCode, and Amp. Click a session to return to the app where it is running.

### Mac health

CPU, memory, GPU, temperatures, network, disk, and battery. The panel includes charts and 24-hour history, configurable alerts, and a manual download, upload, and latency test.

### Built for your workflow

- Notifications when an agent finishes or needs your attention.
- Token usage today, by session, and by project for Claude Code and Codex.
- A configurable global shortcut to open the panel.
- Accessible status indicators using color, shape, and VoiceOver; respects Reduce Motion.
- Optional launch at login.

The speed test uses Cloudflare's public endpoints and transfers about **32 MB per run**. Measurements may be collected in aggregate.

## Install

1. Download **AgentStats.zip** from the [latest release](https://github.com/HamiltonPrado/agentstats/releases/latest).
2. Unzip it and move `AgentStats.app` to your Applications folder.
3. Open the app. If macOS blocks the first launch, go to **System Settings → Privacy & Security → Open Anyway**. The app is locally signed and does not have an Apple Developer signature.

You can also install from the command line with the [GitHub CLI](https://cli.github.com):

```bash
tmp=$(mktemp -d) && gh release download --repo HamiltonPrado/agentstats --pattern AgentStats.zip --dir "$tmp" && ditto -x -k "$tmp/AgentStats.zip" "$tmp" && { pkill -x AgentStats 2>/dev/null || true; ditto "$tmp/AgentStats.app" /Applications/AgentStats.app && open /Applications/AgentStats.app; }
```

## Contribute

Requires macOS 14 or later and the Xcode Command Line Tools.

```bash
./build.sh
open build/AgentStats.app
```

Run the tests with:

```bash
./test.sh
```

Contributions are welcome. Open an [issue](https://github.com/HamiltonPrado/agentstats/issues) to report a problem or suggest an improvement.

## License

AgentStats is distributed under the [MIT License](LICENSE). You may use, modify, and redistribute the code under its terms.

<details>
<summary>Development details</summary>

### Creating a release

Update `VERSION`, then push a tag with the same version, for example:

```bash
git tag v1.10
git push origin v1.10
```

GitHub Actions checks the version, runs the tests, builds the app, and publishes `AgentStats.zip` to the release.

### Diagnostics

- `AgentStats --dump` — system metrics and detected agents.
- `AgentStats --bench` — reader execution times.
- `AgentStats --snapshot <folder>` — renders panel screenshots as PNG files.
- `AGENTSTATS_DISABLE=icon,temps,procs,sessions,usage,gpu,disk` — disables readers for performance measurements.

### Architecture

The `Sampler` actor coordinates data collection and returns an immutable sample. `Monitor` applies the sample on the main actor; SwiftUI views observe only the state they use. The project uses Swift 6 concurrency checking.

</details>
