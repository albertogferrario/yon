#!/usr/bin/env bash
# Exercises homesh against fake ssh, sudo and systemd commands in a temporary
# home. Uses no network; prompts are answered through HOMESH_TTY.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

export HOME="$WORK/home"
export SSH_LOG="$WORK/ssh.log"
export HOMESH_TTY="$WORK/tty"
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
chmod +x "$WORK/bin/ssh" "$WORK/bin/sudo"

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

answers() { printf '%s\n' "$@" >"$HOMESH_TTY"; }
rejects() { ! "$HERE/homesh" "$@"; }
in_config() { grep -qxF -- "$1" "$CONFIG"; }
reset_log() { : >"$SSH_LOG"; }

# A host the user wrote by hand, and one existing key pair.
printf 'Host old\n  HostName 192.0.2.1\n  User me\n' >"$CONFIG"
touch "$HOME/.ssh/k1" "$HOME/.ssh/k1.pub"
cp "$CONFIG" "$WORK/config.original"

check "help lists the host commands" bash -c "'$HERE/homesh' --help | grep -q 'homesh <host> desktop'"
check "interactive commands need a tty" \
  bash -c "HOMESH_TTY=/nonexistent '$HERE/homesh' 2>&1 | grep -q 'need a tty'"

# add: alias, address, default user, first key, then "shell" in the menu.
reset_log
answers box 198.51.100.7 "" 1 1
"$HERE/homesh" add >/dev/null 2>&1
check "add writes the marker above the block" \
  bash -c "grep -B1 -x 'Host box' '$CONFIG' | head -1 | grep -qxF '# homesh'"
check "add writes the address" in_config "  HostName 198.51.100.7"
check "add defaults the user to root" in_config "  User root"
check "add records the chosen key" in_config "  IdentityFile ~/.ssh/k1"
check "add keeps a copy of the previous file" cmp -s "$WORK/config.original" "$CONFIG.homesh.bak"
check "add leaves existing hosts untouched" bash -c "head -3 '$CONFIG' | cmp -s - '$WORK/config.original'"
check "add then offers the host actions" grep -qF -- " -> box" "$SSH_LOG"

for name in "bad name" "-x" "init" "box"; do
  answers "$name" 198.51.100.8 "" 1 1
  check "add rejects the name '$name'" rejects add
done
answers ok-name 'bad addr;x' "" 1 1
check "add rejects an unsafe address" rejects add
check "rejected additions change nothing" bash -c "[ \$(grep -c '^Host ' '$CONFIG') -eq 2 ]"

# The interactive entry point lists hosts as ssh resolves them.
reset_log
answers 2 1
MENU=$("$HERE/homesh" 2>&1)
check "the host menu shows hand-written hosts" grep -Eq '1\) old +me@old.example' <<<"$MENU"
check "the host menu shows added hosts" grep -Eq '2\) box +root@box.example' <<<"$MENU"
check "the host menu offers to add one" grep -Fq '3) + add' <<<"$MENU"
check "the host menu opens the chosen host" grep -qxF -- " -> box" "$SSH_LOG"

reset_log
"$HERE/homesh" box
check "a bare host opens the shell with plain ssh" grep -qxF -- " -> box" "$SSH_LOG"
reset_log
"$HERE/homesh" box shell
check "shell is accepted as an explicit form" grep -qxF -- " -> box" "$SSH_LOG"
check "shell is not advertised in the help" bash -c "! '$HERE/homesh' --help | grep -qw 'shell$\|<host> shell'"
check "a host starting with '-' is rejected" rejects -oProxyCommand=x
check "an unknown host command is rejected" rejects box frobnicate
check "commands reject extra arguments" rejects init extra

# init on a remote host: the questions are asked here, the work runs there.
answers dev n
check "a failed remote init is reported" rejects box init
check "a failed remote init leaves the host entry alone" in_config "  User root"
answers dev n
FAKE_SUDO_OK=1 "$HERE/homesh" box init >/dev/null 2>&1
check "a completed remote init switches the host to the new user" in_config "  User dev"
check "switching the user keeps the rest of the block" in_config "  IdentityFile ~/.ssh/k1"
check "switching the user leaves other hosts alone" in_config "  User me"
answers root n
check "remote init refuses root as the user" rejects box init

check "init refuses to run without root" \
  bash -c "'$HERE/homesh' init 2>&1 | grep -q 'need root'"

# rm: only blocks homesh wrote, and only after a yes.
answers y
check "rm refuses hosts homesh did not add" rejects old rm
answers n
check "rm needs an explicit yes" rejects box rm
check "a declined rm keeps the host" in_config "Host box"
answers y
"$HERE/homesh" box rm >/dev/null 2>&1
check "rm deletes the block" bash -c "! grep -q 'box\|198.51.100.7\|# homesh' '$CONFIG'"
check "rm leaves other hosts intact" bash -c "head -3 '$CONFIG' | cmp -s - '$WORK/config.original'"

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
UNIT="$HOME/.config/systemd/user/homesh-desktop.service"

: >"$SYSTEMCTL_LOG"
"$HERE/homesh" desktop >/dev/null
check "desktop writes the user service" test -f "$UNIT"
check "the service binds the web client to localhost" \
  grep -qF -- "$WORK/bin/xpra start-desktop :100 --start=xfce4-session --bind-tcp=127.0.0.1:14500 --html=on --daemon=no" "$UNIT"
check "desktop enables and starts the service" \
  grep -qxF -- "--user enable --quiet --now homesh-desktop.service" "$SYSTEMCTL_LOG"
check "a new unit triggers a reload" grep -qF -- "daemon-reload" "$SYSTEMCTL_LOG"

: >"$SYSTEMCTL_LOG"
"$HERE/homesh" desktop >/dev/null
check "an unchanged unit is not reloaded" bash -c "! grep -qF daemon-reload '$SYSTEMCTL_LOG'"
check "no temporary unit is left behind" test ! -e "$UNIT.new"

fake_xpra "DEAD session at :100"
check "a dead session on the display does not block the service" "$HERE/homesh" desktop
fake_xpra "LIVE session at :100"
check "a live foreign session blocks the service" \
  bash -c "'$HERE/homesh' desktop 2>&1 | grep -q ':100 busy'"
fake_xpra "LIVE session at :1000"
check "another display number is not mistaken for :100" "$HERE/homesh" desktop

rm "$WORK/bin/xpra"
check "desktop fails clearly without xpra" \
  bash -c "'$HERE/homesh' desktop 2>&1 | grep -q 'xpra missing'"

# install.sh only installs the CLI; it never touches the system.
"$HERE/install.sh" >/dev/null
check "install.sh installs the command for the current user" test -x "$HOME/.local/bin/homesh"
check "the installed command runs" "$HOME/.local/bin/homesh" --help

if command -v shellcheck >/dev/null; then
  check "shellcheck" shellcheck "$HERE/homesh" "$HERE/install.sh" "$HERE/test.sh"
fi

echo
if [[ $FAILURES -gt 0 ]]; then
  echo "$FAILURES failed"
  exit 1
fi
echo "all passed"
