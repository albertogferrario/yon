# homesh

Remote dev boxes over ssh. One bash script that turns a fresh VPS into a
development home and gets you into its shell or its desktop with one command.

```
homesh                  pick host, pick action
homesh add              new host -> ~/.ssh/config
homesh <host>           shell (tmux session)
homesh <host> desktop   xpra desktop through an ssh tunnel
homesh <host> init      provision a fresh box
homesh <host> rm        drop a host homesh added
```

`<host>` is anything ssh accepts: an alias from `~/.ssh/config` or `user@addr`.
Hosts live in `~/.ssh/config` and nowhere else; homesh keeps no state.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/albertogferrario/homesh/main/install.sh | sh
```

Drops `homesh` into `~/.local/bin` (`/usr/local/bin` as root). Touches nothing
else. From a checkout, `./install.sh` does the same.

Client: macOS or Linux with `bash`, `ssh`, `curl`.
Box: Ubuntu or Debian with `apt` and `systemd`. Tested on Ubuntu 26.04 only.

## New box

```
$ homesh add
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
  3) init
  4) rm
> 3
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

After that, `homesh box` lands in a tmux session that survives disconnects,
and `homesh box desktop` opens the desktop in the browser.

## What init does to the box

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

`homesh <host> desktop` makes sure a systemd user service
(`homesh-desktop.service`) runs Xpra with XFCE, forwards port 14500 over the
ssh connection and opens `http://localhost:14500`. `^C` closes the tunnel;
the desktop keeps running and restarts at boot.

The web client listens on the box's localhost **without a password**. Nothing
is exposed to the network, but any local account on the box can reach it.
Fine on a single-user box, not on a shared one.

To remove it, on the box:

```sh
systemctl --user disable --now homesh-desktop.service
```

## Notes

- `add` and `rm` only write blocks marked `# homesh` in `~/.ssh/config`, and
  keep the previous file as `config.homesh.bak`. Hosts you wrote by hand show
  up in the menu and are never modified.
- Hosts defined in files pulled in with `Include` are not listed.
- Port 14500 and display `:100` are fixed.
- tmux sessions do not survive a reboot of the box; the desktop does.
- On the box itself, `homesh init` (as root) and `homesh desktop` act locally.

## Tests

```sh
./test.sh
```

Runs against fake `ssh`, `sudo` and `systemd` in a temporary home. No network.

## License

MIT
