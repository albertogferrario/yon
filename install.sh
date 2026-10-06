#!/usr/bin/env bash
# Installs the homesh CLI on this machine — client or server alike, same job.
# Changes nothing else. The homesh script must sit next to this file.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
[[ -f $HERE/homesh ]] || {
  echo "install: homesh not found next to install.sh" >&2
  exit 1
}

bin_dir="$HOME/.local/bin"
[[ $EUID -eq 0 ]] && bin_dir=/usr/local/bin
mkdir -p "$bin_dir"
install -m 755 "$HERE/homesh" "$bin_dir/homesh"
echo "installed $bin_dir/homesh"

case ":$PATH:" in
  *":$bin_dir:"*) ;;
  *) echo "note: $bin_dir is not on PATH" ;;
esac
