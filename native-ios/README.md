# Lightmapping

A touch-first projection mapping and video mapping studio for iPhone and iPad, written in Swift, SwiftUI and Metal.

Map videos, photos, the live camera, hand drawings and generative visuals onto walls, windows, boxes and sculptures. Perform scenes live or arrange them on a timeline, then export the show or send it to a receiver device that loops it on its own.

This is a clean-room implementation built from a public feature description of a comparable App Store app. No code, assets or binaries from any other app were used.

## Build

Run these commands from inside `native-ios/`.

Requirements: Xcode 15 or later, iOS 17 or later, and a real device (Metal, camera and MIDI need hardware).

```sh
brew install xcodegen
xcodegen generate
open Lightmapping.xcodeproj
```

Set your signing team on the `Lightmapping` target, then run it on your device. Run the unit tests with ⌘U.

## How features map to code

| Feature | Where |
|---|---|
| Squares, circles, text, cubes/boxes, image silhouettes, hand-drawn outlines | `Model/Project.swift` (`SurfaceShape`), `Rendering/MaskRenderer.swift`, `UI/MappingCanvas.swift` |
| Drag corners on screen; bend edges around curved forms | `Geometry/WarpMesh.swift`: a 2×2 corner pin uses a true perspective homography; 3×3 to 5×5 grids use a Catmull-Rom patch |
| Masks and cutouts | `Surface.cutouts`, drawn with the ✂︎ tool and stored in surface UV space, so they follow re-mapping. Soft edges come from `feather` |
| Depth mode: one photo becomes a depth-aware shape | `Vision/ShapeExtractor.swift`: subject mask from Vision, depth from embedded Portrait/LiDAR data, a bundled Core ML model, or a synthetic relief. The `depthContours` and `depthScan` generators read it |
| Several surfaces with different content | Geometry lives on `Project.surfaces`; each `MapScene` assigns a layer stack per surface |
| Layers with independent opacity, blend and order | `Layer`, composited in `Renderer.renderScene` |
| Visualizers, VJ loops, generative shaders, tunnels, neon, shape-aware animations | 26 generators in `Shaders.metal` and 88 presets in `Model/Presets.swift`, 52 of them for Halloween and Christmas |
| Import videos and photos; live camera | `Sources/SourceManager.swift`, `Sources/CameraManager.swift` |
| Draw and animate by hand | `UI/DrawingEditor.swift` and `Sources/DrawingRenderer.swift` (trace-on, pulse, hue cycle, flicker) |
| Crop, fit, kaleidoscope, tile, slide, rotate, zoom, blur, monochrome, invert, color cycle | `layerFragment` in `Shaders.metal`, `LayerUniforms.apply` |
| Audio reactivity | `Engine/AudioAnalyzer.swift`: FFT bands with auto-gain and onset detection |
| MIDI control and MIDI learn | `Engine/MIDIManager.swift`. CCs drive parameters; notes from C1 upward switch scenes |
| BPM-synced LFOs and envelopes; tap tempo | `Model/Modulation.swift`, `Engine.tapTempo()` |
| Hand and face tracking | `CameraManager.runVision`: index-finger position, pinch, face position and mouth opening |
| Scenes with live fade or dissolve transitions | `Engine.goToScene`, `transitionFragment` |
| Timeline with audio track, trim, duplicate and automation | `UI/TimelineEditor.swift`. Automation lanes drive four macros, and any parameter can follow a macro |
| Export in 720p, 1080p or 4K with audio | `Export/ShowExporter.swift`: deterministic offline render, then the audio is muxed in. Save to Photos or share |
| Send to a receiver that loops without your phone | `Export/LinkTransfer.swift` (MultipeerConnectivity) and Receiver mode (`ReceiverView`) |
| HDMI / AirPlay output with controls kept on device | `ExternalDisplaySceneDelegate` puts the clean output on the external screen |
| Save projects | `Model/ProjectStore.swift` (JSON plus an asset folder in Documents, visible in the Files app) |

## Architecture

```
Project ──► Engine (CADisplayLink, @MainActor)
             ├─ ModulationContext  ◄─ mic FFT · MIDI · LFO/envelopes · macros · Vision tracking · timeline
             ├─ FrameState ──► Renderer (Metal)
             │                  1. generators → per-layer textures (mask/depth aware)
             │                  2. layer stack → per-surface content texture (effects, blend)
             │                  3. warped mesh per surface → output texture (mask, feather)
             │                  4. optional scene transition + alignment outlines
             └─ presents the output texture to the device preview and the external display
ShowExporter ──► its own Renderer + offline SourceManager ──► AVAssetWriter
```

Rendering is the same code path live and in export. The exporter builds every modulation value from time, the timeline and pre-analysed audio, so an export looks the same every time.

## Notes and limits

- **Depth model:** to get learned monocular depth, add a Core ML depth model (for example Apple's Depth Anything V2 Small) to the target as `DepthModel.mlpackage`. Without it, depth comes from data embedded in the photo, or a relief estimated from the silhouette.
- **Receiver:** the receiver is this same app in Receiver mode on another iOS or iPadOS device. Plug that device into the projector; it keeps looping after the sender disconnects.
- **Camera in exports:** live camera layers show the last captured frame during export, because there is no live feed offline.
- I wrote this in a Linux container without a Swift toolchain, so it has not yet been compiled. Expect a small round of compiler fixes on the first Xcode build.
