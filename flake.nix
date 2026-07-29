{
  description = "DevShell for My Homelab Scripts";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/master";
    flake-utils.url = "github:numtide/flake-utils";
  };
  outputs = {
    nixpkgs,
    flake-utils,
    ...
  }:
    flake-utils.lib.eachSystem flake-utils.lib.allSystems (system: let
      pkgs = import nixpkgs {
        inherit system;

        config.allowUnfree = true;
      };
    in {
      devShells.default = pkgs.mkShell {
        name = "homelab-scripts";
        packages = with pkgs; [
          wget
          xorriso
          rsync
          cdrtools
        ];
      };
    });
}
