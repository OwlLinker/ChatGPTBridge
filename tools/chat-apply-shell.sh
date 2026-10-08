#!/bin/zsh
set -euo pipefail

# Shell/Terminal 专用 ChatGPTBridge Patch 应用器。
# 从剪贴板或 --patch-file 读取 unified diff，校验后应用到当前 Git 项目。

export LANG="en_US.UTF-8"
export LC_ALL="en_US.UTF-8"

script_path="${0:A}"
script_dir="${script_path:h}"
script_project_root="${script_dir:h}"

# ============================================================
# ChatGPT → Local Project Patch Bridge
#
# 用法：
#
#   复制 ChatGPT 输出的完整 unified diff，然后执行：
#
#       ./tools/chat-apply-shell.sh
#
#   Patch 检查通过后自动应用到本地原文件。
#
#   如果 Patch 失败：
#
#       1. 自动诊断错误
#       2. 只保留最近一次失败：
#
#            .chatgpt/failed.patch
#            .chatgpt/patch-error.txt
#
#       3. 自动把：
#
#            修复要求
#            + 当前错误诊断
#            + 当前失败 Patch
#
#          复制到 macOS 剪贴板
#
#       4. 自动切回 ChatGPT
#
#      然后只需要：
#
#            Command + V
#
#      并发送。
#
#   撤销最近一次成功应用的 Chat Patch：
#
#       ./tools/chat-apply-shell.sh --undo
#
# ============================================================


# ------------------------------------------------------------
# 项目根目录
# ------------------------------------------------------------

if [[ -n "${CHAT_BRIDGE_PROJECT_ROOT:-}" ]] \
    && ROOT="$(git -C "$CHAT_BRIDGE_PROJECT_ROOT" rev-parse --show-toplevel 2>/dev/null)"; then
    :
elif ROOT="$(git -C "$script_project_root" rev-parse --show-toplevel 2>/dev/null)"; then
    :
elif ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"; then
    :
else
    echo "错误：Bridge 所在目录和当前目录都不在 Git 项目中。"
    exit 1
fi

cd "$ROOT"


# ------------------------------------------------------------
# Bridge 文件
# ------------------------------------------------------------

BRIDGE_DIR="$ROOT/.chatgpt"

LAST_PATCH="$BRIDGE_DIR/last-applied.patch"
FAILED_PATCH="$BRIDGE_DIR/failed.patch"
ERROR_REPORT="$BRIDGE_DIR/patch-error.txt"

mkdir -p "$BRIDGE_DIR"

# 原生监控、Hammerspoon 和终端入口共用同一项目的诊断与回滚文件。
# 文件锁覆盖完整应用过程，避免两个进程同时检查、写入或撤销同一 Patch。
if [[ "${CHAT_BRIDGE_LOCKED_ROOT:-}" != "$ROOT" ]]; then
    export CHAT_BRIDGE_LOCKED_ROOT="$ROOT"
    exec /usr/bin/lockf -k -t 120 "$BRIDGE_DIR/apply.lock" "$script_path" "$@"
fi


# ------------------------------------------------------------
# 通用工具
# ------------------------------------------------------------

print_hr() {
    printf '%s\n' "------------------------------------------------------------"
}


is_integer() {
    [[ "${1:-}" == <-> ]]
}


is_safe_project_path() {
    case "${1:-}" in
        ""|/*|../*|*/../*|*/..)
            return 1
            ;;
    esac
    return 0
}


# 当 Patch 的反向严格检查因源码已有后续等价调整而失败时，
# 逐行确认 Patch 新增内容是否已经存在，避免重复把同一 Patch
# 复制回 ChatGPT，形成“已应用但上下文不匹配”的循环诊断。
patch_added_lines_exist() {
    local patch="$1"
    local line current_file added full_path saw_added=0

    current_file=""
    while IFS= read -r line; do
        if [[ "$line" == diff\ --git\ * ]]; then
            current_file="${line#diff --git a/}"
            current_file="${current_file%% b/*}"
            continue
        fi

        [[ "$line" == +* ]] || continue
        [[ "$line" != +++\ * ]] || continue
        [[ -n "$current_file" ]] || return 1
        is_safe_project_path "$current_file" || return 1

        added="${line[2,-1]}"
        [[ -n "$added" ]] || continue
        saw_added=1
        full_path="$ROOT/$current_file"
        [[ -f "$full_path" ]] || return 1
        grep -Fqx -- "$added" "$full_path" || return 1
    done < "$patch"

    (( saw_added == 1 ))
}


