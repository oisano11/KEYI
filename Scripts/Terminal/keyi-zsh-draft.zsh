# Source only from the opt-in interactive zsh loader for Apple Terminal/Ghostty.
[[ -o interactive && ( ${TERM_PROGRAM-} == Apple_Terminal || ${TERM_PROGRAM-} == ghostty ) ]] || return 0

zmodload zsh/parameter 2>/dev/null || return 0
if (( $+parameters[__keyi_zsh_draft_source]
      || $+parameters[__keyi_zsh_draft_helper]
      || $+parameters[__keyi_zsh_draft_session_id]
      || $+parameters[__keyi_zsh_draft_fifo]
      || $+parameters[__keyi_zsh_draft_request_fd]
      || $+parameters[__keyi_zsh_draft_ticket_id]
      || $+parameters[__keyi_zsh_draft_generation]
      || $+parameters[__keyi_zsh_draft_invalidated]
      || $+parameters[__keyi_zsh_draft_baseline_buffer]
      || $+parameters[__keyi_zsh_draft_baseline_cursor]
      || $+parameters[__keyi_zsh_draft_shell_pid]
      || $+parameters[__keyi_zsh_draft_start_seconds]
      || $+parameters[__keyi_zsh_draft_start_microseconds]
      || $+parameters[__keyi_zsh_draft_tty_device]
      || $+parameters[__keyi_zsh_draft_process_group]
      || $+parameters[__keyi_zsh_draft_incoming]
      || $+parameters[__keyi_zsh_draft_ticket_buffer]
      || $+parameters[__keyi_zsh_draft_reply_fd]
      || $+functions[__keyi_zsh_draft_reply]
      || $+functions[__keyi_zsh_draft_reply_open]
      || $+functions[__keyi_zsh_draft_reply_write]
      || $+functions[__keyi_zsh_draft_lease_valid]
      || $+functions[__keyi_zsh_draft_probe]
      || $+functions[__keyi_zsh_draft_encode_buffer]
      || $+functions[__keyi_zsh_draft_line_init]
      || $+functions[__keyi_zsh_draft_line_finish]
      || $+functions[__keyi_zsh_draft_cleanup]
      || $+functions[__keyi_zsh_draft_pre_redraw]
      || $+functions[__keyi_zsh_draft_request_handler]
      || $+functions[__keyi_zsh_draft_unload] )); then
    return 0
fi

typeset __keyi_zsh_draft_source="${${(%):-%x}:A}"
typeset -g __keyi_zsh_draft_helper="${KEYI_TERMINAL_HELPER:-${__keyi_zsh_draft_source:h:h:h}/MacOS/KEYITerminal}"
[[ -x $__keyi_zsh_draft_helper ]] || __keyi_zsh_draft_helper="/Applications/KEYI 可译.app/Contents/MacOS/KEYITerminal"
[[ -x $__keyi_zsh_draft_helper ]] || return 0

zmodload zsh/system 2>/dev/null || return 0
autoload -Uz add-zle-hook-widget
zle -l __keyi_zsh_draft_request_handler >/dev/null 2>&1 && return 0

typeset -g __keyi_zsh_draft_session_id=""
typeset -g __keyi_zsh_draft_fifo=""
typeset -g __keyi_zsh_draft_request_fd=""
typeset -g __keyi_zsh_draft_ticket_id=""
typeset -g __keyi_zsh_draft_generation=0
typeset -g __keyi_zsh_draft_invalidated=0
typeset -g __keyi_zsh_draft_baseline_buffer=""
typeset -g __keyi_zsh_draft_baseline_cursor=0
typeset -g __keyi_zsh_draft_shell_pid=""
typeset -g __keyi_zsh_draft_start_seconds=""
typeset -g __keyi_zsh_draft_start_microseconds=""
typeset -g __keyi_zsh_draft_tty_device=""
typeset -g __keyi_zsh_draft_process_group=""
typeset -g __keyi_zsh_draft_incoming=""
typeset -g __keyi_zsh_draft_ticket_buffer=""
typeset -g __keyi_zsh_draft_reply_fd=""

