# Opt-in, current fish session only; no config.fish changes.
# source "/Applications/KEYI 可译.app/Contents/Resources/Terminal/keyi.fish"

function keyi_translate_draft
    set -l keyi_binary '/Applications/KEYI 可译.app/Contents/MacOS/KEYITerminal'
    if set -q KEYI_TERMINAL_EXECUTABLE
        set keyi_binary "$KEYI_TERMINAL_EXECUTABLE"
    end
    test -x "$keyi_binary"; or return 1
    set -l keyi_cursor (commandline --cursor)
    set -l keyi_snapshot_file (mktemp -t keyi-terminal-snapshot.XXXXXXXX)
    test -n "$keyi_snapshot_file"; or return 1
    set -l keyi_draft_file (mktemp -t keyi-terminal-draft.XXXXXXXX)
    if test -z "$keyi_draft_file"
        command rm -f -- "$keyi_snapshot_file"
        return 1
    end
    # fish commandline prints one generated newline; the helper removes only
    # that newline from the source, and writes back exact draft bytes.
    commandline --current-buffer > "$keyi_snapshot_file"
    command cp -- "$keyi_snapshot_file" "$keyi_draft_file"
    if "$keyi_binary" edit --shell-output "$keyi_draft_file"
        if commandline --current-buffer | command cmp -s "$keyi_snapshot_file" -; and test (commandline --cursor) = "$keyi_cursor"
            set -l keyi_replacement ''
            read --null keyi_replacement < "$keyi_draft_file"; or true
            commandline --replace -- "$keyi_replacement"
            commandline --cursor (string length -- "$keyi_replacement")
            command rm -f -- "$keyi_draft_file" "$keyi_snapshot_file"
            return 0
        end
    end
    command rm -f -- "$keyi_draft_file" "$keyi_snapshot_file"
    return 1
end
if not set -q KEYI_TERMINAL_NO_BIND; or test "$KEYI_TERMINAL_NO_BIND" != 1
    bind \cx\ce keyi_translate_draft
end
