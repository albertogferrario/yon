#!/usr/bin/env bash
# Exercises yon against fake ssh, sudo and systemd commands in a
# temporary home. Uses no network; prompts are answered through YON_TTY.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

export HOME="$WORK/home"
export SSH_LOG="$WORK/ssh.log"
export RSYNC_LOG="$WORK/rsync.log"
export BOX_HOME="$WORK/box-home"
REAL_RSYNC=$(command -v rsync || true)
export REAL_RSYNC
export YON_TTY="$WORK/tty"
CONFIG="$HOME/.ssh/config"
mkdir -p "$HOME/.ssh" "$WORK/bin"
export PATH="$WORK/bin:$PATH"

# Stands in for a server: logs the call, answers -G from the config, and lets
# a shell parse the remote command exactly as a login shell does.
cat >"$WORK/bin/ssh" <<'EOF'
#!/bin/sh
options=""
while [ "$1" != "--" ]; do options="$options $1"; shift; done
echo "$options -> $2" >>"$SSH_LOG"
case "$options" in
  *-G*)
    awk -v h="$2" 'tolower($1)=="host"{f=($2==h)} f&&tolower($1)=="user"{print "user " $2}' "$HOME/.ssh/config"
    echo "hostname $2.example"
    exit 0
    ;;
esac
[ -n "${3:-}" ] || exit 0
exec sh -c "$3"
EOF

# Either pretends the privileged command succeeded, or runs it unprivileged.
cat >"$WORK/bin/sudo" <<'EOF'
#!/bin/sh
[ -z "${FAKE_SUDO_OK:-}" ] || exit 0
exec "$@"
EOF

