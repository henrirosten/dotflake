# Agent Notes

Use the shared docs as the source of truth:
- `README.md` for repository overview, host inventory, commands, and VM usage
- `CONTRIBUTING.md` for validation, style, commit, and PR expectations

Agent-specific guidance:
- Prefer `nix fmt` and `nix flake check --option allow-import-from-derivation false --no-build` to validate changes.
- Keep durable workflow details in the shared docs above rather than duplicating them here.
