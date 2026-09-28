# RoomSplat

Scan a room with **ARKit + RoomPlan** on iOS, then render the result as a
**3D Gaussian splat cloud** with a **Metal** renderer that performs proper
EWA-style 2D covariance projection, per-fragment Gaussian falloff, and
back-to-front alpha compositing.

The app is a self-contained example of how to wire all three Apple
frameworks together with a hand-rolled splat renderer.

---

## Requirements

| Item                | Version                                            |
|---------------------|----------------------------------------------------|
| Xcode               | 26+ (iOS 26 SDK)                                   |
| Deployment target   | iOS 26.0                                           |
| Swift               | 6.0 (strict concurrency)                           |
| Device              | LiDAR-equipped iPhone or iPad (Pro line)           |
| Build tool          | [XcodeGen](https://github.com/yonaskolb/XcodeGen)  |

RoomPlan needs LiDAR; it will not capture in the iOS Simulator. The project
*builds* in the Simulator (useful for iterating on the renderer with
synthetic splats), but you need a real device to actually scan a room.

---

## Quick start

```sh
cd RoomSplat
xcodegen generate
open RoomSplat.xcodeproj
```

In Xcode, set your signing team on the `RoomSplat` target, then run on a
LiDAR device.

To build from the command line for a connected device:

```sh
xcodebuild \
  -project RoomSplat.xcodeproj \
  -scheme RoomSplat \
  -destination 'generic/platform=iOS' \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM=<YOUR_TEAM_ID> \
  build
```

---

## Architectural overview

The app is a three-stage pipeline:

```
                 ┌─────────────────────┐
   ARKit + ─────►│ 1. Scan             │
   RoomPlan      │   RoomCaptureView   │
                 │   RoomCaptureSession│
                 └──────────┬──────────┘
                            │ CapturedRoomData
                            ▼
                 ┌─────────────────────┐
                 │ 2. Build            │
                 │   RoomBuilder       │──► CapturedRoom (walls,
                 │                     │       floors, doors,
                 └──────────┬──────────┘       windows, openings,
                            │                  objects)
                            ▼
                 ┌─────────────────────┐
                 │ 3. Generate splats  │
                 │   SplatGenerator    │──► [Splat]
                 └──────────┬──────────┘
                            │
                            ▼
                 ┌─────────────────────┐
   Metal  ◄──────│ 4. Render           │
                 │   SplatRenderer     │
                 │   Shaders.metal     │
                 └─────────────────────┘
```

Each stage maps to a small, single-purpose module.

### 1. Scan — `Scanning/RoomScannerView.swift`

A `UIViewRepresentable` that owns a `RoomCaptureView` and bridges the
SwiftUI lifecycle to its `RoomCaptureSession`. The `Coordinator`:

- starts/stops the session in response to a `@Binding var isScanning`,
- conforms to `RoomCaptureSessionDelegate` and receives
  `CapturedRoomData` when the user taps **Done**,
- forwards the data to `RoomBuilder.capturedRoom(from:)` (off the main
  actor) to produce the final `CapturedRoom`.

The Coordinator class is `@MainActor`-isolated; the
`captureSession(_:didEndWith:error:)` callback is `nonisolated` because
RoomPlan invokes delegate methods from arbitrary threads. Inside the
callback we hop back onto the main actor with `Task { @MainActor in }`
so the SwiftUI state updates and the `RoomBuilder` `await` are properly
isolated under Swift 6 strict concurrency.

We deliberately do not implement `RoomCaptureViewDelegate`. The built-in
post-scan review UI is skipped — control returns straight to SwiftUI,
which switches to the splat viewer.

### 2. Build — `RoomBuilder`

Apple's standard call. `RoomBuilder(options: [.beautifyObjects])`
post-processes the noisy raw scan into a clean parametric room. The
output is a `CapturedRoom` containing transforms + dimensions for:

- walls, floors (planar `Surface`s with x = width, y = height,
  z = normal),
- doors, windows, openings (also `Surface`s),
- detected objects (parametric oriented bounding boxes with a category
  label like `.bed`, `.sofa`, `.table`, …).

### 3. Generate splats — `Splats/SplatGenerator.swift`

The bridge from parametric geometry to a Gaussian splat cloud.

- **Surfaces.** Each surface is sampled on a regular grid (default
  ~14 samples per linear meter, configurable via `samplesPerMeter`).
  Each sample becomes one splat positioned in world space via the
  surface transform.
- **Objects.** Each detected object is treated as an oriented box.
  All six faces are tiled with the same grid sampler.
- **Splat shape.** Surfaces are flat, so each splat is a thin
  pancake — in-plane σ ≈ 4.5 cm, normal σ ≈ 1.2 cm. The scaling is
  encoded in `Splat.scale` and the orientation in `Splat.rotation`
  (a quaternion derived from the source surface's transform via a
  Shoemake conversion of the upper-3×3).
- **Color.** A simple per-category palette (walls light, floor brown,
  windows blue-tinted, etc.) plus small per-channel jitter so the
  cloud doesn't look flat-shaded.
- **Opacity.** Windows and openings are partly transparent so you can
  see through them.

Output is a flat `[Splat]` array that the renderer can upload directly.

### 4. Render — `Rendering/`

The renderer is the interesting part. Five files:

| File                 | Role                                                          |
|----------------------|---------------------------------------------------------------|
| `ShaderTypes.h`      | C struct definitions shared between Swift and Metal           |
| `Bridging.h`         | Swift bridging header that includes `ShaderTypes.h`           |
| `Splat.swift`        | Swift mirror of `GPUSplat`, layout-compatible, 80 bytes       |
| `SplatRenderer.swift`| MTL pipeline, depth sort, draw call, orbit camera             |
| `MetalSplatView.swift`| `UIViewRepresentable` over `MTKView`, gesture wiring         |
| `Shaders.metal`      | Vertex + fragment shaders implementing 2D EWA splatting       |

#### CPU side: `SplatRenderer`

- Holds the splat buffer (`MTLBuffer` of `GPUSplat`) and a parallel
  `indices` buffer of `UInt32` that the renderer rewrites every
  frame after sorting by view-space depth.
- Owns an orbit camera (`yaw`, `pitch`, `radius`, `target`). The
  target is recentered on the splat cloud's bounding-box midpoint
  whenever new splats are uploaded.
- Builds a perspective projection (`60°` fovy, `[0.05, 100]` near/far)
  and derives pixel focal lengths `f = 0.5 · viewport.y / tan(fovy/2)`
  needed by the shader's Jacobian.
- Issues a single
  `drawPrimitives(.triangleStrip, vertexCount: 4, instanceCount: N)`
  call. The vertex shader expands each instance into a screen-aligned
  bounding quad sized to the projected splat ellipse.

Blend state is the standard premultiplied back-to-front formula:

```
src.rgb = color.rgb * α
src.a   = α
out     = src + (1 − src.a) · dst
```

Depth write is off; depth test is `.always`. Order is established by
the per-frame CPU sort.

#### GPU side: `Shaders.metal`

The vertex shader implements the EWA splat projection:

1. **World covariance.**
   `Σ = R · S · Sᵀ · Rᵀ`, with `R = quaternionToMatrix(splat.rotation)`
   and `S = diag(splat.scale)`.
2. **Camera-space mean.** `t = view · position`. If `t.z ≥ −near`, emit
   a degenerate quad — the splat is behind the camera.
3. **View-space covariance.** `W` = upper 3×3 of `view`,
   `Σ_view = W · Σ · Wᵀ`.
4. **Perspective Jacobian** at the camera-space mean:

   ```
   J = | −fₓ/z      0      fₓ·x/z² |
       |   0     −f_y/z    f_y·y/z² |
   ```

5. **2D screen-space covariance** `Σ′ = J · Σ_view · Jᵀ` (a 2×2),
   plus a `0.3 · I` regularizer along the diagonal — the standard
   3DGS anti-alias trick that prevents singular splats when one
   axis projects to a sub-pixel size.
6. **Conic.** Invert `Σ′` and pass the unique entries
   `(a, b, c)` to the fragment shader so it can evaluate
   `dᵀ Σ′⁻¹ d` cheaply.
7. **Bounding quad.** The largest eigenvalue of `Σ′` gives the major
   axis; the quad is sized to `3√λ_max` pixels and converted to
   clip-space offsets at the splat's depth via
   `clipOffset = (offsetPx / (0.5 · viewport)) · w`.

The fragment shader evaluates the Gaussian:

```
α_eval = opacity · exp(−½ · (a·dx² + 2b·dx·dy + c·dy²))
```

with an early discard for `power > 0` (outside the projected ellipse)
and another for `α < 1/255`. It writes premultiplied
`(rgb·α, α)` for the blender to composite.

---

## Data layout & alignment

`GPUSplat` is the single source of truth for splat memory layout. It is
declared in `ShaderTypes.h` and consumed by both Swift (via the bridging
header) and Metal (via `#include`).

```c
typedef struct {
    simd_float3 position;   // 16 bytes (12 + 4 pad)
    float       opacity;    //  4 bytes (consumes pad slot above)
    simd_float3 scale;      // 16 bytes
    float       _pad0;      //  4 bytes
    simd_float4 rotation;   // 16 bytes  (quaternion x,y,z,w)
    simd_float4 color;      // 16 bytes
} GPUSplat;                 // 80 bytes total
```

The Swift `Splat` struct mirrors this exactly. `Splat.stride` is checked
in practice by uploading the array directly via `device.makeBuffer(bytes:)`
— no manual packing.

`SplatUniforms` carries per-frame matrices, viewport, focal lengths, and
the world-space camera position.

---

## Coordinate conventions

- **World space.** Right-handed, +Y up, RoomPlan's native frame.
- **View space.** Right-handed, camera looks down −Z (Apple convention).
  The Jacobian above assumes this — note the sign on `fₓ/z`.
- **NDC / clip.** Standard Metal: clip-space `[-w, w]` mapping to NDC
  `[-1, 1]`, depth `[0, 1]`.
- **Pixels.** Origin at bottom-left after the standard NDC → viewport
  mapping (`pixel = (ndc · 0.5 + 0.5) · viewport`). The renderer
  converts a pixel-space quad offset to a clip-space offset by
  multiplying by `w` at the splat's depth.

---

## Performance notes

The current renderer is sized for room-scale scans (typically
**5k–25k splats** depending on `samplesPerMeter`).

- **CPU sort per frame.** `Array.sort` on ~10k indices keyed by
  view-space `z`. ~1 ms on a modern A-series core. Cheap enough that
  GPU sort is unnecessary at this scale.
- **Single instanced draw call.** `vertexCount = 4`,
  `instanceCount = N`. Each instance reads `splats[indices[iid]]`
  through a level of indirection so the splat buffer never has to
  be re-uploaded.
- **No depth write, no MSAA.** Splats use stochastic-style
  alpha compositing; MSAA would over-shade the falloff.

To scale up (100k+ splats from a much larger scan or a real photogrammetry
pipeline) you'd want:

- A GPU bitonic / radix sort on view-space depth,
- A tile-based rasterizer (the canonical 3DGS approach) instead of
  one quad per splat,
- Spherical harmonic color instead of constant RGB.

---

## Module map

```
RoomSplat/
├── project.yml                       XcodeGen target definition
├── README.md                         (this file)
└── RoomSplat/
    ├── RoomSplatApp.swift            @main, just hands off to ContentView
    ├── ContentView.swift             Three-state SwiftUI flow:
    │                                   .intro → .scanning → .viewing
    ├── Scanning/
    │   └── RoomScannerView.swift     RoomCaptureView wrapper + delegate
    ├── Splats/
    │   ├── Splat.swift               Splat struct + quaternion math helpers
    │   └── SplatGenerator.swift      CapturedRoom → [Splat]
    ├── Rendering/
    │   ├── ShaderTypes.h             Shared C struct layout
    │   ├── Bridging.h                Swift ⟷ ObjC bridge
    │   ├── Splat.swift               (mirror; same struct as above)
    │   ├── SplatRenderer.swift       Pipeline, sort, draw, orbit camera
    │   ├── MetalSplatView.swift      MTKView + pan/pinch gestures
    │   └── Shaders.metal             EWA splat vertex + fragment shaders
    └── Resources/
        └── Info.plist                NSCameraUsageDescription, ARKit cap
```

---

## Lifecycle in detail

1. App launches into `ContentView` in the `.intro` state.
2. User taps **Start scanning**. We check
   `RoomCaptureSession.isSupported` — if not, we drop into the error
   state. Otherwise the state flips to `.scanning` and the bound
   `isScanning` becomes `true`.
3. `RoomScannerView.updateUIView` sees the change and starts the
   capture session with a default `Configuration`.
4. User scans the room. RoomPlan's built-in dynamic mesh overlay
   provides live feedback during the scan — that's `RoomCaptureView`'s
   own behavior, not anything we add.
5. User taps **Done**. We set `isScanning = false`, which calls
   `captureSession.stop()` and triggers
   `captureSession(_:didEndWith:error:)`.
6. The coordinator hands the raw `CapturedRoomData` to `RoomBuilder`
   inside a `Task`. On success, the resulting `CapturedRoom` is sent
   back to the main actor and the SwiftUI state moves to
   `.viewing(splats:)`.
7. `MetalSplatView.makeUIView` constructs a `SplatRenderer`, uploads
   the splats, and starts the `MTKView` render loop. Pan rotates the
   orbit camera; pinch zooms. **Scan another room** returns to
   `.intro`.

---

## Extending the project

Some natural next steps if you want to take this further:

- **Persist scans.** Encode the `CapturedRoom` (it's `Codable` via
  `USDZ` export) and the `[Splat]` array (binary blob of `GPUSplat`)
  to disk so the user can reopen past scans.
- **Real Gaussian splatting input.** Swap `SplatGenerator` for a
  loader that ingests `.ply` or `.splat` files trained externally
  (e.g. via `gsplat` / Inria's reference implementation). The
  renderer is already shaped for that workflow — `Splat` only needs
  per-splat color (or SH coefficients).
- **AR view.** Replace `MetalSplatView`'s orbit camera with an
  `ARSession`'s pose so the splats anchor in physical space and the
  user can walk around them.
- **Tile-based 3DGS.** Port `Shaders.metal` to a tile-based
  rasterizer to handle million-splat scenes at high frame rates.

---

## License

No license declared — treat as a sample. Adapt freely.
