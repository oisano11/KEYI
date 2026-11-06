#!/bin/zsh
emulate -L zsh
setopt ERR_EXIT NO_UNSET PIPE_FAIL

fail() {
    print -u2 -- "KEYITerminal launcher checks failed: $1"
    exit 1
}

typeset -gi check_count=0
typeset -gi cleanup_done=0

assert_true() {
    local label="$1"
    local actual="$2"
    (( check_count += 1 ))
    [[ "$actual" == yes ]] || fail "$label"
}

assert_equal() {
    local label="$1"
    local actual="$2"
    local expected="$3"
    (( check_count += 1 ))
    [[ "$actual" == "$expected" ]] || fail "$label"
}

assert_contains() {
    local label="$1"
    local text="$2"
    local needle="$3"
    (( check_count += 1 ))
    [[ "$text" == *"$needle"* ]] || fail "$label"
}

assert_not_contains() {
    local label="$1"
    local text="$2"
    local needle="$3"
    (( check_count += 1 ))
    [[ "$text" != *"$needle"* ]] || fail "$label"
}

assert_fails() {
    local label="$1"
    shift
    (( check_count += 1 ))
    if "$@" >/dev/null 2>&1; then
        fail "$label"
    fi
}

if [[ $# -ne 1 ]]; then
    fail "pass the existing KEYITerminal executable path"
fi
binary_input="$1"
[[ -x "$binary_input" ]] || fail "KEYITerminal is not executable"
binary_path="${binary_input:A}"
[[ -x "$binary_path" ]] || fail "resolved KEYITerminal is not executable"

test_root="$(/usr/bin/mktemp -d /tmp/keyi-terminal-launcher.XXXXXX)"
[[ -n "$test_root" && -d "$test_root" ]] || fail "could not create isolated test directory"
bridge_dir="$test_root/bridge"

typeset -a known_profiles
known_profiles=(claude codex gemini qwen opencode aider goose amp cursor copilot kilo pi crush kimi vibe-python)

cleanup() {
    (( cleanup_done == 0 )) || return 0
    cleanup_done=1

    if [[ -d "$bridge_dir" ]]; then /bin/rmdir "$bridge_dir"; fi
    if [[ -d "$test_root" ]]; then /bin/rmdir "$test_root"; fi
}
trap cleanup EXIT

/bin/chmod 700 "$test_root"
/bin/mkdir -m 700 "$bridge_dir"
/bin/chmod 700 "$bridge_dir"

if ! help_output=$(KEYI_TERMINAL_BRIDGE_DIR="$bridge_dir" "$binary_path" --help 2>&1); then
    fail "--help returned failure"
fi
assert_contains "--help documents edit" "$help_output" "KEYITerminal edit"
assert_contains "--help states no global shell config changes" "$help_output" "不修改全局 shell 配置"
assert_not_contains "--help no longer documents run" "$help_output" "KEYITerminal run"

if ! list_output=$(KEYI_TERMINAL_BRIDGE_DIR="$bridge_dir" "$binary_path" list 2>&1); then
    fail "list returned failure"
fi
for profile in "${known_profiles[@]}"; do
    assert_contains "list includes profile $profile" "$list_output" "$profile |"
done
assert_contains "list states that host acceptance is separate" "$list_output" "真实宿主逐项验收"

assert_fails "run entry point is removed" \
    "$binary_path" run --agent codex -- /bin/echo x
assert_fails "editor-path entry point is removed" \
    "$binary_path" editor-path codex

cleanup
trap - EXIT
print -- "KEYITerminal launcher checks passed: $check_count"
