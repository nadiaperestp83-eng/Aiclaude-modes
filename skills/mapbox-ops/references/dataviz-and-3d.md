# Data viz & 3D

Thematic mapping (choropleth, heatmap, proportional symbols) and extruded 3D. Colour-
ramp *theory* (sequential/diverging, contrast, CVD) belongs to the related `color-ops`
skill — this file is the **Mapbox wiring** and its footguns.

## Table of contents
- [fill-extrusion — 3D buildings & extruded data](#fill-extrusion--3d-buildings--extruded-data)
- [Heatmap layer](#heatmap-layer)
- [Data-join choropleth (your data isn't in the tiles)](#data-join-choropleth-your-data-isnt-in-the-tiles)
- [Proportional symbols (√ scaling)](#proportional-symbols--scaling)
- [Sky & atmosphere](#sky--atmosphere)

## fill-extrusion — 3D buildings & extruded data

Two uses: the basemap's buildings, or **your own** polygons (parcels, footprints, 3D
bar/prism maps).

```js
// Basemap buildings (CLASSIC styles): composite source, source-layer "building".
map.addLayer({ id:"3d-buildings", type:"fill-extrusion", source:"composite",
  "source-layer":"building", filter:["==",["get","extrude"],"true"], minzoom:15,
  paint:{
    "fill-extrusion-color":"#ccc",
    "fill-extrusion-height":["get","height"],          // metres, from the tile
    "fill-extrusion-base":["get","min_height"],
    "fill-extrusion-opacity":0.85,
    "fill-extrusion-vertical-gradient":true }});
```

Footguns:
- **Buildings only exist ~zoom 15+** and are **invisible without camera pitch** —
  `map.easeTo({pitch:55})` or you'll swear nothing rendered.
- Heights are **metres**. With terrain on, extrusions drape on the DEM (height is *above*
  ground), which is usually what you want — but a `fill-extrusion-base` from sea-level
  data will float/sink.
- Extrusions render in a **single pass** — you can't interleave other layers between
  faces by z-order; `fill-extrusion-opacity` < 1 looks wrong (faces show through). Keep
  them near-opaque.
- **v3 Standard** ships 3D buildings + landmarks built-in
  (`setConfigProperty("basemap","show3dObjects",true)`), and has no `composite`/`building`
  layer to target — custom `fill-extrusion` there is only for **your own** data. See
  [v3-standard-style.md](v3-standard-style.md).

Extruding your own data is the same layer with a geojson source and height from a
property: `"fill-extrusion-height":["*",20,["get","stories"]]`.

## Heatmap layer

Four knobs, and they interact with zoom:

```js
map.addLayer({ id:"heat", type:"heatmap", source:"pts", maxzoom:15,
  paint:{
    // per-point contribution (data-driven weight)
    "heatmap-weight":["interpolate",["linear"],["get","mag"], 0,0, 6,1],
    // global multiplier — ramp UP with zoom so density stays readable
    "heatmap-intensity":["interpolate",["linear"],["zoom"], 0,1, 15,3],
    // radius in SCREEN px — ramp with zoom or it blobs/vanishes
    "heatmap-radius":["interpolate",["linear"],["zoom"], 0,2, 15,20],
    // colour ramp over density 0..1 — stop 0 MUST be transparent
    "heatmap-color":["interpolate",["linear"],["heatmap-density"],
      0,"rgba(0,0,255,0)", 0.2,"#80f", 0.5,"#f0f", 1,"#f00"],
    "heatmap-opacity":["interpolate",["linear"],["zoom"], 13,1, 15,0] }});
```

Footguns:
- **`heatmap-color` stop 0 must be `rgba(...,0)`** — a solid colour at density 0 washes
  the entire canvas.
- `heatmap-radius` is **screen pixels**, so apparent density shifts with zoom; ramp
  `radius`/`intensity` across zoom and **fade to a `circle` layer** past `maxzoom` (the
  `heatmap-opacity`→0 + a circle layer taking over at high zoom is the standard handoff).

## Data-join choropleth (your data isn't in the tiles)

Vector tiles carry geometry + a key (FIPS, postcode), **not your statistics**. Join at
runtime, two ways:

**1. `feature-state`** — best for interactive / changing data. Key on `promoteId`:

```js
map.addSource("counties", { type:"vector", url:"mapbox://…",
  promoteId:{ "county": "FIPS" } });          // per-source-layer key → stable id
map.addLayer({ id:"choro", type:"fill", source:"counties", "source-layer":"county",
  paint:{ "fill-color":["interpolate",["linear"],
    ["coalesce",["feature-state","rate"],0], 0,"#eee", 100,"#900"] }});

function applyData(rows){                       // rows: {fips, rate}
  for (const r of rows)
    map.setFeatureState({source:"counties", sourceLayer:"county", id:r.fips}, {rate:r.rate});
}
// GOTCHA: feature-state is LOST when a tile reloads (pan/zoom). Reapply:
map.on("sourcedata", e => { if (e.sourceId==="counties" && e.isSourceLoaded) applyData(DATA); });
```

**2. `match` expression** — fine for **static, small/medium** sets; bakes data into the
style. A huge `match` (thousands of entries) bloats the style and re-evals on every
frame — use feature-state past a few hundred features.

```js
"fill-color":["match",["get","FIPS"], "06001","#900", "06003","#c44", /* … */ "#eee"]
```

## Proportional symbols (√ scaling)

Scale `circle-radius` by a value — but radius ∝ value makes big values **dwarf** the rest
(area grows as r²). For honest area perception, radius ∝ **√value**:

```js
"circle-radius":["interpolate",["linear"],["zoom"],
  10, ["*", 2, ["sqrt",["get","pop"]]],
  16, ["*", 6, ["sqrt",["get","pop"]]] ]
```

## Sky & atmosphere

For 3D/terrain/globe scenes, add depth cheaply:

```js
map.setFog({ range:[1,10], "horizon-blend":0.1, color:"#fff", "high-color":"#aaccff" });
// optional sun: map.addLayer({ id:"sky", type:"sky",
//   paint:{ "sky-type":"atmosphere", "sky-atmosphere-sun":[0,5] }});
```

`setFog` is what makes the globe and tilted terrain read as 3D rather than flat.

**Weather (GL JS ≥ 3.7):** `map.setRain({density,intensity,color,opacity})` and
`map.setSnow({density,intensity,flakeSize})` add animated precipitation over the 3D
scene; pass `null` to clear. Dramatic with camera pitch + the Standard `night`/`dusk`
`lightPreset` — see [styles.md](styles.md#visually-dynamic--artistic-styles).
