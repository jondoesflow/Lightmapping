# Lightmapping

A touch-first projection mapping and video mapping studio that runs in your phone's browser. Install it from Safari with **Add to Home Screen** and it opens full screen like an app. You don't need a Mac or the App Store.

It's built the same way as Cheap Pumps (`fuelfinder`): a static `public/` folder with no build step, hosted on Netlify.

## Use it on iPhone

1. Deploy (below) and open the site in **Safari**.
2. Tap **Share → Add to Home Screen**.
3. Open Lightmapping from the home screen. Projects and media are saved on the device in IndexedDB.

## Deploy (Netlify, same as Cheap Pumps)

- In Netlify, choose **Add new site → Import from Git**, pick this repo and keep the defaults. `netlify.toml` already sets `publish = "public"`, and there's no build command.
- Or drag the `public/` folder onto app.netlify.com/drop.

It must be served over HTTPS (Netlify does this), because camera, microphone, the service worker and installation all need it.

## Run locally

```sh
npm start   # serves public/ on http://localhost:8080
npm test    # unit tests for warping, modulation, timeline, presets
```

## Features

| Feature | How it works here | Code |
|---|---|---|
| Squares, circles, text, cubes/boxes, hand-drawn outlines | Shapes rasterised to masks in surface space | `js/media.js` (`mask`), `js/stage.js` |
| Drag corners on screen; bend edges around curves | A 2×2 corner pin uses a true perspective homography; 3×3 to 5×5 grids use a Catmull-Rom patch | `js/geometry.js` |
| Masks, cutouts, soft edges | Cutouts are stored in surface UV space, so they follow re-mapping | `js/stage.js`, `SURFACE_FS` |
| Image silhouettes | Tap the object in a photo. The MediaPipe interactive segmenter loads on first use, with a colour-key fallback offline | `js/vision.js` |
| **Depth mode** (one photo becomes a depth-aware shape) | Silhouette plus a depth map from Depth Anything V2 (optional, about 30 MB the first time) or a distance-transform relief. Depth-aware visuals follow it | `js/vision.js`, `GENERATOR_FS` |
| Multiple surfaces, layers, opacity, blend modes, ordering | Geometry belongs to the project; each scene assigns a layer stack per surface | `js/model.js`, `js/renderer.js` |
| Visualizers, VJ loops, generative shaders, shape-aware animations | 26 GPU generators and 88 presets, **52 of them Halloween and Christmas** | `js/shaders.js`, `js/presets.js` |
| Video, photos, live camera, animated hand drawings | WebGL textures from `<video>`, images, `getUserMedia` and a canvas | `js/media.js` |
| Crop, fit, kaleidoscope, tile, slide, rotate, zoom, blur, monochrome, invert, colour cycle | One effects shader per layer | `LAYER_FS` |
| Audio-reactive visuals | Web Audio FFT bands with auto-gain and onset detection, from the mic or the show's audio track | `js/audio.js` |
| MIDI and MIDI learn | Web MIDI. Works in Chrome, Edge and on Android; **not in Safari on iPhone** | `js/audio.js` |
| BPM-synced LFOs, envelopes, tap tempo, macros | Every slider has a modulation menu | `js/model.js`, `js/engine.js` |
| Hand and face tracking | MediaPipe hand and face landmarks (pinch, hand position, face position, mouth open) | `js/vision.js` |
| Scenes with live fade or dissolve; Perform pads | Two-scene render plus a transition shader | `js/engine.js` |
| Timeline with audio track, trim, duplicate and automation | Clips of scenes; automation lanes drive macros | `js/panels.js` |
| Export 720p, 1080p or 4K with audio | Real-time canvas recording (MediaRecorder). On iPhone the share sheet's **Save Video** puts it in Photos | `js/export.js` |
| Export once, play without your phone | **Receiver mode** (`/receive.html`) on any device wired to the projector. Send it the show and it saves and loops it, even after a restart | `js/link.js`, `js/receive.js` |
| HDMI / AirPlay output | Mirror the screen, then tap ⛶ for clean full-screen output. Or use **Live output** to a receiver so the controls stay on your phone | `js/app.js`, `js/link.js` |
| Works offline | A service worker caches the app. Optional AI models and Link need a connection | `public/sw.js` |

## Differences from a native app

- **Second screen:** a web page can't drive a separate HDMI display. It mirrors, so use projector mode (⛶), or Live output to a receiver to keep the controls private.
- **MIDI:** Safari on iPhone has no Web MIDI.
- **Export:** recording runs in real time, so a 3-minute show takes 3 minutes. Keep the app in the foreground.
- **Link:** connections are brokered by the free public PeerJS server. Video goes directly device to device over WebRTC when the network allows.

## Native iOS version

`native-ios/` has an earlier Swift/SwiftUI/Metal version of the same app. It needs a Mac with Xcode to build and has not been compiled. The web app above replaces it.
