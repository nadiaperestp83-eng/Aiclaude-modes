# v3 Standard style — slots, config, and why layer-walking breaks

GL JS v3 introduced the **Standard** style (`mapbox://styles/mapbox/standard`) — a 3D,
composited basemap that is now the default in Mapbox Studio. It behaves **differently
from the classic styles** (Streets/Outdoors/Light/Dark, `…-v11`/`-v12`), and several
techniques in this skill assume classic styles. Read this before applying them to
Standard.

## Classic vs Standard — which am I on?

| | Classic (`outdoors-v12`, `streets-v12`, …) | Standard (`standard`, `standard-satellite`) |
|---|---|---|
| Layers | Hundreds of **named, enumerable** layers (`land`, `landuse`, `contour`, `poi-label`) | A **single composited basemap** — `getStyle().layers` shows only a few opaque entries |
| Insert position | `addLayer(layer, beforeId)` | `addLayer({…, slot})` — **`"bottom"` / `"middle"` / `"top"`** |
| Recolour basemap | `setPaintProperty` on named fill layers | **`setConfigProperty("basemap", …)`** — not arbitrary recolour |
| Light / time of day | n/a | `setConfigProperty("basemap","lightPreset","dawn\|day\|dusk\|night")` |
| 3D buildings/terrain | add yourself | built in |

## What this changes in this skill

- **[palette.md](palette.md)** (recolouring `land`/`landuse`/`landcover-outdoors`) and
  the **boost-or-add `getStyle().layers` walk** in **[terrain.md](terrain.md)** assume
  **classic** styles. On Standard those layer ids don't exist, so the walk finds nothing
  and the `setPaintProperty` calls no-op. The trail-map source uses
  `outdoors-v12` (classic), so that code is correct **there** — just don't port it to a
  Standard-style page unchanged.
- For a green/verdant look on **Standard**, you can't recolour vegetation per-class; pick
  a `lightPreset`, or use a classic style / a custom Studio style instead.

## Inserting your layers with `slot`

On Standard, place custom layers in a slot so the basemap's labels/roads stay correctly
above/below them:

```js
map.addLayer({ id:"trail-line", type:"line", source:"trail", slot:"middle",
  paint:{ /* … */ } });   // "bottom" under everything, "top" above roads/labels
```

`slot` and `beforeId` are mutually exclusive. A `beforeId` referencing a classic layer id
silently fails on Standard — use `slot`.

## Configuring the basemap

```js
map.on("style.load", () => {
  map.setConfigProperty("basemap", "lightPreset", "dusk");
  map.setConfigProperty("basemap", "showPointOfInterestLabels", false);  // hide POI labels
  map.setConfigProperty("basemap", "show3dObjects", true);
});
```

(On classic styles you'd instead `setLayoutProperty("poi-label","visibility","none")` —
see [palette.md](palette.md).) Available config keys vary by style; read them from the
style's `schema`/imports or the Mapbox Standard docs.

## Other v3 niceties

- **Localisation**: `map.setLanguage("fr")` / `map.setWorldview("CN")` (v3, all styles).
- **RTL text**: `mapboxgl.setRTLTextPlugin(url, null, true)` once, before adding Arabic/
  Hebrew labels, or they render left-to-right and disjointed.
- **Globe**: v3 defaults to `projection:"globe"` at low zoom; set
  `map.setProjection("mercator")` if a flat map is required (e.g. for pixel-exact
  `project()` overlays).
