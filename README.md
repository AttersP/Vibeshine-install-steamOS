# Vibeshine installer for SteamOS

One-command install of [Vibeshine](https://github.com/Nonary/vibeshine) (Nonary's
fork of the Sunshine game-streaming host) on a Steam Deck or other SteamOS device.

> **Experimental.** Vibeshine's SteamOS support is an upstream *beta* profile, and
> upstream does not publish a prebuilt SteamOS download. This script builds one
> on your Deck and installs it with Vibeshine's own installer. See upstream's
> [SteamOS README](https://github.com/Nonary/vibeshine/blob/vibe/packaging/linux/steamos/README.md)
> and [audit](https://github.com/Nonary/vibeshine/blob/vibe/packaging/linux/steamos/AUDIT.md)
> for what is and isn't validated yet.

## What it does

1. Checks that you're on SteamOS as the desktop user, that `distrobox` is available
   (it comes with SteamOS 3.5+), that you have ~12 GB free, and that PipeWire,
   `/dev/uinput` and the GPU render node are accessible.
2. Creates an Arch Linux `distrobox` container called `vibeshine-build` and compiles
   Vibeshine's relocatable **SteamOS user bundle** in it. The build links against
   SteamOS's own `libm` (the same approach upstream uses) so the binary loads on the
   Deck.
3. Checks the bundle with `ldd -r` on the real OS, then runs upstream's
   `install-user.sh`. That installs Vibeshine under `~/.local/share/vibeshine-steamos`
   and enables the `vibeshine-steamos.service` **user** service in both Desktop Mode
   and Gaming Mode.

It never uses `sudo`, never disables the read-only filesystem and installs no
kernel modules, so SteamOS updates won't wipe it.

## Install

In **Desktop Mode**, open Konsole and run (as `deck`, **not** with sudo):

```bash
curl -fsSLO https://raw.githubusercontent.com/AttersP/Vibeshine-install-steamOS/main/install.sh
bash install.sh
```

The first run downloads the container and dependencies, then compiles. On a Deck
this takes roughly 30–90 minutes. Keep it plugged in.

When it finishes:

1. Open <https://localhost:47990>, accept the self-signed certificate and create
   your login.
2. In Moonlight, add the Deck (the script prints its IP address) and enter the
   pairing PIN in the web UI.

Vibeshine uses TCP 47984, 47989, 47990 and 48010, and UDP 47998–48000 and 48010.
Stop Sunshine first if you have it installed, because it uses the same ports.

## Update

Run `bash install.sh` again. It reuses the container and cached build, installs
the new release atomically and keeps your settings and pairings. If the new
release fails to start, upstream's installer rolls back to the previous one.

## Options

| Option | What it does |
| --- | --- |
| `--ref REF` | Build another Vibeshine branch, tag or commit (default `vibe`) |
| `--payload PATH` | Skip the build and install an existing payload directory or `Vibeshine-SteamOS-*.tar.gz` |
| `--jobs N` | Number of parallel compile jobs (by default this is worked out from CPU count and free RAM) |
| `--clean` | Delete the cached source and build tree first |
| `--build-only` | Build the payload without installing it |
| `--no-start` | Install and enable the service, but don't restart it (an active stream keeps running) |
| `--remove-container` | Delete the build container afterwards (saves about 3 GB, but the next update is slower) |
| `--skip-checks` | Skip the PipeWire, uinput and GPU readiness checks |

You can also set these environment variables: `VIBESHINE_REPO`, `VIBESHINE_REF`,
`VIBESHINE_CONTAINER`, `VIBESHINE_CONTAINER_IMAGE` and `VIBESHINE_WORK_DIR` (default
`~/.cache/vibeshine-steamos-build`).

## Uninstall

```bash
bash uninstall.sh                 # removes Vibeshine but keeps settings and pairings
bash uninstall.sh --remove-build  # also deletes the build container and cache
bash uninstall.sh --purge         # also deletes settings and pairings
```

## Known limitations (upstream)

- Gaming Mode captures Gamescope's existing output, so you can't create separate
  virtual monitors. Leave capture and output on **Automatic**.
- Stock Gamescope supports SDR only, so turn off HDR in the client. HDR needs
  upstream's patched Gamescope and a fixed Mesa.
- Use the **Xbox** controller type. DualSense emulation needs `/dev/uhid`, which
  stock SteamOS doesn't give to the user.
- Steam games launch through the Steam client that is already running. Vibeshine's
  frame limiter and Smooth Motion don't apply to them.

## Troubleshooting

```bash
systemctl --user status vibeshine-steamos.service
journalctl --user -u vibeshine-steamos.service -b
```

- **"does not match this SteamOS userspace"**: the Arch container's libraries
  moved ahead of SteamOS. Try `bash install.sh --clean`. If that still fails,
  report it to upstream with the `ldd` output.
- **Out of memory while compiling**: use fewer jobs, for example `--jobs 2`.
- **`systemd user manager is not reachable`**: run the script from Konsole in
  Desktop Mode, not through `sudo` or `su`.

## License

GPL-3.0-only, the same license as Vibeshine.
