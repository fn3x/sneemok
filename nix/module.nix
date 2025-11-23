{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.programs.sneemok;
in
{
  options.programs.sneemok = {
    enable = mkEnableOption "sneemok screenshot tool";

    package = mkOption {
      type = types.package;
      default = pkgs.sneemok;
      defaultText = literalExpression "pkgs.sneemok";
      description = "The sneemok package to use";
    };
  };

  config = mkIf cfg.enable {
    environment.systemPackages = with pkgs; [
      cfg.package
      wl-clipboard # For persistent clipboard
    ];
  };
}
