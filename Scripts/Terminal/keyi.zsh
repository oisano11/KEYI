# Opt-in, current shell only. No rc file is modified.
# source "/Applications/KEYI 可译.app/Contents/Resources/Terminal/keyi.zsh"
# Ctrl+X Ctrl+E edits the complete unsubmitted ZLE buffer; never accept-line.

function keyi_translate_draft() {
    emulate -L zsh
    local keyi_binary="${KEYI_TERMINAL_EXECUTABLE:-/Applications/KEYI 可译.app/Contents/MacOS/KEYITerminal}"
    local keyi_original="$BUFFER" keyi_original_cursor="$CURSOR"
    local keyi_draft_file keyi_replacement
    [[ -x "$keyi_binary" ]] || { zle -M '请先安装 KEYI 终端草稿桥'; return 1; }
    keyi_draft_file=$(mktemp -t keyi-terminal-draft.XXXXXXXX) || return 1
    {
        print -rn -- "$keyi_original" > "$keyi_draft_file" || return 1
        "$keyi_binary" edit "$keyi_draft_file" || return 1
        [[ "$BUFFER" == "$keyi_original" && "$CURSOR" == "$keyi_original_cursor" ]] || {
            zle -M '输入已变化，未覆盖当前草稿'; return 1
        }
        IFS= read -r -d '' keyi_replacement < "$keyi_draft_file" || true
        BUFFER="$keyi_replacement"
        CURSOR=${#BUFFER}
        zle redisplay
    } always {
        command rm -f -- "$keyi_draft_file"
    }
}
zle -N keyi_translate_draft
if [[ "${KEYI_TERMINAL_NO_BIND:-0}" != 1 ]]; then
    bindkey '^X^E' keyi_translate_draft
fi