patch_tracking_summary() {
    local patch="$1"
    local branch head patch_id worktree_state

    branch="$(git branch --show-current 2>/dev/null || true)"
    if [[ -z "$branch" ]]; then
        branch="DETACHED"
    fi

    head="$(git rev-parse --short=12 HEAD 2>/dev/null || true)"
    [[ -n "$head" ]] || head="unknown"

    patch_id="$({
        git patch-id --stable < "$patch" 2>/dev/null || true
    } | awk 'NR == 1 { print $1; exit }')"
    [[ -n "$patch_id" ]] || patch_id="unavailable"

    if [[ -n "$(git status --short 2>/dev/null)" ]]; then
        worktree_state="有未提交修改"
    else
        worktree_state="工作区干净"
    fi

    printf 'Git跟踪号：%s@%s；Patch追踪号：%s；工作区：%s' \
        "$branch" "$head" "$patch_id" "$worktree_state"
}


report_already_applied() {
    local patch="$1"
    local reason="$2"
    local tracking

    tracking="$(patch_tracking_summary "$patch")"

    echo "错误类型：Patch 很可能已经应用过"
    echo
    echo "$reason"
    echo
    echo "追踪信息：$tracking"
    echo
    echo "源码没有再次修改。"

    {
        echo "Diagnosis:"
        echo
        echo "Type: already applied"
        echo
        echo "$reason"
        echo
        echo "$tracking"
        echo
    } >> "$ERROR_REPORT"
}


PATCH_ALREADY_APPLIED=0


# ------------------------------------------------------------
# 应用后的源码语法检查
#
# 只检查本次 Patch 涉及的文件。检查失败时由调用方反向撤销
# 本次 Patch，因此不会把“已应用但无法运行”的状态报告为成功。
# ------------------------------------------------------------

collect_patch_files() {
    local patch="$1"
    local line parsed old_path new_path file_path
    typeset -A seen

    while IFS= read -r line; do
        [[ "$line" == diff\ --git\ * ]] || continue

        parsed="$({ printf '%s\n' "$line"; } | sed -E \
            's#^diff --git a/(.*) b/(.*)$#\1\t\2#')"

        IFS=$'\t' read -r old_path new_path <<< "$parsed"

        for file_path in "$old_path" "$new_path"; do
            [[ -n "$file_path" ]] || continue
            [[ "$file_path" == /dev/null ]] && continue
            file_path="${file_path#\"}"
            file_path="${file_path%\"}"
            file_path="${file_path#a/}"
            file_path="${file_path#b/}"

            if [[ -z "${seen[$file_path]-}" ]]; then
                seen["$file_path"]=1
                printf '%s\n' "$file_path"
            fi
        done
    done < "$patch"
}

validate_js_file() {
    local file="$1"
    local node_bin="${CHAT_BRIDGE_NODE_BIN:-}"

    if [[ -z "$node_bin" ]]; then
        node_bin="$(command -v node 2>/dev/null || true)"
    fi

    if [[ -z "$node_bin" && -d "${HOME:-}/.nvm/versions/node" ]]; then
        node_bin="$(find "${HOME}/.nvm/versions/node" \
            -path '*/bin/node' \
            -type f \
            -perm -111 \
            2>/dev/null |
            sort |
            tail -1)"
    fi

    if [[ -z "$node_bin" || ! -x "$node_bin" ]]; then
        echo "未找到 Node.js，无法检查 JavaScript：$file"
        echo "可设置 CHAT_BRIDGE_NODE_BIN 指定 node 路径。"
        return 1
    fi

    "$node_bin" --check "$file"
}

validate_css_file() {
    local file="$1"

    python3 - "$file" <<'PY'
import sys
from pathlib import Path


path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

stack = []
quote = None
escaped = False
comment = False
segment_start = 0
pair = {
    "{": "}",
    "(": ")",
    "[": "]",
}
closing = set(pair.values())


def fail(position, message):
    line = text.count("\n", 0, position) + 1
    raise SystemExit(f"{path}:{line}: {message}")


for index, char in enumerate(text):
    next_char = text[index + 1] if index + 1 < len(text) else ""

    if comment:
        if char == "*" and next_char == "/":
            comment = False
        continue

    if quote:
        if escaped:
            escaped = False
        elif char == "\\":
            escaped = True
        elif char == quote:
            quote = None
        continue

    if char == "/" and next_char == "*":
        comment = True
        continue

    if char in ("'", '"'):
        quote = char
        continue

    if char in pair:
        stack.append((char, index))
        if char == "{":
            segment_start = index + 1
        continue

    if char in closing:
        if not stack or pair[stack[-1][0]] != char:
            fail(index, f"不匹配的括号：{char}")

        opening, opening_index = stack.pop()
        if char == "}" and opening == "{":
            segment = text[segment_start:index].strip()
            if segment and ":" not in segment and not segment.startswith("@"):
                fail(segment_start, "CSS 声明缺少冒号")
            segment_start = index + 1
        continue

    if char == ";" and stack and stack[-1][0] == "{":
        segment = text[segment_start:index].strip()
        if segment and ":" not in segment and not segment.startswith("@"):
            fail(segment_start, "CSS 声明缺少冒号")
        segment_start = index + 1

if comment:
    fail(len(text), "CSS 注释没有闭合")
if quote:
    fail(len(text), "CSS 字符串没有闭合")
if stack:
    fail(stack[-1][1], f"CSS 括号没有闭合：{stack[-1][0]}")
PY
}

