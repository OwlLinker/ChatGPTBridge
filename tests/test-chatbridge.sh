#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
TEST_ROOT="$(mktemp -d -t chatbridge-test)"

cleanup() {
    rm -rf "$TEST_ROOT"
}

trap cleanup EXIT

fail() {
    print -u2 -r -- "FAIL: $*"
    exit 1
}

for file in "$ROOT"/tools/*.sh; do
    zsh -n "$file" || fail "invalid zsh syntax: $file"
done

bash -n "$ROOT/tools/chat-context.sh" || fail "invalid bash syntax"
swiftc -parse "$ROOT/tools/chat-read-last-diff.swift" || fail "Swift parse failed"
swiftc -parse "$ROOT/tools/chat-monitor.swift" || fail "monitor Swift parse failed"

project="$TEST_ROOT/project"
mkdir -p "$project"
swiftc -O "$ROOT/tools/chat-read-last-diff.swift" -o "$TEST_ROOT/chat-read-last-diff" || fail "Swift compile failed"
swiftc -O "$ROOT/tools/chat-monitor.swift" -o "$TEST_ROOT/chat-monitor" || fail "monitor Swift compile failed"
[[ -x "$TEST_ROOT/chat-monitor" ]] || fail "compiled chat-monitor is not executable"
rg -q 'chmod 755 "\$binary"' "$ROOT/tools/chat-monitor.sh" || fail "monitor launcher does not enforce executable permission"
"$TEST_ROOT/chat-monitor" --self-test >/dev/null || fail "monitor state and Patch self-test failed"
git -C "$project" init -q
git -C "$project" config user.name "ChatGPTBridge Test"
git -C "$project" config user.email "chatbridge-test@example.invalid"

"$ROOT/tools/chat-bridge-install.sh" --force "$project" >/dev/null
project_exclude="$(git -C "$project" rev-parse --path-format=absolute --git-path info/exclude)"
grep -qxF '/.chatgpt/' "$project_exclude" || fail "installer did not exclude the target project's runtime directory"

for file in chat-apply-shell.sh chat-apply-hammerspoon.sh chat-context.sh chat-read-last-diff.sh chat-read-last-diff.swift chat-monitor.sh chat-monitor.swift; do
    cmp -s "$ROOT/tools/$file" "$project/tools/$file" || fail "installer payload mismatch: $file"
done

"$project/tools/chat-bridge-install.sh" --force "$project" >/dev/null || fail "installed updater could not refresh its own project"
for file in chat-monitor.sh chat-monitor.swift; do
    cmp -s "$ROOT/tools/$file" "$project/tools/$file" || fail "installed updater lost $file"
done

standalone_project="$TEST_ROOT/standalone-project"
distribution="$TEST_ROOT/distribution"
mkdir -p "$standalone_project" "$distribution"
git -C "$standalone_project" init -q
cp "$ROOT/tools/chat-bridge-install.sh" "$distribution/chat-bridge-install.sh"
"$distribution/chat-bridge-install.sh" "$standalone_project" >/dev/null \
    || fail "standalone installer could not install its embedded monitor"
for file in chat-monitor.sh chat-monitor.swift; do
    cmp -s "$ROOT/tools/$file" "$standalone_project/tools/$file" \
        || fail "standalone installer payload mismatch: $file"
done
[[ -s "$standalone_project/CHAT-BRIDGE.md" ]] || fail "standalone installer did not include its manual"

if [[ -f "$ROOT/CHAT-BRIDGE.md" ]]; then
    cmp -s "$ROOT/CHAT-BRIDGE.md" "$project/CHAT-BRIDGE.md" || fail "installer manual payload mismatch"
fi
[[ -x "$project/tools/chat-apply-shell.sh" ]] || fail "installed shell script is not executable"
[[ -x "$project/tools/chat-apply-hammerspoon.sh" ]] || fail "installed Hammerspoon script is not executable"

printf '%s\n' 'outside-project-content' > "$TEST_ROOT/outside.txt"
ln -s "$TEST_ROOT/outside.txt" "$project/linked.txt"
mkdir -p "$project/.docker"
secret_value="chatbridge-""secret-marker"
printf '%s\n' "$secret_value" > "$project/.npmrc"
printf '%s\n' "$secret_value" > "$project/config.env"
printf '%s\n' "$secret_value" > "$project/secrets.json"
printf '%s\n' "$secret_value" > "$project/.docker/config.json"
"$project/tools/chat-context.sh" full >/dev/null
if grep -Fq 'outside-project-content' "$project/.chatgpt/project-context.md"; then
    fail "context snapshot followed a symbolic link"
fi
if grep -Fq "$secret_value" "$project/.chatgpt/project-context.md"; then
    fail "context snapshot included a protected secret value"
fi

printf '%s\n' before > "$project/example.txt"
git -C "$project" add example.txt
git -C "$project" commit -qm initial

patch="$TEST_ROOT/change.patch"
cat > "$patch" <<'EOF'
diff --git a/example.txt b/example.txt
--- a/example.txt
+++ b/example.txt
@@ -1 +1 @@
-before
+after
EOF

"$project/tools/chat-apply-shell.sh" --patch-file "$patch" >/dev/null
[[ "$(<"$project/example.txt")" == after ]] || fail "Patch was not applied"

lock_marker="$TEST_ROOT/lock-held"
/usr/bin/lockf -k "$project/.chatgpt/apply.lock" /bin/sh -c 'touch "$1"; sleep 2' sh "$lock_marker" &
lock_pid=$!
for _ in {1..40}; do
    [[ -e "$lock_marker" ]] && break
    sleep 0.05
done
[[ -e "$lock_marker" ]] || fail "could not establish concurrent Patch lock"
lock_started=$SECONDS
undo_output="$(printf 'y\n' | "$project/tools/chat-apply-shell.sh" --undo 2>&1)" || {
    print -u2 -r -- "$undo_output"
    fail "undo command failed"
}
wait "$lock_pid"
(( SECONDS - lock_started >= 1 )) || fail "Patch application did not wait for the project lock"
[[ "$(<"$project/example.txt")" == before ]] || fail "Patch was not undone"

# Hammerspoon routing must use the Patch's repository, not a stale global
# active-project pointer. A deliberately mismatching hunk exercises path-based
# routing while keeping the test core from applying or writing a report.
route_home="$TEST_ROOT/route-home"
stale_project="$TEST_ROOT/stale-project"
route_record="$TEST_ROOT/routed-project"
expected_route_root="$(git -C "$project" rev-parse --show-toplevel)"
mkdir -p "$route_home/.chatbridge" "$stale_project" "$project/src"
git -C "$stale_project" init -q
git -C "$project" config user.name "ChatGPTBridge Test"
git -C "$project" config user.email "chatbridge-test@example.invalid"
printf '%s\n' route-target > "$project/src/route-target.m"
git -C "$project" add src/route-target.m
git -C "$project" commit -qm route-target
printf '%s\n' "$stale_project" > "$route_home/.chatbridge/active-project"
printf '%s\n%s\n' "$stale_project" "$project" > "$route_home/.chatbridge/projects"
cat > "$project/tools/chat-apply-shell.sh" <<'EOF'
#!/bin/zsh
print -r -- "$CHAT_BRIDGE_PROJECT_ROOT" > "$CHATBRIDGE_TEST_ROUTED_ROOT"
EOF
chmod 755 "$project/tools/chat-apply-shell.sh"
route_patch="$TEST_ROOT/mismatching-route.patch"
cat > "$route_patch" <<'EOF'
diff --git a/src/route-target.m b/src/route-target.m
--- a/src/route-target.m
+++ b/src/route-target.m
@@ -1 +1 @@
-not-the-current-source
+patched
EOF
route_output="$(HOME="$route_home" CHATBRIDGE_TEST_ROUTED_ROOT="$route_record" \
    "$project/tools/chat-apply-hammerspoon.sh" --patch-file "$route_patch" 2>&1)" \
    || fail "Hammerspoon wrapper failed routing test: $route_output"
[[ "$(<"$route_record")" == "$expected_route_root" ]] || fail "Patch was routed to the stale project"
[[ "$(<"$route_home/.chatbridge/active-project")" == "$expected_route_root" ]] || fail "active-project was not updated after routing"
[[ "$route_output" == *"[ChatGPTBridge] project route: $expected_route_root"* ]] || fail "project routing was not logged"

# An unreadable Patch has no trustworthy target. The wrapper must fail closed
# instead of silently applying it to whichever project the pointer names.
printf '%s\n' "$stale_project" > "$route_home/.chatbridge/active-project"
unreadable_patch="$TEST_ROOT/unreadable.patch"
printf '%s\n' 'not a unified diff' > "$unreadable_patch"
if route_output="$(HOME="$route_home" CHATBRIDGE_TEST_ROUTED_ROOT="$route_record" \
    "$project/tools/chat-apply-hammerspoon.sh" --patch-file "$unreadable_patch" 2>&1)"; then
    fail "Hammerspoon applied a Patch without target paths"
else
    route_exit=$?
fi
[[ "$route_exit" -eq 2 ]] || fail "unreadable Patch did not return the safe-stop status"
[[ "$(<"$route_home/.chatbridge/active-project")" == "$stale_project" ]] || fail "active-project changed for an unreadable Patch"
[[ "$route_output" == *"未执行应用"* ]] || fail "unreadable Patch did not explain that application was skipped"

print -r -- "ChatGPTBridge tests passed"
