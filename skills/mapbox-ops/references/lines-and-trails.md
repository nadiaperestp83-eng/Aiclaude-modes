# Lines & trails

## `line-dasharray` units are line-widths

The two numbers in `line-dasharray: [dash, gap]` are measured in **line-widths**, not
pixels — so the pattern stays proportional as `line-width` changes. **Solid line =
`[1, 0]`.**

Gotcha: with `line-cap: "round"` each dash is extended by ~½ a line-width on **each
end**, so neighbouring dashes **merge** and the gaps disappear. Fixes:

- Widen the gap (e.g. `[1.1, 1.8]` instead of `[1.1, 0.6]`), or
- Use `line-cap: "butt"` (square ends, no extension).

```js
map.setPaintProperty("trail-line", "line-dasharray", isDashed ? [1.1, 1.8] : [1, 0]);
```

## Casing + line split

Draw two stacked line layers from the same source: a wider **casing** underneath and
the coloured **line** on top. Use zoom-interpolated widths so the trail reads at every
scale:

```js
const trailWidth  = s => ["interpolate",["linear"],["zoom"], 11,3*s, 14,4.5*s, 17,6*s];
const casingWidth = s => ["interpolate",["linear"],["zoom"], 11,5*s, 14,7.5*s, 17,10*s];
map.addLayer({ id:"trail-casing", type:"line", source:"trail",
  layout:{"line-join":"round","line-cap":"round"},
  paint:{"line-color":"#fff","line-opacity":0,"line-width":casingWidth(1)} });
map.addLayer({ id:"trail-line", type:"line", source:"trail",
  layout:{"line-join":"round","line-cap":"round"},
  paint:{"line-color":ACCENT,"line-opacity":1,"line-width":trailWidth(1),
         "line-dasharray":[1.1,1.8]} });
```

## Translucency over hillshade = lies-on-the-terrain look

A **translucent** trail line over a hillshade layer lets the terrain shading **bleed
through**, so the line reads as lying *on* the 3D relief rather than floating above
it. Cheap and convincing — drop `line-opacity` toward ~0.7:

```js
map.setPaintProperty("trail-line", "line-opacity", 0.7);   // hillshade shades the line
```

(For the hillshade itself see [terrain.md](terrain.md).)

## Colour by attribute (difficulty grading)

Data-driven colour via a `match` expression. Coerce the field to string first — the
same dataset often stores the grade as a number in one layer and a string in another:

```js
const DIFF_COLOR = ["match",["to-string",["coalesce",["get","Difficulty"],""]],
  "1","#2e7d32", "2","#7cb342", "3","#f9a825", "4","#ef6c00", "5","#c62828",
  /* fallback */ "#cc7d45"];
map.setPaintProperty("trail-line", "line-color", DIFF_COLOR);
```

## `line-gradient` (needs `lineMetrics`)

To colour a line *along its length* (elevation, speed, progress), use `line-gradient`
over `["line-progress"]` (0→1). Two hard requirements or it **silently renders nothing**:

- the **source** must set `lineMetrics: true` (not the layer — the source);
- the layer must **not** also use `line-dasharray` — they're mutually exclusive.

```js
map.addSource("trail", { type:"geojson", data: fc, lineMetrics: true });   // REQUIRED
map.addLayer({ id:"trail-grad", type:"line", source:"trail",
  layout:{"line-cap":"round"},
  paint:{ "line-width":5, "line-gradient":["interpolate",["linear"],["line-progress"],
    0,"#2e7d32", 0.5,"#f9a825", 1,"#c62828"] }});
```

## Direction arrows along the line

A repeating chevron icon placed along the line, auto-rotated to the line direction:

```js
map.addLayer({ id:"trail-arrows", type:"symbol", source:"trail",
  layout:{ "symbol-placement":"line", "symbol-spacing":68, "icon-image":"rc-arrow",
    "icon-size":["interpolate",["linear"],["zoom"], 12,0.32, 16,0.55],
    "icon-rotation-alignment":"map", "icon-allow-overlap":true,
    "icon-ignore-placement":true }});
```

Draw the chevron pointing **east** (0°); Mapbox rotates it to the segment bearing. Give
it a dark halo stroke under a white stroke so it reads on any basemap.
