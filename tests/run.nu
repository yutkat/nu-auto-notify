# Test entry point: `nu tests/run.nu`. Exits non-zero when a test fails.
#
# Hooks only run in the interactive REPL, so these tests call the installed
# hook closures directly and capture notifications with a `--notifier`
# closure that records them in `$env.SENT`.

use std/assert

const ROOT = path self ..
use ($ROOT | path join nu-auto-notify)
use ($ROOT | path join nu-auto-notify notification.nu) *

def capture []: nothing -> closure { {|n| $env.SENT = ($env.SENT? | default [] | append $n) } }

def ours []: list -> list { where {|h| ($h | describe) =~ '^record' and ($h.__nu_auto_notify? == true) } }

def settings []: nothing -> record {
    {
        threshold: 10sec
        ignore: $DEFAULT_IGNORE
        title: $DEFAULT_TITLE
        body: $DEFAULT_BODY
        cancel_on_sigint: false
        ssh: false
        expire_time: 8sec
    }
}

def --env no-ssh []: nothing -> nothing {
    hide-env -i SSH_CONNECTION SSH_CLIENT SSH_TTY
}

# Simulate one REPL round trip: pre_execution for `line`, the command taking
# `ms` milliseconds and exiting with `code`, then pre_prompt.
def --env run-line [line: string, ms: int, code: int = 0]: nothing -> nothing {
    commandline edit --replace $line
    for h in ($env.config.hooks.pre_execution | ours) { do --env $h.code }
    $env.CMD_DURATION_MS = $ms | into string
    $env.LAST_EXIT_CODE = $code
    for h in ($env.config.hooks.pre_prompt | ours) { do --env $h.code }
}

# --- ignore list ------------------------------------------------------------

def "test default ignore list matches zsh-auto-notify" [] {
    assert equal $DEFAULT_IGNORE [vim nvim less more man tig watch "git commit" top htop ssh nano]
}

def "test ignore matches the first word" [] {
    assert ("vim foo.txt" | is-ignored [vim])
    assert ("  vim" | is-ignored [vim])
    assert not ("nvim foo" | is-ignored [vim])
    assert not ("vimdiff a b" | is-ignored [vim])
    assert not ("echo vim" | is-ignored [vim])
}

def "test ignore matches a multi-word prefix" [] {
    assert ("git commit -m x" | is-ignored ["git commit"])
    assert ("git   commit" | is-ignored ["git commit"])
    assert not ("git commit-tree x" | is-ignored ["git commit"])
    assert not ("git log" | is-ignored ["git commit"])
    assert not ("git" | is-ignored ["git commit"])
}

def "test ignore skips sudo and the external call prefix" [] {
    assert ("sudo vim /etc/hosts" | is-ignored [vim])
    assert ("^ssh host" | is-ignored [ssh])
    assert ("sudo ^docker run x" | is-ignored [docker])
    assert ("sudo -u root vim x" | is-ignored [vim])
    assert ("sudo -E vim" | is-ignored [vim])
    assert ("sudo -uroot vim" | is-ignored [vim])
    assert ("sudo --user=root vim" | is-ignored [vim])
    assert ("sudo --user root vim" | is-ignored [vim])
    assert ("sudo -- vim" | is-ignored [vim])
    assert ("sudo -E -u root ^ssh host" | is-ignored [ssh])
    assert not ("sudo -u vim make" | is-ignored [vim])
}

def "test ignore checks every pipeline segment" [] {
    assert ("git log | less" | is-ignored [less])
    assert ("docker logs -f x | grep err" | is-ignored [docker])
    assert ("cd foo; nvim" | is-ignored [nvim])
    assert not ("cargo build | tee log" | is-ignored [less])
}

def "test empty ignore entries never match" [] {
    assert not ("make" | is-ignored ["" "  "])
}

# --- notifications ----------------------------------------------------------

def --env "test commands at or below the threshold are not notified" [] {
    no-ssh
    assert equal (build-notification (settings) "make" 9sec 0) null
    assert equal (build-notification (settings) "make" 10sec 0) null
}

