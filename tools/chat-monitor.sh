#!/bin/zsh
set -euo pipefail
umask 077

export LANG="en_US.UTF-8"
export LC_ALL="en_US.UTF-8"

script_path="${0:A}"
script_dir="${script_path:h}"
root="${script_dir:h}"
if ! root="$(git -C "$root" rev-parse --show-toplevel 2>/dev/null)"; then
    print -u2 -r -- "错误：ChatGPTBridge 必须位于 Git 项目中。"
    exit 1
fi

runtime="$root/.chatgpt"
binary="$runtime/chat-monitor"
pid_file="$runtime/chat-monitor.pid"
log_file="$runtime/chat-monitor.log"
source_file="$script_dir/chat-monitor.swift"
mkdir -p "$runtime"

is_running() {
    [[ -s "$pid_file" ]] || return 1
    local pid="$(<"$pid_file")"
    [[ "$pid" == <-> ]] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    ps -p "$pid" -o command= 2>/dev/null | grep -Fq "$binary"
}

build_monitor() {
    if [[ ! -x "$binary" || "$source_file" -nt "$binary" ]]; then
        command -v swiftc >/dev/null 2>&1 || {
            print -u2 -r -- "错误：需要 Xcode Command Line Tools 中的 swiftc。"
            exit 2
        }
        swiftc -O "$source_file" -o "$binary"
    fi
    chmod 755 "$binary"
    if [[ ! -x "$binary" ]]; then
        print -u2 -r -- "错误：无法为原生监控器设置执行权限：$binary"
        exit 2
    fi
}

case "${1:-status}" in
    start)
        if is_running; then
            print -r -- "ChatGPTBridge 原生监控已在运行。"
            exit 0
        fi
        build_monitor
        nohup "$binary" --bridge-root "$root" >>"$log_file" 2>&1 </dev/null &
        monitor_pid=$!
        print -r -- "$monitor_pid" > "$pid_file"
        chmod 600 "$pid_file"
        sleep 1
        if is_running; then
            print -r -- "ChatGPTBridge 原生监控已启动（PID $monitor_pid）。"
            print -r -- "日志：$log_file"
        else
            rm -f "$pid_file"
            print -u2 -r -- "监控未能启动；请检查日志：$log_file"
            exit 1
        fi
        ;;
    stop)
        if ! is_running; then
            rm -f "$pid_file"
            print -r -- "ChatGPTBridge 原生监控当前未运行。"
            exit 0
        fi
        monitor_pid="$(<"$pid_file")"
        kill "$monitor_pid"
        for _ in {1..50}; do
            is_running || break
            sleep 0.1
        done
        if is_running; then
            print -u2 -r -- "监控进程仍在运行（PID $monitor_pid）；请检查日志：$log_file"
            exit 1
        fi
        rm -f "$pid_file"
        print -r -- "ChatGPTBridge 原生监控已停止。"
        ;;
    status)
        if is_running; then
            monitor_pid="$(<"$pid_file")"
            read -r cpu rss <<<"$(ps -p "$monitor_pid" -o %cpu=,rss= 2>/dev/null || true)"
            if [[ "${rss:-}" == <-> ]]; then
                memory_mb=$((rss / 1024))
                print -r -- "ChatGPTBridge 原生监控正在运行（PID $monitor_pid；RSS ${memory_mb} MB；CPU ${cpu:-未知}%*）。"
                print -r -- "*CPU 是 ps 报告的当前近似值；RSS 是当前内存快照。"
            else
                print -r -- "ChatGPTBridge 原生监控正在运行（PID $monitor_pid）。"
            fi
        else
            print -r -- "ChatGPTBridge 原生监控当前未运行。"
            exit 1
        fi
        ;;
    foreground)
        build_monitor
        exec "$binary" --bridge-root "$root"
        ;;
    *)
        print -u2 -r -- "用法：$0 {start|stop|status|foreground}"
        exit 2
        ;;
esac
