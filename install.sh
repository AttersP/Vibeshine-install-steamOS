#!/usr/bin/env bash
# shellcheck disable=SC1091
# Install (or update) Vibeshine on SteamOS without touching the read-only OS.
#
# Vibeshine (https://github.com/Nonary/vibeshine) ships an experimental
# "SteamOS user bundle" but no prebuilt download for it. This script:
#   1. checks the Deck is ready (SteamOS, desktop user, distrobox, disk, devices),
#   2. builds the relocatable bundle inside a disposable Arch Linux distrobox,
#      linking against SteamOS's own libm so the result loads on the host,
#   3. hands the bundle to Vibeshine's own install-user.sh, which installs it
#      under ~/.local/share and enables a systemd *user* service that runs in
#      both Desktop Mode and Gaming Mode.
#
# Usage (as the "deck" user, in Desktop Mode Konsole; never with sudo):
#   curl -fsSLO https://raw.githubusercontent.com/AttersP/Vibeshine-install-steamOS/main/install.sh
#   bash install.sh
#
# SPDX-License-Identifier: GPL-3.0-only

set -euo pipefail

VIBESHINE_REPO=${VIBESHINE_REPO:-https://github.com/Nonary/vibeshine.git}
VIBESHINE_REF=${VIBESHINE_REF:-vibe}
CONTAINER_NAME=${VIBESHINE_CONTAINER:-vibeshine-build}
CONTAINER_IMAGE=${VIBESHINE_CONTAINER_IMAGE:-docker.io/library/archlinux:latest}
WORK_DIR=${VIBESHINE_WORK_DIR:-"${XDG_CACHE_HOME:-$HOME/.cache}/vibeshine-steamos-build"}
MIN_FREE_GB=12

# Submodules that only matter for Windows, Flatpak or docs. libwebrtc and
# depot_tools alone are several gigabytes, so never fetch them on a Deck.
SKIP_SUBMODULES=(
  third-party/libwebrtc
  third-party/depot_tools
  third-party/nvapi
  third-party/nvapi-open-source-sdk
  third-party/ViGEmClient
  third-party/doxyconfig
  packaging/linux/flatpak/deps/flatpak-builder-tools
  packaging/linux/flatpak/deps/shared-modules
)

# Arch packages needed to configure and build the SteamOS profile.
BUILD_PACKAGES=(
  base-devel git cmake ninja pkgconf python python-jinja nodejs npm
  shaderc glslang vulkan-headers vulkan-icd-loader
  wayland wayland-protocols libdrm libva libcap libevdev libpipewire libpulse
  libx11 libxcb libxfixes libxrandr libxtst
  openssl curl sqlite miniupnpc opus numactl avahi libnotify libmfx glib2
)

usage() {
  cat <<EOF
Usage: bash install.sh [options]

Builds Vibeshine for SteamOS in a distrobox container and installs it for the
current user. Re-run it at any time to update; settings and pairings are kept.

Options:
  --ref REF          Vibeshine branch, tag or commit to build (default: $VIBESHINE_REF)
  --payload PATH     Skip the build and install an existing payload directory
                     or Vibeshine-SteamOS-*.tar.gz bundle
  --jobs N           Parallel compile jobs (default: based on CPU and RAM)
  --clean            Delete the cached source/build tree before building
  --build-only       Build the payload but do not install it
  --no-start         Install and enable the service but do not (re)start it
  --remove-container Delete the build container afterwards (saves ~3 GB;
                     the next update has to recreate it)
  --skip-checks      Skip the device/session readiness checks
  -h, --help         Show this help

Environment overrides: VIBESHINE_REPO, VIBESHINE_REF, VIBESHINE_CONTAINER,
VIBESHINE_CONTAINER_IMAGE, VIBESHINE_WORK_DIR.
EOF
}

if [[ -t 1 ]]; then
  c_bold=$'\e[1m' c_red=$'\e[31m' c_yel=$'\e[33m' c_grn=$'\e[32m' c_off=$'\e[0m'
else
  c_bold='' c_red='' c_yel='' c_grn='' c_off=''
fi
log()  { printf '%s==>%s %s\n' "$c_bold" "$c_off" "$*"; }
ok()   { printf '%s  ok%s %s\n' "$c_grn" "$c_off" "$*"; }
warn() { printf '%swarn%s %s\n' "$c_yel" "$c_off" "$*" >&2; }
die()  { printf '%serror%s %s\n' "$c_red" "$c_off" "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Runs inside the Arch container. It is serialized with `declare -f` so this
# script also works when piped from curl. Arguments: work dir, repo, ref,
# jobs, clean (yes/no), followed by the submodule paths to skip.
# ---------------------------------------------------------------------------
container_build() {
  set -euo pipefail
  local work=$1 repo=$2 ref=$3 jobs=$4 clean=$5
  shift 5
  local -a skip=("$@")
  local src="$work/vibeshine" build="$work/build" payload="$work/payload"
  local -a pkgs=(@BUILD_PACKAGES@)

  retry() {
    local attempt
    for attempt in 1 2 3 4; do
      "$@" && return 0
      echo "warn: attempt $attempt failed: $*" >&2
      sleep $((attempt * 5))
    done
    "$@"
  }

  echo "==> Installing build dependencies in the container"
  sudo pacman -Syu --needed --noconfirm "${pkgs[@]}"

  [[ -d /run/host/usr/lib ]] || { echo "error: host filesystem is not mounted at /run/host" >&2; exit 1; }
  [[ -e /run/host/usr/lib/libm.so.6 ]] || { echo "error: SteamOS libm.so.6 not found under /run/host" >&2; exit 1; }

  if [[ "$clean" == yes ]]; then
    rm -rf -- "$src" "$build"
  fi
  rm -rf -- "$payload"

  if [[ ! -d "$src/.git" ]]; then
    echo "==> Cloning $repo"
    git clone --filter=blob:none -- "$repo" "$src"
  fi
  cd "$src"
  git remote set-url origin "$repo"
  echo "==> Checking out $ref"
  git fetch --tags --force origin
  if git rev-parse --verify --quiet "refs/remotes/origin/$ref" >/dev/null; then
    git checkout --force -B "$ref" "origin/$ref"
  else
    git checkout --force --detach "$ref"
  fi
  git clean -ffdx

  echo "==> Fetching submodules (Windows/Flatpak-only modules skipped)"
  local -a skip_cfg=()
  local path name
  for path in "${skip[@]}"; do
    name=$(git config -f .gitmodules --get-regexp '^submodule\..*\.path$' |
      awk -v p="$path" '$2 == p { sub(/^submodule\./, "", $1); sub(/\.path$/, "", $1); print $1 }')
    [[ -n "$name" ]] && skip_cfg+=(-c "submodule.$name.update=none")
  done
  git "${skip_cfg[@]}" submodule sync
  # --force re-checks out submodules whose earlier fetch was interrupted
  # (git otherwise skips them when HEAD already matches, leaving them empty).
  retry git "${skip_cfg[@]}" submodule update --init --force --jobs 4
  # Recurse into nested submodules, except build-deps: its nested FFmpeg,
  # x265 etc. are multi-GB source trees, while the build only needs the
  # build-deps tag to download prebuilt FFmpeg.
  local sub
  while read -r sub; do
    [[ "$sub" == third-party/build-deps ]] && continue
    [[ -f "$sub/.gitmodules" ]] || continue
    retry git -C "$sub" submodule update --init --recursive --force --jobs 4
  done < <(git submodule status | awk '$1 !~ /^-/ { print $2 }')
  while read -r sub; do
    if [[ -z "$(git -C "$sub" ls-files | head -n1)" ]] || ! git -C "$sub" diff --quiet; then
      echo "error: submodule $sub is incomplete; re-run with --clean" >&2
      exit 1
    fi
  done < <(git submodule status | awk '$1 !~ /^-/ { print $2 }')

  echo "==> Configuring the SteamOS bundle"
  # SteamOS's glibc is older than Arch's. Link libm/libmvec from the host (as
  # upstream's SteamOS audit does) so the executable resolves on the Deck.
  local host_link="-Wl,-rpath-link,/run/host/usr/lib -Wl,-rpath-link,/run/host/usr/lib/pulseaudio -Wl,--push-state,--no-as-needed /run/host/usr/lib/libm.so.6"
  [[ -e /run/host/usr/lib/libmvec.so.1 ]] && host_link+=" /run/host/usr/lib/libmvec.so.1"
  host_link+=" -Wl,--pop-state"

  cmake -S "$src" -B "$build" -G Ninja -Wno-dev \
    -D CMAKE_BUILD_TYPE=Release \
    -D CMAKE_INSTALL_PREFIX="$payload" \
    -D CMAKE_EXE_LINKER_FLAGS="$host_link" \
    -D CMAKE_DISABLE_FIND_PACKAGE_Boost=ON \
    -D SUNSHINE_BUILD_STEAMOS=ON \
    -D BUILD_DOCS=OFF \
    -D BUILD_TESTS=OFF \
    -D SUNSHINE_ENABLE_TRAY=OFF \
    -D SUNSHINE_SYSTEM_VULKAN_HEADERS=ON \
    -D SUNSHINE_ENABLE_CUDA=OFF \
    -D SUNSHINE_ENABLE_DRM=OFF \
    -D SUNSHINE_PUBLISHER_NAME='Nonary' \
    -D SUNSHINE_PUBLISHER_WEBSITE='https://github.com/Nonary/vibeshine' \
    -D SUNSHINE_PUBLISHER_ISSUE_URL='https://github.com/Nonary/vibeshine/issues'

  echo "==> Building with $jobs jobs (this takes a while on a Deck)"
  cmake --build "$build" --parallel "$jobs"
  cmake --install "$build"
  echo "==> Payload staged at $payload"
}

# ---------------------------------------------------------------------------
# Host side
# ---------------------------------------------------------------------------
payload_arg=
jobs=
clean=no
build_only=no
no_start=no
remove_container=no
skip_checks=no
while (($#)); do
  case "$1" in
    --ref) (($# >= 2)) || die "--ref needs a value"; VIBESHINE_REF=$2; shift 2 ;;
    --payload) (($# >= 2)) || die "--payload needs a path"; payload_arg=$2; shift 2 ;;
    --jobs) (($# >= 2)) || die "--jobs needs a number"; jobs=$2; shift 2 ;;
    --clean) clean=yes; shift ;;
    --build-only) build_only=yes; shift ;;
    --no-start) no_start=yes; shift ;;
    --remove-container) remove_container=yes; shift ;;
    --skip-checks) skip_checks=yes; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done
[[ -z "$jobs" || "$jobs" =~ ^[1-9][0-9]*$ ]] || die "--jobs must be a positive integer"
[[ -z "$payload_arg" || "$build_only" == no ]] || die "--payload and --build-only cannot be combined"

preflight() {
  log "Checking this machine"
  [[ $(id -u) -ne 0 ]] || die "run this as your desktop user (deck), not with sudo"
  ok "running as ${USER:-$(id -un)}"

  local os_id=
  if [[ -r /etc/os-release ]]; then
    os_id=$(. /etc/os-release && printf '%s' "${ID:-}")
  fi
  if [[ "$os_id" == steamos ]]; then
    ok "SteamOS $(. /etc/os-release && printf '%s' "${VERSION_ID:-} ${BUILD_ID:-}")"
  else
    warn "this is not SteamOS (ID=${os_id:-unknown}); the SteamOS bundle targets Gamescope systems"
  fi
  [[ $(uname -m) == x86_64 ]] || die "only x86_64 is supported"

  local cmd
  for cmd in systemctl flock ldd tar; do
    command -v "$cmd" >/dev/null || die "missing required command: $cmd"
  done
  systemctl --user show-environment >/dev/null 2>&1 ||
    die "the systemd user manager is not reachable; run this from Konsole in Desktop Mode"
  ok "systemd user session available"

  if [[ -z "$payload_arg" ]]; then
    command -v distrobox >/dev/null ||
      die "distrobox is missing; it ships with SteamOS 3.5+. Update SteamOS and try again"
    command -v podman >/dev/null || command -v docker >/dev/null ||
      die "neither podman nor docker is available for distrobox"
    ok "distrobox $(distrobox version 2>/dev/null | awk '{print $NF}' | head -n1)"

    mkdir -p -- "$WORK_DIR"
    local free_kb
    free_kb=$(df -Pk -- "$WORK_DIR" | awk 'NR == 2 { print $4 }')
    if ((free_kb < MIN_FREE_GB * 1024 * 1024)); then
      die "need about ${MIN_FREE_GB} GB free in $WORK_DIR for the build (have $((free_kb / 1024 / 1024)) GB)"
    fi
    ok "$((free_kb / 1024 / 1024)) GB free for the build"
  fi

  if [[ "$skip_checks" == no ]]; then
    if [[ -S "${XDG_RUNTIME_DIR:-/nonexistent}/pipewire-0" ]]; then ok "PipeWire socket present"
    else warn "PipeWire socket not found; audio/video capture needs a running graphical session"; fi
    if [[ -w /dev/uinput ]]; then ok "/dev/uinput writable (keyboard, mouse, Xbox pad)"
    else warn "/dev/uinput is not writable; remote input will not work"; fi
    local dev render=no
    for dev in /dev/dri/renderD*; do [[ -r "$dev" && -w "$dev" ]] && render=yes; done
    if [[ "$render" == yes ]]; then ok "GPU render node accessible (VAAPI encoding)"
    else warn "no accessible /dev/dri/renderD* node; hardware encoding will fail"; fi
  fi

  if pgrep -x sunshine >/dev/null 2>&1; then
    warn "Sunshine is running. It uses the same ports as Vibeshine; stop or uninstall it"
    warn "(e.g. 'systemctl --user disable --now sunshine' or remove the Flatpak/Decky plugin)."
  fi
}

default_jobs() {
  local cpus mem_gb by_mem
  cpus=$(nproc 2>/dev/null || echo 2)
  mem_gb=$(awk '/^MemAvailable:/ { print int($2 / 1024 / 1024) }' /proc/meminfo 2>/dev/null || echo 4)
  # Heavy C++23 translation units need roughly 2 GB each.
  by_mem=$((mem_gb / 2))
  ((by_mem >= 1)) || by_mem=1
  ((cpus < by_mem)) && by_mem=$cpus
  printf '%s\n' "$by_mem"
}

container_exists() {
  distrobox list --no-color 2>/dev/null | awk -F'|' '{ gsub(/ /, "", $2); print $2 }' | grep -qx -- "$CONTAINER_NAME"
}

build_payload() {
  [[ -n "$jobs" ]] || jobs=$(default_jobs)

  if container_exists; then
    ok "reusing distrobox container $CONTAINER_NAME"
  else
    log "Creating build container $CONTAINER_NAME ($CONTAINER_IMAGE)"
    distrobox create --yes --no-entry --name "$CONTAINER_NAME" --image "$CONTAINER_IMAGE"
  fi

  local script="$WORK_DIR/container-build.sh"
  {
    printf '#!/usr/bin/env bash\n'
    declare -f container_build | sed "s|@BUILD_PACKAGES@|${BUILD_PACKAGES[*]}|"
    printf 'container_build "$@"\n'
  } > "$script"
  chmod 700 -- "$script"

  log "Building Vibeshine ($VIBESHINE_REF) inside the container"
  distrobox enter --name "$CONTAINER_NAME" -- bash "$script" \
    "$WORK_DIR" "$VIBESHINE_REPO" "$VIBESHINE_REF" "$jobs" "$clean" "${SKIP_SUBMODULES[@]}"

  payload_dir="$WORK_DIR/payload"
}

unpack_payload() {
  if [[ -d "$payload_arg" ]]; then
    payload_dir=$(CDPATH='' cd -- "$payload_arg" && pwd -P)
    return
  fi
  [[ -f "$payload_arg" ]] || die "--payload must be a directory or a .tar.gz bundle"
  local dest="$WORK_DIR/unpacked"
  rm -rf -- "$dest"
  mkdir -p -- "$dest"
  log "Unpacking $payload_arg"
  tar -xzf "$payload_arg" -C "$dest"
  # CPack wraps the payload in one top-level directory.
  local found
  found=$(find "$dest" -maxdepth 3 -type f -path '*/bin/vibeshine' -print -quit)
  [[ -n "$found" ]] || die "no bin/vibeshine found inside $payload_arg"
  payload_dir=$(dirname -- "$(dirname -- "$found")")
}

verify_payload() {
  log "Verifying the bundle against this SteamOS install"
  [[ -x "$payload_dir/bin/vibeshine" ]] || die "payload has no bin/vibeshine"
  local missing
  missing=$(ldd -r "$payload_dir/bin/vibeshine" 2>&1 | grep -E 'not found|undefined symbol|version .* not found' || true)
  if [[ -n "$missing" ]]; then
    printf '%s\n' "$missing" | head -n 20 >&2
    die "the built binary does not match this SteamOS userspace (see above). Try --clean, or report it upstream"
  fi
  ok "all libraries and symbols resolve"
}

install_payload() {
  local installer="$payload_dir/share/vibeshine/steamos/install-user.sh"
  [[ -x "$installer" ]] || die "payload is missing share/vibeshine/steamos/install-user.sh"
  local -a args=(--payload "$payload_dir")
  [[ "$no_start" == yes ]] && args+=(--no-start)
  log "Installing with Vibeshine's install-user.sh"
  "$installer" "${args[@]}"
}

finish() {
  local ip
  ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{ for (i = 1; i < NF; i++) if ($i == "src") { print $(i + 1); exit } }') || ip=
  echo
  log "${c_grn}Vibeshine is installed.${c_off}"
  if [[ "$no_start" == no ]] && systemctl --user is-active --quiet vibeshine-steamos.service; then
    ok "vibeshine-steamos.service is running"
  else
    warn "the service is not running yet; check: journalctl --user -u vibeshine-steamos.service -b"
  fi
  cat <<EOF

Next steps
  1. Open https://localhost:47990 on the Deck${ip:+ (or https://$ip:47990 from another device)},
     accept the self-signed certificate and create your Vibeshine login.
  2. In Moonlight, add this Deck${ip:+ ($ip)} and enter the PIN in the web UI.
  3. Keep capture/output on "Automatic" and use an Xbox controller type; HDR
     needs a patched Gamescope, so leave client HDR off.

Useful commands
  systemctl --user status vibeshine-steamos.service
  journalctl --user -u vibeshine-steamos.service -b
  bash install.sh            # update to the latest $VIBESHINE_REF
  bash uninstall.sh          # remove (keeps settings and pairings)
EOF
}

main() {
  preflight
  payload_dir=
  if [[ -n "$payload_arg" ]]; then
    unpack_payload
  else
    build_payload
    if [[ "$remove_container" == yes ]]; then
      log "Removing build container $CONTAINER_NAME"
      distrobox rm --force "$CONTAINER_NAME" >/dev/null 2>&1 || warn "could not remove container $CONTAINER_NAME"
    fi
  fi
  verify_payload
  if [[ "$build_only" == yes ]]; then
    log "Payload ready at $payload_dir"
    exit 0
  fi
  install_payload
  finish
}

main
