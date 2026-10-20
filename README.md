# nu-auto-notify

Desktop notifications for long-running commands in Nushell.

nu-auto-notify sends a notification when a command takes longer than a
threshold, so you can switch away while a build or download runs. It is a
Nushell port of
[zsh-auto-notify](https://github.com/MichaelAquilina/zsh-auto-notify): a plain
module that installs a `pre_execution` and a `pre_prompt` hook and calls
`notify-send` (Linux) or `osascript` (macOS).

## Requirements

- The latest Nushell release (developed with 0.116)
- Linux with `notify-send` (libnotify) and a notification daemon, or macOS

## Install

Clone the repository, then add to your `config.nu`:

```nu
use /path/to/nu-auto-notify/nu-auto-notify
nu-auto-notify enable
```

Or install it with [nupm](https://github.com/nushell/nupm) from the clone
(`$env.NUPM_HOME/modules` must be in `$env.NU_LIB_DIRS`):

```nu
nupm install /path/to/nu-auto-notify --path
```

and add to your `config.nu`:

```nu
use nu-auto-notify
nu-auto-notify enable
```

`use` alone changes nothing. To try it without your own configuration:

```sh
nu --config examples/minimal-config.nu
```

## Usage

```nu
nu-auto-notify enable                                    # notify after 10 seconds
nu-auto-notify enable --threshold 20sec --also-ignore [docker bat]
nu-auto-notify status                                    # current state and settings
nu-auto-notify disable                                   # remove the hooks
```

Running `enable` again replaces the previous hooks and settings without
duplicates. `disable` removes only the hooks `enable` added; your own hooks
stay where they are.

| Flag                 | Default                                                   | Meaning                                                  |
| -------------------- | --------------------------------------------------------- | -------------------------------------------------------- |
| `--threshold`        | `10sec`                                                   | Notify when a command runs longer than this              |
| `--ignore`           | see below                                                 | Replace the ignore list                                  |
| `--also-ignore`      | `[]`                                                      | Add to the ignore list                                   |
| `--title`            | `'"{command}" Completed'`                                 | Title template or closure                                |
| `--body`             | `"Total time: {elapsed} seconds\nExit code: {exit_code}"` | Body template or closure                                 |
| `--cancel-on-sigint` | off                                                       | No notification when the command was stopped with Ctrl+C |
| `--ssh`              | off                                                       | Also notify inside SSH sessions                          |
| `--expire-time`      | `8sec`                                                    | How long `notify-send` shows the notification            |
| `--notifier`         | `notify-send` / `osascript`                               | Closure called with the notification instead             |

Notifications for a non-zero exit code use the `critical` urgency.

### Ignored commands

The default ignore list is `vim nvim less more man tig watch "git commit" top
htop ssh nano`. An entry matches the leading words of any pipeline segment
(split on `|` and `;`), after `sudo` (with its options) and Nushell's `^`
prefix:

- `vim` ignores `vim foo`, `sudo vim /etc/hosts` and `git log | vim -`, but not
  `vimdiff a b`
- `"git commit"` ignores `git commit -v`, but not `git commit-tree` or `git log`

### Templates

`--title` and `--body` take a [`format pattern`](https://www.nushell.sh/commands/docs/format_pattern.html)
string with these fields, or a closure that receives them as a record:

| Field       | Example        |
| ----------- | -------------- |
| `command`   | `cargo build`  |
| `elapsed`   | `75` (seconds) |
| `duration`  | `1min 15sec`   |
| `exit_code` | `0`            |

```nu
nu-auto-notify enable --title "{command}" --body {|f|
    if $f.exit_code == 0 { $"done in ($f.duration)" } else { $"failed with ($f.exit_code)" }
}
```

### Custom notifier

`--notifier` replaces `notify-send`/`osascript`. The closure receives a record
with the fields above plus `title`, `body`, `urgency` (`normal` or
`critical`) and `expire_time`:

```nu
nu-auto-notify enable --notifier {|n| ^ntfy publish mytopic $"($n.title): ($n.body)" }
```

Errors from the notifier are printed and do not break the prompt.

## How it works

The `pre_execution` hook stores the command line (`commandline`). The
`pre_prompt` hook reads `$env.CMD_DURATION_MS` and `$env.LAST_EXIT_CODE`,
consumes the stored command and decides whether to notify. Because the
command is consumed, an empty Enter or Ctrl+C at the prompt never repeats the
previous notification. Both hooks are records marked with a
`__nu_auto_notify` key, which is how `enable` and `disable` find them.

## Known issues

- The elapsed time is measured by Nushell (`CMD_DURATION_MS`), so it covers
  the whole command line, not only the slowest command in it.
- Nushell reports an external killed by Ctrl+C with exit code `-2`, which
  `--cancel-on-sigint` treats like `130`. An interrupted built-in command
  (for example `sleep 1min`) exits with `1` and is still notified.
- Pipeline splitting is textual, so a `|` or `;` inside a string or closure
  also starts a segment for the ignore list.
- Unlike zsh-auto-notify, notifications are not forwarded to the SSH client;
  `--ssh` only stops skipping SSH sessions.

## Development

```sh
nu tests/run.nu
```
