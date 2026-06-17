# Headless verification

Verify a Mapbox page renders and markers land where expected by driving headless
Chromium with Playwright and screenshotting. Pixel-accurate alignment checks use
`map.project(lngLat)`.

## Serve, don't `file://`

A page that `fetch`es GeoJSON/photos at runtime must be **served** (same-origin, or the
canvas taints and `createImageBitmap` throws — see [markers.md](markers.md)):

```bash
python -m http.server 8777 --directory <site-dir>
# open http://localhost:8777/preview/index.html
```

## The `'load'`-in-background-tab quirk

Mapbox's `'load'` event **may not fire** in a throttled / backgrounded / headless tab —
a known harness quirk; the map renders fine in the foreground. Guard your init so
either event triggers it exactly once:

```js
let _inited = false;
function init() { if (_inited) return; _inited = true; /* setup layers, render */ }
map.on("load", init);
map.on("idle", init);   // fallback if the first 'load' frame was missed
```

In Playwright, wait on a DOM/JS signal you control rather than the map's `'load'`:
e.g. set `window.__mapReady = true` at the end of `init()` and
`page.wait_for_function("window.__mapReady === true")`.

## Marker-alignment check via `map.project`

`map.project([lng, lat])` returns the pixel coords **relative to the map canvas**. Add
the canvas's page offset to compare against a screenshot or a DOM-space click:

```js
const m = map.getCanvas().getBoundingClientRect();
const p = map.project([lng, lat]);
const pageXY = { x: m.left + p.x, y: m.top + p.y };   // where the marker's anchor lands
```

The runnable harness — launch chromium, wait for ready, screenshot, and assert a
known lng/lat projects to the expected pixel — is in
[../scripts/screenshot_map.py](../scripts/screenshot_map.py).

## What to assert

- No console errors (`page.on("console", …)`), especially `Image "<name>" already
  exists` (double-`addImage`) or style-load failures.
- The canvas isn't blank (screenshot non-uniform, or `map.loaded() === true`).
- A representative marker's projected pixel falls within the canvas and (optionally)
  over a non-background colour in the screenshot.
