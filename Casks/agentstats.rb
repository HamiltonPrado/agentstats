# Cask do Homebrew para o AgentStats. A versão e o sha256 são atualizados pelo CI a cada release.
#   brew tap hamiltonprado/agentstats https://github.com/HamiltonPrado/agentstats
#   brew install --cask agentstats
cask "agentstats" do
  version "1.18.1"
  sha256 "246c72ad3e2f888d3e3717aa3962f83b5190ad14777fe4c81f189719180b92e4"

  url "https://github.com/HamiltonPrado/agentstats/releases/download/v#{version}/AgentStats.zip"
  name "AgentStats"
  desc "Menu bar monitor for AI coding agents and system metrics"
  homepage "https://github.com/HamiltonPrado/agentstats"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "AgentStats.app"

  # A app tem certificado próprio (sem Developer ID nem notarização). Sem tirar a quarentena,
  # o macOS bloquearia a primeira abertura.
  postflight_steps do
    run "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "{{appdir}}/AgentStats.app"]
  end

  uninstall quit: "local.agentstats"

  zap trash: [
    "~/.claude/agentstats",
    "~/Library/Application Support/AgentStats",
    "~/Library/Preferences/local.agentstats.plist",
  ]
end