# Logs its arguments, separated by "|", then copies for real with host:path
# taken as a path under BOX_HOME, which stands in for the home of the box.
# openrsync runs a local copy by starting "rsync --server" from PATH; that
# call is passed through untouched, since its stdout carries the protocol.
cat >"$WORK/bin/rsync" <<'EOF'
#!/bin/sh
[ "$1" != --server ] || exec "$REAL_RSYNC" "$@"
printf '%s|' "$@" >>"$RSYNC_LOG"
echo >>"$RSYNC_LOG"
[ -n "$REAL_RSYNC" ] || exit 0
for argument; do
  shift
  case $argument in
    /* | .* | -*) ;;
    *:*) argument="$BOX_HOME/${argument#*:}" ;;
  esac
  set -- "$@" "$argument"
done
exec "$REAL_RSYNC" "$@" >/dev/null
EOF

# No forwarded port answers here, and no browser is opened.
printf '#!/bin/sh\nexit 1\n' >"$WORK/bin/curl"
# The remote side of a tunnel returns at once instead of holding it.
# shellcheck disable=SC2016  # $1 and $@ belong to the generated script
printf '#!/bin/sh\n[ "$1" = infinity ] || exec /bin/sleep "$@"\n' >"$WORK/bin/sleep"
for tool in open xdg-open; do
  printf '#!/bin/sh\nexit 0\n' >"$WORK/bin/$tool"
done
chmod +x "$WORK/bin/ssh" "$WORK/bin/rsync" "$WORK/bin/sudo" "$WORK/bin/curl" "$WORK/bin/sleep" "$WORK/bin/open" "$WORK/bin/xdg-open"

FAILURES=0

check() { # check <description> <command...>
  local description=$1
  shift
  if "$@" >/dev/null 2>&1; then
    echo "ok   $description"
  else
    echo "FAIL $description"
    FAILURES=$((FAILURES + 1))
  fi
}

answers() { printf '%s\n' "$@" >"$YON_TTY"; }
rejects() { ! "$HERE/yon" "$@"; }
in_config() { grep -qxF -- "$1" "$CONFIG"; }
reset_log() { : >"$SSH_LOG"; }

# A host the user wrote by hand, and one existing key pair.
printf 'Host old\n  HostName 192.0.2.1\n  User me\n' >"$CONFIG"
touch "$HOME/.ssh/k1" "$HOME/.ssh/k1.pub"
cp "$CONFIG" "$WORK/config.original"

check "help lists every command" \
  bash -c "'$HERE/yon' --help | grep -c '^yon \(add\|install\|desktop\|open\|put\|get\|rm\) ' | grep -qx 7"
check "help shows the host-first form" \
  bash -c "'$HERE/yon' --help | grep -qxF 'yon <host> install|desktop|rm' && '$HERE/yon' --help | grep -qxF 'yon <host> open <port>'"
check "help shows the host-first form of put and get" \
  bash -c "'$HERE/yon' --help | grep -qxF 'yon <host> put <local> [remote]' && '$HERE/yon' --help | grep -qxF 'yon <host> get <remote> [local]'"
check "interactive commands need a tty" \
  bash -c "YON_TTY=/nonexistent '$HERE/yon' 2>&1 | grep -q 'need a tty'"

# add: alias, address, default user, first key, then "shell" in the menu.
reset_log
answers box 198.51.100.7 "" 1 1
"$HERE/yon" add >/dev/null 2>&1
check "add writes the marker above the block" \
  bash -c "grep -B1 -x 'Host box' '$CONFIG' | head -1 | grep -qxF '# yon'"
check "add writes the address" in_config "  HostName 198.51.100.7"
check "add defaults the user to root" in_config "  User root"
check "add records the chosen key" in_config "  IdentityFile ~/.ssh/k1"
check "add keeps a copy of the previous file" cmp -s "$WORK/config.original" "$CONFIG.yon.bak"
check "add leaves existing hosts untouched" bash -c "head -3 '$CONFIG' | cmp -s - '$WORK/config.original'"
check "add then offers the host actions" grep -qF -- " -> box" "$SSH_LOG"

for name in "bad name" "-x" "install" "open" "put" "get" "box"; do
  answers "$name" 198.51.100.8 "" 1 1
  check "add rejects the name '$name'" rejects add
done
answers ok-name 'bad addr;x' "" 1 1
check "add rejects an unsafe address" rejects add
answers nobox ""
check "add rejects an empty address" rejects add
check "rejected additions change nothing" bash -c "[ \$(grep -c '^Host ' '$CONFIG') -eq 2 ]"

# The interactive entry point lists hosts as ssh resolves them.
reset_log
answers 2 1
MENU=$("$HERE/yon" 2>&1)
check "the host menu shows hand-written hosts" grep -Eq '1\) old +me@old.example' <<<"$MENU"
check "the host menu shows added hosts" grep -Eq '2\) box +root@box.example' <<<"$MENU"
check "the host menu offers to add one" grep -Fq '3) + add' <<<"$MENU"
check "the host menu opens the chosen host" grep -qxF -- " -> box" "$SSH_LOG"

reset_log
"$HERE/yon" box
check "a bare host opens the shell with plain ssh" grep -qxF -- " -> box" "$SSH_LOG"
reset_log
"$HERE/yon" box shell
check "shell is accepted as an explicit form" grep -qxF -- " -> box" "$SSH_LOG"
check "shell is not advertised in the help" bash -c "! '$HERE/yon' --help | grep -qw 'shell$\|<host> shell'"
check "a host starting with '-' is rejected" rejects -oProxyCommand=x
check "an unknown host command is rejected" rejects box frobnicate
check "commands reject extra arguments" rejects install extra

# install on a remote host: the questions are asked here, the work runs there.
answers dev n
check "a failed remote install is reported" rejects box install
check "a failed remote install leaves the host entry alone" in_config "  User root"
answers dev n
FAKE_SUDO_OK=1 "$HERE/yon" box install >/dev/null 2>&1
check "a completed remote install switches the host to the new user" in_config "  User dev"
check "switching the user keeps the rest of the block" in_config "  IdentityFile ~/.ssh/k1"
check "switching the user leaves other hosts alone" in_config "  User me"
answers root n
check "remote install refuses root as the user" rejects box install

# Without a host, install asks which one; the machine itself is the last pick.
reset_log
answers 2 dev n
FAKE_SUDO_OK=1 "$HERE/yon" install >/dev/null 2>&1
check "install without a host asks for one" grep -qF -- " -> box" "$SSH_LOG"
answers 3
check "install offers this machine, where it needs root" \
  bash -c "'$HERE/yon' install 2>&1 | grep -q '3) this machine' && '$HERE/yon' install 2>&1 | grep -q 'need root'"
check "the copy sent to a box never asks for a host" \
  bash -c "YON_INSTALL_USER=dev '$HERE/yon' install 2>&1 | grep -q 'need root'"
reset_log
answers 2
"$HERE/yon" desktop >/dev/null 2>&1 || true
check "desktop without a host asks for one" grep -qF -- "-L 14500:localhost:14500 -> box" "$SSH_LOG"

# open: one ssh connection carries the forward; the local port is the first
# free one from the port of the box.
forwarded() { grep -Eq -- "-L $1:localhost:$2 -> box\$" "$SSH_LOG"; }
reset_log
"$HERE/yon" box open 3000 >/dev/null 2>&1
check "open forwards the port of the box" forwarded '[0-9]+' 3000
reset_log
answers 8080
"$HERE/yon" box open >/dev/null 2>&1
check "open asks for the port" forwarded '[0-9]+' 8080
reset_log
answers 2 8081
OPENED=$("$HERE/yon" open 2>&1)
check "open without a host asks for one" forwarded '[0-9]+' 8081
check "open does not offer this machine" bash -c "! grep -q 'this machine' <<<'$OPENED'"
reset_log
answers 2 3 8082
"$HERE/yon" >/dev/null 2>&1
check "the action menu offers open" forwarded '[0-9]+' 8082
reset_log
"$HERE/yon" box open 80 >/dev/null 2>&1
check "a privileged port is forwarded from an unprivileged one" forwarded '8[0-9]{3}' 80
for port in 0 65536 abc 80x 080 ""; do
  answers ""
  check "open rejects the port '$port'" rejects box open "$port"
done
check "open takes a single port" rejects box open 3000 3001

# put, get: one rsync each way, for files and directories alike.
# The tildes below are literal on purpose: yon resolves them itself.
copied() { grep -qxF -- "-a|--partial|--progress|--|$1|$2|" "$RSYNC_LOG"; }
mkdir -p "$WORK/stuff/dir" "$WORK/stuff/back" "$BOX_HOME/work/site"
echo payload >"$WORK/stuff/dir/inner"
ln -s inner "$WORK/stuff/dir/link"
touch "$WORK/stuff/file" "$WORK/stuff/my file" "$WORK/stuff/a:b" "$BOX_HOME/notes.txt" "$BOX_HOME/work/site/index"
cd "$WORK/stuff"
: >"$RSYNC_LOG"
"$HERE/yon" box put "$WORK/stuff/file"
check "put copies to the home of the box by default" copied "$WORK/stuff/file" "box:."
"$HERE/yon" box put dir/ work
check "put takes a directory and a destination" copied ./dir "box:work"
# shellcheck disable=SC2088
"$HERE/yon" box put a:b '~/in box'
check "put keeps a local name with a colon local" copied ./a:b "box:in box"
"$HERE/yon" box put file '~'
check "a remote tilde means the home of the box" copied ./file "box:."
check "put rejects a missing local path" rejects box put nothing-here
check "put takes at most two paths" rejects box put file a b

: >"$RSYNC_LOG"
"$HERE/yon" box get work/site/
check "get copies into the current directory by default" copied "box:work/site" .
# shellcheck disable=SC2088
"$HERE/yon" box get '~/notes.txt' "$WORK/stuff/back"
check "get takes a destination" copied "box:notes.txt" "$WORK/stuff/back"
"$HERE/yon" me@198.51.100.9 get notes.txt
check "get works on a destination outside the config" copied "me@198.51.100.9:notes.txt" .
check "get takes at most two paths" rejects box get a b c

if [[ -n $REAL_RSYNC ]]; then
  check "put lands a file in the home of the box" test -f "$BOX_HOME/file"
  check "a directory named with a trailing slash is copied whole" \
    bash -c "grep -qx payload '$BOX_HOME/work/dir/inner'"
  check "put keeps symlinks as symlinks" test -L "$BOX_HOME/work/dir/link"
  check "get brings a directory back whole" test -f "$WORK/stuff/site/index"
  check "get lands a file in the destination" test -f "$WORK/stuff/back/notes.txt"
fi

# Asked for, a local path is unescaped the way a terminal pastes a dropped file.
: >"$RSYNC_LOG"
answers 'my\ file ' ""
"$HERE/yon" box put >/dev/null 2>&1
check "put asks for the paths" copied "./my file" "box:."
answers "'$WORK/stuff/my file'" work
"$HERE/yon" box put >/dev/null 2>&1
check "put accepts a quoted dropped path" copied "$WORK/stuff/my file" "box:work"
# shellcheck disable=SC2088
answers '~/.ssh/k1' ""
"$HERE/yon" box put >/dev/null 2>&1
check "a local tilde means the home of this machine" copied "$HOME/.ssh/k1" "box:."
: >"$RSYNC_LOG"
answers 2 file ""
PUT=$("$HERE/yon" put 2>&1)
check "put without a host asks for one" copied ./file "box:."
check "put does not offer this machine" bash -c "! grep -q 'this machine' <<<'$PUT'"
answers 2 work ""
"$HERE/yon" get >/dev/null 2>&1
check "get without a host asks for one" copied "box:work" .
answers ""
check "get rejects an empty remote path" rejects box get
: >"$RSYNC_LOG"
answers 2 4 file ""
"$HERE/yon" >/dev/null 2>&1
check "the action menu offers put" copied ./file "box:."
answers 2 5 work ""
"$HERE/yon" >/dev/null 2>&1
check "the action menu offers get" copied "box:work" .
check "put and get take no arguments without a host" bash -c "! '$HERE/yon' put file && ! '$HERE/yon' get work"
cd "$HERE"

# A listener on the loopback interface occupies a port picked by the system.
if command -v python3 >/dev/null; then
  python3 -c 'import socket, sys, time
s = socket.socket()
s.bind(("127.0.0.1", 0))
s.listen(1)
print(s.getsockname()[1])
sys.stdout.flush()
time.sleep(60)' >"$WORK/busy-port" &
  LISTENER=$!
  until [[ -s $WORK/busy-port ]]; do sleep 0.1; done
  BUSY=$(cat "$WORK/busy-port")
  reset_log
  "$HERE/yon" box open "$BUSY" >/dev/null 2>&1
  check "a busy local port is skipped" bash -c "grep -Eq -- '-L [0-9]+:localhost:$BUSY -> box\$' '$SSH_LOG' && ! grep -qF -- '-L $BUSY:' '$SSH_LOG'"
  kill "$LISTENER"
  wait "$LISTENER" 2>/dev/null || true
  reset_log
  "$HERE/yon" box open "$BUSY" >/dev/null 2>&1
  check "a free local port matches the port of the box" forwarded "$BUSY" "$BUSY"
fi

# rm: only blocks yon wrote, and only after a yes.
answers y
check "rm refuses hosts yon did not add" rejects old rm
answers n
check "rm needs an explicit yes" rejects box rm
check "a declined rm keeps the host" in_config "Host box"
answers 2 y
"$HERE/yon" rm >/dev/null 2>&1
check "rm without a host asks for one and deletes its block" \
  bash -c "! grep -q 'box\|198.51.100.7\|# yon' '$CONFIG'"
check "rm leaves other hosts intact" bash -c "head -3 '$CONFIG' | cmp -s - '$WORK/config.original'"

# From here on the machine has no hosts: install and desktop mean itself.
: >"$CONFIG"
check "with no hosts, install acts on this machine" \
  bash -c "'$HERE/yon' install 2>&1 | grep -q 'need root'"
check "with no hosts, rm has nothing to pick" bash -c "'$HERE/yon' rm 2>&1 | grep -q 'no hosts'"

# fake_xpra <line>: an xpra whose "list" prints the given line.
fake_xpra() {
  # shellcheck disable=SC2016  # $1 belongs to the generated script
  printf '#!/bin/sh\n[ "$1" = list ] && echo "%s"\nexit 0\n' "$1" >"$WORK/bin/xpra"
}

# Desktop service on this machine, with systemd and Xpra replaced by fakes.
export SYSTEMCTL_LOG="$WORK/systemctl.log"
for tool in xpra xfce4-session; do
  printf '#!/bin/sh\nexit 0\n' >"$WORK/bin/$tool"
done
cat >"$WORK/bin/systemctl" <<'EOF'
#!/bin/sh
echo "$*" >>"$SYSTEMCTL_LOG"
case "$*" in *is-active*) exit 1 ;; esac
EOF
printf '#!/bin/sh\necho yes\n' >"$WORK/bin/loginctl"
chmod +x "$WORK/bin/xpra" "$WORK/bin/xfce4-session" "$WORK/bin/systemctl" "$WORK/bin/loginctl"
UNIT="$HOME/.config/systemd/user/yon-desktop.service"

: >"$SYSTEMCTL_LOG"
"$HERE/yon" desktop >/dev/null
check "desktop writes the user service" test -f "$UNIT"
check "the service binds the web client to localhost" \
  grep -qF -- "$WORK/bin/xpra start-desktop :100 --start=xfce4-session --bind-tcp=127.0.0.1:14500 --html=on --daemon=no" "$UNIT"
check "the service restarts after any exit" grep -qxF -- "Restart=always" "$UNIT"
check "desktop enables and starts the service" \
  grep -qxF -- "--user enable --quiet --now yon-desktop.service" "$SYSTEMCTL_LOG"
check "a new unit triggers a reload" grep -qF -- "daemon-reload" "$SYSTEMCTL_LOG"

: >"$SYSTEMCTL_LOG"
"$HERE/yon" desktop >/dev/null
check "an unchanged unit is not reloaded" bash -c "! grep -qF daemon-reload '$SYSTEMCTL_LOG'"
check "no temporary unit is left behind" test ! -e "$UNIT.new"

fake_xpra "DEAD session at :100"
check "a dead session on the display does not block the service" "$HERE/yon" desktop
fake_xpra "LIVE session at :100"
check "a live foreign session blocks the service" \
  bash -c "'$HERE/yon' desktop 2>&1 | grep -q ':100 busy'"
fake_xpra "LIVE session at :1000"
check "another display number is not mistaken for :100" "$HERE/yon" desktop

rm "$WORK/bin/xpra"
check "desktop fails clearly without xpra" \
  bash -c "'$HERE/yon' desktop 2>&1 | grep -q 'xpra missing'"

# install.sh only installs the CLI; it never touches the system.
"$HERE/install.sh" >/dev/null
check "install.sh installs the command for the current user" test -x "$HOME/.local/bin/yon"
check "the installed command runs" "$HOME/.local/bin/yon" --help

if command -v shellcheck >/dev/null; then
  check "shellcheck" shellcheck "$HERE/yon" "$HERE/install.sh" "$HERE/test.sh"
fi

echo
if [[ $FAILURES -gt 0 ]]; then
  echo "$FAILURES failed"
  exit 1
fi
echo "all passed"