def --env "test long commands produce the default title and body" [] {
    no-ssh
    let n = build-notification (settings) "  make all  " 12sec 0
    assert equal $n.title '"make all" Completed'
    assert equal $n.body "Total time: 12 seconds\nExit code: 0"
    assert equal $n.urgency normal
    assert equal $n.command "make all"
    assert equal $n.elapsed 12
    assert equal $n.duration 12sec
    assert equal $n.exit_code 0
    assert equal $n.expire_time 8sec
}

def --env "test elapsed time is truncated to whole seconds" [] {
    no-ssh
    let n = build-notification (settings) "make" 75999ms 0
    assert equal $n.elapsed 75
    assert equal $n.duration 75sec
}

def --env "test non-zero exit is critical" [] {
    no-ssh
    assert equal (build-notification (settings) "make" 11sec 2 | get urgency) critical
    assert equal (build-notification (settings) "make" 11sec 130 | get urgency) critical
}

def --env "test interrupted commands are suppressed only on request" [] {
    no-ssh
    let st = settings | upsert cancel_on_sigint true
    assert equal (build-notification $st "make" 11sec 130) null
    assert equal (build-notification $st "^make" 11sec -2) null
    assert equal (build-notification $st "make" 11sec 1 | get urgency) critical
    assert not equal (build-notification (settings) "make" 11sec 130) null
}

def --env "test ignored and empty commands are not notified" [] {
    no-ssh
    assert equal (build-notification (settings) "git commit -v" 60sec 0) null
    assert equal (build-notification (settings) "   " 60sec 0) null
}

def --env "test ssh sessions are skipped unless enabled" [] {
    no-ssh
    $env.SSH_CONNECTION = "10.0.0.1 5000 10.0.0.2 22"
    assert equal (build-notification (settings) "make" 60sec 0) null
    assert not equal (build-notification (settings | upsert ssh true) "make" 60sec 0) null
}

def --env "test string and closure templates" [] {
    no-ssh
    let st = settings | merge {
        title: "{command} -> {exit_code}"
        body: {|f| $"took ($f.duration)" }
    }
    let n = build-notification $st "make {x}" 61sec 3
    assert equal $n.title "make {x} -> 3"
    assert equal $n.body "took 1min 1sec"
}

# --- enable / disable -------------------------------------------------------

def --env "test use alone does not change config" [] {
    # The module is already imported at the top of this file.
    assert equal ($env.config.hooks.pre_execution | ours | length) 0
    assert equal ($env.config.hooks.pre_prompt | ours | length) 0
    assert equal (nu-auto-notify status | get enabled) false
}

def --env "test enable installs one hook of each kind before user hooks" [] {
    $env.config.hooks.pre_prompt = [{|| "mine" }]
    $env.config.hooks.pre_execution = [{code: {|| "mine" }}]
    nu-auto-notify enable
    assert equal ($env.config.hooks.pre_prompt | length) 2
    assert equal ($env.config.hooks.pre_execution | length) 2
    assert equal ($env.config.hooks.pre_prompt | first 1 | ours | length) 1
    assert equal ($env.config.hooks.pre_execution | first 1 | ours | length) 1
    let st = nu-auto-notify status
    assert equal $st.enabled true
    assert equal $st.threshold 10sec
    assert equal $st.ignore $DEFAULT_IGNORE
    assert equal $st.notifier default
    assert equal $st.hooks {pre_execution: 1, pre_prompt: 1}
}

def --env "test enable is idempotent and replaces settings" [] {
    nu-auto-notify enable
    nu-auto-notify enable --threshold 20sec --also-ignore [docker bat] --cancel-on-sigint --notifier (capture)
    nu-auto-notify enable --threshold 20sec --also-ignore [docker bat] --cancel-on-sigint --notifier (capture)
    assert equal ($env.config.hooks.pre_prompt | ours | length) 1
    assert equal ($env.config.hooks.pre_execution | ours | length) 1
    let st = nu-auto-notify status
    assert equal $st.threshold 20sec
    assert equal $st.ignore ($DEFAULT_IGNORE ++ [docker bat])
    assert equal $st.cancel_on_sigint true
    assert equal $st.notifier custom
}

