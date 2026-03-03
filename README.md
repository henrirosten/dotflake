# Dotflake

Nix flake repository for:
- NixOS host configurations
- Standalone Home Manager profile (`hrosten`) for non-NixOS systems

## Managed Hosts

| Host | Purpose |
|------|---------|
| `x1` | ThinkPad X1 Carbon |
| `t480` | ThinkPad T480 |
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
nixos-rebuild build --flake .#x1
nixos-rebuild build --flake .#t480
nixos-rebuild build --flake .#nocturn
```

Apply (local):
```bash
sudo nixos-rebuild switch --flake .#x1
sudo nixos-rebuild switch --flake .#t480
```

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
nix run .#x1-vm
nix run .#t480-vm
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

Share a host directory with any VM app (mounted writable at `/mnt/host-share` in the guest):
```bash
nix run .#generic-vm -- --share-dir /path/to/host/dir
```
When `--share-dir` is provided, the VM autologin shell starts in `/mnt/host-share`.

Environment overrides:
- `NIX_DISK_IMAGE` (default: `./<vm-name>.qcow2`)
- `VM_HOST_SHARE_DIR` (same effect as `--share-dir`)
- `CODEX_HOST_AUTH_FILE` (default: `$HOME/.codex/auth.json`)

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

## CI Workflows

- `.github/workflows/check.yml`: formatting, lint, flake eval checks, and host build matrix
- `.github/workflows/bootstrap-nix.yml`: bootstrap script lint + Ubuntu integration checks
- `.github/workflows/flake-update.yml`: scheduled/manual `flake.lock` update with VM smoke check
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
