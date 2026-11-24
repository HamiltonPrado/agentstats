#!/bin/zsh
# Compila o AgentStats e cria AgentStats.app (app só de barra de menus).
set -euo pipefail
cd "$(dirname "$0")"

# Versão: variável VERSION (a CI passa a da tag) ou o ficheiro VERSION
VERSION="${VERSION:-$(cat VERSION)}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/AgentStats"

APP="build/AgentStats.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AgentStats"

# Ícone: gera o .icns a partir de Resources/AppIcon-1024.png (criado por Scripts/make-icon.swift)
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
    sips -z $s $s Resources/AppIcon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) Resources/AppIcon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>AgentStats</string>
    <key>CFBundleDisplayName</key><string>AgentStats</string>
    <key>CFBundleIdentifier</key><string>local.agentstats</string>
    <key>CFBundleExecutable</key><string>AgentStats</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSLocationUsageDescription</key><string>O macOS só mostra o nome da rede Wi-Fi a apps com acesso à Localização. O AgentStats não pede a tua posição.</string>
    <key>NSLocationWhenInUseUsageDescription</key><string>O macOS só mostra o nome da rede Wi-Fi a apps com acesso à Localização. O AgentStats não pede a tua posição.</string>
    <key>NSAppleEventsUsageDescription</key><string>O AgentStats usa o System Events só para ligar e desligar o modo escuro quando carregas no atalho rápido.</string>
    <key>CFBundleURLTypes</key><array><dict>
        <key>CFBundleURLName</key><string>local.agentstats</string>
        <key>CFBundleURLSchemes</key><array><string>agentstats</string></array>
    </dict></array>
    <key>NSMicrophoneUsageDescription</key><string>O AgentStats só usa o microfone se escolheres gravá-lo numa gravação de ecrã.</string>
    <key>NSAudioCaptureUsageDescription</key><string>O AgentStats precisa de receber o som das apps que ajustares no mixer, para lhes mudar o volume. Nada é gravado nem enviado.</string>
</dict>
</plist>
PLIST

Scripts/sign.sh "$APP"
echo "✅ Criado: $PWD/$APP (versão $VERSION)"
