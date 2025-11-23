{
  pkgs ? import <nixpkgs> { },
}:
{
  sneemok = pkgs.callPackage ./nix/sneemok.nix { };
}
