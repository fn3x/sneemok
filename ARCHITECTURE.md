# Complete Architecture Explanation (made by AI)

## Overview

The screenshot tool uses a **layered rendering architecture** with a **tool-based interaction system**.

## The Rendering Pipeline

When you see the screen, it's the result of multiple rendering passes that happen in a specific order:

```
┌─────────────────────────────────────────────────────┐
│ 1. Screenshot Image (base layer)                   │
├─────────────────────────────────────────────────────┤
│ 2. Black Overlay (50% opacity)                     │
├─────────────────────────────────────────────────────┤
│ 3. Undarkened Selection Region (screenshot again)  │
├─────────────────────────────────────────────────────┤
│ 4. Canvas Elements (arrows, rectangles, etc.)      │
├─────────────────────────────────────────────────────┤
│ 5. Tool Overlays (borders, handles, previews)      │
└─────────────────────────────────────────────────────┘
                    ↓
            What you see on screen
```

## File Structure & Responsibilities

```
src/
├── main.zig              # Event loop & input handling
├── state.zig             # Application state & tool management
├── output.zig            # Rendering pipeline (layers 1-4)
├── canvas/
│   ├── canvas.zig        # Canvas state (selection, elements)
│   └── element.zig       # Canvas elements (arrows, etc.)
└── tools/
    ├── tool.zig          # Tool interface
    ├── selection.zig     # Selection tool (layer 5 for selection)
    ├── arrow.zig         # Arrow tool
    └── ...
```

---

## Detailed Breakdown

### 1. main.zig - Event Loop & Input

**Role:** Receives Wayland events and delegates to appropriate handlers

**Key Functions:**

```zig
fn pointerListener() {
    // Receives pointer events from Wayland
    switch (event) {
        .motion => {
            // Update pointer position
            state.pointer_x = x;
            state.pointer_y = y;
            
            // Delegate to current tool
            state.current_tool.onPointerMove(&state.canvas, x, y);
            
            // Trigger redraw ONLY if actively doing something
            if (tool is actively drawing/selecting) {
                state.setAllOutputsDirty();
            }
        },
        .button => {
            // Delegate button press/release to tool
            state.current_tool.onPointerPress/Release(...);
        }
    }
}
```

**Important:** `main.zig` does NOT do rendering. It only:
1. Receives input events
2. Updates state
3. Delegates to tools
4. Triggers redraws when needed

---

### 2. state.zig - Global State

**Role:** Holds all application state and manages tool switching

```zig
pub const AppState = struct {
    // Wayland connections
    display: *wl.Display,
    compositor: *wl.Compositor,
    outputs: ArrayList(*Output),
    
    // Canvas (holds image, selection, drawn elements)
    canvas: Canvas,
    
    // Current tool (union of all tool types)
    current_tool: Tool,
    tool_mode: ToolMode,  // .selection, .draw_arrow, etc.
    
    // Input tracking
    pointer_x: i32,
    pointer_y: i32,
    
    pub fn setTool(mode: ToolMode) {
        // Switches tools, creates new tool instance
        self.current_tool = switch (mode) {
            .selection => Tool{ .selection = SelectionTool.init() },
            .draw_arrow => Tool{ .arrow = ArrowTool.init() },
            // ...
        };
    }
};
```

**Key Point:** State is just data storage. No rendering logic here.

---

### 3. canvas/canvas.zig - Canvas State

**Role:** Stores what's on the canvas (image, selection, elements)

```zig
pub const Canvas = struct {
    // The screenshot image
    image: ?[*c]u8,
    width: i32,
    height: i32,
    
    // Current selection (if any)
    selection: ?Selection,
    
    // Drawn elements (arrows, shapes, etc.)
    elements: ArrayList(Element),
};

pub const Selection = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    
    // Current interaction (moving, resizing, etc.)
    interaction: InteractionMode,
    
    // Drag offset for moving
    drag_offset_x: i32,
    drag_offset_y: i32,
};
```

**Key Point:** Canvas doesn't know HOW to draw itself. It just stores data.

---

### 4. output.zig - THE RENDERING ENGINE

**Role:** This is where the magic happens. Takes all the state and renders it to screen.

**THE COMPLETE RENDERING PIPELINE:**

