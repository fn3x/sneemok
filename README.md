# sneemok

Wayland screenshot annotation tool in Zig.

The main repository is on [codeberg](https://codeberg.org/fn3x/sneemok), which is where the issue tracker may be found and where contributions are accepted.

Read-only mirrors exist on [github](https://github.com/fn3x/sneemok).

## Build

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
