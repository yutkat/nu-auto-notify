# Minimal config to try nu-auto-notify without any other customization:
#
#   XDG_CONFIG_HOME=$(mktemp -d) nu --config examples/minimal-config.nu
#
# In your own config.nu, replace the path below with where you cloned the repo,
# or put the clone's parent directory in $env.NU_LIB_DIRS and `use nu-auto-notify`.

$env.config.show_banner = false

use ../nu-auto-notify
# Notifies when a command runs longer than 10 seconds, except for interactive
# programs such as vim, less or ssh.
nu-auto-notify enable