```zig
pub fn renderOutput(self: *Output) void {
    const state = self.state;  // Get app state
    const cr = cairo_context;  // Cairo drawing context
    
    // ═══════════════════════════════════════════════════
    // LAYER 1: Draw Screenshot Image (base)
    // ═══════════════════════════════════════════════════
    if (state.canvas.image) |image| {
        const img_surface = cairo_image_surface_create_for_data(image, ...);
        
        // CRITICAL: Use SOURCE operator to REPLACE everything
        c.cairo_set_operator(cr, c.CAIRO_OPERATOR_SOURCE);
        c.cairo_set_source_surface(cr, img_surface, ...);
        c.cairo_paint(cr);  // Paints the whole image
    }
    // Result: Screenshot fills the screen
    
    // ═══════════════════════════════════════════════════
    // LAYER 2: Draw Black Overlay (darkening)
    // ═══════════════════════════════════════════════════
    c.cairo_set_operator(cr, c.CAIRO_OPERATOR_OVER);  // Composite on top
    c.cairo_set_source_rgba(cr, 0.0, 0.0, 0.0, 0.50);  // 50% black
    c.cairo_paint(cr);  // Paints over entire screen
    // Result: Semi-transparent black over everything
    
    // ═══════════════════════════════════════════════════
    // LAYER 3: Undarkened Selection Region
    // ═══════════════════════════════════════════════════
    // This is WHERE output.zig and tools.zig OVERLAP
    
    if (state.current_tool == .selection) {
        const sel_tool = &state.current_tool.selection;
        
        // Draw TEMPORARY selection (while dragging)
        if (sel_tool.is_selecting) {
            // Calculate selection rectangle
            const sel_x = min(anchor, current);
            const sel_y = ...;
            const sel_w = abs(current - anchor) + 1;
            
            // Draw the UNDARKENED region
            if (state.canvas.image) |image| {
                const img_surface = ...;
                
                c.cairo_save(cr);
                c.cairo_set_operator(cr, c.CAIRO_OPERATOR_SOURCE);  // REPLACE
                c.cairo_set_source_surface(cr, img_surface, ...);
                c.cairo_rectangle(cr, local_x, local_y, sel_w, sel_h);
                c.cairo_fill(cr);  // Fills ONLY the rectangle
                c.cairo_restore(cr);
                
                // Draw white border (THIS GETS OVERWRITTEN BY TOOL!)
                c.cairo_set_source_rgba(cr, 1.0, 1.0, 1.0, 0.5);
                c.cairo_rectangle(...);
                c.cairo_stroke(cr);
            }
        }
    }
    
    // Draw FINALIZED selection (after release)
    if (state.canvas.selection) |sel| {
        // Same as above but using canvas.selection data
        // Draws undarkened region + green border (OVERWRITTEN BY TOOL!)
    }
    // Result: Selected area is bright, rest is dark
    
    // ═══════════════════════════════════════════════════
    // LAYER 4: Canvas Elements (persistent drawings)
    // ═══════════════════════════════════════════════════
    for (state.canvas.elements.items) |*element| {
        element.render(cr, offset_x, offset_y);
    }
    // Result: Arrows, rectangles, etc. drawn on top
    
    // ═══════════════════════════════════════════════════
    // LAYER 5: Tool Overlays (THIS IS IMPORTANT!)
    // ═══════════════════════════════════════════════════
    state.current_tool.render(cr, &state.canvas, offset_x, offset_y);
    // This calls the tool's render() function
    // For SelectionTool, this draws:
    //   - Selection borders (OVERWRITES the borders from Layer 3!)
    //   - Resize handles
    //   - Dimension labels
    // Result: Final UI overlays drawn on top of everything
}
```

**CRITICAL UNDERSTANDING:**

The borders are drawn TWICE:
1. **In Layer 3 (output.zig):** White border for temp, green for finalized
2. **In Layer 5 (tool.render()):** OVERWRITES Layer 3's borders!

This is why changing colors in `output.zig` doesn't work - the tool draws LAST.

---

### 5. tools/selection.zig - Selection Tool Logic

**Role:** Handles selection interaction AND draws selection UI

**Two Separate Responsibilities:**

#### A. INTERACTION (responds to input)