function __keyi_zsh_draft_reply_open {
    local __keyi_reply_path="$1"
    [[ "$__keyi_reply_path" == "${__keyi_zsh_draft_fifo:h}"/reply-*.fifo
       && -p "$__keyi_reply_path" && ! -L "$__keyi_reply_path" ]] || return 1
    __keyi_zsh_draft_reply_fd=""
    sysopen -w -o nonblock,cloexec -u __keyi_zsh_draft_reply_fd "$__keyi_reply_path" 2>/dev/null
}

function __keyi_zsh_draft_reply_write {
    local __keyi_reply_fd="$1"
    local __keyi_reply_text="$2"
    # A vanished reader can raise SIGPIPE. Isolate the bounded nonblocking
    # write in a subshell so the interactive shell itself cannot be killed.
    ( syswrite -o "$__keyi_reply_fd" "$__keyi_reply_text"$'\n' 2>/dev/null )
    local __keyi_status=$?
    { exec {__keyi_reply_fd}>&-; } 2>/dev/null
    __keyi_zsh_draft_reply_fd=""
    return $__keyi_status
}

function __keyi_zsh_draft_reply {
    local __keyi_reply_path="$1"
    local __keyi_reply_text="$2"
    __keyi_zsh_draft_reply_open "$__keyi_reply_path" || return 1
    __keyi_zsh_draft_reply_write "$__keyi_zsh_draft_reply_fd" "$__keyi_reply_text"
}

