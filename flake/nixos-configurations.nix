{ inputs, specialArgs }:
{
  generic = inputs.nixpkgs.lib.nixosSystem {
    inherit specialArgs;
    modules = [ ../hosts/generic/configuration.nix ];
  };

  x1 = inputs.nixpkgs.lib.nixosSystem {
    inherit specialArgs;
    modules = [ ../hosts/x1/configuration.nix ];
  };

  t480 = inputs.nixpkgs.lib.nixosSystem {
    inherit specialArgs;
    modules = [ ../hosts/t480/configuration.nix ];
  };

  t14s = inputs.nixpkgs.lib.nixosSystem {
    inherit specialArgs;
    modules = [ ../hosts/t14s/configuration.nix ];
  };

  nocturn = inputs.nixpkgs.lib.nixosSystem {
    inherit specialArgs;
    modules = [ ../hosts/nocturn/configuration.nix ];
  };
}