```zig
pub const SelectionTool = struct {
    anchor_x: i32,          // Where selection started
    anchor_y: i32,
    last_pointer_x: i32,    // Current pointer position
    last_pointer_y: i32,
    is_selecting: bool,     // Currently dragging?
    
    pub fn onPointerPress(x: i32, y: i32) {
        // Check if clicking on existing selection handle
        if (canvas.selection exists) {
            const handle = sel.getHandleAt(x, y);
            if (handle) {
                // Start moving/resizing
                sel.interaction = .moving or .resizing_nw, etc.
            }
        } else {
            // Start new selection
            self.anchor_x = x;
            self.anchor_y = y;
            self.is_selecting = true;
        }
    }
    
    pub fn onPointerMove(x: i32, y: i32) {
        // Update position tracking
        self.last_pointer_x = x;
        self.last_pointer_y = y;
        
        // If interacting with existing selection, update it
        if (sel.interaction == .moving) {
            sel.move(x, y);
        }
        if (sel.interaction == .resizing_*) {
            sel.resize(dx, dy);
        }
    }
    
    pub fn onPointerRelease(x: i32, y: i32) {
        if (self.is_selecting) {
            // Finalize the selection
            canvas.selection = Selection{
                .x = min(anchor, x),
                .y = min(anchor, y),
                .width = abs(x - anchor) + 1,
                .height = abs(y - anchor) + 1,
            };
            self.is_selecting = false;
        }
        
        // Reset interaction mode
        sel.interaction = .none;
    }
};
```

#### B. RENDERING (draws UI)

```zig
pub fn render(self: *SelectionTool, cr: *cairo_t, canvas: *Canvas, offset: i32) {
    // Draw finalized selection UI
    if (canvas.selection) |sel| {
        drawSelection(cr, sel, offset);  // Borders + handles + labels
    }
    
    // Draw temporary selection UI (while dragging)
    if (self.is_selecting) {
        drawTempSelection(cr, self.anchor, self.last_pointer, offset);
    }
}

fn drawSelection(cr, sel, offset) {
    // Draw green border
    c.cairo_set_source_rgba(cr, 0.0, 1.0, 0.0, 1.0);  // ← CHANGE COLOR HERE
    c.cairo_rectangle(cr, sel.x, sel.y, sel.w, sel.h);
    c.cairo_stroke(cr);
    
    // Draw resize handles (8 circles)
    drawResizeHandles(cr, ...);
    
    // Draw dimensions label
    drawDimensionsLabel(cr, ...);
}

fn drawTempSelection(cr, anchor, pointer, offset) {
    // Draw white border
    c.cairo_set_source_rgba(cr, 1.0, 1.0, 1.0, 0.5);  // ← CHANGE COLOR HERE
    c.cairo_rectangle(...);
    c.cairo_stroke(cr);
}
```

---

## The Complete Flow: What Happens When You Drag

Let's trace a complete interaction:

### Step 1: Click Mouse Button

```
User clicks at (500, 300)
    ↓
main.zig::pointerListener receives .button event
    ↓
Calls: state.current_tool.onPointerPress(&state.canvas, 500, 300)
    ↓
selection.zig::onPointerPress executes:
    - Sets anchor_x = 500, anchor_y = 300
    - Sets last_pointer_x = 500, last_pointer_y = 300
    - Sets is_selecting = true
    - Sets canvas.selection = null (clear old selection)
    ↓
main.zig does NOT call setAllOutputsDirty() (no redraw yet!)
    ↓
Screen unchanged
```

### Step 2: Move Mouse (while button held)

