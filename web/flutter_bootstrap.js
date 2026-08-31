{{flutter_js}}
{{flutter_build_config}}

// CanvasKit renders on the CPU here because on Safari it exhausts WebGL
// contexts. Safari caps a page at ~16; a single session logged 289 creations,
// and past the cap Safari kills the oldest context, the engine replaces it, and
// the cap is hit again — an unrecoverable loop that renders as the whole UI
// blinking, unable to reach even the sign-in form. Confirmed 2026-08-31: CPU
// rendering is stable, engine defaults still blink.
//
// Not the renderer's fault in the sense of being fixable by switching it —
// skwasm leaks identically. Nor ours: the app builds no WebGL surfaces of its
// own (no HtmlElementView, CustomPaint, Image widgets or platform views), which
// is also why the known upstream issues do not apply.
//
// `renderer` keeps the alternatives one URL away, since this trades GPU
// rasterization for stability and the tradeoff may be worth revisiting:
//   ?renderer=gpu    back on the GPU, capped to one surface — UNTESTED
//   ?renderer=stock  engine defaults; reproduces the blinking
const renderer = new URLSearchParams(window.location.search).get('renderer');

const rendererConfig = {
  gpu: { canvasKitMaximumSurfaces: 1 },
  stock: {},
}[renderer] ?? { canvasKitForceCpuOnly: true };

_flutter.loader.load({
  serviceWorkerSettings: {
    serviceWorkerVersion: {{flutter_service_worker_version}}
  },
  config: rendererConfig,
});
