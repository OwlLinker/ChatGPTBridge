#!/bin/zsh
set -euo pipefail

# Hammerspoon 专用 ChatGPTBridge 包装器。
# 只输出简短状态到 stdout，详细诊断输出到 stderr，供 Hammerspoon 控制台显示。

export LANG="en_US.UTF-8"
export LC_ALL="en_US.UTF-8"

script_path="${0:A}"
script_dir="${script_path:h}"
project_root="${script_dir:h}"
core_script="$script_dir/chat-apply-shell.sh"

# Hammerspoon 定位最近生成上下文的 Git 项目；手动调用时仍用脚本所在项目。
active_project_file="${HOME}/.chatbridge/active-project"
active_projects_file="${HOME}/.chatbridge/projects"
active_project_root=""
if [[ -r "$active_project_file" ]]; then
    active_project_candidate="$(<"$active_project_file")"
    if [[ -n "$active_project_candidate" ]] \
        && active_project_root="$(git -C "$active_project_candidate" rev-parse --show-toplevel 2>/dev/null)"; then
        project_root="$active_project_root"
    fi
fi

if [[ "${1:-}" == "--hammerspoon" ]]; then
    shift
fi

# The global active-project pointer can become stale when another project
# refreshes its snapshot. Prefer the unique repository where this exact Patch
# passes a read-only check, otherwise use unique file-path ownership.
argv=("$@")
patch_file=""
for (( index = 1; index <= ${#argv[@]}; index++ )); do
    if [[ "${argv[$index]}" == "--patch-file" ]] \
        && (( index < ${#argv[@]} )); then
        patch_file="${argv[$((index + 1))]}"
        break
    fi
done

project_roots=()
add_project_candidate() {
    local candidate="$1"
    local resolved=""
    [[ -n "$candidate" ]] || return 0
    resolved="$(git -C "$candidate" rev-parse --show-toplevel 2>/dev/null)" || return 0
    local known
    for known in "${project_roots[@]}"; do
        [[ "$known" == "$resolved" ]] && return 0
    done
    project_roots+=("$resolved")
}

add_project_candidate "$active_project_root"
if [[ -r "$active_projects_file" ]]; then
    while IFS= read -r candidate; do
        add_project_candidate "$candidate"
    done < "$active_projects_file"
fi
add_project_candidate "${script_dir:h}"

patch_paths=()
if [[ -n "$patch_file" && -f "$patch_file" && ${#project_roots[@]} -gt 0 ]]; then
    parse_root="${active_project_root:-${project_roots[1]}}"
    while IFS= read -r -d '' entry; do
        patch_path="${entry##*$'\t'}"
        [[ -n "$patch_path" ]] && patch_paths+=("$patch_path")
    done < <(git -C "$parse_root" apply --recount --numstat -z "$patch_file" 2>/dev/null || true)

    # numstat can fail to parse malformed hunks. Diff headers still identify
    # target paths so a unique project can be selected safely.
    if (( ${#patch_paths[@]} == 0 )); then
        while IFS= read -r patch_path; do
            [[ -n "$patch_path" && "$patch_path" != /dev/null ]] && patch_paths+=("$patch_path")
        done < <(sed -n \
            -e 's|^diff --git a/\(.*\) b/.*$|\1|p' \
            -e 's|^--- a/||p' \
            "$patch_file" | sort -u)
    fi

    applicable_roots=()
    for candidate in "${project_roots[@]}"; do
        if git -C "$candidate" apply --check --recount "$patch_file" >/dev/null 2>&1; then
            applicable_roots+=("$candidate")
        fi
    done

    if (( ${#applicable_roots[@]} == 1 )); then
        project_root="${applicable_roots[1]}"
    elif (( ${#patch_paths[@]} > 0 )); then
        path_match_roots=()
        for candidate in "${project_roots[@]}"; do
            all_paths_match=1
            for patch_path in "${patch_paths[@]}"; do
                if [[ ! -e "$candidate/$patch_path" ]] \
                    && ! git -C "$candidate" ls-files --error-unmatch -- "$patch_path" >/dev/null 2>&1; then
                    all_paths_match=0
                    break
                fi
            done
            (( all_paths_match == 1 )) && path_match_roots+=("$candidate")
        done

        if (( ${#applicable_roots[@]} > 1 )); then
            if (( ${#path_match_roots[@]} == 1 )); then
                project_root="${path_match_roots[1]}"
            else
                print -u2 -r -- "错误：无法唯一确认 Patch 所属项目，未执行应用。"
                exit 2
            fi
        elif (( ${#applicable_roots[@]} == 0 )); then
            if (( ${#path_match_roots[@]} == 1 )); then
                project_root="${path_match_roots[1]}"
            else
                print -u2 -r -- "错误：无法根据 Patch 文件路径唯一确认项目，未执行应用。"
                exit 2
            fi
        fi
    else
        print -u2 -r -- "错误：无法从 Patch 读取目标文件路径，未执行应用。"
        exit 2
    fi
fi

if [[ -n "$project_root" && "$project_root" != "$active_project_root" ]]; then
    mkdir -p "${HOME}/.chatbridge"
    chmod 700 "${HOME}/.chatbridge"
    pointer_tmp="${active_project_file}.tmp.$$"
    printf '%s\n' "$project_root" > "$pointer_tmp"
    chmod 600 "$pointer_tmp"
    mv -f "$pointer_tmp" "$active_project_file"
fi
print -u2 -r -- "[ChatGPTBridge] project route: $project_root"

output_file="$(mktemp -t chat-apply-hammerspoon)"

cleanup_hammerspoon() {
    rm -f "$output_file"
}

trap cleanup_hammerspoon EXIT

if cd "$project_root" && CHAT_BRIDGE_PROJECT_ROOT="$project_root" "$core_script" "$@" >"$output_file" 2>&1; then
    exit_code=0
else
    exit_code=$?
fi

if grep -Fq "错误类型：Patch 很可能已经应用过" "$output_file" ||
   grep -Fq "Type: already applied" "$output_file"
then
    print -r -- "Patch已应用，无需重复修改"
    cat "$output_file" >&2
    exit 0
fi

if (( exit_code == 0 )); then
    print -r -- "修改成功"
    exit 0
fi

print -r -- "Patch损坏，诊断已复制"
cat "$output_file" >&2
exit "$exit_code"
