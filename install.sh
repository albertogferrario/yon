#!/bin/sh
# Installs the yon CLI on this machine — client or box alike, same job.
# Changes nothing else.
#
#   curl -fsSL https://yon.sh/install | sh
#   ./install.sh        from a checkout: installs the yon next to this file
#
# POSIX sh, wrapped in main so a truncated download cannot run half of it.
set -eu

SOURCE_URL="https://raw.githubusercontent.com/albertogferrario/yon/master/yon"

main() {
  bin_dir="$HOME/.local/bin"
  [ "$(id -u)" -ne 0 ] || bin_dir=/usr/local/bin
  mkdir -p "$bin_dir"

  # Run as a file, $0 is this script; piped into a shell, it is the shell.
  local_copy="$(dirname "$0")/yon"
  case "$0" in
    *install.sh) ;;
    *) local_copy="" ;;
  esac

  if [ -n "$local_copy" ] && [ -f "$local_copy" ]; then
    install -m 755 "$local_copy" "$bin_dir/yon"
  else
    curl -fsSL "$SOURCE_URL" -o "$bin_dir/yon.download"
    chmod 755 "$bin_dir/yon.download"
    mv "$bin_dir/yon.download" "$bin_dir/yon"
  fi
  echo "installed $bin_dir/yon"

  case ":$PATH:" in
    *":$bin_dir:"*) ;;
    *) echo "note: $bin_dir is not on PATH" ;;
  esac
}

main
