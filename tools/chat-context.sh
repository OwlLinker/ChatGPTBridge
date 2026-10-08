#!/usr/bin/env bash
set -euo pipefail

# 通用 Bridge：脚本放在任意 Git 项目的 tools/ 下即可使用。
# 从其他工作目录通过绝对路径调用时，也会根据脚本位置识别项目根目录。

# 用法：
#
#   ./tools/chat-context.sh full
#       生成完整项目上下文：.chatgpt/project-context.md
#
#   ./tools/chat-context.sh diff
#       生成相对当前 Git HEAD 的工作区增量：.chatgpt/project-diff.md
#
# 将生成的 Markdown 文件提供给普通 ChatGPT Chat，用于后续代码分析和
# unified diff 生成。脚本会排除 .git、.chatgpt、依赖目录和敏感文件。
#
# 新对话使用 diff 时，发送：
#
#   项目代码修改以后，只生成变化
#
#   ./tools/chat-context.sh diff
#
#   这是项目相对于之前完整快照的最新变化，以这个 diff 更新当前代码状态。
#
# 新对话使用 full 时，发送：
#
#   新对话，生成整个项目
#
#   ./tools/chat-context.sh full
#
#   project-context.md 是当前项目的完整源码快照。后续代码分析以这个文件中的实际项目内容为准。

MODE="${1:-full}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

if ROOT="$(git -C "${SCRIPT_PROJECT_ROOT}" rev-parse --show-toplevel 2>/dev/null)"; then
    :
elif ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"; then
    :
else
    ROOT="${PWD}"
fi

OUT_DIR="${ROOT}/.chatgpt"
IGNORE_FILE="${CHAT_BRIDGE_IGNORE_FILE:-${ROOT}/.chatgpt/ignore}"
ACTIVE_PROJECT_DIR="${HOME}/.chatbridge"
ACTIVE_PROJECT_FILE="${ACTIVE_PROJECT_DIR}/active-project"
ACTIVE_PROJECTS_FILE="${ACTIVE_PROJECT_DIR}/projects"

MAX_FILE_BYTES="${MAX_FILE_BYTES:-524288}"       # 单文件 512 KB
MAX_TOTAL_BYTES="${MAX_TOTAL_BYTES:-12582912}"   # 总计约 12 MB

mkdir -p "${OUT_DIR}"

record_active_project() {
    git -C "${ROOT}" rev-parse --git-dir >/dev/null 2>&1 || return 0

    mkdir -p "${ACTIVE_PROJECT_DIR}"
    chmod 700 "${ACTIVE_PROJECT_DIR}"
    local projects_tmp="${ACTIVE_PROJECTS_FILE}.tmp.$$"
    { [[ -f "${ACTIVE_PROJECTS_FILE}" ]] && cat "${ACTIVE_PROJECTS_FILE}" || true
      printf '%s\n' "${ROOT}"
    } | LC_ALL=C sort -u > "${projects_tmp}"
    chmod 600 "${projects_tmp}"
    mv -f "${projects_tmp}" "${ACTIVE_PROJECTS_FILE}"
    local tmp="${ACTIVE_PROJECT_FILE}.tmp.$$"
    printf '%s\n' "${ROOT}" > "${tmp}"
    chmod 600 "${tmp}"
    mv -f "${tmp}" "${ACTIVE_PROJECT_FILE}"
}

# 不修改项目 .gitignore，只在本地 Git exclude 中忽略 .chatgpt
if git -C "${ROOT}" rev-parse --git-dir >/dev/null 2>&1; then
    GIT_EXCLUDE="$(git -C "${ROOT}" rev-parse --path-format=absolute --git-path info/exclude)"
    mkdir -p "$(dirname "${GIT_EXCLUDE}")"

    if ! grep -qxF '/.chatgpt/' "${GIT_EXCLUDE}" 2>/dev/null; then
        printf '\n/.chatgpt/\n' >> "${GIT_EXCLUDE}"
    fi
fi

file_size() {
    local file="$1"

    if stat -f '%z' "${file}" >/dev/null 2>&1; then
        stat -f '%z' "${file}"
    else
        stat -c '%s' "${file}"
    fi
}

