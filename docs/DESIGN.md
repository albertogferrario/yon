# Design

How yon is put together and why. The README covers usage.

## Scope

yon does five things on a remote Linux box: open a persistent shell,
open a desktop, show one of its ports in the browser, copy files and
directories to and from it, and set up a fresh machine. It orchestrates
`ssh`, `rsync`, `tmux`, `systemd` and Xpra; it reimplements none of them.
Removing yon leaves the box and the ssh configuration fully usable by hand.

Session naming, file synchronisation, networking overlays and development
tooling are out of scope.

## States

A box is in up to two states, gained in order. Each is held in one place,
and each command moves one of them, where it is held.

| State | Held by | Up | Down |
| --- | --- | --- | --- |
| known | the client, in `~/.ssh/config` | `add` | `rm` |
| ready | the box | `install` | |

`shell`, `desktop`, `open`, `put` and `get` require a state and change
none. No fact is copied between holders.

Every command runs without arguments and asks for what it needs. A host
given first, in the manner of ssh, answers the host question in advance.
`open` also takes the port after the command word, `put` and `get` their
two paths. Without a host,
`install` and `desktop` also offer the local machine, and act
on it directly when no hosts are configured, which is the case on a box.

## One script

The whole tool is a single Bash file, identical on the client and on the
box. It is written against Bash 3.2, the version shipped with macOS: no
associative arrays, no `mapfile`, and empty arrays are expanded as
`${array[@]+"${array[@]}"}` to stay valid under `set -u`.

Bash was chosen because the work is process orchestration. A compiled
language would mostly hold shell fragments in strings. The trade-off is
weaker testing and quoting hazards, addressed by the conventions below.

## Hosts

Hosts are the entries of `~/.ssh/config`. yon has no host database.

- Listing reads the `Host` lines and skips patterns. User and address are
  resolved by `ssh -G`, so the menu shows what ssh would actually use.
- `add` appends a block preceded by the marker line `# yon`.
- `rm` and the user switch after `install` only touch blocks that carry the
  marker. Hand-written hosts are listed and usable, never modified.
- Every write keeps the previous file as `config.yon.bak`.
- `Include`d files are not parsed.

Any first argument that is not a command word is taken as an ssh
destination, so `user@addr` works without a config entry.

## Running on the target

Remote work is expressed as POSIX `sh` scripts held in variables. `run`
executes a script with `sh -c` locally, or through
`ssh -- host "sh -c '<quoted script>'"` when a host is set. The explicit
`sh -c` keeps the behaviour independent of the remote login shell. `quote`
wraps the script in single quotes; values interpolated into scripts are
validated against strict patterns first.

Nothing is installed on the box for `shell`, `desktop` and `open`; `put`
and `get` expect `rsync` there. `install` is the exception: the client
copies the script to a `mktemp` file on the box, runs it there, and removes
it.

## Prompts

Interactive input is read from file descriptor 3, opened once on the
terminal. This keeps prompts working while standard input is in use (the
script being copied to the box, a pipe) and makes them scriptable: when
`YON_TTY` names a file, answers are read from it line by line. The test
suite relies on this.

`ask`, `confirm` and `choose` return through the variables `ANSWER` and
`CHOICE` instead of standard output, because a command substitution would
run them in a subshell with its own copy of the descriptor.

## Shell

`yon <host>` is `ssh -- <host>`. Persistence comes from the box: `install`
appends to the user's `.bashrc` a line that attaches every interactive ssh
login to the tmux session `main`.

The same snippet puts `~/.local/bin` on `PATH`, and it must do so before
the attach. On Ubuntu `~/.profile` sources `.bashrc` first and extends
`PATH` afterwards; since tmux takes over inside `.bashrc`, the login shell
never reaches that line, and shells started by tmux are not login shells.
Without the snippet, user-installed tools are missing inside tmux.

## Tunnel

`desktop` and `open` share one mechanism, `forward`. A single ssh
connection runs a script on the box, carries `-L <local>:localhost:<port>`
and ends in `sleep infinity`, which holds the tunnel in the foreground.

Locally, a background watcher polls the forwarded port and opens the
browser when it answers; any HTTP reply counts, error pages included. A
single connection means a single authentication. `LogLevel=ERROR` hides the
"open failed" notices ssh prints while the port is polled before anything
on the box has bound it. A pseudo-terminal is requested so that closing the
connection hangs up the remote `sleep`.

## Desktop

The script run before the hold writes the systemd user unit if it differs
from the existing one, enables and starts it, and checks lingering. The
forward is `14500` on both ends. When the local port already answers, the
tunnel is taken to be open and only the browser is launched.