def --env "test ignore replaces the default list" [] {
    nu-auto-notify enable --ignore [make] --also-ignore [make cargo]
    assert equal (nu-auto-notify status | get ignore) [make cargo]
}

def --env "test enable rejects a broken template without changes" [] {
    nu-auto-notify enable --threshold 5sec
    let before = $env.config.hooks
    let before_state = nu-auto-notify status
    assert error { nu-auto-notify enable --title "{nope}" }
    assert equal $env.config.hooks $before
    assert equal (nu-auto-notify status) $before_state
}

def --env "test disable removes only its own hooks" [] {
    $env.config.hooks.pre_prompt = [{|| "before" }]
    $env.config.hooks.pre_execution = []
    let before = $env.config.hooks
    nu-auto-notify enable
    nu-auto-notify enable
    nu-auto-notify disable
    assert equal $env.config.hooks $before
    assert equal (nu-auto-notify status | get enabled) false
}

def --env "test disable keeps hooks the user added after enable" [] {
    nu-auto-notify enable
    $env.config.hooks.pre_prompt ++= [{|| "later" }]
    $env.config.hooks.pre_execution ++= [{condition: {|| true }, code: {|| "later" }}]
    nu-auto-notify disable
    assert equal ($env.config.hooks.pre_prompt | length) 1
    assert equal ($env.config.hooks.pre_execution | length) 1
    assert equal ($env.config.hooks.pre_prompt | ours | length) 0
}

def --env "test disable without enable is a no-op" [] {
    let before = $env.config
    nu-auto-notify disable
    assert equal $env.config $before
}

# --- hooks ------------------------------------------------------------------

def --env "test a long command is notified once" [] {
    no-ssh
    nu-auto-notify enable --threshold 1sec --notifier (capture)
    run-line "^sleep 2" 2100
    assert equal ($env.SENT | length) 1
    assert equal $env.SENT.0.title '"^sleep 2" Completed'
    # A prompt without pre_execution (Ctrl+C at the prompt) sees the same
    # CMD_DURATION_MS but no new command.
    for h in ($env.config.hooks.pre_prompt | ours) { do --env $h.code }
    assert equal ($env.SENT | length) 1
    # An empty Enter runs pre_execution with an empty line.
    run-line "" 2100
    assert equal ($env.SENT | length) 1
}

def --env "test short, ignored and failing commands through the hooks" [] {
    no-ssh
    nu-auto-notify enable --threshold 1sec --also-ignore [docker] --notifier (capture)
    run-line "ls" 5
    run-line "docker compose up" 5000 130
    run-line "^false" 3000 1
    assert equal ($env.SENT | length) 1
    assert equal $env.SENT.0.urgency critical
    assert equal $env.SENT.0.body "Total time: 3 seconds\nExit code: 1"
}

def --env "test no notification after disable" [] {
    no-ssh
    nu-auto-notify enable --threshold 1sec --notifier (capture)
    let prompt = $env.config.hooks.pre_prompt | ours | first
    nu-auto-notify disable
    run-line "make" 5000
    # A stale hook reference does nothing once disabled.
    $env.__NU_AUTO_NOTIFY_PENDING = {command: "make"}
    do --env $prompt.code
    assert equal ($env.SENT? | default []) []
}

def --env "test notifier errors do not escape the hook" [] {
    no-ssh
    nu-auto-notify enable --threshold 1sec --notifier {|n| error make {msg: "boom"} }
    run-line "make" 5000
    assert equal $env.__NU_AUTO_NOTIFY_PENDING null
}

def --env "test template errors do not escape the hook" [] {
    no-ssh
    nu-auto-notify enable --threshold 1sec --body {|f| if $f.exit_code == 0 { "ok" } else { error make {msg: "boom"} } } --notifier (capture)
    run-line "make" 5000 1
    assert equal $env.__NU_AUTO_NOTIFY_PENDING null
    assert equal ($env.SENT? | default []) []
}

