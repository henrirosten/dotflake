{
  forAllSystems,
  mkPkgs,
  checks,
}:
forAllSystems (
  system:
  let
    pkgs = mkPkgs system;
  in
  {
    default = pkgs.mkShell {
      inherit (checks.${system}.pre-commit-check) shellHook;
      buildInputs =
        checks.${system}.pre-commit-check.enabledPackages
        ++ (with pkgs; [
          age
          sops
        ]);
    };
  }
)
