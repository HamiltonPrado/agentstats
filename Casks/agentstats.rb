# Cask do Homebrew para o AgentStats. A versão e o sha256 são atualizados pelo CI a cada release.
#   brew tap hamiltonprado/agentstats https://github.com/HamiltonPrado/agentstats
#   brew install --cask agentstats
cask "agentstats" do
  version "1.19"
  sha256 "add9aab51ba7f7d699cd260c5cb7e4e103f91f153f6a11c3a446d02a70702d8c"

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
