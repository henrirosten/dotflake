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

All hosts use `pkgs.linuxPackages_latest` from the locked nixpkgs input. Updating
that input advances the kernel along with the other system packages.

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

### GPU Hang Diagnostics

Graphical hosts save i915 hang diagnostics in unique UTC-stamped directories
under `/var/log/gpu-hang/`. Read captures with sudo; they contain GPU memory
and journal data.

To take a manual capture before rebooting:

```bash
sudo gpu-hang-capture --once
```

The command prints the capture directory and exits nonzero if the capture is
incomplete. Inspect the saved files before relying on them. The sysfs dump
does not survive a reboot; saved captures do. After recovery,
`gnome-freeze-debug -1` shows the previous boot's journal.

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
VM apps share the Nix store over host-enforced read-only 9p. There are no default exchange folders; use `--share-dir` to share host directories.

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

Shares are read-only, enforced by QEMU on the host and mounted `ro` in the guest.

Environment overrides:
- `NIX_DISK_IMAGE` (default: `./<vm-name>.qcow2`)

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

## Agent VMs

Run coding agents in a VM that never gets write access to a host checkout.
Work comes back as Git commits that you review and merge by commit ID.
The first launch clones the branch you start from into `/work` in the guest.
The host checkout is not shared. The guest can read the host's Nix store and the
launcher's transfer directories; the only host directory it can write to is its
export directory.
Each later launch sends the branch again, and the guest fetches it into
`host/<branch>` at boot without changing its own branches.
The instance keeps its home directory and `/work` across restarts.
Named instances let several agents work on the same project side by side.

`dotflake-agent` comes with the Home Manager profile. The x1 host configuration
installs the `dotflake-vm` launcher; elsewhere, run it from a dotflake checkout:

```bash
# Defaults, and the options that change them:
#   project:     the Git repository you start in (--project PATH), default: CWD
#   instance:    default (--instance NAME)
#   resources:   8192 MiB RAM, 2 vCPUs (--ram-mb MB, --cpus N)
#   credentials: none (--auth PROVIDER[=FILE], repeatable)
nix run .#dotflake-vm
```

The launcher is not in Home Manager because it depends on a VM that itself
uses the Home Manager profile; including it there would create a dependency cycle.

With the installed launcher, start from the target repository and commit host
edits first. For example:

```bash
# Host: start the instance and run Codex in the guest checkout.
dotflake-vm --auth codex --exec codex
# Guest: after editing or committing in /work, export branches and uncommitted work.
agent-export
# Host: import, review, then merge the exact commit ID printed by review.
dotflake-agent import
dotflake-agent review
git merge <commit-id-from-review>
# Host: send newer commits to a running instance (each launch does this).
dotflake-agent push
# Guest: fetch them, then merge or rebase host/<branch> yourself.
agent-update
```

Existing credentials are kept unless you add `--auth-replace`.
The guest prompt shows `vm` followed by the providers that currently have
credentials in the guest, for example `vm codex copilot`.
`--exec` runs once after console login. `/work` survives shutdown, but changes
reach the host only through `agent-export`, so export before powering off:
`--exec 'codex; agent-export; sudo poweroff'`. Shut down with `sudo poweroff`:
QEMU's Ctrl-A x skips the guest shutdown, like pulling the plug, and can lose
the last few seconds of guest writes.

The host terminal size and `TERM` are applied before it starts, but later host terminal resizes do not reach the guest.
Copilot supports wheel scrolling without an extra mouse flag; if mouse support was disabled in its saved settings, use `--mouse=on` to enable it again. Hold Shift while dragging to select text with the host terminal. `--no-mouse` disables Copilot's own wheel scrolling. Copilot's own copy uses OSC 52 escape sequences, which some terminals, such as GNOME Terminal (VTE), ignore; use the host terminal's Ctrl+Shift+C / Ctrl+Shift+V instead.

Without `=FILE`, Codex uses `${CODEX_HOME:-$HOME/.codex}/auth.json`, Claude uses
`${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json`, and Copilot uses
`COPILOT_GITHUB_TOKEN`, then the `copilot-cli` keyring entry. Missing defaults
print a note and continue. Use a file to select another account (`~/` expands to
`$HOME`); the last occurrence of a provider wins:

```bash
dotflake-vm --instance personal --auth codex=~/.codex-personal/auth.json
```

The launcher's `--auth` option does not import Antigravity CLI credentials.

Copilot files contain a token, exported as `COPILOT_GITHUB_TOKEN` in the guest.
Use a fine-grained PAT with only **Copilot Requests** permission. Store it with
`nix shell nixpkgs#libsecret -c secret-tool store --label='Copilot CLI' service copilot-cli`.
Broader tokens require explicit opt-in, such as `--auth copilot=<(gh auth token)`.

The bootstrap token lives under `/run` in the guest. Codex and Claude credentials
selected with `--auth` persist on the data disk until deleted inside the guest
or with `discard`; omitting `--auth` does not revoke them. Manage instances with:

```bash
dotflake-agent list
dotflake-agent discard --refs
```

