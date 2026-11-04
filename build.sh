#!/bin/bash
# 编译并打包成 NetBall.app（无 Dock 图标的常驻小工具）
set -euo pipefail
cd "$(dirname "$0")"

APP="NetBall.app"
MIN_MACOS="12.0"
TARGET="arm64-apple-macosx${MIN_MACOS}"

# 部署目标必须同时写入 Mach-O，不能只依赖 Info.plist 或开发机默认值。
PLIST_MIN=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)
if [[ "$PLIST_MIN" != "$MIN_MACOS" ]]; then
	echo "错误：Info.plist 最低版本 $PLIST_MIN 与构建目标 $MIN_MACOS 不一致" >&2
	exit 1
fi

echo "==> 编译 $TARGET"
mkdir -p build .modulecache   # 模块缓存放本地：沙箱/CI 环境下默认缓存目录可能不可写
swiftc -target "$TARGET" -O -module-cache-path "$PWD/.modulecache" -o build/NetBall main.swift TrafficAttribution.swift ProxyTrafficProbe.swift SamplingPerformance.swift PanelPresentation.swift

# 在替换应用包之前检查实际产物，避免误发依赖较新系统的二进制。
BUILD_INFO=$(xcrun vtool -show-build build/NetBall)
ARCHS=$(lipo -archs build/NetBall)
BINARY_MIN=$(printf '%s\n' "$BUILD_INFO" | awk '$1 == "minos" { print $2 }')
PLATFORM=$(printf '%s\n' "$BUILD_INFO" | awk '$1 == "platform" { print $2 }')
if [[ "$ARCHS" != "arm64" || "$PLATFORM" != "MACOS" || "$BINARY_MIN" != "$MIN_MACOS" ]]; then
	echo "错误：产物不是预期的 arm64 / MACOS / $MIN_MACOS：$ARCHS / $PLATFORM / $BINARY_MIN" >&2
	exit 1
fi
printf '%s\n' "$BUILD_INFO"

# 只替换当前项目的固定应用目录；拒绝符号链接，避免误删其他位置。
APP_PATH="$PWD/$APP"
if [[ "$APP" != "NetBall.app" || -L "$APP_PATH" ]]; then
	echo "错误：拒绝替换非预期应用路径 $APP_PATH" >&2
	exit 1
fi
echo "==> 打包 $APP_PATH"
rm -rf "$APP_PATH"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
cp build/NetBall "$APP/Contents/MacOS/NetBall"

# 本地临时签名：让系统把它当成稳定身份（可选，失败不影响运行）
if codesign --force --sign - "$APP" >/dev/null 2>&1; then
	echo "==> 已做 ad-hoc 签名"
else
	echo "==> 跳过签名（本地运行不受影响）"
fi

echo "==> 完成：$PWD/$APP"
echo "    启动：open $APP        停止：右键球体 → 退出"
