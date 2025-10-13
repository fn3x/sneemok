{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
    in
    {
      devShells.x86_64-linux.default = pkgs.mkShell {
        packages = with pkgs; [
          zig
        ];

        buildInputs = with pkgs; [
          stb
          wayland-scanner
          wayland-protocols
          wayland
          pkg-config
          dbus
          libxkbcommon
          pixman
          wlroots
          wlr-protocols
        ];
      };
    };
}
