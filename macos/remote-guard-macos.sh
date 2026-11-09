#!/bin/bash
# ============================================================
# remote-guard-macos.sh — macOS 远程控制监控 + 推送
#
# 用法:
#   ./remote-guard-macos.sh            单次检测（launchd 每分钟调用）
#   ./remote-guard-macos.sh --instant  即时模式（常驻 2 秒轮询，launchd KeepAlive 托管）
#   ./remote-guard-macos.sh --test     发送测试推送
#
# 依赖: 仅 macOS 自带工具 (bash/lsof/pgrep/ioreg/curl/launchctl)
# 配置: 同目录 push-channels.conf
# 状态: 同目录 state-macos.conf / instant.pid
#
# 检测项:
#   1) macOS 内置屏幕共享/ARD (screensharingd + 5900 已建立连接)
#   2) RustDesk / AnyDesk / TeamViewer / ToDesk / 向日葵(AweSun) /
#      Chrome 远程桌面 / Parsec：进程 + 非 80/443 已建立直连（强信号单次即告警）
#      + CPU 持续占用（连续 2 次采样）
#   3) VNC 端口 5900-5902 被未知进程监听（未知远控）
#   4) 输入注入：锁屏下 HIDIdleTime 持续小于阈值 = 异地注入
#      （只统计输入时间，不记录按键内容）
# ============================================================

DIR="$(cd "$(dirname "$0")" && pwd)"
CONF="$DIR/push-channels.conf"
STATE="$DIR/state-macos.conf"
LOG="$DIR/remote-guard.log"
PIDFILE="$DIR/instant.pid"

# ---------- 默认配置（被 push-channels.conf 覆盖） ----------
ENABLED_CHANNELS=""
BARK_KEY=""
BARK_BASE="https://api.day.app"
BARK_GROUP="remote-guard"
HAYO_TOKEN=""
HAYO_BASE="https://hayo.svip8.vip"

[ -f "$CONF" ] && . "$CONF"

# ---------- 检测参数 ----------
CPU_ACTIVE=8.0            # 单核 CPU% 持续占用（3 秒采样折算）
STREAK_NEED=2             # 连续命中次数（每分钟一次）
PEER_PORT_EXCLUDE="80 443"
INSTANT_LOOP=2            # 即时模式轮询间隔（秒）
INSTANT_LATCH=30          # 即时模式解除保持期（秒）
PUSH_GAP=10               # 两次告警最小间隔（秒）
HID_ACTIVE_NS=2000000000  # 输入空闲 < 2s 视为有输入
LOCK_MIN_TICKS=4          # 锁屏注入判定所需连续输入 tick（每秒 1 tick）

log() { echo "$(date '+%Y-%m-%d %H:%M:%S')  $*" >> "$LOG"; }

urlenc() {
    # 纯 bash URL 编码（macOS bash 3.2 兼容，不依赖 jq/python）
    local s="$1" out="" i c o
    for ((i = 0; i < ${#s}; i++)); do
        c="${s:$i:1}"
        case "$c" in
            [a-zA-Z0-9.~_-]) out="$out$c" ;;
            *)  o=$(printf '%02X' "'$c")
                out="$out%$o" ;;
        esac
    done
    printf '%s' "$out"
}

push_notify() {
    # $1=标题 $2=正文；任一通道成功返回 0
    local title="$1" body="$2" ok=1 ch code uri
    body=$(printf '%s' "$body" | tr '\r\n' '  ' | sed 's/  */ | /g')
    for ch in $ENABLED_CHANNELS; do
        case "$ch" in
            bark)
                if [ -n "$BARK_KEY" ]; then
                    uri="${BARK_BASE}/${BARK_KEY}/$(urlenc "$title")/$(urlenc "$body")?group=$(urlenc "$BARK_GROUP")"
                    code=$(curl -s -m 10 -o /dev/null -w '%{http_code}' "$uri" 2>/dev/null)
                    [ "$code" = "200" ] && ok=0
                fi
                ;;
            hayo)
                if [ -n "$HAYO_TOKEN" ]; then
                    uri="${HAYO_BASE}/send?token=$(urlenc "$HAYO_TOKEN")&title=$(urlenc "$title")&content=$(urlenc "$body")"
                    code=$(curl -s -m 10 -o /dev/null -w '%{http_code}' "$uri" 2>/dev/null)
                    [ "$code" = "200" ] && ok=0
                fi
                ;;
        esac
    done
    return $ok
}