```
User moves mouse to (550, 350)
    ↓
main.zig::pointerListener receives .motion event
    ↓
Updates: state.pointer_x = 550, state.pointer_y = 350
    ↓
Calls: state.current_tool.onPointerMove(&state.canvas, 550, 350)
    ↓
selection.zig::onPointerMove executes:
    - Sets last_pointer_x = 550
    - Sets last_pointer_y = 350
    ↓
main.zig checks: is sel_tool.is_selecting true? YES!
    ↓
main.zig calls: state.setAllOutputsDirty()
    ↓
This triggers: output.renderOutput() for each monitor
    ↓
output.zig::renderOutput executes THE ENTIRE PIPELINE:

1. Draws screenshot (REPLACES everything)
   c.cairo_paint() with SOURCE operator
   
2. Draws 50% black overlay over entire screen
   c.cairo_paint() with OVER operator
   
3. Checks: is current_tool == .selection? YES
   Checks: is sel_tool.is_selecting? YES
   Calculates:
     - sel_x = min(500, 550) = 500
     - sel_y = min(300, 350) = 300
     - sel_w = abs(550 - 500) + 1 = 51
     - sel_h = abs(350 - 300) + 1 = 51
   Draws:
     - Undarkened 51x51 region at (500, 300)
     - White border around it
   
4. Draws canvas elements (none yet)

5. Calls: state.current_tool.render(cr, &canvas, offset)
     ↓
   selection.zig::render executes:
     - Checks: is is_selecting? YES
     - Calls: drawTempSelection(500, 300, 550, 350)
       - Draws white border (OVERWRITES Layer 3's border!)
    ↓
Screen now shows:
  - Semi-dark screenshot
  - Bright 51x51 selection at (500,300)
  - White border around it
```

### Step 3: Release Mouse Button

```
User releases button at (600, 400)
    ↓
main.zig::pointerListener receives .button .released event
    ↓
Calls: state.current_tool.onPointerRelease(&state.canvas, 600, 400)
    ↓
selection.zig::onPointerRelease executes:
    - Checks: is is_selecting? YES
    - Calculates final selection:
        sel_x = min(500, 600) = 500
        sel_y = min(300, 400) = 300
        sel_w = abs(600 - 500) + 1 = 101
        sel_h = abs(400 - 300) + 1 = 101
    - Creates: canvas.selection = Selection{ x:500, y:300, w:101, h:101 }
    - Sets: is_selecting = false
    ↓
main.zig calls: state.setAllOutputsDirty()
    ↓
output.zig::renderOutput executes:

1-2. Same (screenshot + overlay)

3. Checks: is is_selecting? NO (now false)
   Checks: does canvas.selection exist? YES
   Draws:
     - Undarkened 101x101 region at (500, 300)
     - Green border around it

4. Same (no elements)

5. Calls: state.current_tool.render(...)
     ↓
   selection.zig::render executes:
     - Checks: does canvas.selection exist? YES
     - Calls: drawSelection(sel)
       - Draws green border (OVERWRITES Layer 3!)
       - Draws 8 resize handles
       - Draws dimension label
    ↓
Screen now shows:
  - Semi-dark screenshot
  - Bright 101x101 selection at (500,300)
  - Green border with resize handles
  - Dimension label showing "101 × 101"
```

---

## Why Colors Need to Be Changed in selection.zig

When you change colors in `output.zig`:

```zig
// In output.zig Layer 3
c.cairo_set_source_rgba(cr, 1.0, 0.0, 0.0, 0.5);  // RED
c.cairo_rectangle(...);
c.cairo_stroke(cr);  // Draws red border
```

This DOES draw a red border... but then Layer 5 happens:

```zig
// In selection.zig Layer 5
c.cairo_set_source_rgba(cr, 1.0, 1.0, 1.0, 0.5);  // WHITE
c.cairo_rectangle(...);
c.cairo_stroke(cr);  // Draws white border ON TOP
```

Result: You see white, because it's drawn LAST.

**Solution:** Change colors in the tool files, not output.zig.

---

## Why We Draw Borders Twice (Design Question)

You might ask: "Why draw the border in BOTH output.zig and selection.zig?"

**Answer:** We probably shouldn't! This is redundant. But here's why it ended up this way:

1. **output.zig** draws the border because the original code had selection rendering integrated into the output rendering
2. **selection.zig** draws the border because in the new tool architecture, each tool is responsible for its own UI

**Better Design:** 
- `output.zig` should ONLY draw the undarkened region (no border)
- `selection.zig` should ONLY draw the border and handles

But the current code works, so we left it as-is for now.

---

## Cairo Operators - CRITICAL CONCEPT

Cairo has different "operators" that control HOW pixels are combined:

### CAIRO_OPERATOR_SOURCE
**Replaces** destination pixels with source pixels.
```zig
c.cairo_set_operator(cr, c.CAIRO_OPERATOR_SOURCE);
c.cairo_paint(cr);  // Replaces EVERYTHING with the source
```