# --- runner -----------------------------------------------------------------

# Each test runs in its own closure, so `$env` changes do not leak between
# tests.
const TESTS = [
    "test default ignore list matches zsh-auto-notify"
    "test ignore matches the first word"
    "test ignore matches a multi-word prefix"
    "test ignore skips sudo and the external call prefix"
    "test ignore checks every pipeline segment"
    "test empty ignore entries never match"
    "test commands at or below the threshold are not notified"
    "test long commands produce the default title and body"
    "test elapsed time is truncated to whole seconds"
    "test non-zero exit is critical"
    "test interrupted commands are suppressed only on request"
    "test ignored and empty commands are not notified"
    "test ssh sessions are skipped unless enabled"
    "test string and closure templates"
    "test use alone does not change config"
    "test enable installs one hook of each kind before user hooks"
    "test enable is idempotent and replaces settings"
    "test ignore replaces the default list"
    "test enable rejects a broken template without changes"
    "test disable removes only its own hooks"
    "test disable keeps hooks the user added after enable"
    "test disable without enable is a no-op"
    "test a long command is notified once"
    "test short, ignored and failing commands through the hooks"
    "test no notification after disable"
    "test notifier errors do not escape the hook"
    "test template errors do not escape the hook"
]

def run-test [name: string]: nothing -> any {
    try {
        match $name {
            "test default ignore list matches zsh-auto-notify" => { test default ignore list matches zsh-auto-notify }
            "test ignore matches the first word" => { test ignore matches the first word }
            "test ignore matches a multi-word prefix" => { test ignore matches a multi-word prefix }
            "test ignore skips sudo and the external call prefix" => { test ignore skips sudo and the external call prefix }
            "test ignore checks every pipeline segment" => { test ignore checks every pipeline segment }
            "test empty ignore entries never match" => { test empty ignore entries never match }
            "test commands at or below the threshold are not notified" => { test commands at or below the threshold are not notified }
            "test long commands produce the default title and body" => { test long commands produce the default title and body }
            "test elapsed time is truncated to whole seconds" => { test elapsed time is truncated to whole seconds }
            "test non-zero exit is critical" => { test non-zero exit is critical }
            "test interrupted commands are suppressed only on request" => { test interrupted commands are suppressed only on request }
            "test ignored and empty commands are not notified" => { test ignored and empty commands are not notified }
            "test ssh sessions are skipped unless enabled" => { test ssh sessions are skipped unless enabled }
            "test string and closure templates" => { test string and closure templates }
            "test use alone does not change config" => { test use alone does not change config }
            "test enable installs one hook of each kind before user hooks" => { test enable installs one hook of each kind before user hooks }
            "test enable is idempotent and replaces settings" => { test enable is idempotent and replaces settings }
            "test ignore replaces the default list" => { test ignore replaces the default list }
            "test enable rejects a broken template without changes" => { test enable rejects a broken template without changes }
            "test disable removes only its own hooks" => { test disable removes only its own hooks }
            "test disable keeps hooks the user added after enable" => { test disable keeps hooks the user added after enable }
            "test disable without enable is a no-op" => { test disable without enable is a no-op }
            "test a long command is notified once" => { test a long command is notified once }
            "test short, ignored and failing commands through the hooks" => { test short, ignored and failing commands through the hooks }
            "test no notification after disable" => { test no notification after disable }
            "test notifier errors do not escape the hook" => { test notifier errors do not escape the hook }
            "test template errors do not escape the hook" => { test template errors do not escape the hook }
            _ => (error make {msg: $"no such test: ($name)"})
        }
        null
    } catch {|err| $err.msg }
}

def main [] {
    let results = $TESTS | each {|name| {name: $name, error: (do { run-test $name })} }
    for r in $results {
        if $r.error == null {
            print $"ok    ($r.name)"
        } else {
            print $"FAIL  ($r.name): ($r.error)"
        }
    }
    let failed = $results | where error != null | length
    print $"\n($results | length) tests, ($failed) failed"
    if $failed > 0 { exit 1 }
}
