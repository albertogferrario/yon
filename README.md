# yon

Remote dev boxes over ssh. One bash script that turns a fresh VPS into a
development home and gets you into its shell or its desktop with one command.

```
yon                  pick host, pick action
yon <host>           shell (tmux session)

yon add              new host -> ~/.ssh/config
yon install          set up a fresh box
yon desktop          xpra desktop through an ssh tunnel
yon open             a port of the box, in the browser
yon rm               drop a host yon added
```

Every command asks for what it needs. Put the host first to skip that
question: `yon <host> install`, `yon <host> open 3000`. `<host>` is anything ssh accepts, an alias
from `~/.ssh/config` or `user@addr`.

| A box | Held by | Up | Down |
| --- | --- | --- | --- |
| is known here | `~/.ssh/config` | `add` | `rm` |
| is ready | the box | `install` | |

Each command moves one row. `add` takes any server you can reach. yon keeps
no state of its own.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/albertogferrario/yon/main/install.sh | sh
```

Drops `yon` into `~/.local/bin` (`/usr/local/bin` as root). Touches nothing
else. From a checkout, `./install.sh` does the same.

Client: macOS or Linux with `bash`, `ssh`, `curl`.
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
  4) install
  5) rm
> 4
user on box [me]: dev
desktop (xpra+xfce, ~1GB)? [y/N] y

plan
  user     dev (+sudo, root's ssh keys)
  sshd     dev only, keys only (root, passwords, other accounts: out)
  net      ufw (ssh only), fail2ban, unattended-upgrades
  tmux     autoattach on ssh login
  desktop  xpra+xfce, linger

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
  including provider or automation accounts.
- Enables `ufw` with only ssh open. Anything else you serve from the box
  needs its own rule.
- Installs `fail2ban`, `tmux`, `unattended-upgrades`.
- Appends to the user's `.bashrc`: `~/.local/bin` on `PATH`, and attach to
  the tmux session `main` on ssh login.
- With the desktop: adds the xpra.org apt repository, installs Xpra and XFCE,
  disables Xpra's system-wide proxy, enables lingering for the user.

It shows this plan and waits for a yes. It does not undo itself: keep the
root session open until you have verified the new login from another
terminal. It installs no dev tools or agents.

## Desktop

`yon <host> desktop` makes sure a systemd user service
(`yon-desktop.service`) runs Xpra with XFCE, forwards port 14500 over the
ssh connection and opens `http://localhost:14500`. `^C` closes the tunnel;
the desktop keeps running and restarts at boot.

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
- `open` speaks plain http to the forwarded port.
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
