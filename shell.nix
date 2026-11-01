{
  pkgs ?
    # If pkgs is not defined, instantiate nixpkgs from locked commit
    let
      lockFile = builtins.fromJSON (builtins.readFile ./flake.lock);
      lock = lockFile.nodes.${lockFile.nodes.root.inputs.nixpkgs}.locked;
      nixpkgs = fetchTarball {
        url = "https://github.com/nixos/nixpkgs/archive/${lock.rev}.tar.gz";
        sha256 = lock.narHash;
      };
    in
    import nixpkgs { overlays = [ ]; },
  ...
}:
{
  default = pkgs.mkShell {
    NIX_CONFIG = ''
      extra-experimental-features = nix-command flakes
    ''
    + builtins.readFile ./flake/agent-cache.conf;
    nativeBuildInputs = with pkgs; [
      age
      git
      home-manager
      nix
      nixos-rebuild
      shellcheck
      sops
    ];
  };
}
