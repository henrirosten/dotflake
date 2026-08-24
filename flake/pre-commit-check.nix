{ inputs, self }:
system:
inputs.git-hooks-nix.lib.${system}.run {
  src = self.outPath;
  # default_stages = ["pre-commit" "pre-push"];
  hooks = {
    # lint commit messages
    gitlint.enable = true;
    # lint GitHub Actions workflows
    actionlint.enable = true;
    # validate YAML syntax
    check-yaml.enable = true;
    # prevent committing private keys
    detect-private-keys.enable = true;
    # prevent committing unresolved merge markers
    check-merge-conflicts.enable = true;
    # fix end-of-files
    end-of-file-fixer.enable = true;
    # remove trailing whitespace
    trim-trailing-whitespace.enable = true;
    # normalize line endings
    mixed-line-endings.enable = true;
    # spell check
    typos = {
      enable = true;
      settings.configPath = ".typos.toml";
    };
    # nix formatter
    nixfmt.enable = true;
    # removes dead nix code
    deadnix.enable = true;
    # prevents use of nix anti-patterns
    statix = {
      enable = true;
      args = [
        "fix"
      ];
    };
    # bash linter
    shellcheck.enable = true;
    # bash formatter
    shfmt = {
      enable = true;
      args = [
        "--indent"
        "2"
      ];
    };
  };
}