Use for:
- Drawing the initial screenshot (Layer 1)
- Drawing undarkened selection region (replaces the dark overlay)

### CAIRO_OPERATOR_OVER
**Composites** source over destination (alpha blending).
```zig
c.cairo_set_operator(cr, c.CAIRO_OPERATOR_OVER);
c.cairo_set_source_rgba(cr, 0, 0, 0, 0.5);  // 50% transparent
c.cairo_paint(cr);  // Adds 50% black on top
```

Use for:
- Drawing the black overlay (Layer 2)
- Drawing borders and UI elements (Layer 5)

### CAIRO_OPERATOR_CLEAR
**Clears** pixels (makes transparent).
```zig
c.cairo_set_operator(cr, c.CAIRO_OPERATOR_CLEAR);
c.cairo_paint(cr);  // Makes everything transparent
```

Use for:
- Clearing the canvas (we tried this but it showed the desktop)

---

## Why The Screen Was Getting Darker

**The Bug:**
Every time we rendered, we were doing:
```
Frame 1: screenshot + 50% black overlay = semi-dark
Frame 2: screenshot + 50% black overlay + 50% black overlay = darker
Frame 3: screenshot + 50% black overlay + 50% black overlay + 50% black overlay = even darker
```

**The Fix:**
Use `CAIRO_OPERATOR_SOURCE` for the initial screenshot:
```zig
c.cairo_set_operator(cr, c.CAIRO_OPERATOR_SOURCE);
c.cairo_paint(cr);  // REPLACES everything, doesn't stack
```

This ensures each frame starts fresh.

---

## Tool Architecture

Each tool follows this interface:

```zig
pub const Tool = union(enum) {
    selection: SelectionTool,
    arrow: ArrowTool,
    rectangle: RectangleTool,
    // ...
    
    // Interaction methods (modify state)
    pub fn onPointerPress(canvas, x, y);
    pub fn onPointerMove(canvas, x, y);
    pub fn onPointerRelease(canvas, x, y);
    
    // Rendering method (draw UI)
    pub fn render(cr, canvas, offset);
    
    // Cursor method (what cursor to show)
    pub fn getCursor(canvas, x, y) -> CursorType;
};
```

Tools are **stateless** between uses - when you switch tools, the old tool is destroyed and a new one is created. Only the `canvas` persists.

---

## Data Flow Summary

```
Input Event (Wayland)
    ↓
main.zig (event handling)
    ↓
Tool methods (modify canvas/tool state)
    ↓
setAllOutputsDirty() (if needed)
    ↓
output.zig::renderOutput()
    ├→ Draw layers 1-4 (screenshot, overlay, undarkening, elements)
    └→ Call tool.render() for layer 5 (UI overlays)
    ↓
Screen updated
```

**Key Insight:** Rendering is completely separate from interaction. Tools modify state, then rendering happens based on that state.

---

## Common Mistakes & Gotchas

### 1. Changing colors in the wrong file
❌ Change in `output.zig` → Gets overwritten
✅ Change in `tools/selection.zig` → Actually visible

### 2. Forgetting to trigger redraw
❌ Modify state but don't call `setAllOutputsDirty()` → Screen doesn't update
✅ Call `setAllOutputsDirty()` after state changes

### 3. Using wrong Cairo operator
❌ Use OVER for screenshot → Stacking/darkening
✅ Use SOURCE for screenshot → Fresh each frame

### 4. Modifying canvas in render functions
❌ `render()` should modify canvas → State changes during rendering
✅ `render()` should only READ canvas → Clean separation

### 5. Not understanding the layer order
❌ Draw handles before selection → Handles hidden
✅ Draw selection, THEN handles → Handles visible

---

## How to Add a New Tool

Let's say you want to add a Circle tool:

### Step 1: Create the tool file

