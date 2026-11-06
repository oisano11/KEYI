# Opt-in, current shell only. Requires Bash 4+ READLINE_LINE/READLINE_POINT.
# source "/Applications/KEYI 可译.app/Contents/Resources/Terminal/keyi.bash"
# This replaces edit-and-execute-command with a non-executing buffer widget.

if (( BASH_VERSINFO[0] < 4 )); then
    printf '%s\n' 'KEYI: Bash 4+ is required; macOS Bash 3.2 is not silently enabled.' >&2
    return 1
fi
keyi_translate_draft() {
    local keyi_binary="${KEYI_TERMINAL_EXECUTABLE:-/Applications/KEYI 可译.app/Contents/MacOS/KEYITerminal}"
    local keyi_original="$READLINE_LINE" keyi_original_cursor="$READLINE_POINT"
    local keyi_draft_file keyi_replacement keyi_result=1
    [[ -x "$keyi_binary" ]] || { printf '%s\n' '请先安装 KEYI 终端草稿桥' >&2; return 1; }
    keyi_draft_file=$(mktemp -t keyi-terminal-draft.XXXXXXXX) || return 1
    if printf '%s' "$keyi_original" > "$keyi_draft_file" && "$keyi_binary" edit "$keyi_draft_file"; then
        if [[ "$READLINE_LINE" == "$keyi_original" && "$READLINE_POINT" == "$keyi_original_cursor" ]]; then
            IFS= read -r -d '' keyi_replacement < "$keyi_draft_file" || true
            READLINE_LINE="$keyi_replacement"
            READLINE_POINT=$(printf '%s' "$keyi_replacement" | LC_ALL=C wc -c)
            keyi_result=0
        else
            printf '%s\n' '输入已变化，未覆盖当前草稿' >&2
        fi
    fi
    command rm -f -- "$keyi_draft_file"
    return "$keyi_result"
}
if [[ "${KEYI_TERMINAL_NO_BIND:-0}" != 1 ]]; then
    bind -x '"\C-x\C-e":keyi_translate_draft'
fi
