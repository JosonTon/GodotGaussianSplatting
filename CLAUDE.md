# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

对话使用中文。

## Project Overview

Godot 4.3 (Forward Plus) implementation of real-time 3D Gaussian Splatting via GPU compute shaders. Pure GDScript + GLSL — no custom native compilation needed. The imgui-godot addon ships pre-built binaries.

## Running the Project

Open in Godot 4.3 and run the main scene (`main.tscn`). Drag & drop `.ply` files onto the window to load models. A demo model is included at `resources/demo.ply`.

## Architecture

### Rendering Pipeline (4 stages, all GPU compute)

1. **Projection** (`resources/shaders/compute/gsplat_projection.glsl`) — Frustum culling, 3D→2D covariance projection, spherical harmonic color evaluation, generates tile-keyed sort pairs
2. **Radix Sort** (3 passes: `radix_sort_upsweep/spine/downsweep.glsl`) — GPU radix sort ordering splats by tile ID + depth. Adapted from [vulkan_radix_sort](https://github.com/jaesung-cs/vulkan_radix_sort)
3. **Boundaries** (`gsplat_boundaries.glsl`) — Detects tile boundaries in sorted array, builds per-tile start/end index ranges
4. **Render** (`gsplat_render.glsl`) — 16x16 tile-based alpha blending (back-to-front), shared memory optimization, early exit on opacity threshold

### Key Files

| File | Role |
|------|------|
| `main.gd` / `main.tscn` | Entry point, ImGui debug UI (FPS, stage timings, VRAM, controls) |
| `util/gaussian_splatting_rasterizer.gd` | Orchestrates all 6 compute pipelines, manages GPU buffers. Constants: TILE_SIZE=16, WORKGROUP_SIZE=512, PARTITION_SIZE=4096 |
| `util/ply_file.gd` | Binary PLY parser, async loading via WorkerThreadPool. 60 floats/splat (240 bytes): position, precomputed 3D covariance, opacity, SH coefficients |
| `util/render_context.gd` | Wrapper around `RenderingDevice` — buffer/texture creation, GLSL→SPIR-V compilation, descriptor sets, deletion queue |
| `util/camera.gd` | FreeLookCamera with FREE_LOOK (RMB+WASD), ORBIT (LMB), and NONE modes |
| `resources/shaders/spatial/main.gdshader` | Display shader — samples Texture2DRD, sRGB→linear conversion |

### Data Flow

```
PLY File → PlyFile (CPU, async) → GPU Splat Buffer
  → Projection → Radix Sort → Boundaries → Render
  → Texture2DRD → Display Shader → Screen
```

### Sort Key Format

Each splat generates one key-value pair per intersected tile:
- **Key:** `(tile_id << 16) | depth` (32-bit)
- **Value:** Gaussian index

### Compute Shader Workgroup Sizes

- Projection/Boundaries/Render: 256 threads
- Radix sort: 512 threads per workgroup
- Render dispatches as 16x16 thread tiles (1 thread per pixel)

## Configuration

- **Autoload:** ImGuiRoot (`addons/imgui-godot/data/ImGuiRoot.tscn`)
- **Input:** `toggle_imgui` (Ctrl+H), `toggle_fullscreen` (Ctrl+F)
- **VSync:** Adaptive (mode 3)
- **GDScript warnings:** Several disabled (unassigned_variable, unused_parameter, shadowed_variable, etc.)
