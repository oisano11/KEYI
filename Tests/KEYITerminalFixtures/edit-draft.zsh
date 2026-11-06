#!/bin/zsh
# Offline fixture: only edits the explicit mktemp draft supplied by the check.
[[ "$1" == edit && -f "$2" ]] || exit 2
if [[ "${KEYI_FIXTURE_CANCEL:-0}" == 1 ]]; then exit 1; fi
printf '%s' $'translated fixture🙂\nsecond line\n\n' > "$2"
