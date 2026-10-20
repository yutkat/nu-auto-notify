# nu-auto-notify: desktop notifications when a long-running command finishes.
#
# `use nu-auto-notify` only defines commands; nothing changes until
# `nu-auto-notify enable` is run.

use notification.nu [DEFAULT_IGNORE DEFAULT_TITLE DEFAULT_BODY build-notification notify-default render]

# Key that marks the hook records installed by this module.
const MARKER = "__nu_auto_notify"

def state []: nothing -> record {
    $env.__NU_AUTO_NOTIFY? | default {enabled: false}
}

def is-ours []: any -> bool {
    let hook = $in
    ($hook | describe) =~ '^record' and ($hook | get -o $MARKER) == true
}

def hooks [name: string]: nothing -> list {
    $env.config.hooks | get -o $name | default []
}

def --env on-execution []: nothing -> nothing {
    $env.__NU_AUTO_NOTIFY_PENDING = {command: (commandline)}
}

# The command line is consumed here, so later prompts (an empty Enter, Ctrl+C
# at the prompt) never notify about the same command again.
def --env on-prompt []: nothing -> nothing {
    let exit_code = $env.LAST_EXIT_CODE? | default 0
    let duration = $env.CMD_DURATION_MS? | default "0" | into int | into duration --unit ms
    let pending = $env.__NU_AUTO_NOTIFY_PENDING?
    $env.__NU_AUTO_NOTIFY_PENDING = null
    let st = state
    if $pending == null or not $st.enabled {
        return
    }
    try {
        let n = build-notification $st $pending.command $duration $exit_code
        if $n != null {
            do --env $st.notifier $n
        }
    } catch {|err|
        print -e $"nu-auto-notify: ($err.msg)"
    }
}

def --env remove-hooks []: nothing -> nothing {
    for name in [pre_execution pre_prompt] {
        let current = hooks $name
        if ($current | any {|h| $h | is-ours }) {
            $env.config.hooks = ($env.config.hooks | upsert $name ($current | where {|h| not ($h | is-ours) }))
        }
    }
}

# Enable notifications for long-running commands in the current session.
#
# Installs a pre_execution hook that records the command line and a pre_prompt
# hook that sends a notification when that command ran longer than the
# threshold. Running it again replaces the previous installation (and its
# settings) instead of adding duplicates.
#
# Templates for --title and --body use `{command}`, `{elapsed}` (whole
# seconds), `{duration}` and `{exit_code}`; a closure receives a record with
# those fields instead.
export def --env enable [
    --threshold: duration = 10sec # Notify when a command runs longer than this
    --ignore: list<string> # Commands never notified about, matched by leading words (default: vim nvim less more man tig watch "git commit" top htop ssh nano)
    --also-ignore: list<string> = [] # Commands added to the ignore list
    --title: oneof<string, closure> # Notification title (default: '"{command}" Completed')
    --body: oneof<string, closure> # Notification body (default: "Total time: {elapsed} seconds\nExit code: {exit_code}")
    --cancel-on-sigint # Do not notify when the command was interrupted by Ctrl+C
    --ssh # Also notify inside SSH sessions
    --expire-time: duration = 8sec # How long notify-send shows the notification
    --notifier: closure # Called with the notification record instead of notify-send/osascript
]: nothing -> nothing {
    let settings = {
        threshold: $threshold
        ignore: ($ignore | default $DEFAULT_IGNORE | append $also_ignore | uniq)
        title: ($title | default $DEFAULT_TITLE)
        body: ($body | default $DEFAULT_BODY)
        cancel_on_sigint: $cancel_on_sigint
        ssh: $ssh
        expire_time: $expire_time
        # `default` would call a closure fallback instead of returning it.
        notifier: (if $notifier == null { {|n| notify-default $n } } else { $notifier })
        custom_notifier: ($notifier != null)
    }
    # Fails on a broken template before anything is changed.
    let sample = {command: "true", elapsed: 0, duration: 0sec, exit_code: 0}
    render $settings.title $sample | ignore
    render $settings.body $sample | ignore

    remove-hooks
    let hooks = $env.config.hooks
    $env.config.hooks = ($hooks
        | upsert pre_execution (hooks pre_execution | prepend {$MARKER: true, code: {|| on-execution }})
        | upsert pre_prompt (hooks pre_prompt | prepend {$MARKER: true, code: {|| on-prompt }}))

    $env.__NU_AUTO_NOTIFY = $settings | insert enabled true
    $env.__NU_AUTO_NOTIFY_PENDING = null
}

# Disable notifications and remove the hooks enable added.
#
# Other hooks are kept.
export def --env disable []: nothing -> nothing {
    remove-hooks
    if (state).enabled {
        $env.__NU_AUTO_NOTIFY = {enabled: false}
    }
    $env.__NU_AUTO_NOTIFY_PENDING = null
}

# Show whether nu-auto-notify is enabled and its settings.
export def status []: nothing -> record {
    let st = state
    {
        enabled: $st.enabled
        threshold: ($st.threshold? | default null)
        ignore: ($st.ignore? | default null)
        cancel_on_sigint: ($st.cancel_on_sigint? | default null)
        ssh: ($st.ssh? | default null)
        expire_time: ($st.expire_time? | default null)
        notifier: (if not $st.enabled { null } else if $st.custom_notifier { "custom" } else { "default" })
        hooks: {
            pre_execution: (hooks pre_execution | where {|h| $h | is-ours } | length)
            pre_prompt: (hooks pre_prompt | where {|h| $h | is-ours } | length)
        }
    }
}