The service refuses to start when a live Xpra session not managed by the
unit already holds display `:100`; dead sessions listed by `xpra list` are
ignored. The HTML5 client binds to `127.0.0.1` only, without a password.

## Open

`open` runs no script before the hold: it forwards a port something on the
box already serves. The local port is the first free one from the port of
the box upwards, probed with Bash's `/dev/tcp` on both loopback addresses,
so two tunnels to the same port number on different boxes can coexist. Ports
below 1024 need root to bind locally; for those the search starts 8000
higher.

The forward targets `localhost` on the box, so services bound to the
loopback interface are reachable and the firewall is not involved.

## Install

`install` runs as root on the box. Order matters in two places: the ssh rule
is added to the firewall before the firewall is enabled, and the sshd
drop-in is validated with `sshd -t` before the reload. The drop-in is named
`00-hardening.conf` because sshd keeps the first value it reads for each
option.

Run from the client, `install` asks its questions locally and passes the
answers to the remote run through `YON_INSTALL_USER` and
`YON_INSTALL_DESKTOP`; their presence also tells the copy on the box to
act on the box itself. The plan and the final confirmation are still shown
by the remote side. Knowing the chosen user, the client can then repoint
the host entry, which is needed because root can no longer log in.

Steps are idempotent, but there is no rollback.

## Put, get

Each is a single `rsync -a --partial --progress` over ssh. `scp -r` needs
nothing on the box, but it follows symlinks instead of copying them, drops
modification times and cannot resume, which matters for project trees.
`rsync` is therefore required on both sides; `install` adds it to the box,
and a box without it fails with rsync's own message.

Three adjustments are made to the paths before `rsync` sees them:

- A relative local path is prefixed with `./`, because `rsync` reads a name
  with a colon before any slash as `host:path`.
- A leading `~/` is removed from a path on the box, and an empty path or
  `~` becomes `.`. Relative paths already start at the home of the box, so
  the result does not depend on the remote side expanding the tilde.
- Trailing slashes are removed from the source. `rsync` would otherwise
  copy the contents of the directory instead of the directory, and
  completion and dropped paths add the slash unasked.

With the slash gone, the destination of a directory is always its
container: `put site work` gives `work/site`, and `work` is created when
missing. Unlike `cp -r`, a directory cannot be renamed by the copy; a
single file can.

A local path typed at the prompt is first unescaped the way terminals paste
a dropped file (surrounding single quotes or backslash escapes, a trailing
space), and a leading tilde is expanded. Paths given as arguments have
already been through the shell and are taken as they are.

`put` checks that the local path exists; everything else is left to
`rsync`, whose messages and exit status pass through. The options are the
ones the rsync 2.6.9 shipped with macOS understands.

## Conventions

- Under `pipefail`, a reader that exits early (`grep -q`, `awk '{exit}'`)
  can kill the writer with SIGPIPE and fail the pipeline. Readers in
  pipelines consume their whole input.
- Messages are short and lower-case, in the vocabulary of the tools
  involved. Errors name the cause and, where one exists, the command that
  fixes it.
- Command words are few: plain unix verbs, one per transition. A bare host
  means shell; `shell` is accepted but not listed.

## Testing

`test.sh` runs the script in a temporary home with fake `ssh`, `sudo`,
`systemctl`, `loginctl`, `rsync` and `xpra` on `PATH`. The fake `ssh` hands the
remote command to a local shell, so quoting is exercised for real. Config
edits, name validation, menus, the desktop unit, the choice of the local
port and the arguments handed to `rsync` are covered; a fake `sleep` ends
the tunnel at once. The fake `rsync` then runs the real one against a
directory standing in for the home of the box, so the copy itself is
checked, ssh transport excluded. CI runs the suite on Ubuntu and macOS.

`install` needs root and a real system. It is checked by hand on a
disposable VM:

1. Launch an Ubuntu VM and put a public key in root's `authorized_keys`.
2. With a throwaway `HOME` and an ssh wrapper pointing at its config, run
   `yon add`, then `install` with the desktop.
3. Verify: the new user logs in and root is refused; `ufw` and `fail2ban`
   are active; `yon <host> desktop` serves the Xpra page through the
   tunnel; closing the tunnel leaves the service running; the service is
   back after a reboot.

Because `install` sets `AllowUsers`, the VM's own management account loses
ssh access. That is expected.

## Limits

- Tested on Ubuntu 26.04 only; Debian is supported in principle.
- Port 14500 and display `:100` are fixed, so one desktop per client at a
  time.
- The desktop has no authentication beyond ssh and local access to the box.
- `open` assumes plain http on the forwarded port.
- `put` and `get` overwrite without asking. With an rsync older than
  3.2.4 on the client, the remote shell splits a path on the box that
  contains spaces.
- No uninstall for what `install` changes.
