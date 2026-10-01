#!/usr/bin/env bash
# Remove a Vibeshine SteamOS user installation made by install.sh.
# SPDX-License-Identifier: GPL-3.0-only

set -euo pipefail

CONTAINER_NAME=${VIBESHINE_CONTAINER:-vibeshine-build}
WORK_DIR=${VIBESHINE_WORK_DIR:-"${XDG_CACHE_HOME:-$HOME/.cache}/vibeshine-steamos-build"}
data_home=${XDG_DATA_HOME:-"$HOME/.local/share"}
config_home=${XDG_CONFIG_HOME:-"$HOME/.config"}

usage() {
  cat <<EOF
Usage: bash uninstall.sh [--remove-build] [--purge] [--yes]

Removes the Vibeshine service, launcher and installed releases. Settings and
Moonlight pairings in $config_home/vibeshine are kept unless --purge is given.

  --remove-build  Also delete the build container ($CONTAINER_NAME) and the
                  cached source/build tree ($WORK_DIR)
  --purge         Also delete Vibeshine settings, credentials and pairings
  --yes           Do not ask for confirmation
EOF
}

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

remove_build=no
purge=no
assume_yes=no
while (($#)); do
  case "$1" in
    --remove-build) remove_build=yes; shift ;;
    --purge) purge=yes; shift ;;
    --yes|-y) assume_yes=yes; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done
[[ $(id -u) -ne 0 ]] || die "run this as your desktop user (deck), not with sudo"
[[ "$HOME" == /* && "$data_home" == /* && "$config_home" == /* ]] || die "HOME and XDG paths must be absolute"

if [[ "$purge" == yes && "$assume_yes" == no ]]; then
  read -r -p "Delete all Vibeshine settings and Moonlight pairings in $config_home/vibeshine? [y/N] " reply
  [[ "$reply" == [yY]* ]] || die "aborted"
fi

uninstaller="$data_home/vibeshine-steamos/current/share/vibeshine/steamos/uninstall-user.sh"
if [[ -x "$uninstaller" ]]; then
  # Copy it out first: it deletes the directory it lives in.
  tmp=$(mktemp)
  trap 'rm -f -- "$tmp"' EXIT
  cp -- "$uninstaller" "$tmp"
  bash "$tmp"
elif [[ -e "$data_home/vibeshine-steamos" || -e "$config_home/systemd/user/vibeshine-steamos.service" ]]; then
  echo "Installed uninstaller not found; removing the service and files directly."
  systemctl --user disable --now vibeshine-steamos.service 2>/dev/null || true
  rm -f -- "$config_home/systemd/user/vibeshine-steamos.service" "$HOME/.local/bin/vibeshine-steamos-session"
  rm -rf -- "$data_home/vibeshine-steamos"
  systemctl --user daemon-reload || true
  systemctl --user reset-failed vibeshine-steamos.service 2>/dev/null || true
else
  echo "Vibeshine does not appear to be installed for $(id -un)."
fi

if [[ "$remove_build" == yes ]]; then
  if command -v distrobox >/dev/null; then
    distrobox rm --force "$CONTAINER_NAME" >/dev/null 2>&1 || true
  fi
  case "$WORK_DIR" in
    /*/vibeshine-steamos-build) rm -rf -- "$WORK_DIR" ;;
    *) echo "Not deleting unexpected work directory: $WORK_DIR" >&2 ;;
  esac
  echo "Removed the build container and cached build tree."
fi

if [[ "$purge" == yes ]]; then
  rm -rf -- "$config_home/vibeshine"
  echo "Deleted Vibeshine settings and pairings."
fi

echo "Done."
