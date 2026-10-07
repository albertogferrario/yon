# yon

Remote dev boxes over ssh. One bash script that turns a fresh VPS into a
development home and gets you into its shell or its desktop with one command.
For work that keeps running while the laptop is closed: coding agents,
personal assistants, dev servers.

```
yon                  pick host, pick action
yon <host>           shell (tmux session)

yon add              new host -> ~/.ssh/config
yon install          set up a fresh box
yon desktop          xpra desktop through an ssh tunnel
yon open             a port of the box, in the browser
yon put              file or dir -> box
yon get              file or dir <- box
yon rm               drop a host yon added
```

Every command asks for what it needs. Put the host first to skip that
question: `yon <host> install`, `yon <host> open 3000`,
`yon <host> put <local> [remote]`, `yon <host> get <remote> [local]`.
`<host>` is anything ssh accepts, an alias from `~/.ssh/config` or
`user@addr`.

| A box | Held by | Up | Down |
| --- | --- | --- | --- |
| is known here | `~/.ssh/config` | `add` | `rm` |
| is ready | the box | `install` | |

Each command moves one row. `add` takes any server you can reach. yon keeps
no state of its own.

## Use cases

- **Coding agents on a VPS.** Claude Code, Codex or OpenCode run in the
  box's tmux session: they keep working when the laptop sleeps or the
  connection drops, and `yon box` reattaches to them. Any ssh client lands
  in the same session, a phone app such as Termius or Blink included.
  `yon box open 3000` shows the dev server an agent started.
- **A personal assistant that stays up.** OpenClaw, Hermes Agent and similar
  assistants run as long-lived services on the box. `install` leaves only
  ssh reachable from the network; the assistant's web UI stays on the box's
  localhost and `yon box open 18789` (the OpenClaw dashboard) brings it to
  the client's browser.
- **A desktop on a server.** `yon box desktop` is an XFCE session in the
  browser, for GUI tools, or for signing in or solving a CAPTCHA in a
  browser running on the box.

Everything goes over ssh: no VPN, no agent on the client, no hosted
service. Any provider works.

## Install

```sh
curl -fsSL https://yon.sh/install | sh
```

Drops `yon` into `~/.local/bin` (`/usr/local/bin` as root). Touches nothing
else. From a checkout, `./install.sh` does the same.

Client: macOS or Linux with `bash`, `ssh`, `curl`, `rsync`.
Box: Ubuntu or Debian with `apt` and `systemd`. Tested on Ubuntu 26.04 only.

## New box

```
$ yon add
host: box
addr: 203.0.113.10
user [root]:

key
  1) id_ed25519
  2) + new key
  3) ssh default
> 1
added box

box
  1) shell
  2) desktop
  3) open
  4) put
  5) get
  6) install
  7) rm
> 6
user on box [me]: dev
desktop (xpra+xfce, ~1GB)? [y/N] y

plan
  user     dev (+sudo, root's ssh keys)
  sshd     dev only, keys only (root, passwords, other accounts: out)
  out      ubuntu
  net      ufw (ssh only), fail2ban, unattended-upgrades
  tmux     autoattach on ssh login
  desktop  xpra+xfce, linger, started

go? [y/N] y
...
box: user -> dev
```

After that, `yon box` lands in a tmux session that survives disconnects,
and `yon box desktop` opens the desktop in the browser.

## What install does to the box

Read this before running it on a machine you care about.

- Creates the user (asks for its sudo password) and copies root's
  `authorized_keys` to it.
- Writes `/etc/ssh/sshd_config.d/00-hardening.conf`: no root login, no
  passwords, `AllowUsers <user>`. **Every other account loses ssh access**,
  including provider or automation accounts. The plan names the accounts
  with a login shell that would be shut out.
- Enables `ufw` with only ssh open. Anything else you serve from the box
  needs its own rule.
