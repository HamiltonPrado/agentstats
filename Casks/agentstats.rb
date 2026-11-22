# Cask do Homebrew para o AgentStats. A versão e o sha256 são atualizados pelo CI a cada release.
#   brew tap hamiltonprado/agentstats https://github.com/HamiltonPrado/agentstats
#   brew install --cask agentstats
cask "agentstats" do
  version "1.17"
  sha256 "37d2bcf193677105e0540b163f80ca52020dffdd6fe7672d3359ea255b50a34e"

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

  # A app é assinada localmente (sem Developer ID nem notarização). Sem tirar a quarentena,
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