# ---------- 状态读写（简单 key=value） ----------
state_get() { [ -f "$STATE" ] && sed -n "s/^$1=//p" "$STATE" | tail -1; }
state_set() {
    local k="$1" v="$2" tmp
    tmp="$STATE.tmp"
    [ -f "$STATE" ] && grep -v "^$k=" "$STATE" > "$tmp" || : > "$tmp"
    echo "$k=$v" >> "$tmp"
    mv "$tmp" "$STATE"
}

# ---------- 工具函数 ----------
cputime_seconds() {
    # ps cputime 格式 "MM:SS.ss" 或 "HH:MM:SS"，统一折算秒
    local t="$1" p
    p=$(echo "$t" | awk -F: '{n=NF; s=$n; if(n>=2) s+=$(n-1)*60; if(n>=3) s+=$(n-2)*3600; print s}')
    printf '%s' "$p"
}

proc_cputime() {
    # $1=pid -> 累计 CPU 秒（失败输出 0）
    local t
    t=$(ps -o cputime= -p "$1" 2>/dev/null | tr -d ' ')
    [ -n "$t" ] && printf '%s' "$(cputime_seconds "$t")" || printf '0'
}

est_conns_for_pid() {
    # $1=pid -> 该进程的已建立 TCP 连接（远程端点列表）
    lsof -nP -iTCP -sTCP:ESTABLISHED -a -p "$1" 2>/dev/null | awk 'NR>1 {print $9}' | grep -- '->' | sed 's/.*->//'
}

peer_conns_for_pid() {
    # 排除 80/443 信令后的直连端点
    local ep port
    for ep in $(est_conns_for_pid "$1"); do
        port="${ep##*:}"
        skip=0
        for x in $PEER_PORT_EXCLUDE; do [ "$port" = "$x" ] && skip=1; done
        [ $skip -eq 0 ] && echo "$ep"
    done
}

is_remote_ep() {
    # 排除本机/内网回环
    local ip="${1%%:*}"
    case "$ip" in
        127.*|::1|localhost) return 1 ;;
    esac
    return 0
}

is_locked() {
    ioreg -n Root -d2 2>/dev/null | grep -q 'CGSSessionScreenIsLocked = 1'
}

hid_idle_ns() {
    ioreg -c IOHIDSystem 2>/dev/null | grep 'HIDIdleTime' | head -1 | sed 's/.*= *//' | tr -d ',{}<>'
}

# ---------- 工具表（名称:进程1|进程2|...，空格分隔） ----------
TOOLS='
RustDesk:rustdesk|rustdesk_desktop
AnyDesk:anydesk|AnyDesk
TeamViewer:TeamViewer|teamviewer_service|TeamViewer_Service
ToDesk:ToDesk|ToDesk_Service
向日葵:SunloginClient|SunloginRemote|AweSun|awesun_guard|sunloginclient
Chrome远程桌面:remoting_me2me_host
Parsec:parsecd
'

tool_procs() { echo "$2" | tr '|' ' '; }

find_tool_pids() {
    # $*=进程名列表 -> 输出 pid
    local pn pid
    for pn in "$@"; do
        pgrep -x "$pn" 2>/dev/null
        pgrep -ix "$pn" 2>/dev/null
    done | sort -u
}

# ============================================================
# 模式分发
# ============================================================
if [ "$1" = "--test" ]; then
    if push_notify "remote-guard macOS 测试" "推送通道配置成功 $(date '+%H:%M:%S')"; then
        log "测试推送: 成功"; echo "test push ok"
    else
        log "测试推送: 失败"; echo "test push failed（检查 push-channels.conf）"; exit 1
    fi
    exit 0
fi

