# sneemok

Wayland screenshot annotation tool in Zig.

The main repository is on [codeberg](https://codeberg.org/fn3x/sneemok), which is where the issue tracker may be found and where contributions are accepted.

Read-only mirrors exist on [github](https://github.com/fn3x/sneemok).

## Installation

### NixOS (system-wide)

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    sneemok.url = "github:fn3x/sneemok";
  };

  outputs = { nixpkgs, sneemok, ... }: {
    nixosConfigurations.yourhostname = nixpkgs.lib.nixosSystem {
      modules = [
        sneemok.nixosModules.default
        {
          programs.sneemok.enable = true;
        }
      ];
    };
  };
}
```

### Home Manager

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager.url = "github:nix-community/home-manager";
    sneemok.url = "github:fn3x/sneemok";
  };

  outputs = { nixpkgs, home-manager, sneemok, ... }: {
    homeConfigurations.youruser = home-manager.lib.homeManagerConfiguration {
      modules = [
        sneemok.homeManagerModules.default
        {
          programs.sneemok.enable = true;
        }
      ];
    };
  };
}
```

### Direct install (no module)

```nix
{
  inputs.sneemok.url = "github:fn3x/sneemok";
  # Or local: sneemok.url = "path:/path/to/sneemok";

  outputs = { sneemok, ... }: {
    # NixOS
    environment.systemPackages = [ sneemok.packages.x86_64-linux.default ];
    
    # Or Home Manager
    home.packages = [ sneemok.packages.x86_64-linux.default ];
  };
}
```

### Build from source

```bash
# Clone repo
git clone https://github.com/fn3x/sneemok
cd sneemok

# Build
nix build

# Run
./result/bin/sneemok
```

## Build

**With Nix:**
```bash
nix build
```

**Without Nix:**
```bash
zig build
```

**Dependencies:**
- wl-roots compositor
- cairo (usually included in most Linux distributions)
- wl-clipboard (optional but recommended)

## Usage

```bash
./sneemok
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
├── main.zig        # Events
├── state.zig       # State
├── output.zig      # Rendering
├── canvas/         # Image + elements
└── tools/          # Selection + drawing tools
```

**Rendering:** Screenshot → Overlay → Selection → Elements → Tool UI

**Format:** BGRA internally, RGBA PNG export

**Clipboard:** wl-copy (persistent) or native Wayland (clears on exit)

## License

MIT
