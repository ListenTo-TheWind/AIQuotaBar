#!/bin/zsh
# 构建并安装 AI Quota Bar:release 构建 → 打包 .app → 装配 LaunchAgent → 启动
set -euo pipefail
ROOT="${0:A:h:h}"
APP="$ROOT/AIQuotaBar.app"
PLIST=~/Library/LaunchAgents/local.ai-quota-bar.plist
LABEL="local.ai-quota-bar"

cd "$ROOT"
swift build -c release

mkdir -p "$APP/Contents/MacOS"
cp "$ROOT/app/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/.build/release/AIQuotaBar" "$APP/Contents/MacOS/AIQuotaBar"

mkdir -p "${PLIST:h}"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array>
    <string>$APP/Contents/MacOS/AIQuotaBar</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><false/>
</dict></plist>
EOF

pkill -f "$APP/Contents/MacOS/AIQuotaBar" 2>/dev/null || true
sleep 1
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
sleep 2
echo "AI Quota Bar 已安装并启动(进程:$(pgrep -f "$APP" | head -1));日志:/tmp/aiq-state.log"