# ============================================================
# 即时模式：2 秒轮询，直连/screensharingd 秒级告警
# ============================================================
if [ "$1" = "--instant" ]; then
    # 单实例
    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; then
        exit 0
    fi
    echo $$ > "$PIDFILE"
    log "[即时] 即时通道待命 (PID $$，轮询 ${INSTANT_LOOP}s)"

    last_alert=0
    holding=0

    while true; do
        sleep "$INSTANT_LOOP"
        now=$(date +%s)

        trigger=""
        detail=""

        # 内置屏幕共享：screensharingd 在跑 + 5900 有已建立连接
        if pgrep -x screensharingd >/dev/null 2>&1; then
            ss_ep=$(lsof -nP -iTCP:5900 -sTCP:ESTABLISHED 2>/dev/null | awk 'NR>1 {print $9}' | sed 's/.*->//' | head -3 | tr '\n' ',')
            if [ -n "$ss_ep" ]; then
                trigger="屏幕共享(ARD/VNC)"
                detail="5900 已建立会话 (${ss_ep%,})"
            fi
        fi

        # 第三方工具：非 80/443 直连（单次即告警）
        if [ -z "$trigger" ]; then
            for tline in $TOOLS; do
                [ -z "$tline" ] && continue
                tname="${tline%%:*}"
                tprocs="${tline#*:}"
                for pid in $(find_tool_pids $(tool_procs x $tprocs)); do
                    ep=$(peer_conns_for_pid "$pid" | head -3 | tr '\n' ',')
                    if [ -n "$ep" ]; then
                        trigger="$tname"
                        detail="被控直连会话 (${ep%,})"
                        break 2
                    fi
                done
            done
        fi

        if [ -n "$trigger" ]; then
            holding=$((now + INSTANT_LATCH))
            if [ $((now - last_alert)) -ge $PUSH_GAP ]; then
                if push_notify "远程控制告警" "检测到本机可能正被远程控制（即时通道）: $trigger - $detail 主机: $(hostname -s) 时间: $(date '+%Y-%m-%d %H:%M:%S')"; then
                    log "[即时] 即时告警已推送: $trigger: $detail"
                else
                    log "[即时] 即时告警推送失败: $trigger: $detail"
                fi
                last_alert=$now
            fi
        elif [ "$holding" -gt 0 ] && [ "$now" -ge "$holding" ]; then
            holding=0
            if [ $((now - last_alert)) -ge $PUSH_GAP ]; then
                if push_notify "远程控制已解除" "本机远程控制迹象已消失（即时通道）。主机: $(hostname -s)  时间: $(date '+%Y-%m-%d %H:%M:%S')"; then
                    log "[即时] 即时通道已恢复: 已推送"
                else
                    log "[即时] 即时通道已恢复: 推送失败"
                fi
                last_alert=$now
            fi
        fi
    done
    exit 0
fi

# ============================================================
# 单次检测模式（launchd 每分钟）
# ============================================================
findings=""
add_finding() { findings="${findings}· $1: $2
"; }

# --- 1) 内置屏幕共享 / ARD ---
if pgrep -x screensharingd >/dev/null 2>&1; then
    ss_ep=$(lsof -nP -iTCP:5900 -sTCP:ESTABLISHED 2>/dev/null | awk 'NR>1 {print $9}' | sed 's/.*->//' | head -3 | tr '\n' ',')
    if [ -n "$ss_ep" ]; then
        add_finding "屏幕共享" "5900 已建立会话 (${ss_ep%,})"
    fi
fi

# --- 2) 第三方远控工具 ---
for tline in $TOOLS; do
    [ -z "$tline" ] && continue
    tname="${tline%%:*}"
    tprocs="${tline#*:}"

    pids=$(find_tool_pids $(tool_procs x $tprocs))
    [ -z "$pids" ] && continue

    has_peer=0
    peer_ep=""
    first_pid=$(echo "$pids" | head -1)

    for pid in $pids; do
        ep=$(peer_conns_for_pid "$pid" | head -3 | tr '\n' ',')
        if [ -n "$ep" ]; then
            has_peer=1
            peer_ep="${ep%,}"
            break
        fi
    done

    # CPU 采样（与上一轮 state 对比）
    cpu_key="CPU_$(echo "$tname" | tr -cd 'a-zA-Z0-9_')"
    prev_cpu=$(state_get "$cpu_key")
    cur_cpu=$(proc_cputime "$first_pid")
    state_set "$cpu_key" "$first_pid:$cur_cpu"

    prev_pid=""; prev_val=0
    case "$prev_cpu" in
        *:*) prev_pid="${prev_cpu%%:*}"; prev_val="${prev_cpu#*:}" ;;
    esac

    cpu_rate=0
    if [ -n "$prev_pid" ] && [ "$prev_pid" = "$first_pid" ] && [ "$prev_val" -gt 0 ] 2>/dev/null; then
        cpu_rate=$(echo "$cur_cpu $prev_val" | awk '{d=$1-$2; if(d<0) d=0; printf "%.1f", d * 20}')  # 3 秒采样折算 %（60/3=20）
    fi

    streak_key="STREAK_$(echo "$tname" | tr -cd 'a-zA-Z0-9_')"
    streak=$(state_get "$streak_key")
    [ -z "$streak" ] && streak=0

    if [ "$has_peer" = "1" ]; then
        streak=$((streak + 1))
        [ $streak -lt $STREAK_NEED ] && streak=$STREAK_NEED   # 直连单次即告警
        add_finding "$tname" "被控直连会话 (${peer_ep})"
    elif [ "$(echo "$cpu_rate >= $CPU_ACTIVE" | bc 2>/dev/null || echo 0)" = "1" ]; then
        streak=$((streak + 1))
        [ $streak -ge $STREAK_NEED ] && add_finding "$tname" "CPU ${cpu_rate}% 持续占用"
    else
        streak=0
    fi
    state_set "$streak_key" "$streak"
