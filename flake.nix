{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];
    in
      {
      packages = forAllSystems (system: {
        default = nixpkgs.legacyPackages.${system}.callPackage ./nix/package.nix { };
      });

      apps = forAllSystems (system: {
        default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/sneemok";
        };
      });

      devShells = forAllSystems (system: 
        let pkgs = nixpkgs.legacyPackages.${system};
        in {
          default = pkgs.mkShell {
            packages = with pkgs; [ zig ];
            buildInputs = with pkgs; [
              wayland-scanner
              wayland-protocols
              wayland
              pkg-config
              dbus
              wlroots
              wlr-protocols
              cairo
            ];
          };
        });

      nixosModules.default = { config, lib, pkgs, ... }:
        let
          cfg = config.services.sneemok;
          sneemokPkg = self.packages.${pkgs.system}.default;
        in
          {
          imports = [ ./nix/nixos-module.nix ];

          config = lib.mkIf cfg.enable {
            services.sneemok.package = lib.mkDefault sneemokPkg;
          };
        };

      homeManagerModules.default = { config, lib, pkgs, ... }:
        let
          cfg = config.services.sneemok;
          sneemokPkg = self.packages.${pkgs.system}.default;
        in
          {
          imports = [ ./nix/hm-module.nix ];

          config = lib.mkIf cfg.enable {
            services.sneemok.package = lib.mkDefault sneemokPkg;
          };
        };
    };
}