validate_html_file() {
    local file="$1"
    local output
    local tidy_bin="${CHAT_BRIDGE_TIDY_BIN:-}"

    if [[ -z "$tidy_bin" ]]; then
        tidy_bin="$(command -v tidy 2>/dev/null || true)"
    fi

    if [[ -z "$tidy_bin" || ! -x "$tidy_bin" ]]; then
        echo "未找到 HTML Tidy，无法检查 HTML：$file"
        echo "可安装 tidy，或设置 CHAT_BRIDGE_TIDY_BIN 指定路径。"
        return 1
    fi

    output="$("$tidy_bin" -errors -quiet -utf8 "$file" 2>&1 >/dev/null || true)"
    if grep -Eiq '(^|[[:space:]])error:' <<< "$output"; then
        printf '%s\n' "$output"
        return 1
    fi
}

validate_source_file() {
    local file="$1"
    local full_path="$ROOT/$file"

    [[ -f "$full_path" ]] || return 0

    case "$file" in
        *.js|*.mjs|*.cjs)
            validate_js_file "$full_path"
            ;;
        *.css)
            validate_css_file "$full_path"
            ;;
        *.html|*.htm)
            validate_html_file "$full_path"
            ;;
        *.sh|*.zsh|*.bash)
            local shebang
            shebang="$(head -1 "$full_path")"
            if [[ "$shebang" == *bash* ]]; then
                bash -n "$full_path"
            else
                zsh -n "$full_path"
            fi
            ;;
        *.json)
            python3 -m json.tool "$full_path" >/dev/null
            ;;
    esac
}

validate_applied_files() {
    local patch="$1"
    local file
    local checked=0

    echo "执行本次修改的语法检查..."

    while IFS= read -r file; do
        [[ -n "$file" ]] || continue
        case "$file" in
            *.js|*.mjs|*.cjs|*.css|*.html|*.htm|*.sh|*.zsh|*.bash|*.json)
                echo "  检查：$file"
                if ! validate_source_file "$file"; then
                    echo "语法检查失败：$file"
                    return 1
                fi
                checked=1
                ;;
        esac
    done < <(collect_patch_files "$patch")

    if (( checked == 0 )); then
        echo "  没有可用的脚本、JSON、JS、CSS 或 HTML 检查器目标"
    fi
}


# ------------------------------------------------------------
# 显示 Patch 指定行附近内容
# ------------------------------------------------------------

show_patch_context() {
    local patch="$1"
    local line="$2"

    is_integer "$line" || return 0

    local start=$(( line - 8 ))
    local end=$(( line + 8 ))

    (( start < 1 )) && start=1

    echo
    echo "Patch 故障位置附近："
    echo

    nl -ba "$patch" |
        sed -n "${start},${end}p" |
        awk -v bad="$line" '
        {
            number=$1
            $1=""
            sub(/^[ \t]+/, "", $0)

            if (number == bad)
                printf "> %5s | %s\n", number, $0
            else
                printf "  %5s | %s\n", number, $0
        }'
}


# ------------------------------------------------------------
# 显示当前源码指定行附近内容
# ------------------------------------------------------------

show_source_context() {
    local file="$1"
    local line="$2"

    is_safe_project_path "$file" || return 0
    [[ -f "$file" ]] || return 0
    is_integer "$line" || return 0

    local start=$(( line - 8 ))
    local end=$(( line + 8 ))

    (( start < 1 )) && start=1

    echo
    echo "当前本地源码附近："
    echo

    nl -ba "$file" |
        sed -n "${start},${end}p"
}


# ------------------------------------------------------------
# 创建诊断报告
#
# 注意：
# 使用 >，不是 >>
#
# 因此报告始终覆盖旧内容，
# 永远只代表当前这一次失败。
# ------------------------------------------------------------

write_report_header() {
    {
        echo "ChatGPTBridge Patch 诊断报告"
        echo
        echo "Project: $ROOT"
        echo "Branch: $(git branch --show-current 2>/dev/null || true)"
        echo "HEAD: $(git rev-parse --short HEAD 2>/dev/null || true)"
        echo
        echo "Git status:"
        echo
        git status --short || true
        echo
    } > "$ERROR_REPORT"
}


# ------------------------------------------------------------
# 从 corrupt patch 错误中提取 Patch 行号
#
# 支持：
#
#   error: corrupt patch at line 122
#
#   error: corrupt patch at /var/.../xxx.patch:122
# ------------------------------------------------------------