done

# --- 3) 未知进程监听 VNC 端口 ---
for port in 5900 5901 5902; do
    listener=$(lsof -nP -iTCP:$port -sTCP:LISTEN 2>/dev/null | awk 'NR>1 {print $1}' | head -1)
    if [ -n "$listener" ]; then
        case "$listener" in
            screensharingd|launchd|SystemUIServer|"") : ;;
            RustDesk|AnyDesk|TeamViewer*|ToDesk*|SunloginClient|AweSun*|remoting*) : ;;
            *) add_finding "未知VNC监听" "端口 $port 被 $listener 监听" ;;
        esac
    fi
done

# --- 4) 输入注入传感器（锁屏下 HIDIdleTime 持续小） ---
lock_ticks=0
if is_locked; then
    for ((i = 0; i < 10; i++)); do
        sleep 1
        idle=$(hid_idle_ns)
        if [ -n "$idle" ] && [ "$idle" -lt "$HID_ACTIVE_NS" ] 2>/dev/null; then
            lock_ticks=$((lock_ticks + 1))
        fi
    done
    if [ "$lock_ticks" -ge "$LOCK_MIN_TICKS" ]; then
        add_finding "输入注入" "锁屏下检测到输入注入 (10s 内 $lock_ticks 次输入)"
    fi
fi

# --- 汇总与推送 ---
was_controlled=$(state_get "controlled")
now_controlled=0
[ -n "$findings" ] && now_controlled=1

if [ "$now_controlled" = "1" ]; then
    if [ "$was_controlled" != "1" ]; then
        if push_notify "远程控制告警" "检测到本机可能正被远程控制:
$findings 主机: $(hostname -s)  时间: $(date '+%Y-%m-%d %H:%M:%S')"; then
            log "告警已推送: $(echo "$findings" | tr '\n' ' ' | tr -s ' ')"
            state_set "lastNotify" "$(date +%s)"
        else
            log "告警推送失败（下次重试）: $(echo "$findings" | tr '\n' ' ' | tr -s ' ')"
        fi
    else
        last_notify=$(state_get "lastNotify")
        if [ -n "$last_notify" ] && [ $(( $(date +%s) - last_notify )) -ge 1800 ]; then
            if push_notify "远程控制持续提醒" "本机仍处于被控状态:
$findings 时间: $(date '+%Y-%m-%d %H:%M:%S')"; then
                log "持续提醒已推送"
                state_set "lastNotify" "$(date +%s)"
            fi
        else
            log "仍在受控（未到提醒间隔）: $(echo "$findings" | tr '\n' ' ' | tr -s ' ')"
        fi
    fi
else
    if [ "$was_controlled" = "1" ]; then
        if push_notify "远程控制已解除" "本机远程控制迹象已消失。主机: $(hostname -s)  时间: $(date '+%Y-%m-%d %H:%M:%S')"; then
            log "已恢复: 已推送"
        else
            log "已恢复: 推送失败"
        fi
    fi
fi

state_set "controlled" "$now_controlled"
state_set "lastRun" "$(date '+%Y-%m-%d %H:%M:%S')"

# 日志轮转 2MB
if [ -f "$LOG" ] && [ "$(stat -f%z "$LOG" 2>/dev/null || echo 0)" -gt 2097152 ]; then
    mv "$LOG" "$LOG.1"
fi

exit 0
