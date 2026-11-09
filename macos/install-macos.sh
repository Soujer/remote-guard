#!/bin/bash
# install-macos.sh — macOS 一键部署（launchd 每分钟检测 + 常驻即时通道）
# 用法: bash install-macos.sh        安装
#       bash install-macos.sh remove 卸载

set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
LABEL_MAIN="com.soujer.remote-guard"
LABEL_INSTANT="com.soujer.remote-guard.instant"
PLIST_MAIN="$HOME/Library/LaunchAgents/$LABEL_MAIN.plist"
PLIST_INSTANT="$HOME/Library/LaunchAgents/$LABEL_INSTANT.plist"

if [ "$1" = "remove" ]; then
    launchctl unload "$PLIST_MAIN" 2>/dev/null || true
    launchctl unload "$PLIST_INSTANT" 2>/dev/null || true
    rm -f "$PLIST_MAIN" "$PLIST_INSTANT"
    [ -f "$DIR/instant.pid" ] && kill "$(cat "$DIR/instant.pid" 2>/dev/null)" 2>/dev/null || true
    echo "已卸载 launchd 任务（文件保留在 $DIR）"
    exit 0
fi

# 检查配置
if [ ! -f "$DIR/push-channels.conf" ]; then
    if [ -f "$DIR/push-channels.conf.example" ]; then
        cp "$DIR/push-channels.conf.example" "$DIR/push-channels.conf"
        echo "!! 已从模板创建 push-channels.conf，请先编辑填入你的 Bark key / hayo token"
        echo "   编辑: open -t '$DIR/push-channels.conf'"
        exit 1
    else
        echo "缺少 push-channels.conf"; exit 1
    fi
fi

chmod +x "$DIR/remote-guard-macos.sh"

# 测试推送
echo "== 测试推送通道 =="
if bash "$DIR/remote-guard-macos.sh" --test; then
    echo "   通道正常（看手机）"
else
    echo "   推送失败，请检查配置后重试"; exit 1
fi

# 主检测：每分钟
cat > "$PLIST_MAIN" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL_MAIN</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$DIR/remote-guard-macos.sh</string>
    </array>
    <key>StartInterval</key><integer>60</integer>
    <key>RunAtLoad</key><true/>
    <key>StandardOutPath</key><string>/dev/null</string>
    <key>StandardErrorPath</key><string>/dev/null</string>
</dict>
</plist>
EOF

# 即时通道：常驻 KeepAlive
cat > "$PLIST_INSTANT" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL_INSTANT</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$DIR/remote-guard-macos.sh</string>
        <string>--instant</string>
    </array>
    <key>KeepAlive</key><true/>
    <key>RunAtLoad</key><true/>
    <key>StandardOutPath</key><string>/dev/null</string>
    <key>StandardErrorPath</key><string>/dev/null</string>
</dict>
</plist>
EOF

launchctl unload "$PLIST_MAIN" 2>/dev/null || true
launchctl unload "$PLIST_INSTANT" 2>/dev/null || true
launchctl load "$PLIST_MAIN"
launchctl load "$PLIST_INSTANT"

echo ""
echo "== 部署完成 =="
echo "   主检测（每分钟）: launchctl list | grep $LABEL_MAIN"
echo "   即时通道（常驻） : launchctl list | grep $LABEL_INSTANT"
echo "   日志: $DIR/remote-guard.log"
echo "   卸载: bash install-macos.sh remove"
