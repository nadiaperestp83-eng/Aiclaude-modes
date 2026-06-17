# Expressions

Mapbox style expressions drive data- and zoom-dependent styling. The footguns below
are the ones that cost real time.

## The zoom-outermost rule (the big one)

A **`["zoom"]`** expression may only appear as the **top-level input to an
`interpolate` or `step`**. You **cannot nest it deeper** — not inside a `match`/`case`
branch, not as an inner input to another expression, not in a `filter`. Violating it
throws *"zoom expressions are not supported"* (or silently no-ops in some contexts).

To vary by **both zoom and data**, put the zoom `interpolate` **outermost** and a data
expression in each **stop output**:

```js
// WRONG — zoom nested inside match → error
["match", ["get","kind"], "big", ["interpolate",["linear"],["zoom"], 10,2, 16,6], 1]

// RIGHT — zoom outermost, data expression per stop
["interpolate", ["linear"], ["zoom"],
  10, ["match", ["get","kind"], "big", 2, 1],
  16, ["match", ["get","kind"], "big", 6, 3]]
```

## `step` vs `interpolate`

- **`interpolate`** — smooth blend between stops (sizes, opacities, colours, widths).
  `["interpolate",["linear"],["zoom"], 11,3, 17,6]`. Use `["exponential",base]` for a
  perceptually even ramp across many zooms.
- **`step`** — hard jumps at thresholds (discrete tiers, e.g. cluster colour buckets).
  `["step",["get","point_count"], "#0f0", 10,"#ff0", 100,"#f00"]`.

## `match` vs `case`

- **`match`** — switch on one input against literal values (fast, readable). Values can
  be arrays to share an output. Last arg is the **mandatory default**.
  `["match",["get","class"], ["wood","grass"],"#bcd29c", "#dde4d0"]`
- **`case`** — ordered boolean conditions (ranges, compound logic). Last arg is the else.
  `["case", ["<",["get","h"],100],"#0f0", ["<",["get","h"],500],"#ff0", "#f00"]`

`match` only tests equality; the moment you need `<`/`>`/`&&`, switch to `case`.

## `coalesce` for missing data

Fields are often absent or typed inconsistently. Guard with `coalesce` (first non-null)
and `to-string`/`to-number` to normalise:

```js
["match", ["to-string", ["coalesce", ["get","Difficulty"], ""]],
  "1","#2e7d32", /* … */ "#cc7d45"]
```

## `feature-state` in expressions (hover/selection)

`["feature-state","hover"]` reads runtime state set by `map.setFeatureState` — the
canonical hover/highlight pattern (no `setData`, see
[interaction-and-performance.md](interaction-and-performance.md)). Constraints:

- **Paint properties only** — not layout, not `filter`.
- The source feature needs a **stable id** (`generateId:true` or `promoteId`).
- Default with `coalesce`, since state is undefined until first set:
  `["case", ["boolean",["feature-state","hover"],false], "#ff0", "#888"]`

## Debugging

`map.queryRenderedFeatures(point)[0].layer.paint` and the GL JS console error messages
name the offending sub-expression. Build complex expressions incrementally — Mapbox
validates the whole tree and a single type mismatch rejects all of it.
