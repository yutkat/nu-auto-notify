# Building and sending notifications; no side effects on the shell state.

export const DEFAULT_IGNORE = [vim nvim less more man tig watch "git commit" top htop ssh nano]
export const DEFAULT_TITLE = '"{command}" Completed'
export const DEFAULT_BODY = "Total time: {elapsed} seconds\nExit code: {exit_code}"

# Exit codes of a command interrupted by Ctrl+C: 130 from shells and scripts,
# -2 from Nushell for an external killed by SIGINT.
const SIGINT_CODES = [130 -2]

# sudo options that take the next word as their argument.
const SUDO_ARG_OPTIONS = [
    -u -g -C -D -h -p -r -t -T -U
    --user --group --close-from --chdir --host --prompt --role --type --command-timeout --other-user
]

# Leading words that do not name the command being run.
def strip-prefixes []: list<string> -> list<string> {
    let words = $in
    if ($words | is-empty) {
        return $words
    }
    let head = $words.0 | str replace -r '^\^' ''
    if $head == sudo {
        $words | skip 1 | skip-sudo-options | strip-prefixes
    } else {
        $words | skip 1 | prepend $head
    }
}

def skip-sudo-options []: list<string> -> list<string> {
    let words = $in
    match $words.0? {
        null => $words
        "--" => ($words | skip 1)
        $w if $w in $SUDO_ARG_OPTIONS => ($words | skip 2 | skip-sudo-options)
        $w if ($w | str starts-with "-") => ($words | skip 1 | skip-sudo-options)
        _ => $words
    }
}

def words []: string -> list<string> {
    str trim | split row -r '\s+' | where {|w| $w != "" }
}

# True when a pipeline segment of the command line starts with the words of an
# ignore entry ("git commit" matches `git commit -m x`, not `git commit-tree`).
export def is-ignored [ignore: list<string>]: string -> bool {
    let entries = $ignore | each { words } | where {|e| $e | is-not-empty }
    $in | split row -r '[|;]' | each { words | strip-prefixes } | any {|segment|
        $entries | any {|entry| ($segment | first ($entry | length)) == $entry }
    }
}

def in-ssh []: nothing -> bool {
    [SSH_CONNECTION SSH_CLIENT SSH_TTY] | any {|var| $env | get -o $var | is-not-empty }
}

export def render [template: any, fields: record]: nothing -> string {
    if ($template | describe) == closure {
        do $template $fields | into string
    } else {
        $fields | format pattern $template
    }
}

# Build the notification for a finished command, or null when none is due.
export def build-notification [st: record, command: string, duration: duration, exit_code: int]: nothing -> any {
    let command = $command | str trim
    if ($command | is-empty) or $duration <= $st.threshold {
        return null
    }
    if $st.cancel_on_sigint and $exit_code in $SIGINT_CODES {
        return null
    }
    if not $st.ssh and (in-ssh) {
        return null
    }
    if ($command | is-ignored $st.ignore) {
        return null
    }
    let elapsed = $duration / 1sec | math floor
    let fields = {command: $command, elapsed: $elapsed, duration: ($elapsed * 1sec), exit_code: $exit_code}
    $fields | merge {
        title: (render $st.title $fields)
        body: (render $st.body $fields)
        urgency: (if $exit_code == 0 { "normal" } else { "critical" })
        expire_time: $st.expire_time
    }
}

export def notify-default [n: record]: nothing -> nothing {
    match $nu.os-info.name {
        "linux" => {
            let ms = $n.expire_time / 1ms | math floor
            ^notify-send --app-name=nu $"--urgency=($n.urgency)" $"--expire-time=($ms)" --hint=int:transient:1 -- $n.title $n.body
        }
        "macos" => {
            let r = ^osascript -e 'on run argv' -e 'display notification (item 1 of argv) with title (item 2 of argv)' -e 'end run' $n.body $n.title | complete
            # osascript prints "ApplePersistence=NO" to stderr on every run.
            let errors = $r.stderr | lines | where {|l| $l !~ 'ApplePersistence=(NO|YES)' }
            if ($errors | is-not-empty) or $r.exit_code != 0 {
                error make {msg: $"osascript failed: ($errors | str join ' ')"}
            }
        }
        $os => { error make {msg: $"unsupported platform '($os)'; pass --notifier"} }
    }
}
