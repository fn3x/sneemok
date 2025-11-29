{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in
      {
      packages.${system}.default = pkgs.callPackage ./nix/package.nix { };

      apps.${system}.default = {
        type = "app";
        program = "${self.packages.${system}.default}/bin/sneemok";
      };

      devShells.${system}.default = pkgs.mkShell {
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

      nixosModules.default = { config, lib, pkgs, ... }:
        with lib;
        let
          cfg = config.programs.sneemok;
        in
          {
          options.programs.sneemok = {
            enable = mkEnableOption "sneemok screenshot tool";
            package = mkOption {
              type = types.package;
              default = self.packages.${system}.default;
              description = "The sneemok package to use";
            };
          };

          config = mkIf cfg.enable {
            environment.systemPackages = [ cfg.package ];
          };
        };

      homeManagerModules.default = { config, lib, pkgs, ... }:
        with lib;
        let
          cfg = config.programs.sneemok;
        in
          {
          options.programs.sneemok = {
            enable = mkEnableOption "sneemok screenshot tool";
            package = mkOption {
              type = types.package;
              default = self.packages.${system}.default;
              description = "The sneemok package to use";
            };
          };

          config = mkIf cfg.enable {
            home.packages = [ cfg.package ];
          };
        };
    };
}
