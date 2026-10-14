#!/bin/bash
# 安装开机自启（LaunchAgent）
set -euo pipefail
cd "$(dirname "$0")"

APP="$(pwd)/NetBall.app"
BIN="$APP/Contents/MacOS/NetBall"
PLIST="$HOME/Library/LaunchAgents/local.netball.plist"

if [ ! -x "$BIN" ]; then
	echo "找不到 $BIN，请先运行 ./build.sh" >&2
	exit 1
fi

mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>local.netball</string>
	<key>ProgramArguments</key>
	<array>
		<string>$BIN</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<false/>
	<key>LimitLoadToSessionType</key>
	<string>Aqua</string>
</dict>
</plist>
EOF

launchctl unload "$PLIST" >/dev/null 2>&1 || true
launchctl load "$PLIST"

echo "已安装开机自启：$PLIST"
echo "程序路径：$BIN"
echo "（移动 NetBall.app 后需要重新运行本脚本）"
