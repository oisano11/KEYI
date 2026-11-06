#!/bin/zsh
set -euo pipefail
keyi_test_root=${0:A:h:h:h}
typeset -g BUFFER=$'当前草稿🙂\n第二行\n'
typeset -g CURSOR=${#BUFFER}
typeset -g KEYI_TERMINAL_NO_BIND=1
typeset -g KEYI_TERMINAL_EXECUTABLE="$keyi_test_root/Tests/KEYITerminalFixtures/edit-draft.zsh"
typeset -g keyi_redisplays=0
zle() {
    if [[ "$1" == redisplay ]]; then (( keyi_redisplays += 1 )); fi
    return 0
}
source "$keyi_test_root/Scripts/Terminal/keyi.zsh"
keyi_translate_draft
[[ "$BUFFER" == $'translated fixture🙂\nsecond line\n\n' ]] || exit 1
[[ "$CURSOR" == ${#BUFFER} && "$keyi_redisplays" == 1 ]] || exit 1
export KEYI_FIXTURE_CANCEL=1
keyi_saved_buffer="$BUFFER"
keyi_saved_cursor="$CURSOR"
if keyi_translate_draft; then exit 1; fi
[[ "$BUFFER" == "$keyi_saved_buffer" && "$CURSOR" == "$keyi_saved_cursor" ]] || exit 1
printf '%s\n' 'KEYI zsh buffer fixture checks passed: 4 (no UI, no commands submitted)'