extract_corrupt_line() {
    local error_file="$1"
    local line=""

    line="$(
        sed -nE \
            's/.*corrupt patch at line ([0-9]+).*/\1/p' \
            "$error_file" |
        head -1
    )"

    if [[ -z "$line" ]]; then
        line="$(
            sed -nE \
                's/.*corrupt patch at .*:([0-9]+)[[:space:]]*$/\1/p' \
                "$error_file" |
            head -1
        )"
    fi

    printf '%s' "$line"
}


# ------------------------------------------------------------
# 把本次失败诊断 + 本次失败 Patch
# 自动复制到 macOS 剪贴板
#
# 不读取任何历史记录。
# ------------------------------------------------------------

copy_failure_bundle_to_clipboard() {
    local patch="$1"

    {
        cat <<'EOF'
下面是本地 ChatGPTBridge 自动生成的最新一次 Patch 失败诊断。

请仅根据本次错误和本次失败 Patch 修复。

重要基线约束：

- 本次失败 Patch 视为完全未应用，不得成为当前源码基线。
- 禁止在当前失败版本上继续修改或叠加 Patch。
- 必须回到该失败 Patch 之前最近一个没有发生错误的成功版本。
- 修复后的 Patch 必须基于这个最后成功版本重新生成。

要求：

1. 保持原修改目标不变，不要重新设计功能。
2. 只修复导致 Patch 无法应用的问题。
3. 必须基于下面提供的真实 Patch 和错误信息。
4. 输出一个完整、连续的 unified diff。
5. 必须使用标准：
   diff --git a/... b/...
6. 所有修改必须放在同一个 diff 代码块中。
7. diff 内不要插入解释文字。
8. 不要使用 ... 省略任何代码。
9. 所有文件路径使用项目根目录相对路径。
10. 确保每个 hunk 完整。
11. Patch 必须能够通过：

    git apply --recount --check

只输出修正后的完整 Patch。

===== BEGIN LATEST PATCH ERROR REPORT =====

EOF

        if [[ -f "$ERROR_REPORT" ]]; then
            cat "$ERROR_REPORT"
        else
            echo "(没有生成 patch-error.txt)"
        fi

        cat <<'EOF'

===== END LATEST PATCH ERROR REPORT =====


===== BEGIN LATEST FAILED PATCH =====

EOF

        if [[ -f "$patch" ]]; then
            cat "$patch"
        else
            echo "(没有找到 failed.patch)"
        fi

        cat <<'EOF'

===== END LATEST FAILED PATCH =====
EOF

} | {
    if [[ -n "${CHAT_BRIDGE_REPORT_FILE:-}" ]]; then
        umask 077
        tee "$CHAT_BRIDGE_REPORT_FILE" | /usr/bin/pbcopy
    else
        /usr/bin/pbcopy
    fi
}
}


# ------------------------------------------------------------
# 自动激活 Chat 或 Codex
# ------------------------------------------------------------

activate_chatgpt() {
    osascript \
        -e 'tell application id "com.openai.codex" to activate' \
        >/dev/null 2>&1 ||
    open -b "com.openai.codex" \
        >/dev/null 2>&1 ||
    osascript \
        -e 'tell application "ChatGPT" to activate' \
        >/dev/null 2>&1 ||
    open -a "ChatGPT" \
        >/dev/null 2>&1 ||
    true
}


# ------------------------------------------------------------
# Patch 失败诊断
# ------------------------------------------------------------

