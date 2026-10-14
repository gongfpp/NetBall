#!/bin/bash
# 编译并打包成 NetBall.app（无 Dock 图标的常驻小工具）
set -euo pipefail
cd "$(dirname "$0")"

APP="NetBall.app"

echo "==> 编译"
mkdir -p build .modulecache   # 模块缓存放本地：沙箱/CI 环境下默认缓存目录可能不可写
swiftc -O -module-cache-path "$PWD/.modulecache" -o build/NetBall main.swift

echo "==> 打包 $APP"
rm -rf "$APP"
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
