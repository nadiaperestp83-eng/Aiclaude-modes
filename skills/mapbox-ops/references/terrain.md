# Terrain: hillshade, contours, 3D

All three use Mapbox-hosted tilesets available to **any** access token — no special
entitlement needed.

## Hillshade (shaded relief)

A `raster-dem` source + a `hillshade` layer. **`hillshade-exaggeration` max is 1.0.**

```js
map.addSource("rc-dem", { type:"raster-dem",
  url:"mapbox://mapbox.mapbox-terrain-dem-v1", tileSize:512, maxzoom:14 });
map.addLayer({ id:"rc-hillshade", type:"hillshade", source:"rc-dem",
  paint:{ "hillshade-exaggeration":1.0,            // 1.0 = max
          "hillshade-shadow-color":"#4a3f30",
          "hillshade-highlight-color":"#faf6ec",
          "hillshade-accent-color":"#6e5b42" }}, firstSymbolLayerId);
```

## Contours (altitude lines)

A **vector** source `mapbox://mapbox.mapbox-terrain-v2`, source-layer **`"contour"`** —
far denser than the sparse contours most base styles ship (down to ~10 m where
available). The `index` field flags the **index lines** (every 5th/10th) for heavier
styling. Draw a fine base set + a bolder filtered index set:

```js
map.addSource("rc-terrain", { type:"vector", url:"mapbox://mapbox.mapbox-terrain-v2" });
map.addLayer({ id:"rc-contour", type:"line", source:"rc-terrain", "source-layer":"contour",
  layout:{"line-join":"round"},
  paint:{ "line-color":"#7a5733",
    "line-width":["interpolate",["linear"],["zoom"], 12,0.4, 16,0.85],
    "line-opacity":["interpolate",["linear"],["zoom"], 11,0.20, 14,0.34, 17,0.44] }},
  firstSymbolLayerId);
map.addLayer({ id:"rc-contour-index", type:"line", source:"rc-terrain", "source-layer":"contour",
  filter:[">=",["coalesce",["get","index"],0],5],   // index (every 5th/10th) lines, bolder
  layout:{"line-join":"round"},
  paint:{ "line-color":"#5e3f1d",
    "line-width":["interpolate",["linear"],["zoom"], 12,0.9, 16,1.7],
    "line-opacity":["interpolate",["linear"],["zoom"], 11,0.30, 14,0.48, 17,0.58] }},
  firstSymbolLayerId);
```

## 3D terrain (extruded DEM + tilted camera)

`map.setTerrain` extrudes the DEM; tilt the camera and let the user rotate it:

```js
map.addControl(new mapboxgl.NavigationControl({ visualizePitch:true }), "bottom-right");
// enable
map.setTerrain({ source:"rc-dem", exaggeration:1.4 });
map.easeTo({ pitch:64, duration:900 });
// disable
map.setTerrain(null);
map.easeTo({ pitch:0, bearing:0, duration:700 });
```

`visualizePitch:true` shows the pitch on the compass. Right-drag / ctrl-drag rotates &
pitches the camera. When re-fitting bounds after enabling 3D, preserve the camera:
`map.fitBounds(b, { pitch: map.getPitch(), bearing: map.getBearing() })`.

## Boost-or-add pattern (respect the base style)

> **Classic styles only.** The `getStyle().layers` walk below finds named layers that
> exist in classic styles but **not** in the v3 Standard style (which exposes no
> enumerable basemap layers). On Standard, add your DEM/contour layers via a `slot` and
> skip the boost step — see [v3-standard-style.md](v3-standard-style.md).

Don't blindly add tilesets — the chosen style may already ship hillshade/contours.
Walk `map.getStyle().layers`: **boost** an existing hillshade (match by `type`) or
contour (match by id regex); **add** the Mapbox tilesets only if absent. Insert added
layers **beneath the first `symbol` layer** so labels stay on top.

```js
function setupTerrain() {
  const layers = map.getStyle().layers || [];
  const firstSymbol = (layers.find(l => l.type === "symbol") || {}).id;  // sit beneath labels
  let hasHill = false;
  for (const ly of layers) {
    if (ly.type === "hillshade") {                 // boost the style's own hillshade
      hasHill = true;
      map.setPaintProperty(ly.id, "hillshade-exaggeration", 1.0);
      map.setPaintProperty(ly.id, "hillshade-shadow-color", "#4a3f30");
    }
    if (/contour/i.test(ly.id) && ly.type === "line") {   // hide its sparse contour lines
      map.setLayoutProperty(ly.id, "visibility", "none"); // (keep contour LABELS — the numbers)
    }
  }
  if (!hasHill) { /* addSource rc-dem + addLayer rc-hillshade above, before firstSymbol */ }
  /* always add the dense Terrain-v2 contours above, before firstSymbol */
}
```

Track every layer id you boosted or added in one array so a single "Terrain" toggle
can flip them all with `setLayoutProperty(id, "visibility", …)`.
