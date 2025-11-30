# sneemok

Wayland screenshot annotation tool in Zig.

The main repository is on [codeberg](https://codeberg.org/fn3x/sneemok), which is where the issue tracker may be found and where contributions are accepted.

Read-only mirrors exist on [github](https://github.com/fn3x/sneemok).


## Dependencies
- [wayland](https://wayland.freedesktop.org/) (compositor)
- [wlroots](https://gitlab.freedesktop.org/wlroots/wlroots) (compositor)
- [cairo](https://www.cairographics.org/) (drawing)
- [D-Bus](https://gitlab.freedesktop.org/dbus/dbus) (communication with portal and sneemok daemon)
- XDG Desktop Portal (for screenshot capture)

## Installation

### Convenient script:

```bash
wget https://codeberg.org/fn3x/sneemok/raw/branch/main/scripts/install.sh
chmod +x install.sh
./install.sh
```

### Arch:

```bash
yay -S sneemok
# or
yay -S sneemok-git
```

### Nix
#### Option 1: Home Manager (Recommended for single user)

In your Home Manager configuration:

```nix
{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    home-manager.url = "github:nix-community/home-manager";
    sneemok.url = "git+https://codeberg.org/fn3x/sneemok.git";
  };

  outputs = { nixpkgs, home-manager, sneemok, ... }: {
    homeConfigurations.youruser = home-manager.lib.homeManagerConfiguration {
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
      modules = [
        sneemok.homeManagerModules.default
        {
          services.sneemok = {
            enable = true;
          };
        }
      ];
    };
  };
}
```

Then rebuild:
```bash
home-manager switch --flake .#youruser
```

#### Option 2: NixOS (System-wide)

In your NixOS configuration:

```nix
{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    sneemok.url = "git+https://codeberg.org/fn3x/sneemok.git";
  };

  outputs = { nixpkgs, sneemok, ... }: {
    nixosConfigurations.yourhostname = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        sneemok.nixosModules.default
        {
          services.sneemok = {
            enable = true;
          };
        }
      ];
    };
  };
}
```

Then rebuild:
```bash
sudo nixos-rebuild switch --flake .#yourhostname
```

## Managing the Service

### Start/Stop/Status

```bash
systemctl --user start sneemok
systemctl --user stop sneemok
systemctl --user status sneemok
systemctl --user restart sneemok
```

View logs:
```bash
journalctl --user -u sneemok -f
```

### Taking Screenshots

Once the service is running:

```bash
# Trigger a screenshot
sneemok --screenshot

# Or just
sneemok
```

### Keybindings

Add to your compositor config (e.g., Hyprland):

```
bind = $mainMod, P, exec, sneemok
bind = $mainMod SHIFT, P, exec, sneemok --screenshot
```

Or in sway/i3:

```
bindsym $mod+p exec sneemok
bindsym $mod+Shift+p exec sneemok --screenshot
```

## Troubleshooting

**Service won't start:**
```bash
# Check logs
journalctl --user -u sneemok -n 50

# Check if D-Bus session bus is available
echo $DBUS_SESSION_BUS_ADDRESS

# Check if compositor is running
echo $WAYLAND_DISPLAY
```

**Screenshots not triggering:**
```bash
# Test D-Bus connection manually
dbus-send --session --print-reply \
  --dest=org.sneemok.Service \
  /org/sneemok/service \
  org.sneemok.Service.Screenshot
```

**Service keeps restarting:**
```bash
# Check what's failing
systemctl --user status sneemok
journalctl --user -u sneemok -f
```

Common issues:
- XDG Desktop Portal not available → Install xdg-desktop-portal-hyprland or equivalent
- Compositor not running → Service requires graphical session
- D-Bus session bus not available → Check session setup

## Disabling the Service

Manually:
```bash
systemctl --user disable --now sneemok
```

Home Manager:
```nix
services.sneemok.enable = false;
```

NixOS:
```nix
services.sneemok.enable = false;
```

### Build from source

**With Nix:**
```bash
nix build
```

**Without Nix:**
```bash
zig build
```

### Keys

- `s` - Selection tool
- `a` - Arrow
- `r` - Rectangle  
- `c` - Circle
- `l` - Line
- `Ctrl+C` - Copy to clipboard
- `ESC` - Change current tool to selection or exit
- `Mouse wheel up` - Increase thickness of the current tool
- `Mouse wheel down` - Decrease thickness of the current tool

### Mouse

- Drag to create selection/draw
- Resize handles on selection
- Click inside to move

## Architecture

```
src/
├── main.zig        # Events, signals and threading of the D-Bus handler
├── state.zig       # Application state
├── wayland.zig     # Wayland-related objects
├── dbus.zig        # Dbus struct with connection initialization, requesting and parsing screenshot from portal
├── output.zig      # Rendering
├── canvas/         # Image + elements
└── tools/          # Selection + drawing tools
```

**Rendering:** Screenshot → Overlay → Selection → Elements → Tool UI

**Format:** BGRA internally, RGBA PNG export

**Clipboard:** Native Wayland

## License

MIT
