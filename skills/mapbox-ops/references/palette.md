# Recolouring a base style's palette

Shift an off-the-shelf base style toward a custom palette at runtime with
`setPaintProperty` on its land/vegetation fill layers — no Studio edit, no custom
style upload. Touch only land & vegetation; leave water/roads/labels alone.

> **Classic styles only.** This relies on named, enumerable layers (`land`, `landuse`,
> …) which exist in Streets/Outdoors/Light/Dark but **not** in the v3 Standard style.
> For Standard, use `setConfigProperty` — see [v3-standard-style.md](v3-standard-style.md).

## The layer-type gotcha

The colour property name depends on the layer **type**: a `background` layer uses
`background-color`, a `fill` layer uses `fill-color`. Detect the type per layer:

```js
function setFill(id, val) {
  const ly = map.getLayer(id);
  if (!ly) return;                                   // layer name varies by style — guard
  const prop = (ly.type === "background" ? "background" : "fill") + "-color";
  try { map.setPaintProperty(id, prop, val); } catch (e) {}
}
```

## Green-shift example (Mapbox Outdoors / Streets layer names)

```js
function setupPalette() {
  setFill("land", "#e8ebe0");                                            // base land (background)
  setFill("landcover-outdoors",                                          // vegetation
    ["match",["get","class"], "snow","#ffffff", /* default */ "#c6d4ac"]);
  setFill("national-park", "#aecb8e");
  setFill("landuse", ["match",["get","class"],                          // per-class choropleth
    "park","#bad49b", "pitch","#b2cd8c", "cemetery","#c4d8aa",
    ["wood","grass","scrub"],"#bcd29c", "residential","#e9ece1",
    /* default */ "#dde4d0"]);
}
```

The `["match",["get","class"], …]` form is the general **choropleth** pattern: colour
each feature by a categorical property, with a trailing default. The exact layer ids
(`land`, `landuse`, `landcover-outdoors`, `national-park`) are Mapbox-style-specific —
inspect `map.getStyle().layers` for the style in use and guard every `getLayer`.

## Hiding the basemap's own POI labels

A custom POI layer competes with the style's generic POI labels (its own car-park
"P"s, etc.). Hide the base layer so only your markers show:

```js
if (map.getLayer("poi-label")) map.setLayoutProperty("poi-label", "visibility", "none");
```

## Resolving style + token from `.env` (order matters)

When a token comes from a credential store / `.env`, **resolve the token first** —
that read is what triggers the `.env` load — and only **then** read `MAPBOX_STYLE`. If
you read the style before the token load runs, a style set only in `.env` is invisible
and you silently fall back to the default style. (Python example, but the ordering rule
is general.)

```python
token = resolve_token(cli_token)        # triggers .env load as a side effect
style = cli_style or os.environ.get("MAPBOX_STYLE") or DEFAULT_STYLE   # now .env is loaded
```