```zig
// src/tools/circle.zig
pub const CircleTool = struct {
    center_x: ?i32 = null,
    center_y: ?i32 = null,
    current_x: i32 = 0,
    current_y: i32 = 0,
    is_drawing: bool = false,
    
    pub fn init() CircleTool {
        return .{};
    }
    
    pub fn onPointerPress(self: *CircleTool, canvas: *Canvas, x: i32, y: i32) void {
        self.center_x = x;
        self.center_y = y;
        self.is_drawing = true;
    }
    
    pub fn onPointerMove(self: *CircleTool, canvas: *Canvas, x: i32, y: i32) void {
        if (self.is_drawing) {
            self.current_x = x;
            self.current_y = y;
        }
    }
    
    pub fn onPointerRelease(self: *CircleTool, canvas: *Canvas, x: i32, y: i32) void {
        if (!self.is_drawing) return;
        
        // Calculate radius
        const dx = x - self.center_x.?;
        const dy = y - self.center_y.?;
        const radius = sqrt(dx*dx + dy*dy);
        
        // Add to canvas
        const circle = CircleElement{
            .center_x = self.center_x.?,
            .center_y = self.center_y.?,
            .radius = radius,
        };
        canvas.addElement(Element{ .circle = circle });
        
        self.is_drawing = false;
    }
    
    pub fn render(self: *const CircleTool, cr: ?*cairo_t, canvas: *Canvas, offset_x: i32, offset_y: i32) void {
        const cairo = cr orelse return;
        
        // Draw preview while drawing
        if (self.is_drawing and self.center_x != null) {
            const dx = self.current_x - self.center_x.?;
            const dy = self.current_y - self.center_y.?;
            const radius = sqrt(dx*dx + dy*dy);
            
            c.cairo_set_source_rgba(cairo, 1.0, 1.0, 1.0, 0.5);
            c.cairo_arc(cairo, center_x - offset_x, center_y - offset_y, radius, 0, 2*PI);
            c.cairo_stroke(cairo);
        }
    }
    
    pub fn getCursor(_: *const CircleTool, _: *Canvas, _: i32, _: i32) CursorType {
        return .crosshair;
    }
};
```

### Step 2: Add to Tool union

```zig
// src/tools/tool.zig
pub const Tool = union(enum) {
    selection: SelectionTool,
    arrow: ArrowTool,
    circle: CircleTool,  // ← ADD THIS
    // ...
};
```

### Step 3: Add to ToolMode

```zig
// src/state.zig
pub const ToolMode = enum {
    selection,
    draw_arrow,
    draw_circle,  // ← ADD THIS
    // ...
};
```

### Step 4: Add to setTool

```zig
// src/state.zig
pub fn setTool(self: *AppState, mode: ToolMode) void {
    self.tool_mode = mode;
    self.current_tool = switch (mode) {
        .selection => Tool{ .selection = SelectionTool.init() },
        .draw_arrow => Tool{ .arrow = ArrowTool.init() },
        .draw_circle => Tool{ .circle = CircleTool.init() },  // ← ADD THIS
        // ...
    };
}
```

### Step 5: Add keyboard shortcut

```zig
// src/main.zig
fn keyboardListener(...) {
    switch (key.key) {
        31 => state.setTool(.selection),  // 's'
        30 => state.setTool(.draw_arrow),  // 'a'
        46 => state.setTool(.draw_circle),  // 'c' ← ADD THIS
        // ...
    }
}
```

Done! Press 'c' to switch to circle tool.

---

## Performance Considerations

### When Redraws Happen

Currently redraws happen when:
- Moving/resizing selection (is_selecting or interaction != .none)
- Drawing with tools (is_drawing = true)
- Button release (to show final state)

NOT when:
- Just moving mouse (hovering)
- Clicking without moving

This prevents excessive rendering.

### Multiple Monitors

Each monitor gets its own `Output` struct and renders independently. All outputs share the same `AppState`, so they all show the same thing, just at different positions.

### Cairo Performance

Cairo is GPU-accelerated through the backend. Drawing is fast, but:
- Creating image surfaces is expensive (we do this every frame)
- Could optimize by caching the image surface

---

## Summary

The architecture is:
1. **Layered rendering** - 5 distinct layers drawn in order
2. **Tool-based interaction** - Each tool handles its own input/rendering
3. **Separation of concerns** - State, rendering, and interaction are separate
4. **Cairo operators** - SOURCE replaces, OVER composites

The key to understanding it: **Follow the data flow from input → state → rendering → screen**.
