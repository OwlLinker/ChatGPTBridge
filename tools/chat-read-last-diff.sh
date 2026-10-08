#!/bin/zsh
set -euo pipefail

# 不依赖 Hammerspoon：读取 ChatGPT 最后一个助手 Diff 并应用到当前 Git 项目。
# 脚本可从任意工作目录通过绝对路径调用，项目根目录根据脚本位置自动识别。
# 首次运行会将 chat-read-last-diff.swift 编译到项目 .chatgpt/ 运行目录。

export LANG="en_US.UTF-8"
export LC_ALL="en_US.UTF-8"

script_path="${0:A}"
script_dir="${script_path:h}"
script_project_root="${script_dir:h}"

if ! ROOT="$(git -C "$script_project_root" rev-parse --show-toplevel 2>/dev/null)"; then
    echo "错误：Bridge 所在目录不在 Git 项目中。" >&2
    exit 1
fi

bridge_dir="$ROOT/.chatgpt"
reader_source="$script_dir/chat-read-last-diff.swift"
reader_binary="$bridge_dir/chat-read-last-diff"
patch_file="$(mktemp -t chat-read-last-diff-patch)"

cleanup() {
    rm -f "$patch_file"
}

trap cleanup EXIT

if [[ ! -f "$reader_source" ]]; then
    echo "错误：找不到 Diff 读取器：$reader_source" >&2
    exit 2
fi

if ! command -v swiftc >/dev/null 2>&1; then
    echo "错误：未找到 swiftc，无法读取 ChatGPT 界面。" >&2
    echo "请安装 Xcode Command Line Tools。" >&2
    exit 3
fi

mkdir -p "$bridge_dir"

if [[ ! -x "$reader_binary" || "$reader_source" -nt "$reader_binary" ]]; then
    echo "首次运行：编译 ChatGPT Diff 读取器..." >&2
    swiftc -O "$reader_source" -o "$reader_binary"
fi

echo "读取 ChatGPT 最后一个助手 Diff..." >&2
if ! "$reader_binary" >"$patch_file"; then
    echo "错误：无法从 ChatGPT 读取 Diff。" >&2
    exit 4
fi

if [[ ! -s "$patch_file" ]]; then
    echo "错误：读取到的 Diff 为空。" >&2
    exit 5
fi

# 复用统一 Bridge：Patch 校验、应用后语法检查、失败诊断和剪贴板诊断均保持一致。
exec "$script_dir/chat-apply-shell.sh" --patch-file "$patch_file"