- Installs `fail2ban`, `rsync`, `tmux`, `unattended-upgrades`.
- Appends to the user's `.bashrc`: `~/.local/bin` on `PATH`, and attach to
  the tmux session `main` on ssh login.
- With the desktop: adds the xpra.org apt repository (source file from a
  fixed Xpra release tag), installs Xpra and XFCE,
  disables Xpra's system-wide proxy, enables lingering for the user and
  starts the desktop service.

It shows this plan and waits for a yes. It does not undo itself: keep the
root session open until you have verified the new login from another
terminal. It installs no dev tools or agents.

## Desktop

`yon <host> desktop` makes sure a systemd user service
(`yon-desktop.service`) runs Xpra with XFCE, forwards port 14500 over the
ssh connection and opens `http://localhost:14500`. `^C` closes the tunnel;
the desktop keeps running and restarts at boot. `install` with the desktop
starts the same service, so the display `:100` exists before the first
`yon <host> desktop`. The service restarts after any exit; to stop it, use
`systemctl --user stop yon-desktop.service` on the box.

The web client listens on the box's localhost **without a password**. Nothing
is exposed to the network, but any local account on the box can reach it.
Fine on a single-user box, not on a shared one.

To remove it, on the box:

```sh
systemctl --user disable --now yon-desktop.service
```

## Open

`yon <host> open 3000` forwards port 3000 of the box over the ssh
connection and opens `http://localhost:3000`: a dev server or a preview
becomes visible on the client and nowhere else. `^C` closes the tunnel.
Nothing is installed or started on the box, and no firewall rule is needed.

If the local port is taken, the next free one is used and the address
printed says which. Ports below 1024 are served from 8000 higher: 80 on the
box is `http://localhost:8080`.

## Put, get

```
$ yon box put ./site work        -> ~/work/site on the box
$ yon box get work/site/dist     -> ./dist here
```

`put` copies a file or a directory to the box, `get` copies one back. Both
are `rsync -a`: symlinks, permissions and times are kept, and running the
same command again resumes an interrupted copy or sends only what changed.
Paths on the box start at its home, which is also where `put` lands when no
destination is given; `get` lands in the current directory. Without paths,
both ask: a file dropped on the terminal is accepted as the local path.

A directory is copied as a whole, with or without a trailing slash, and
always into the destination, which is created if missing: it keeps its
name. A single file can be renamed on the way, `put a.txt b.txt`. Files
already at the destination are overwritten without asking; nothing is
deleted there. `rsync` must be on both sides: `install` puts it on the box.

## Leaving a box

Nothing here is automated. On the box:

```sh
systemctl --user disable --now yon-desktop.service
```

Then remove what you put there yourself (credentials, repository keys,
agent logins) and delete the user or hand it over. To give other accounts
ssh access back, edit or remove
`/etc/ssh/sshd_config.d/00-hardening.conf` and reload ssh. On the client,
`yon <host> rm`.

## Notes

- `add` and `rm` only write blocks marked `# yon` in `~/.ssh/config`, and
  keep the previous file as `config.yon.bak`. Hosts you wrote by hand show
  up in the menu and are never modified.
- Hosts defined in files pulled in with `Include` are not listed.
- Port 14500 and display `:100` are fixed for the desktop.
- `open` speaks plain http to the forwarded port. A port that does not
  speak http, such as Postgres, is forwarded all the same: after 90 seconds
  yon says there is no http answer and keeps the tunnel open.
- tmux sessions do not survive a reboot of the box; the desktop does.
- `install` and `desktop` without a host also offer `this machine`; with no
  hosts configured, as on the box itself, they act on it directly.
- `install.sh` puts the CLI on the client; `yon install` sets up a box.

## Tests

```sh
./test.sh
```

Runs against fake `ssh`, `sudo` and `systemd` in a temporary home.
No network beyond the loopback interface.
How it is built: [docs/DESIGN.md](docs/DESIGN.md).

## License

MIT
