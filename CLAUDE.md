# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This is a Nix flake-based configuration repository for:
- NixOS hosts (`x1`, `t480`, `nocturn`, and a VM-focused `generic` profile)
- Standalone home-manager configuration (`.#hrosten`) for non-NixOS systems

## Commands

**Enter development shell** (flake):
```bash
nix develop
```

**Enter alternative shell** (includes `home-manager` from `shell.nix`):
```bash
nix-shell
```

**Format and lint all files**:
```bash
nix fmt
```

**Run flake checks**:
```bash
nix flake check --option allow-import-from-derivation false
```

**Run flake checks without builds**:
```bash
nix flake check --option allow-import-from-derivation false --no-build
```

**Build NixOS configuration**:
```bash
nixos-rebuild build --flake .#x1
nixos-rebuild build --flake .#t480
nixos-rebuild build --flake .#nocturn
```

**Apply NixOS configuration** (local):
```bash
sudo nixos-rebuild switch --flake .#x1
sudo nixos-rebuild switch --flake .#t480
```

**Deploy to remote host** (resolves IP via MAC/ARP):
```bash
./scripts/deploy.sh nocturn
./scripts/deploy.sh nocturn dry-activate
./scripts/deploy.sh --list
```

**Apply standalone home-manager configuration** (for non-NixOS like Ubuntu):
```bash
home-manager switch --flake .#hrosten
```

**Run VM apps**:
```bash
nix run .#x1-vm
nix run .#t480-vm
nix run .#generic-vm
```

## Architecture

- `flake.nix` - Main entry point; delegates output construction to `flake/` helpers
- `flake/` - Split flake output builders (`apps-vm.nix`, `nixos-configurations.nix`, `home-configurations.nix`, `checks.nix`, `pre-commit-check.nix`, `formatter.nix`, `dev-shells.nix`)
- `hosts/` - Per-machine configurations (`x1`, `t480`, `nocturn`, `generic`), each with `configuration.nix` and `hardware-configuration.nix`
- `users/` - User-specific NixOS modules defining user accounts (name, username, email, ssh keys, shell, groups)
- `users/hrosten/home.nix` - User profile composition for hrosten home-manager setup
- `modules/nixos/` - Reusable NixOS modules (`common-nix`, `gui`, `host-common`, `laptop`, `ssh`, `remotebuild`, `gnome-freeze-watchdog`)
- `modules/home/` - Reusable home-manager modules (`bash`, `zsh`, `git`, `vim`, `starship`, `ssh-conf`, `gui-extras`, `vscode`, `shell-common`, `codex-cli`)
- `scripts/run-vm.sh` - VM runner template used by flake VM apps
- `scripts/deploy.sh` - Remote deployment script using MAC-based host discovery
- `bootstrap-nix.sh` - Nix installer helper for non-NixOS systems

NixOS modules are exported via `outputs.nixosModules`. Home-manager modules are exported via `outputs.homeModules`.

## Style

- Nix files: `nixfmt` formatting
- Bash files: `shfmt` (2-space indent) and `shellcheck`
- File/module naming: kebab-case (e.g., `shell-common.nix`, `host-common.nix`)

## Linting/Formatting

The flake uses git-hooks-nix for pre-commit checks including:
- `nixfmt` - Nix formatter
- `deadnix` - Removes dead Nix code
- `statix` - Nix linter (runs with `fix` argument)
- `shellcheck` - Bash linter
- `shfmt` - Bash formatter (2-space indent)
- `typos` - Spell checker
- `gitlint` - Commit message linter
- `actionlint` - GitHub Actions workflow linter
- `check-yaml` - YAML syntax validator
- `check-merge-conflicts` - Prevents committing unresolved merge markers
- `detect-private-keys` - Prevents committing private keys
- `end-of-file-fixer` - Ensures files end with a newline
- `trim-trailing-whitespace` - Removes trailing whitespace
- `mixed-line-endings` - Normalizes line endings

## GPU hang diagnostics (x1)

When investigating display freezes or i915 issues on `x1`:
- Automatic captures live under `/var/log/gpu-hang/<UTC-timestamp>/`, produced
  by `modules/nixos/gpu-hang-capture.nix`. Each capture contains the raw
  `/sys/class/drm/card*/error` dump (which is wiped on reboot if not captured
  in time) plus the kernel journal for that boot. These persist across
  reboots. Access model matches journald: dirs `0750` and files `0640`, owned
  `root:systemd-journal` — readable by members of the `systemd-journal` group,
  sudo otherwise.
- `gnome-freeze-debug [BOOT]` collects GNOME/kernel/suspend signals on demand
  (from `modules/nixos/gnome-freeze-watchdog.nix`). BOOT defaults to `-1`.
- `modules/nixos/gnome-freeze-watchdog.nix` also watches for GPU wedges and
  surfaces a post-login notification after a reboot, with a pointer to the
  captured logs.
- Known i915 kernel params and the escalation path (e.g. `i915.enable_guc=0`)
  are documented inline in `hosts/x1/configuration.nix`.

## Commit Conventions

- Short imperative subject (e.g., "Add vscode", "Refactor home modules")
- One change/theme per commit
- Include a `Signed-off-by:` trailer (use `git commit --signoff`)