function __keyi_zsh_draft_lease_valid {
    setopt localoptions extendedglob
    local __keyi_lease_id="$1"
    local __keyi_deadline="$2"
    [[ $__keyi_lease_id == [0-9a-f](#c8)-[0-9a-f](#c4)-[0-9a-f](#c4)-[0-9a-f](#c4)-[0-9a-f](#c12)
       && $__keyi_deadline == <-> ]] || return 1
    local __keyi_lease_path="${__keyi_zsh_draft_fifo:h}/lease-${__keyi_lease_id}.txt"
    [[ -f $__keyi_lease_path && ! -L $__keyi_lease_path ]] || return 1
    local __keyi_lease_line
    IFS= read -r __keyi_lease_line < "$__keyi_lease_path" || return 1
    [[ $__keyi_lease_line == "${__keyi_lease_id}"$'\t'"${__keyi_deadline}"$'\t1' ]] || return 1
    zmodload zsh/datetime 2>/dev/null || return 1
    local -i __keyi_now_us
    (( __keyi_now_us = EPOCHREALTIME * 1000000 ))
    (( __keyi_now_us + 2 < __keyi_deadline ))
}

function __keyi_zsh_draft_probe {
    local __keyi_host_pid="$1"
    local __keyi_probe_result
    __keyi_probe_result="$("$__keyi_zsh_draft_helper" zsh-draft probe "$__keyi_host_pid" "$__keyi_zsh_draft_session_id" 2>/dev/null)" || return 1
    [[ $__keyi_probe_result == OK ]]
}

function __keyi_zsh_draft_encode_buffer {
    print -rn -- "$BUFFER" | /usr/bin/base64 | /usr/bin/tr -d '\n'
}

function __keyi_zsh_draft_line_init {
    __keyi_zsh_draft_cleanup
    local __keyi_registration
    __keyi_registration="$("$__keyi_zsh_draft_helper" zsh-draft register "$$" "$TTY" 2>/dev/null)" || return 0
    IFS=$'\t' read -r __keyi_zsh_draft_session_id __keyi_zsh_draft_fifo \
        __keyi_zsh_draft_shell_pid __keyi_zsh_draft_start_seconds \
        __keyi_zsh_draft_start_microseconds __keyi_zsh_draft_tty_device \
        __keyi_zsh_draft_process_group <<< "$__keyi_registration"
    [[ -n $__keyi_zsh_draft_session_id && -p $__keyi_zsh_draft_fifo ]] || {
        __keyi_zsh_draft_cleanup
        return 0
    }
    sysopen -rw -o nonblock,cloexec -u __keyi_zsh_draft_request_fd "$__keyi_zsh_draft_fifo" 2>/dev/null || {
        __keyi_zsh_draft_cleanup
        return 0
    }
    zle -F -w "$__keyi_zsh_draft_request_fd" __keyi_zsh_draft_request_handler
}

function __keyi_zsh_draft_line_finish {
    __keyi_zsh_draft_cleanup
}

function __keyi_zsh_draft_cleanup {
    if [[ -n $__keyi_zsh_draft_request_fd ]]; then
        zle -F "$__keyi_zsh_draft_request_fd" 2>/dev/null
        { exec {__keyi_zsh_draft_request_fd}>&-; } 2>/dev/null
    fi
    if [[ -n $__keyi_zsh_draft_session_id ]]; then
        "$__keyi_zsh_draft_helper" zsh-draft unregister "$__keyi_zsh_draft_session_id" >/dev/null 2>&1
    fi
    __keyi_zsh_draft_session_id=""
    __keyi_zsh_draft_fifo=""
    __keyi_zsh_draft_request_fd=""
    __keyi_zsh_draft_ticket_id=""
    __keyi_zsh_draft_generation=0
    __keyi_zsh_draft_invalidated=0
    __keyi_zsh_draft_incoming=""
    __keyi_zsh_draft_ticket_buffer=""
}

function __keyi_zsh_draft_pre_redraw {
    [[ -n $__keyi_zsh_draft_ticket_id ]] || return 0
    if [[ "$BUFFER" != "$__keyi_zsh_draft_baseline_buffer" || $CURSOR -ne $__keyi_zsh_draft_baseline_cursor ]]; then
        __keyi_zsh_draft_invalidated=1
        (( __keyi_zsh_draft_generation += 1 ))
        __keyi_zsh_draft_baseline_buffer="$BUFFER"
        __keyi_zsh_draft_baseline_cursor=$CURSOR
    fi
}

function __keyi_zsh_draft_request_handler {
    setopt localoptions no_ksharrays
    local __keyi_fd="$1"
    local __keyi_chunk __keyi_count=0 __keyi_line
    local -a __keyi_fields
    sysread -i "$__keyi_fd" -s 65536 -t 0 -c __keyi_count __keyi_chunk 2>/dev/null
    (( __keyi_count > 0 )) && __keyi_zsh_draft_incoming+="$__keyi_chunk"
    (( ${#__keyi_zsh_draft_incoming} <= 300000 )) || {
        __keyi_zsh_draft_incoming=""
        return 0
    }
    [[ $__keyi_zsh_draft_incoming == *$'\n'* ]] || return 0
    __keyi_line="${__keyi_zsh_draft_incoming%%$'\n'*}"
    __keyi_zsh_draft_incoming="${__keyi_zsh_draft_incoming#*$'\n'}"
    IFS=$'\t' read -r -A __keyi_fields <<< "$__keyi_line"
    local __keyi_operation="${__keyi_fields[1]}"
    local __keyi_ticket="${__keyi_fields[2]}"
    local __keyi_host_pid
    local __keyi_reply
    local __keyi_separator=$'\t'

    if [[ $__keyi_operation == CAPTURE && ${#__keyi_fields} -eq 5 ]]; then
        __keyi_host_pid="${__keyi_fields[3]}"
        [[ ${__keyi_fields[4]} == $__keyi_zsh_draft_session_id ]] || return 0
        __keyi_reply="${__keyi_fields[5]}"
        [[ $__keyi_host_pid == <-> ]] && __keyi_zsh_draft_probe "$__keyi_host_pid" || {
            __keyi_zsh_draft_reply "$__keyi_reply" "ACK${__keyi_separator}CAPTURE${__keyi_separator}$__keyi_ticket${__keyi_separator}$__keyi_zsh_draft_session_id${__keyi_separator}0"
            return 0
        }
        __keyi_zsh_draft_ticket_id="$__keyi_ticket"
        __keyi_zsh_draft_generation=0
        __keyi_zsh_draft_invalidated=0
        __keyi_zsh_draft_baseline_buffer="$BUFFER"
        __keyi_zsh_draft_ticket_buffer="$BUFFER"
        __keyi_zsh_draft_baseline_cursor=$CURSOR
        local __keyi_buffer_base64="$(__keyi_zsh_draft_encode_buffer)"
        local __keyi_ack="ACK${__keyi_separator}CAPTURE${__keyi_separator}$__keyi_ticket${__keyi_separator}$__keyi_zsh_draft_session_id${__keyi_separator}$__keyi_zsh_draft_shell_pid${__keyi_separator}$__keyi_zsh_draft_start_seconds${__keyi_separator}$__keyi_zsh_draft_start_microseconds${__keyi_separator}$__keyi_zsh_draft_tty_device${__keyi_separator}$__keyi_zsh_draft_process_group${__keyi_separator}$CURSOR${__keyi_separator}$__keyi_zsh_draft_generation${__keyi_separator}$__keyi_buffer_base64"
        __keyi_zsh_draft_reply "$__keyi_reply" "$__keyi_ack"
        return 0
    fi

    if [[ $__keyi_operation == COMMIT && ${#__keyi_fields} -eq 16 ]]; then
        __keyi_host_pid="${__keyi_fields[4]}"
        __keyi_reply="${__keyi_fields[16]}"
        local __keyi_shell_pid="${__keyi_fields[5]}"
        local __keyi_start_seconds="${__keyi_fields[6]}"
        local __keyi_start_microseconds="${__keyi_fields[7]}"
        local __keyi_tty_device="${__keyi_fields[8]}"
        local __keyi_process_group="${__keyi_fields[9]}"
        local __keyi_cursor="${__keyi_fields[10]}"
        local __keyi_generation="${__keyi_fields[11]}"
        local __keyi_lease_id="${__keyi_fields[12]}"
        local __keyi_lease_deadline="${__keyi_fields[13]}"
        local __keyi_expected_buffer="${__keyi_fields[14]}"
        local __keyi_translated_base64="${__keyi_fields[15]}"
        [[ $__keyi_ticket == $__keyi_zsh_draft_ticket_id
           && $__keyi_host_pid == <->
           && $__keyi_shell_pid == $$
           && $__keyi_start_seconds == $__keyi_zsh_draft_start_seconds
           && $__keyi_start_microseconds == $__keyi_zsh_draft_start_microseconds
           && $__keyi_tty_device == $__keyi_zsh_draft_tty_device
           && $__keyi_process_group == $__keyi_zsh_draft_process_group
           && $__keyi_cursor == $CURSOR
           && $__keyi_generation == $__keyi_zsh_draft_generation
           && $__keyi_zsh_draft_invalidated -eq 0 ]] || {
            __keyi_zsh_draft_reply "$__keyi_reply" "ACK${__keyi_separator}COMMIT${__keyi_separator}$__keyi_ticket${__keyi_separator}0"
            return 0
        }
        local __keyi_current_buffer="$(__keyi_zsh_draft_encode_buffer)"
        [[ $__keyi_current_buffer == $__keyi_expected_buffer ]] || {
            __keyi_zsh_draft_reply "$__keyi_reply" "ACK${__keyi_separator}COMMIT${__keyi_separator}$__keyi_ticket${__keyi_separator}0"
            return 0
        }
        local __keyi_translated="$(
            print -rn -- "$__keyi_translated_base64" | /usr/bin/base64 -D 2>/dev/null
        )"
        [[ -n $__keyi_translated && $__keyi_translated != *$'\n'* && $__keyi_translated != *$'\r'* ]] || {
            __keyi_zsh_draft_reply "$__keyi_reply" "ACK${__keyi_separator}COMMIT${__keyi_separator}$__keyi_ticket${__keyi_separator}0"
            return 0
        }
        __keyi_zsh_draft_probe "$__keyi_host_pid" || {
            __keyi_zsh_draft_reply "$__keyi_reply" "ACK${__keyi_separator}COMMIT${__keyi_separator}$__keyi_ticket${__keyi_separator}0"
            return 0
        }
        __keyi_zsh_draft_reply_open "$__keyi_reply" || return 0
        local __keyi_commit_reply_fd="$__keyi_zsh_draft_reply_fd"
        [[ $__keyi_ticket == $__keyi_zsh_draft_ticket_id
           && $__keyi_cursor == $CURSOR
           && $__keyi_generation == $__keyi_zsh_draft_generation
           && $__keyi_zsh_draft_invalidated -eq 0
           && "$BUFFER" == "$__keyi_zsh_draft_ticket_buffer" ]] \
            && __keyi_zsh_draft_lease_valid "$__keyi_lease_id" "$__keyi_lease_deadline" || {
                __keyi_zsh_draft_reply_write "$__keyi_commit_reply_fd" \
                    "ACK${__keyi_separator}COMMIT${__keyi_separator}$__keyi_ticket${__keyi_separator}0"
                return 0
            }
        local __keyi_original_buffer="$BUFFER"
        local __keyi_original_cursor=$CURSOR
        BUFFER="$__keyi_translated"
        CURSOR=${#BUFFER}
        __keyi_zsh_draft_ticket_id=""
        __keyi_zsh_draft_ticket_buffer=""
        __keyi_zsh_draft_invalidated=0
        zle -R
        if ! __keyi_zsh_draft_reply_write "$__keyi_commit_reply_fd" \
            "ACK${__keyi_separator}COMMIT${__keyi_separator}$__keyi_ticket${__keyi_separator}1"; then
            BUFFER="$__keyi_original_buffer"
            CURSOR=$__keyi_original_cursor
            zle -R
        fi
        return 0
    fi
}

function __keyi_zsh_draft_unload {
    add-zle-hook-widget -d line-init __keyi_zsh_draft_line_init
    add-zle-hook-widget -d line-finish __keyi_zsh_draft_line_finish
    add-zle-hook-widget -d line-pre-redraw __keyi_zsh_draft_pre_redraw
    __keyi_zsh_draft_cleanup
    unfunction __keyi_zsh_draft_reply __keyi_zsh_draft_probe \
        __keyi_zsh_draft_reply_open __keyi_zsh_draft_reply_write \
        __keyi_zsh_draft_lease_valid \
        __keyi_zsh_draft_encode_buffer __keyi_zsh_draft_line_init \
        __keyi_zsh_draft_line_finish __keyi_zsh_draft_cleanup \
        __keyi_zsh_draft_pre_redraw __keyi_zsh_draft_request_handler
    unset __keyi_zsh_draft_helper __keyi_zsh_draft_session_id \
        __keyi_zsh_draft_fifo __keyi_zsh_draft_request_fd \
        __keyi_zsh_draft_ticket_id __keyi_zsh_draft_generation \
        __keyi_zsh_draft_invalidated __keyi_zsh_draft_baseline_buffer \
        __keyi_zsh_draft_baseline_cursor __keyi_zsh_draft_shell_pid \
        __keyi_zsh_draft_start_seconds __keyi_zsh_draft_start_microseconds \
        __keyi_zsh_draft_tty_device __keyi_zsh_draft_process_group \
        __keyi_zsh_draft_incoming __keyi_zsh_draft_ticket_buffer \
        __keyi_zsh_draft_reply_fd
}

zle -N __keyi_zsh_draft_request_handler
add-zle-hook-widget line-init __keyi_zsh_draft_line_init
add-zle-hook-widget line-finish __keyi_zsh_draft_line_finish
add-zle-hook-widget line-pre-redraw __keyi_zsh_draft_pre_redraw
unset __keyi_zsh_draft_source
