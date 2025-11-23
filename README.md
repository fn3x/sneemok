# sneemok

Wayland screenshot annotation tool in Zig.

## Build

```bash
zig build
```

**Dependencies:**
- Wayland
- Cairo
- wl-clipboard (optional)

## Usage

```bash
./sneemok
```

### Keys

- `S` - Selection tool
- `A` - Arrow
- `R` - Rectangle  
- `C` - Circle
- `L` - Line
- `Ctrl+C` - Copy to clipboard
- `Enter` - Print coordinates
- `ESC` - Exit
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
