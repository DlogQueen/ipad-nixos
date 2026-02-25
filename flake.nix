{
  description = "iPad NixOS - Linux on iPad via checkm8/pongoOS";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    devenv = {
      url = "github:cachix/devenv";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, devenv, ... }@inputs:
    let
      buildSystem = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${buildSystem};

      # Cross-compilation: build on x86_64, target aarch64 (iPad ARM64)
      pkgsCross = import nixpkgs {
        localSystem.system = buildSystem;
        crossSystem.system = "aarch64-linux";
      };
    in
    {
      # Dev shell (x86_64 tools for RE, flashing, serial, etc.)
      devShells.${buildSystem}.default = devenv.lib.mkShell {
        inherit inputs pkgs;
        modules = [ ./devenv.nix ];
      };

      # Cross-compiled packages for iPad (aarch64, 16KB pages)
      packages.${buildSystem} = {
        kernel = pkgsCross.callPackage ./kernel {};
      };
    };
}
