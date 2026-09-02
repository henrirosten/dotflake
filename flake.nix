{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    git-hooks-nix = {
      url = "github:cachix/git-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nixos-hardware = {
      url = "github:nixos/nixos-hardware";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nix-index-database = {
      url = "github:Mic92/nix-index-database";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    codex-cli-nix = {
      url = "github:sadjow/codex-cli-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    sbomnix = {
      url = "github:tiiuae/sbomnix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    nix-claude-code = {
      url = "github:ryoppippi/nix-claude-code";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{ self, ... }:
    let
      inherit (self) outputs;

      stateVersion = "23.11";
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      defaultSystem = "x86_64-linux";
      forAllSystems = inputs.nixpkgs.lib.genAttrs systems;
      mkPkgs = system: inputs.nixpkgs.legacyPackages.${system};

      moduleOutputs = {
        nixosModules = import ./modules/nixos;
        homeModules = import ./modules/home;
      };

      specialArgs = {
        inherit
          inputs
          outputs
          stateVersion
          ;
      };

      mkPreCommitCheck = import ./flake/pre-commit-check.nix {
        inherit
          inputs
          self
          ;
      };

      nixosConfigurations = import ./flake/nixos-configurations.nix {
        inherit
          inputs
          specialArgs
          ;
      };

      # Standalone home-manager configuration entrypoint
      # Available through 'home-manager switch --flake .#hrosten'
      # Cross-system entries are also exported as:
      # - hrosten-x86_64-linux
      # - hrosten-aarch64-linux
      homeConfigurations = import ./flake/home-configurations.nix {
        inherit
          inputs
          systems
          defaultSystem
          mkPkgs
          specialArgs
          ;
      };

      apps = import ./flake/apps-vm.nix {
        inherit
          inputs
          forAllSystems
          mkPkgs
          nixosConfigurations
          ;
      };

      checks = import ./flake/checks.nix {
        inherit
          inputs
          forAllSystems
          mkPkgs
          mkPreCommitCheck
          defaultSystem
          stateVersion
          ;
        moduleOutputs = moduleOutputs;
      };

      formatter = import ./flake/formatter.nix {
        inherit
          forAllSystems
          mkPkgs
          checks
          ;
      };

      devShells = import ./flake/dev-shells.nix {
        inherit
          forAllSystems
          mkPkgs
          checks
          ;
      };
    in
    {
      inherit (moduleOutputs)
        nixosModules
        homeModules
        ;

      inherit
        homeConfigurations
        nixosConfigurations
        apps
        formatter
        checks
        devShells
        ;
    };
}