diagnose_failure() {
    local patch="$1"
    local error_file="$2"

    #
    # failed.patch 永远覆盖旧版本。
    #
    cp "$patch" "$FAILED_PATCH"

    #
    # patch-error.txt 永远重新创建。
    #
    write_report_header

    {
        echo "Git error:"
        echo
        cat "$error_file"
        echo
    } >> "$ERROR_REPORT"


    echo
    print_hr
    echo


    # ========================================================
    # 1. Patch 本身结构损坏
    # ========================================================

    if grep -q 'corrupt patch at' "$error_file"; then

        local line
        line="$(extract_corrupt_line "$error_file")"

        echo "错误类型：Patch 结构损坏"
        echo
        echo "Git 无法解析这个 unified diff。"
        echo
        echo "这不是本地源码冲突，而是 Patch 本身格式不合法。"

        if [[ -n "$line" ]] && is_integer "$line"; then
            echo
            echo "Git 报告的故障行：$line"

            show_patch_context "$patch" "$line"
        fi

        echo
        echo "常见原因："
        echo
        echo "  1. @@ hunk 行数与实际内容不一致"
        echo "  2. 某个 hunk 被截断"
        echo "  3. diff 中混入了解释文字"
        echo "  4. Patch 复制不完整"
        echo "  5. 某行缺少 unified diff 要求的前缀"
        echo "  6. 多个代码块没有完整复制"
        echo
        echo "已经自动尝试："
        echo
        echo "  ✓ UTF-8 BOM 清理"
        echo "  ✓ CRLF → LF"
        echo "  ✓ Markdown code fence 提取"
        echo "  ✓ git apply --recount"
        echo
        echo "上述处理后仍然失败，因此需要修正 Patch。"

        {
            echo "Diagnosis:"
            echo
            echo "Type: corrupt patch"
            echo "Patch structure is invalid."
            echo "Corrupt patch line: ${line:-unknown}"
            echo
        } >> "$ERROR_REPORT"

        if [[ -n "$line" ]] && is_integer "$line"; then

            local report_start=$(( line - 8 ))
            local report_end=$(( line + 8 ))

            (( report_start < 1 )) && report_start=1

            {
                echo "Patch context:"
                echo

                nl -ba "$patch" |
                    sed -n "${report_start},${report_end}p"

                echo
            } >> "$ERROR_REPORT"
        fi

        return
    fi


    # ========================================================
    # 2. Patch 很可能已经应用过
    #
    # 必须在普通 patch failed 判断之前进行。
    # ========================================================

    if git apply \
        --recount \
        --check \
        -R \
        "$patch" \
        >/dev/null 2>&1
    then
        PATCH_ALREADY_APPLIED=1
        report_already_applied \
            "$patch" \
            "该 Patch 无法再次正向应用，但通过了严格的反向安全检查：git apply --recount --check -R。"

        return
    fi

    if patch_added_lines_exist "$patch"; then
        PATCH_ALREADY_APPLIED=1
        report_already_applied \
            "$patch" \
            "严格反向检查未通过，但 Patch 中的全部非空新增行都已在目标文件中找到；这是弱匹配，不能确认对应的提交。"

        return
    fi


    # ========================================================
    # 3. Patch 与当前源码不匹配
    # ========================================================

    if grep -qE 'patch failed: .+:[0-9]+' "$error_file"; then

        local failed=""
        local file=""
        local line=""

        failed="$(
            sed -nE \
                's/^error: patch failed: (.+):([0-9]+)$/\1|\2/p' \
                "$error_file" |
            head -1
        )"

        if [[ -z "$failed" ]]; then
            failed="$(
                sed -nE \
                    's/.*patch failed: (.+):([0-9]+).*/\1|\2/p' \
                    "$error_file" |
                head -1
            )"
        fi

        if [[ -n "$failed" ]]; then
            file="${failed%%|*}"
            line="${failed##*|}"
        fi

        echo "错误类型：Patch 与当前源码不匹配"

        if [[ -n "$file" ]]; then
            echo
            echo "文件："
            echo
            echo "  $file"
        fi

        if [[ -n "$line" ]] && is_integer "$line"; then
            echo
            echo "Patch 目标位置："
            echo
            echo "  line $line"

            show_source_context "$file" "$line"
        fi

        echo
        echo "判断："
        echo
        echo "  Patch 语法通常没有问题。"
        echo "  但生成 Patch 时使用的源码上下文"
        echo "  与当前本地源码已经不一致。"
        echo
        echo "常见原因："
        echo
        echo "  - 本地代码在生成 Patch 后又修改过"
        echo "  - Chat 使用的是旧 project-context.md"
        echo "  - 前一轮 Patch 已修改了附近代码"
        echo "  - 当前 Git branch 已变化"
        echo "  - Patch 基于另一版本生成"

        {
            echo "Diagnosis:"
            echo
            echo "Type: source context mismatch"
            echo
            echo "Patch syntax appears valid,"
            echo "but source context does not match."
            echo
            echo "File: ${file:-unknown}"
            echo "Target line: ${line:-unknown}"
            echo
        } >> "$ERROR_REPORT"

        if [[ -n "$file" ]] &&
           [[ -f "$file" ]] &&
           [[ -n "$line" ]] &&
           is_integer "$line"
        then

            local report_start=$(( line - 8 ))
            local report_end=$(( line + 8 ))

            (( report_start < 1 )) && report_start=1

            {
                echo "Current source context:"
                echo

                nl -ba "$file" |
                    sed -n "${report_start},${report_end}p"

                echo
            } >> "$ERROR_REPORT"
        fi

        return
    fi


    # ========================================================
    # 4. 文件路径错误
    # ========================================================

    if grep -qE \
        'No such file or directory|does not exist in index|unable to find|No such file' \
        "$error_file"
    then
        echo "错误类型：Patch 文件路径与当前项目不一致"
        echo
        echo "可能原因："
        echo
        echo "  1. Patch 使用了错误文件路径"
        echo "  2. 文件已经移动"
        echo "  3. 文件已经重命名"
        echo "  4. Patch 来自其他项目或分支"

        {
            echo "Diagnosis:"
            echo
            echo "Type: invalid file path"
            echo
            echo "Patch refers to a path that cannot be resolved"
            echo "in the current project."
            echo
        } >> "$ERROR_REPORT"

        return
    fi


    # ========================================================
    # 5. 其他 Patch 内容异常
    # ========================================================

    if grep -qE \
        'cannot apply binary patch|unrecognized input|invalid path' \
        "$error_file"
    then
        echo "错误类型：Patch 内容或目标异常"
        echo
        echo "Git 原始错误："
        echo
        cat "$error_file"

        {
            echo "Diagnosis:"
            echo
            echo "Type: invalid patch content"
            echo
            echo "Patch target or patch content is invalid."
            echo
        } >> "$ERROR_REPORT"

        return
    fi


    # ========================================================
    # 6. 无法自动分类
    # ========================================================

    echo "错误类型：无法自动分类"
    echo
    echo "Git 原始错误："
    echo
    cat "$error_file"

    {
        echo "Diagnosis:"
        echo
        echo "Type: unclassified"
        echo
        echo "Unclassified git apply failure."
        echo
    } >> "$ERROR_REPORT"
}


