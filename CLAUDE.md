# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

RopeTool is a Roblox Studio plugin for creating and editing "ropes": contiguous chains of
elongated parts (boxes or cylinders) laid end to end, e.g. hanging ropes strung between two
attachment points. Like PolyMap, the rope structure is *implicitly discovered* from the parts in
the scene rather than stored anywhere: a discovered rope is a list of vertices joined by edges,
where each edge remembers which side of it its part sits on. It outputs a `.rbxmx` plugin file
built via Rojo.

Modes:
- **Add** — click two attachment points (snapping to part corners/edges, including mesh edges via
  the Geometry package's `blackboxFindClosestMeshEdge`) to build a sagging rope between them.
- **Move** — hover/click to select a rope (discovered by walking matching adjacent parts), then
  drag its endpoints (axis arrows, or the endpoint sphere for a free drag with Add-style
  snapping) or the vertical-only middle handle (sag). Panel edits (segments, type, diameter,
  sag, color, material) apply to the selected rope.

## Build Commands

```bash
# Build the plugin (default build task)
rojo build -p "RopeTool v1.0.rbxmx"

# Run tests (*.spec.lua files in the Src folder)
# Tests can call t.screenshot("name") to capture the viewport (use Read tool to view the output)
# For UI tests: mount into ScreenGui parented to CoreGui, use ReactRoblox.act to flush rendering
python runtests.py

# Install dependencies (must fix the Luau types after installing)
wally install
rojo sourcemap default.project.json --output sourcemap.json
wally-package-types --sourcemap sourcemap.json Packages
```

Tools are managed via Aftman (`aftman.toml`): Rojo 7.6.1. Dependencies are managed via Wally (`wally.toml`).

## Architecture

Three-layer design:

1. **Functionality layer** — Session lifecycle, rope discovery/building, 3D handles.
   - `src/createRopeSession.lua` — Session lifecycle: Move/Add tools, hover + selection UX,
     endpoint/sag draggers, add-point snapping, undo/redo via ChangeHistoryService recordings.
   - `src/RopeGraph.lua` — Implicit discovery: vertices + edges walked from a seed part via
     endpoint adjacency and a property-overlap heuristic (shape / cross-section / color / material).
   - `src/buildRope.lua` — Builds/updates the segment parts along the curve, reusing parts in
     place during drags.
   - `src/ropeCurve.lua` — The parabolic sag curve: point generation and sag estimation (inverse).
   - `src/Dragger/` — MoveHandles (with optional axis filter for the vertical-only sag handle)
     and GrabPointHandle (the freely-draggable endpoint sphere with Add-style snapping), built
     on DraggerFramework.

2. **Settings layer** — Persistent configuration via `plugin:GetSetting`/`SetSetting`.
   - `src/Settings.lua` — Settings key `"ropeToolState"`. Stores mode, segments, segment type,
     sag, diameter, rope color/material, recent colors/materials.

3. **UI layer** — React components.
   - `src/RopeToolGui.lua` — Main settings panel: mode chips, rope parameters, and the
     color/material selection UX (shared design with PolyMap's paint panels).
   - `src/RopeOverlay.lua` — Viewport overlay: hover/selected rope polylines, add-point markers,
     preview curve.
   - `src/PluginGui/` — Shared reusable components (copied verbatim across plugins, don't change
     this unless asked).

**Entry point:** `loader.server.lua` creates the toolbar button and dock widget, then lazy-loads
`src/main.lua` on first activation. `src/main.lua` orchestrates session management and mounts the
React UI.

## Key Conventions

- All source files use `--!strict` (Luau strict type checking).
- React components use `React.createElement` (aliased as `e`) — not JSX.
- The Signal library (`Packages.Signal`) is used for custom events throughout.
- Modules typically `return` a single function rather than a table of exports.
- Undo/redo integrates with `ChangeHistoryService` using recording-based waypoints; on undo/redo
  the selection is re-resolved by re-discovering the rope from a surviving part (discovery is
  stateless, so there is no mesh rebuild machinery like PolyMap's).

## Dependencies (via Wally)

- **React / ReactRoblox / RoactCompat** — UI framework
- **DraggerFramework / DraggerSchemaCore / DraggerHandler** — 3D handle/manipulator system
- **Roact** — Used by DraggerToolComponent for handle rendering
- **Signal (GoodSignal)** — Event system
- **Geometry** — Part corner/edge extraction for add-point snapping
- **createSharedToolbar** — Optional toolbar combining with other plugins
