{ config, lib, ... }:

with lib;

let
  cfg = config.services.sneemok;
in
{
  options.services.sneemok = {
    enable = mkEnableOption "sneemok screenshot daemon";

    package = mkOption {
      type = types.package;
      defaultText = literalExpression "pkgs.sneemok";
      description = "The sneemok package to use";
    };
  };

  config = mkIf cfg.enable {
    home.packages = [ cfg.package ];

    systemd.user.services.sneemok = {
      Unit = {
        Description = "Sneemok Screenshot Annotation Tool";
        Documentation = "https://codeberg.com/fn3x/sneemok";
        PartOf = [ "graphical-session.target" ];
        After = [ "graphical-session.target" ];
        # Requires compositor and D-Bus
        Requisite = [ "graphical-session.target" ];
      };

      Service = {
        Type = "simple";
        ExecStart = "${cfg.package}/bin/sneemok --daemon";
        Restart = "on-failure";
        RestartSec = 5;
        
        # Environment = [
        #   "PATH=${pkgs.wl-clipboard}/bin"  # For wl-copy fallback
        # ];

        # Security hardening
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = "read-only";
        NoNewPrivileges = true;
        
        # Allow access to Wayland and D-Bus
        RestrictAddressFamilies = [ "AF_UNIX" ];
      };

      Install = {
        WantedBy = [ "graphical-session.target" ];
      };
    };
  };
}