# ------------------------------------------------------------
# 处理真实 Patch 失败后的公共流程
# ------------------------------------------------------------

finish_failure() {
    echo
    print_hr
    echo
    echo "源码未发生任何修改。"
    echo
    echo "本次故障 Patch："
    echo
    echo "  .chatgpt/failed.patch"
    echo
    echo "本次诊断报告："
    echo
    echo "  .chatgpt/patch-error.txt"

    copy_failure_bundle_to_clipboard "$FAILED_PATCH"

    echo
    echo "✓ 本次诊断信息和失败 Patch"
    echo "  已自动复制到 macOS 剪贴板。"
    echo
    echo "✓ 不包含任何历史错误记录。"
    echo
    if [[ "${CHAT_BRIDGE_NO_ACTIVATE:-0}" != 1 ]]; then
        echo "✓ 正在切回 ChatGPT..."
        echo
        echo "回到当前会话后只需要："
        echo
        echo "  Command + V"
        echo
        echo "然后发送。"
        echo
        activate_chatgpt
    fi
}


# ------------------------------------------------------------
# 撤销最近一次成功 Patch
#
# --undo 不清除失败诊断。
#
# 因为它不是一次新的 Patch 应用请求。
# ------------------------------------------------------------

undo_last_patch() {

    if [[ ! -f "$LAST_PATCH" ]]; then
        echo "没有可撤销的 Bridge Patch。"
        exit 1
    fi

    echo
    echo "准备撤销最近一次 Chat Patch："
    echo

    git apply \
        --recount \
        --stat \
        "$LAST_PATCH" || true

    echo
    echo "执行反向安全检查..."
    echo

    if ! git apply \
        --recount \
        --check \
        -R \
        "$LAST_PATCH"
    then
        echo
        echo "错误：当前源码已经发生额外变化。"
        echo
        echo "无法安全撤销最近一次 Chat Patch。"
        echo
        echo "源码未发生任何修改。"

        exit 1
    fi

    echo "✓ 可以安全撤销"
    echo

    printf "确认撤销最近一次 Chat Patch？ [y/N] "
    read -r answer

    case "$answer" in
        y|Y|yes|YES)
            ;;
        *)
            echo
            echo "已取消。"
            exit 0
            ;;
    esac

    git apply \
        --recount \
        -R \
        "$LAST_PATCH"

    rm -f "$LAST_PATCH"

    echo
    echo "✓ 最近一次 Chat Patch 已撤销。"
    echo

    git status --short
}


# ------------------------------------------------------------
# --undo
#
# 必须放在“清除旧错误”之前。
# ------------------------------------------------------------

if [[ "${1:-}" == "--undo" ]]; then
    undo_last_patch
    exit 0
fi


# ------------------------------------------------------------
# --patch-file
#
# 自动提取路径使用临时文件；普通模式继续从剪贴板读取。
# ------------------------------------------------------------

PATCH_FILE=""

if [[ "${1:-}" == "--patch-file" ]]; then
    if [[ -z "${2:-}" ]]; then
        echo "错误：--patch-file 缺少文件路径。"
        exit 2
    fi

    PATCH_FILE="$2"
    shift 2

    if [[ ! -f "$PATCH_FILE" ]]; then
        echo "错误：Patch 文件不存在：$PATCH_FILE"
        exit 2
    fi
fi


# ------------------------------------------------------------
# 新一轮 Patch 应用开始
#
# 这里是关键：
#
# 每次正常执行 chat-apply-shell.sh，
# 都先删除上一轮失败记录。
#
# 因此：
#
#   failed.patch
#   patch-error.txt
#
# 要么不存在，
# 要么只属于“当前这一轮”。
#
# 绝不会混入历史错误。
# ------------------------------------------------------------

