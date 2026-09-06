# Dotflake

Nix flake repository for:
- NixOS host configurations
- Standalone Home Manager profile (`hrosten`) for non-NixOS systems

## Managed Hosts

| Host | Purpose |
|------|---------|
| `x1` | ThinkPad X1 Carbon |
| `t480` | ThinkPad T480 |
| `t14s` | ThinkPad T14s |
| `nocturn` | Headless server (Ryzen 9 5950X, 64 GB RAM) |
| `generic` | VM-focused profile used for local and CI testing |

## Quick Start

```bash
git clone https://github.com/henrirosten/dotflake.git
cd dotflake
```

Inspect available outputs:
```bash
nix flake show --all-systems
```

## Developer Workflow

Enter a flake dev shell (pre-commit tools):
```bash
nix develop
```

Alternative shell (includes `home-manager` from `shell.nix`):
```bash
nix-shell
```

Format and lint:
```bash
nix fmt
```

Run flake checks without builds:
```bash
nix flake check --option allow-import-from-derivation false --no-build
```

Run full checks:
```bash
nix flake check --option allow-import-from-derivation false
```

## NixOS Usage

Build:
```bash
nixos-rebuild build --flake .#<host>
```
Available hosts: `x1`, `t480`, `t14s`, `nocturn`, `generic`

Apply (local):
```bash
sudo nixos-rebuild switch --flake .#<host>
```
Typical local hosts: `x1`, `t480`, `t14s`

Show the deployed dotflake revision on a host:
```bash
nixos-version --configuration-revision
```
This reports the git revision (or dirty revision) of the flake the system was built from.

## Remote Deployment

`scripts/deploy.sh` deploys to remote hosts by resolving their IP via MAC address lookup (ARP cache, falling back to nmap subnet scan).

```bash
./scripts/deploy.sh nocturn              # deploy (switch)
./scripts/deploy.sh nocturn dry-activate # dry run
./scripts/deploy.sh --list               # show host IPs
./scripts/deploy.sh --help               # full usage
```

## VM Apps

Run a host in QEMU:
```bash
nix run .#<host>-vm
```
Examples:
```bash
nix run .#x1-vm
nix run .#t14s-vm
nix run .#generic-vm
```

Show runner options:
```bash
nix run .#x1-vm -- --help
```

Default behavior: VM disk images are deleted on exit; add `--keep-disk` to persist them.

Example custom resources:
```bash
nix run .#x1-vm -- --ram-mb 2048 --cpus 2 --disk-size 16G --disk-image ./x1.qcow2 --keep-disk
```

Share one or more host directories with any VM app:
```bash
nix run .#generic-vm -- --share-dir /path/to/host/dir
nix run .#generic-vm -- --share-dir ~/.config --share-dir ~/src/dotflake
```
With one shared directory, it is mounted at `/mnt/host-share`. With multiple shared directories, they are mounted under `/mnt/host-share/<name>`. The autologin shell still starts in the user's home directory and prints the mounted share paths.
Shared paths must not contain `:`, commas, or whitespace.

Environment overrides:
- `NIX_DISK_IMAGE` (default: `./<vm-name>.qcow2`)
- `VM_HOST_SHARE_DIR` (same effect as `--share-dir`)
- `VM_HOST_SHARE_DIRS` (same effect as repeating `--share-dir`, colon-separated; shared paths must not contain `:`)
- `CODEX_HOST_AUTH_FILE` (default: `$HOME/.codex/auth.json`)
- `CLAUDE_HOST_AUTH_FILE` (default: `$HOME/.claude/.credentials.json`)

### Run Graphical Apps On `generic-vm` Over SSH

All VM apps forward guest SSH to host `127.0.0.1:2222`.

1. Start the VM and keep its disk:
```bash
nix run .#generic-vm -- --keep-disk
```

2. From another terminal, connect with X11 forwarding:
```bash
ssh -Y -p 2222 hrosten@127.0.0.1
```

3. Launch a GUI app from the SSH session:
```bash
firefox &
# or
gedit &
```

Notes:
- Use `-Y` (trusted X11 forwarding) for better compatibility with desktop apps.
- Your host must have a running X server for forwarded windows to appear.

## Standalone Home Manager (Ubuntu and similar)

Install Nix (automatic mode):
```bash
./bootstrap-nix.sh
```

`bootstrap-nix.sh` also supports explicit modes:
```bash
./bootstrap-nix.sh auto
./bootstrap-nix.sh multi
./bootstrap-nix.sh single
```

Apply profile:
```bash
nix-shell
home-manager switch --flake .#hrosten
```

## VPN

The `vpn` launcher expects:
- a local SOPS file at `~/.config/dotflake/secrets/vpn.yaml`
- an age key at `~/.config/sops/age/keys.txt`
- the Home Manager profile to be applied with `home-manager switch --flake .#hrosten`

Usage:
```bash
vpn list
vpn <profile>
```

To modify the local VPN secrets, edit `~/.config/dotflake/secrets/vpn.yaml` with `sops`, then reapply `home-manager switch --flake .#hrosten`. On NixOS systems where Home Manager is applied through the system configuration, `nixos-rebuild switch --flake .#<host>` also picks up the change.

To use `vpn` inside a VM:
```bash
nix run .#generic-vm -- --share-dir ~/.config
```

That shares `~/.config/dotflake/secrets/vpn.yaml` and the age key with the guest. After boot, run `vpn list` or `vpn <profile>` inside the VM.

## CI Workflows

- `.github/workflows/check.yml`: formatting, lint, flake eval checks, and host build matrix
- `.github/workflows/bootstrap-nix.yml`: bootstrap script lint + Ubuntu integration checks
- `.github/dependabot.yml`: weekly grouped GitHub Actions `uses:` update PRs and grouped Nix flake input update PRs checked every day at 01:00 UTC (04:00 EEST / 03:00 EET)
- `.github/workflows/flakevuln.yml`: upstream-only scheduled/manual vulnerability scan for `nixosConfigurations.x1.config.system.build.toplevel` using `.github/flakevuln/manual_analysis.csv`
- `.github/workflows/flake-update.yml`: VM smoke check for flake update PRs
- `.github/workflows/zizmor.yml`: GitHub Actions workflow security linting

## Repository Layout

```text
flake.nix                    # Flake entrypoint
flake/                       # Split flake output builders
hosts/                       # Per-host NixOS configs
modules/nixos/               # Reusable NixOS modules
modules/home/                # Reusable Home Manager modules
users/                       # User-specific module data and HM composition
scripts/run-vm.sh            # VM runner template used by flake VM apps
scripts/deploy.sh            # Remote deployment via MAC-based host discovery
bootstrap-nix.sh             # Nix bootstrap helper script
```

## Contribution Notes

See `CONTRIBUTING.md` for validation commands, style conventions, and commit/PR expectations.