is_secret_path() {
    local path="$1"
    local base="${path##*/}"

    case "${path}" in
        .env|.env.*|*.env|*/.env|*/.env.*|*/.env)
            return 0
            ;;
        *.pem|*.key|*.p12|*.pfx|*.mobileprovision|*.tfvars|*.tfvars.json|*.secret|*.secrets)
            return 0
            ;;
        */.ssh/*|.ssh/*|*/.aws/*|.aws/*|*/.config/gcloud/*|.config/gcloud/*|*/.docker/config.json|.docker/config.json)
            return 0
            ;;
    esac

    case "${base}" in
        id_rsa|id_rsa.pub|id_ed25519|id_ed25519.pub|id_ecdsa|id_ecdsa.pub|id_dsa|id_dsa.pub|id_x25519|id_x25519.pub|.npmrc|.netrc|.pypirc)
            return 0
            ;;
        credentials|credentials.*|credentials_*|credentials-*|*credentials*|*secret*|*secrets*|*token*)
            return 0
            ;;
        secrets|secrets.*|secrets_*|secrets-*)
            return 0
            ;;
    esac

    return 1
}

is_custom_ignored() {
    local path="$1"

    [[ -f "${IGNORE_FILE}" ]] || return 1

    if git -C "${ROOT}" rev-parse --git-dir >/dev/null 2>&1; then
        git -C "${ROOT}" \
            -c "core.excludesfile=${IGNORE_FILE}" \
            check-ignore \
            --no-index \
            --quiet \
            --stdin \
            <<< "${path}" \
            >/dev/null 2>&1
        return $?
    fi

    local pattern
    while IFS= read -r pattern || [[ -n "${pattern}" ]]; do
        pattern="${pattern%%#*}"
        pattern="${pattern#"${pattern%%[![:space:]]*}"}"
        pattern="${pattern%"${pattern##*[![:space:]]}"}"
        [[ -n "${pattern}" ]] || continue
        [[ "${pattern}" == !* ]] && continue
        pattern="${pattern#/}"

        case "${path}" in
            ${pattern}|${pattern}/*)
                return 0
                ;;
        esac
    done < "${IGNORE_FILE}"

    return 1
}

should_include() {
    local path="$1"
    local base="${path##*/}"

    # Do not follow links out of the project root. A linked text file can
    # otherwise expose content from outside the project snapshot boundary.
    [[ -L "${ROOT}/${path}" ]] && return 1

    case "${path}" in
        .git/*|*/.git/*)
            return 1
            ;;
        .chatgpt/*|*/.chatgpt/*)
            return 1
            ;;
        CHAT-BRIDGE.md|BRIDGE-MANUAL.md|tools/chat-*.sh|tools/chat-*.swift|\
        utils/ChatGPTApplyPatch.lua|modules/keyComboBind/ChatGPTPatchMonitorToggle.lua|\
        config/chatGPTPatchMonitor.json)
            return 1
            ;;
        node_modules/*|*/node_modules/*)
            return 1
            ;;
        vendor/*|*/vendor/*)
            return 1
            ;;
        dist/*|*/dist/*)
            return 1
            ;;
        build/*|*/build/*)
            return 1
            ;;
        .cache/*|*/.cache/*)
            return 1
            ;;
        __pycache__/*|*/__pycache__/*)
            return 1
            ;;
        .venv/*|*/.venv/*|venv/*|*/venv/*)
            return 1
            ;;
        .idea/*|*/.idea/*|.vscode/*|*/.vscode/*)
            return 1
            ;;
        coverage/*|*/coverage/*|.nyc_output/*|*/.nyc_output/*)
            return 1
            ;;
        .next/*|*/.next/*|.nuxt/*|*/.nuxt/*|.turbo/*|*/.turbo/*)
            return 1
            ;;
    esac

    if is_custom_ignored "${path}"; then
        return 1
    fi

    if is_secret_path "${path}"; then
        return 1
    fi

    # 常见文本/代码文件
    case "${path}" in
        *.lua|\
        *.m|*.mm|*.h|*.hh|*.hpp|*.hxx|*.c|*.cc|*.cpp|*.cxx|\
        *.swift|*.swiftinterface|*.metal|*.proto|\
        *.xcconfig|*.pbxproj|*.entitlements|*.storyboard|*.xib|*.strings|*.stringsdict|\
        *.rs|*.go|*.java|*.kt|*.kts|*.cs|*.fs|*.fsx|*.fsi|*.vb|\
        *.dart|*.scala|*.sc|*.groovy|*.gradle|*.ex|*.exs|*.erl|*.hrl|*.clj|*.cljs|*.cljc|*.pl|*.pm|\
        *.rb|*.php|*.vue|*.svelte|*.css|*.scss|*.html|*.xml|\
        *.json|\
        *.md|\
        *.txt|\
        *.sh|\
        *.bash|\
        *.zsh|\
        *.py|\
        *.js|\
        *.mjs|\
        *.cjs|\
        *.ts|\
        *.tsx|\
        *.jsx|\
        *.yaml|\
        *.yml|\
        *.toml|\
        *.xcconfig|*.pbxproj|*.entitlements|*.storyboard|*.xib|*.strings|*.stringsdict|\
        *.ini|\
        *.conf|\
        *.cfg|\
        *.plist|\
        *.sql)
            return 0
            ;;
    esac

    # 常见无扩展名文本文件
    case "${base}" in
        README|LICENSE|Makefile|Dockerfile|Rakefile|Gemfile)
            return 0
            ;;
    esac

    return 1
}

is_implementation_file() {
    case "$1" in
        *.lua|*.m|*.mm|*.h|*.hh|*.hpp|*.hxx|*.c|*.cc|*.cpp|*.cxx|\
        *.swift|*.swiftinterface|*.metal|*.proto|*.xcconfig|*.pbxproj|*.entitlements|\
        *.storyboard|*.xib|*.strings|*.stringsdict|*.rs|*.go|*.java|*.kt|*.kts|\
        *.cs|*.fs|*.fsx|*.fsi|*.vb|*.dart|*.scala|*.sc|*.groovy|*.gradle|\
        *.ex|*.exs|*.erl|*.hrl|*.clj|*.cljs|*.cljc|*.pl|*.pm|*.rb|*.php|\
        *.vue|*.svelte|*.css|*.scss|*.html|*.xml|*.json|*.yaml|*.yml|*.toml|*.plist|\
        *.py|*.js|*.mjs|*.cjs|*.ts|*.tsx|*.jsx|*.sh|*.bash|*.zsh|*.sql)
            return 0
            ;;
    esac
    return 1
}

append_file() {
    local output="$1"
    local rel="$2"
    local force_full="${3:-false}"
    local abs="${ROOT}/${rel}"

    [[ -f "${abs}" ]] || return 0
    should_include "${rel}" || return 0

    local size
    size="$(file_size "${abs}")"

    if [[ "${force_full}" != true ]] && (( size > MAX_FILE_BYTES )); then
        printf '\n===== SKIPPED LARGE FILE: %s (%s bytes) =====\n' \
            "${rel}" "${size}" >> "${output}"
        return 0
    fi

    printf '\n\n===== BEGIN FILE: %s =====\n' "${rel}" >> "${output}"
    cat "${abs}" >> "${output}"

    # 确保 END marker 从新行开始
    if [[ -s "${abs}" ]] && [[ "$(tail -c 1 "${abs}" 2>/dev/null || true)" != "" ]]; then
        printf '\n' >> "${output}"
    fi

    printf '===== END FILE: %s =====\n' "${rel}" >> "${output}"
}

write_header() {
    local output="$1"

    {
        printf '# Local project context\n\n'
        printf 'Project root: `%s`\n\n' "$(basename "${ROOT}")"

        if git -C "${ROOT}" rev-parse --git-dir >/dev/null 2>&1; then
            printf 'Branch: `%s`\n\n' \
                "$(git -C "${ROOT}" branch --show-current 2>/dev/null || true)"

            head="$(git -C "${ROOT}" rev-parse --short HEAD 2>/dev/null || true)"
            [[ -n "${head}" ]] || head="none (no commits)"
            printf 'HEAD: `%s`\n\n' "${head}"
        fi

        cat <<'EOF'
This file is an automatically generated snapshot of a local source tree.

When analysing the project:

- Treat `===== BEGIN FILE: ... =====` as the exact file path.
- Treat the included source files as the current local source baseline.
- All implementation and behavior-defining files are included before supporting documents; implementation files are never truncated by the snapshot size limits.
- Do not invent files that are not present in this snapshot.
- Distinguish existing implementation from proposed changes.
- If the user provides a newer real source file, that file supersedes all previous context and Patch history.
- Do not treat `.chatgpt/failed.patch`, `.chatgpt/patch-error.txt` or any failed Patch as applied source.
- A failed Patch must be repaired against the last successful, error-free source version.

Patch output protocol:

- Output one complete, continuous unified diff only when a code change is requested.
- Use `diff --git a/... b/...` and project-root-relative paths.
- Put the complete diff in one fenced code block; do not use `...` to omit code.
- Ensure every hunk is complete and can pass `git apply --recount --check`.
- `Tab+A` automatically reads the last assistant `Diff` code block; the manual clipboard path remains available for Terminal use.
- Do not assume a Patch becomes a new baseline until the user confirms it works or continues with a new request without reporting an error.

The `.chatgpt` directory is Bridge runtime state and is intentionally excluded from the source snapshot.

EOF

        if [[ -f "${OUT_DIR}/PATCH-BASELINE.md" ]]; then
            printf '\n## Project Patch baseline rules\n\n'
            cat "${OUT_DIR}/PATCH-BASELINE.md"
            printf '\n'
        fi
    } > "${output}"
}

generate_full() {
    local output="${OUT_DIR}/project-context.md"
    local tmp="${output}.tmp"

    write_header "${tmp}"

    {
        printf '\n# Repository status\n\n'
        printf '```text\n'

        if git -C "${ROOT}" rev-parse --git-dir >/dev/null 2>&1; then
            git -C "${ROOT}" status --short || true
        else
            printf 'Not a Git repository.\n'
        fi

        printf '```\n'

        printf '\n# Project file tree\n\n'
        printf '```text\n'
    } >> "${tmp}"

    local files=()

    if git -C "${ROOT}" rev-parse --git-dir >/dev/null 2>&1; then
        while IFS= read -r -d '' file; do
            should_include "${file}" || continue
            files+=("${file}")
        done < <(
            git -C "${ROOT}" \
                ls-files \
                --cached \
                --others \
                --exclude-standard \
                -z
        )
    else
        while IFS= read -r -d '' abs; do
            local rel="${abs#"${ROOT}/"}"
            should_include "${rel}" || continue
            files+=("${rel}")
        done < <(
            find "${ROOT}" \
                -type f \
                -not -path '*/.git/*' \
                -not -path '*/.chatgpt/*' \
                -print0
        )
    fi

    if (( ${#files[@]} > 0 )); then
        printf '%s\n' "${files[@]}" | LC_ALL=C sort >> "${tmp}"
    fi

    printf '```\n' >> "${tmp}"

    local total=0

    # Include all implementation sources first and in full. Limits apply only
    # to supporting material so it cannot displace code needed for a safe Patch.
    while IFS= read -r file; do
        [[ -n "${file}" ]] || continue
        is_implementation_file "${file}" || continue

        local abs="${ROOT}/${file}"
        [[ -f "${abs}" ]] || continue

        local size
        size="$(file_size "${abs}")"
        append_file "${tmp}" "${file}" true
        total=$((total + size))
    done < <(
        if (( ${#files[@]} > 0 )); then
            printf '%s\n' "${files[@]}" | LC_ALL=C sort
        fi
    )

    while IFS= read -r file; do
        [[ -n "${file}" ]] || continue
        is_implementation_file "${file}" && continue

        local abs="${ROOT}/${file}"
        [[ -f "${abs}" ]] || continue

        local size
        size="$(file_size "${abs}")"

        if (( size <= MAX_FILE_BYTES && total + size > MAX_TOTAL_BYTES )); then
            {
                printf '\n\n# Supporting context size limit reached\n\n'
                printf 'Remaining documentation and supporting files were omitted after reaching %s bytes. All implementation files above are included in full.\n' \
                    "${MAX_TOTAL_BYTES}"
            } >> "${tmp}"
            break
        fi

        append_file "${tmp}" "${file}"

        if (( size <= MAX_FILE_BYTES )); then
            total=$((total + size))
        fi
    done < <(
        if (( ${#files[@]} > 0 )); then
            printf '%s\n' "${files[@]}" | LC_ALL=C sort
        fi
    )

    mv "${tmp}" "${output}"
    record_active_project

    printf 'Generated:\n%s\n' "${output}"
    printf 'Size: %s bytes\n' "$(file_size "${output}")"
}

generate_diff() {
    local output="${OUT_DIR}/project-diff.md"
    local tmp="${output}.tmp"

    if ! git -C "${ROOT}" rev-parse --git-dir >/dev/null 2>&1; then
        printf 'diff mode requires a Git repository.\n' >&2
        exit 1
    fi

    write_header "${tmp}"

    {
        printf '\n# Current Git status\n\n'
        printf '```text\n'
        git -C "${ROOT}" status --short || true
        printf '```\n'

        printf '\n# Current working-tree changes relative to Git HEAD\n'
        printf '\nThis is not necessarily a diff since the last uploaded snapshot.\n'
        printf 'It includes all current unstaged, staged and untracked project changes that pass the inclusion rules.\n'
    } >> "${tmp}"

    # macOS 默认 Bash 3.2 不支持 declare -A，使用索引数组收集后排序去重。
    local changed_files=()

    while IFS= read -r -d '' file; do
        changed_files+=("${file}")
    done < <(
        git -C "${ROOT}" diff --name-only -z
    )

    while IFS= read -r -d '' file; do
        changed_files+=("${file}")
    done < <(
        git -C "${ROOT}" diff --cached --name-only -z
    )

    while IFS= read -r -d '' file; do
        changed_files+=("${file}")
    done < <(
        git -C "${ROOT}" \
            ls-files \
            --others \
            --exclude-standard \
            -z
    )

    if (( ${#changed_files[@]} == 0 )); then
        printf '\nNo local changes.\n' >> "${tmp}"
        mv "${tmp}" "${output}"
        record_active_project
        printf 'Generated:\n%s\n' "${output}"
        exit 0
    fi

    while IFS= read -r file; do
        [[ -n "${file}" ]] || continue
        should_include "${file}" || continue

        printf '\n\n## %s\n' "${file}" >> "${tmp}"

        if git -C "${ROOT}" ls-files --error-unmatch -- "${file}" \
            >/dev/null 2>&1; then

            printf '\n### Unstaged diff\n\n```diff\n' >> "${tmp}"
            git -C "${ROOT}" \
                --no-pager \
                diff \
                --no-ext-diff \
                -- "${file}" >> "${tmp}" || true
            printf '\n```\n' >> "${tmp}"

            printf '\n### Staged diff\n\n```diff\n' >> "${tmp}"
            git -C "${ROOT}" \
                --no-pager \
                diff \
                --cached \
                --no-ext-diff \
                -- "${file}" >> "${tmp}" || true
            printf '\n```\n' >> "${tmp}"
        else
            printf '\n### New untracked file\n' >> "${tmp}"
            if is_implementation_file "${file}"; then
                append_file "${tmp}" "${file}" true
            else
                append_file "${tmp}" "${file}"
            fi
        fi
    done < <(
        printf '%s\n' "${changed_files[@]}" | LC_ALL=C sort -u
    )

    mv "${tmp}" "${output}"
    record_active_project

    printf 'Generated:\n%s\n' "${output}"
    printf 'Size: %s bytes\n' "$(file_size "${output}")"
}

case "${MODE}" in
    full)
        generate_full
        ;;
    diff)
        generate_diff
        ;;
    *)
        printf 'Usage: %s [full|diff]\n' "$0" >&2
        exit 2
        ;;
esac
