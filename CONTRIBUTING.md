# Contributing

Repository overview, host inventory, VM usage, and bootstrap steps live in `README.md`.

## Scope

This repository is check-driven. There is no standalone unit-test suite, so changes should be validated with formatting, linting, and relevant builds.

## Local Workflow

Enter a dev shell:
```bash
nix develop
```

Alternative shell (non-flake, includes `home-manager`):
```bash
nix-shell
```

Run formatting and linting:
```bash
nix fmt
```

Run evaluation checks without builds:
```bash
nix flake check --option allow-import-from-derivation false --no-build
```

Run full checks:
```bash
nix flake check --option allow-import-from-derivation false
```

Validate target hosts when relevant:
```bash
nixos-rebuild build --flake .#<host>
home-manager switch --flake .#hrosten
```
Use the affected host, for example `x1`, `t480`, `t14s`, `nocturn`, or `generic`.

## Style

- Nix files: `nixfmt`
- Bash files: `shfmt -i 2` and `shellcheck`
- Nix linting: `statix` and `deadnix`
- Spelling: `typos`

Module and file naming should use kebab-case (for example `shell-common.nix`).

## Commit Messages

- Keep messages short and imperative (`Add vscode`, `Refactor home modules`)
- Keep each commit focused on one change/theme
- Include a `Signed-off-by:` trailer

## Pull Requests

PR descriptions should include:
- What changed and which hosts/modules were affected
- Validation commands run locally
- Related issues/links when applicable