rm -f "$FAILED_PATCH"
rm -f "$ERROR_REPORT"


# ------------------------------------------------------------
# 临时文件
# ------------------------------------------------------------

TMP_RAW="$(mktemp -t chatgpt-raw)"
TMP_PATCH="$(mktemp -t chatgpt-patch)"
TMP_ERROR="$(mktemp -t chatgpt-error)"


cleanup() {
    rm -f \
        "$TMP_RAW" \
        "$TMP_PATCH" \
        "$TMP_ERROR"
}


trap cleanup EXIT


# ------------------------------------------------------------
# 1. 读取 Patch 输入
# ------------------------------------------------------------

if [[ -n "$PATCH_FILE" ]]; then
    cat "$PATCH_FILE" > "$TMP_RAW"
else
    /usr/bin/pbpaste -Prefer txt > "$TMP_RAW"
fi

if [[ ! -s "$TMP_RAW" ]]; then
    if [[ -n "$PATCH_FILE" ]]; then
        echo "错误：Patch 文件为空。"
    else
        echo "错误：macOS 剪贴板为空。"
    fi
    exit 10
fi


# ------------------------------------------------------------
# 2. 标准化并提取 Patch
#
# 自动处理：
#
#   UTF-8 BOM
#   CRLF
#   CR
#   ```diff
#   ```patch
#   ```
#
# 从第一个：
#
#   diff --git a/... b/...
#
# 开始。
# ------------------------------------------------------------

if ! python3 - "$TMP_RAW" "$TMP_PATCH" <<'PY'
import sys
from pathlib import Path


src = Path(sys.argv[1])
dst = Path(sys.argv[2])


data = src.read_bytes()


# UTF-8 BOM
if data.startswith(b"\xef\xbb\xbf"):
    data = data[3:]


# 统一换行符
data = data.replace(b"\r\n", b"\n")
data = data.replace(b"\r", b"\n")


try:
    text = data.decode("utf-8")
except UnicodeDecodeError as exc:
    print(
        f"错误：Patch 内容不是有效 UTF-8：{exc}",
        file=sys.stderr,
    )
    sys.exit(2)


lines = text.splitlines()


# ------------------------------------------------------------
# 找第一个 diff --git
# ------------------------------------------------------------

start = None

for index, line in enumerate(lines):
    if line.startswith("diff --git a/"):
        start = index
        break


if start is None:
    print(
        "错误：输入内容中没有找到标准 Git Patch。",
        file=sys.stderr,
    )
    sys.exit(3)


# ------------------------------------------------------------
# 判断是否位于 Markdown fenced code block
# ------------------------------------------------------------

inside_fence = False
fence_marker = None

for index in range(start - 1, -1, -1):

    stripped = lines[index].strip()

    if not stripped:
        continue

    if stripped.startswith("```"):
        inside_fence = True
        fence_marker = "```"

    elif stripped.startswith("~~~"):
        inside_fence = True
        fence_marker = "~~~"

    break


# ------------------------------------------------------------
# 提取 Patch
# ------------------------------------------------------------

result = []


for line in lines[start:]:

    stripped = line.strip()

    if (
        inside_fence
        and fence_marker is not None
        and stripped == fence_marker
    ):
        break

    result.append(line)


# 清除尾部多余空行
while result and not result[-1].strip():
    result.pop()


if not result:
    print(
        "错误：提取后的 Patch 为空。",
        file=sys.stderr,
    )
    sys.exit(4)


dst.write_text(
    "\n".join(result) + "\n",
    encoding="utf-8",
)
PY
then
    echo
    echo "Patch 提取失败。"
    exit 11
fi


# ------------------------------------------------------------
# 3. 基本格式检查
#
# 这些属于输入问题，不生成诊断文件。
#
# 因为 ChatGPT 不需要根据 failed.patch 来修复。
# ------------------------------------------------------------

if [[ ! -s "$TMP_PATCH" ]]; then
    echo "错误：提取后的 Patch 为空。"
    exit 12
fi


if ! grep -q '^diff --git a/' "$TMP_PATCH"; then
    echo "错误：Patch 缺少标准 diff --git 文件头。"
    exit 13
fi


if ! grep -q '^--- ' "$TMP_PATCH"; then
    echo "错误：Patch 缺少 --- 文件头。"
    exit 14
fi


if ! grep -q '^+++ ' "$TMP_PATCH"; then
    echo "错误：Patch 缺少 +++ 文件头。"
    exit 15
fi


# ------------------------------------------------------------
# 4. 显示准备修改的文件
# ------------------------------------------------------------

echo
echo "准备应用以下修改："
echo

grep '^diff --git ' "$TMP_PATCH" |
    sed -E \
        's#^diff --git a/(.*) b/(.*)$#  \2#'

echo


