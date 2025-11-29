{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.sneemok;
in
{
  options.services.sneemok = {
    enable = mkEnableOption "sneemok screenshot daemon";

    package = mkOption {
      type = types.package;
      description = "The sneemok package to use";
    };
  };

  config = mkIf cfg.enable {
    # Install package system-wide
    environment.systemPackages = [ cfg.package pkgs.wl-clipboard ];

    # Create systemd user service (will be available to all users)
    systemd.user.services.sneemok = {
      description = "Sneemok Screenshot Annotation Tool";
      documentation = [ "https://codeberg.com/fn3x/sneemok" ];
      partOf = [ "graphical-session.target" ];
      after = [ "graphical-session.target" ];
      requisite = [ "graphical-session.target" ];

      serviceConfig = {
        Type = "simple";
        ExecStart = "${cfg.package}/bin/sneemok --daemon";
        Restart = "on-failure";
        RestartSec = 5;
        
        # Environment = "PATH=${pkgs.wl-clipboard}/bin";

        # Security hardening
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = "read-only";
        NoNewPrivileges = true;
        RestrictAddressFamilies = "AF_UNIX";
      };

      wantedBy = [ "graphical-session.target" ];
    };
  };
}