`discard` requires the instance to be stopped and asks you to type its name;
`--refs` also removes its imported tracking refs. State lives under
`${XDG_STATE_HOME:-$HOME/.local/state}/dotflake/agents/`.
The guest reaches only the internet. Its traffic leaves through pasta and passt
in a host network namespace that blocks host, LAN, VPN/Tailscale, loopback,
link-local and multicast addresses, apart from DNS to the host's resolvers.
Host addresses and directly connected networks are read at launch.
No ports are forwarded, and root in the guest cannot change this. Merged flakes, `.envrc`, hooks and CI can run code on the host, which is why
`review` highlights them.

### Local Model Agent VM

`dotflake-local-vm` runs the Pi coding agent with a Qwen3.5-4B model inside the
VM, so prompts and code are not sent to a model provider. It uses the same
export, import, and review workflow as `dotflake-vm`. By default it uses
instance `local`, 8192 MiB RAM, and 4 vCPUs. It requires KVM. The model runs on
the CPU with an 8192-token context, so it suits small, well-scoped tasks; a
small edit can take a few minutes.

Run these commands from the dotflake checkout:

```bash
# Once, while online: fetch the VM and the model (about 3.14 GB).
nix build .#dotflake-local-vm
# Start the agent; --offline also stops Nix from downloading.
nix run --offline .#dotflake-local-vm
```

To work on another repository, append `-- --project /path/to/project` to `nix run`.

By default the guest has no network device, so even guest root cannot reach the
network, and builds and tests in the guest can use only what the VM includes.
`--network online` gives the same filtered internet access as `dotflake-vm`;
the model still runs locally. `dotflake-vm` also accepts `--network offline`.

`local-agent` provides default VM guidance through Pi's agent-directory
`APPEND_SYSTEM.md`: passwordless `sudo` is available for the task, the project
is in `/work`, and network availability is inferred from the guest's default
routes at startup. When a non-loopback interface exists, the launcher waits up
to five seconds for a route. If none appears, the prompt says networking may
still be starting. Offline guests without a network interface skip this wait.
The generated default is refreshed on each launch. Existing user prompt files
are preserved; a trusted project's `.pi/APPEND_SYSTEM.md` takes precedence over
the agent-directory file, following Pi's normal behavior.

The console starts Pi. Exit it for a shell (press Ctrl-C twice), then run
`local-agent` to restart it or `local-agent --print 'Explain this project'` for a
single request; `--exec bash` starts a shell instead. Run `agent-export` in the
guest, then name the instance from the project repository on the host:

```bash
dotflake-agent import --instance local
dotflake-agent review --instance local
```

The launcher rejects `--auth` and cannot use `dotflake-vm` instances, so it does
not copy agent credentials into the guest. The current branch is still sent to
the guest with its history, including any committed secrets. Pi sessions persist in
`~/.local/share/dotflake/local-agent` in the guest. If Pi cannot reach the
model, check `journalctl -u local-model`.

### Local Model Agent VM on Nocturn

`dotflake-local-vm-nocturn` runs the same local agent with Qwen3.6-35B-A3B
(UD-Q4_K_M): a 32,768-token context, 8,192 output tokens, eight inference
threads and a 32 GiB model-service cap. Its defaults suit nocturn: instance
`local-nocturn`, 40,960 MiB RAM, 8 vCPUs and no network device. Leave at least
8 GiB of host memory outside the guest. Pi is ready about a minute after
launch, and the model generates roughly 8 to 14 output tokens per second.
Model settings for both launchers are in `flake/local-model-profiles.nix`.

The agent works on a Git repository checked out on nocturn; bring it up to date
there before starting. Connect to nocturn with SSH and start `tmux`, which the
nocturn configuration installs: the guest console is the terminal, and a dropped
connection would otherwise stop the VM without a guest shutdown. Then, from a
dotflake checkout on nocturn:

```bash
# Once, while online: fetch the VM and the model (about 22.1 GB).
nix build .#dotflake-local-vm-nocturn
# Start the agent on the project.
nix run --offline .#dotflake-local-vm-nocturn -- --project /path/to/project
```

Work with Pi in the guest, then run `agent-export` and `sudo poweroff`. The
model server listens only on the guest's loopback interface and no ports are
forwarded, so it is not reachable from the LAN. Pi settings persist per
instance, so this launcher uses its own instance; name it when importing and
reviewing on nocturn, then fetch the result from your workstation:

```bash
# Nocturn, in /path/to/project:
dotflake-agent import --instance local-nocturn
dotflake-agent review --instance local-nocturn
git merge <commit-id-from-review>
# Workstation, in your clone of the project:
git fetch ssh://nocturn/path/to/project <branch>
git merge --ff-only FETCH_HEAD
```

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

## Coding Agent CLIs

`modules/home/llm-agents.nix` installs Antigravity CLI, Codex, Claude Code, and
GitHub Copilot CLI from [`numtide/llm-agents.nix`](https://github.com/numtide/llm-agents.nix).
Dependabot bumps it with the other flake inputs; to update only the agents, run
`nix flake update llm-agents`.

Prebuilt agents come from the Numtide cache in `flake/agent-cache.conf`. If a
NixOS host doesn't have the cache configured yet, load it for the first switch
so Codex isn't compiled from source (`nix-shell` already does this for
standalone Home Manager):

```bash
export NIX_CONFIG="$(cat flake/agent-cache.conf)"
sudo --preserve-env=NIX_CONFIG nixos-rebuild switch --flake .#<host>
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