# ------------------------------------------------------------
# 5. 安全检查
#
# --recount：
#
# ChatGPT 偶尔会生成：
#
#   @@ -120,8 +120,10 @@
#
# 但 hunk 中实际行数与 8 / 10 不完全一致。
#
# --recount 根据实际内容重新计算。
# ------------------------------------------------------------

echo "执行 Patch 结构及源码上下文检查..."
echo

: > "$TMP_ERROR"

if ! git apply \
    --recount \
    --check \
    --verbose \
    "$TMP_PATCH" \
    2>"$TMP_ERROR"
then

    #
    # 只有到这里才是真正值得发送给 ChatGPT
    # 进行 Patch 修复的错误。
    #

    diagnose_failure \
        "$TMP_PATCH" \
        "$TMP_ERROR"

    if (( PATCH_ALREADY_APPLIED )); then
        echo
        echo "✓ Patch 已经应用，无需重复修改。"
        exit 0
    fi

    finish_failure

    exit 20
fi


# ------------------------------------------------------------
# 6. 检查通过
# ------------------------------------------------------------

echo "✓ Patch 结构正确"
echo "✓ Patch 与当前源码匹配"
echo "✓ 安全检查通过"
echo


# ------------------------------------------------------------
# 7. 显示修改统计
# ------------------------------------------------------------

git apply \
    --recount \
    --stat \
    "$TMP_PATCH" || true

echo


# ------------------------------------------------------------
# 8. 自动应用
#
# 不询问 y/N。
#
# 只有 git apply --check 完整通过后，
# 才会执行真正修改。
# ------------------------------------------------------------

echo "安全检查通过，自动应用 Patch..."
echo

: > "$TMP_ERROR"

if ! git apply \
    --recount \
    "$TMP_PATCH" \
    2>"$TMP_ERROR"
then

    #
    # 极少见情况：
    #
    # check 成功，但实际 apply 失败。
    #
    # 仍然只记录当前这一轮错误。
    #

    cp "$TMP_PATCH" "$FAILED_PATCH"

    write_report_header

    {
        echo "Git error during final apply:"
        echo
        cat "$TMP_ERROR"
        echo
        echo "Diagnosis:"
        echo
        echo "Type: final apply failure"
        echo
        echo "The safety check succeeded,"
        echo "but the final git apply command failed."
        echo
        echo "The working tree may have changed"
        echo "between check and apply."
        echo
    } >> "$ERROR_REPORT"

    echo "错误：安全检查通过，但实际应用 Patch 时发生异常。"
    echo
    cat "$TMP_ERROR"

    finish_failure

    exit 21
fi


# ------------------------------------------------------------
# 9. 应用后语法检查
#
# 语法检查失败时立即反向撤销本次 Patch，不能把“代码已修改但
# 无法解析”的状态保存成成功 Patch。
# ------------------------------------------------------------

VALIDATION_OUTPUT=""

if ! VALIDATION_OUTPUT="$(validate_applied_files "$TMP_PATCH" 2>&1)"; then
    cp "$TMP_PATCH" "$FAILED_PATCH"

    write_report_header

    {
        echo "Validation error:"
        echo
        printf '%s\n' "$VALIDATION_OUTPUT"
        echo
        echo "Diagnosis:"
        echo
        echo "Type: syntax validation failed"
        echo "The Patch was applied, but a changed source file failed syntax validation."
        echo
    } >> "$ERROR_REPORT"

    echo "$VALIDATION_OUTPUT"
    echo
    echo "错误：Patch 应用后语法检查失败。"
    echo
    echo "执行反向安全检查并撤销本次 Patch..."

    if git apply \
        --recount \
        --check \
        -R \
        "$TMP_PATCH" \
        >/dev/null 2>&1
    then
        git apply \
            --recount \
            -R \
            "$TMP_PATCH"
        echo "✓ 本次 Patch 已自动撤销，源码恢复到应用前状态。"
    else
        echo "警告：无法安全自动撤销本次 Patch，请立即检查 git diff。"
    fi

    finish_failure
    exit 22
fi

printf '%s\n' "$VALIDATION_OUTPUT"


# ------------------------------------------------------------
# 10. 保存最近一次成功 Patch
# ------------------------------------------------------------

cp "$TMP_PATCH" "$LAST_PATCH"


# ------------------------------------------------------------
# 11. 成功后确保不存在失败记录
#
# 理论上开始执行时已经删除，
# 这里再次清理，保证状态绝对明确。
# ------------------------------------------------------------

rm -f "$FAILED_PATCH"
rm -f "$ERROR_REPORT"


# ------------------------------------------------------------
# 12. 完成
# ------------------------------------------------------------

echo "✓ Patch 已成功应用到原项目文件。"
echo

git status --short

echo
echo "查看实际修改："
echo
echo "  git diff"
echo
echo "撤销本次 Bridge 修改："
echo
echo "  ./tools/chat-apply-shell.sh --undo"
