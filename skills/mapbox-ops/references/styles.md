# Style library & composition

Compose maps in a variety of looks: pick a base style by use case, switch styles at
runtime, mix in third-party tiles, or hand-roll a style. The machine-readable catalog is
[../assets/style-catalog.json](../assets/style-catalog.json) — load it to build a style
switcher or to look up a `url` by `use` tag.

## Table of contents
- [First-party style catalog](#first-party-style-catalog)
- [Choose a base by use case](#choose-a-base-by-use-case)
- [Setting & switching styles at runtime](#setting--switching-styles-at-runtime)
- [Light/dark by system preference](#lightdark-by-system-preference)
- [Custom & third-party styles](#custom--third-party-styles)
- [Hand-rolled style JSON](#hand-rolled-style-json)
- [Gotchas](#gotchas)

## First-party style catalog

| Style | URL | Family | Best for |
|---|---|---|---|
| Standard | `mapbox://styles/mapbox/standard` | standard (3D) | v3 default; 3D city, modern, configurable light |
| Standard Satellite | `mapbox://styles/mapbox/standard-satellite` | standard (3D) | 3D + aerial |
| Streets | `mapbox://styles/mapbox/streets-v12` | classic | wayfinding, general reference |
| Outdoors | `mapbox://styles/mapbox/outdoors-v12` | classic | trail/terrain/hillshade |
| Light | `mapbox://styles/mapbox/light-v11` | classic | **dataviz** base (muted) |
| Dark | `mapbox://styles/mapbox/dark-v11` | classic | **dataviz** base (dark) |
| Satellite | `mapbox://styles/mapbox/satellite-v9` | classic | pure imagery (no labels) |
| Satellite Streets | `mapbox://styles/mapbox/satellite-streets-v12` | classic | aerial + labels |
| Navigation Day/Night | `mapbox://styles/mapbox/navigation-{day,night}-v1` | classic | turn-by-turn |

`family` matters: **classic** styles have named, enumerable layers (palette recolour +
the terrain layer-walk work); **standard** is the v3 composited 3D basemap (use slots +
`setConfigProperty`). See [v3-standard-style.md](v3-standard-style.md). Version suffixes
(`-v11`/`-v12`) move — confirm against the Mapbox Styles API before pinning.

## Choose a base by use case

- **Choropleth / heatmap / any thematic data** → `light-v11` or `dark-v11`. A muted base
  lets the data carry the colour; `streets` competes with it. (Or Standard with a
  monochrome `lightPreset`.)
- **Trail / outdoor / elevation** → `outdoors-v12` (ships contours + terrain hooks).
- **Photoreal / inspection** → `satellite-streets-v12` (plain `satellite-v9` has no labels
  or roads — context-free imagery).
- **3D city / showcase** → `standard` with `lightPreset:"dusk"`/`"night"`, or
  `standard-satellite`.
- **Wayfinding / routing** → `streets-v12` or `navigation-*`.

## Setting & switching styles at runtime

Set at init with `style:`; switch with `setStyle()`. **Switching wipes your custom
sources/layers/images** — re-add them on `style.load` via one idempotent installer (full
pattern in [lifecycle.md](lifecycle.md)):

```js
const map = new mapboxgl.Map({ container:"map", style:"mapbox://styles/mapbox/light-v11" });
function installCustom(){ /* guarded addSource/addLayer/addImage */ }
map.on("load", installCustom);
map.on("style.load", installCustom);   // fires after every setStyle

document.querySelector("#styleSwitcher").addEventListener("change", e =>
  map.setStyle(e.target.value));       // installCustom re-runs on style.load
```

A switcher UI can be generated straight from the catalog asset (map each entry to an
`<option value="<url>">`).

## Light/dark by system preference

```js
const dark = matchMedia("(prefers-color-scheme: dark)");
const pick = () => dark.matches ? "mapbox://styles/mapbox/dark-v11"
                                : "mapbox://styles/mapbox/light-v11";
map.setStyle(pick());
dark.addEventListener("change", () => map.setStyle(pick()));
// On the Standard style, prefer one style + setConfigProperty('basemap','lightPreset',
// dark.matches ? 'night' : 'day') — no full reload, keeps custom layers (no re-add).
```

The Standard `lightPreset` route is cheaper and avoids the re-add dance — switch full
styles only when crossing the classic↔standard or imagery↔vector boundary.

## Custom & third-party styles

- **Mapbox Studio**: design → publish → use `mapbox://styles/USERNAME/STYLEID`. This is
  the right home for brand palettes, custom fonts/sprites, and curated layer visibility.
- **Third-party vector tiles** (no Mapbox basemap): pass a full **style-JSON URL** to
  `style:` — MapTiler, Stadia, OpenFreeMap, or Protomaps/PMTiles. These use their **own**
  API key, not a Mapbox token.
- **Mixing**: Mapbox-hosted tilesets used elsewhere in this skill
  (`mapbox.mapbox-terrain-dem-v1`, `mapbox-terrain-v2`) require a **Mapbox** token even on
  a third-party base style — so a fully token-free OSM base can't pull Mapbox DEM/contours.
  Source equivalents (e.g. AWS Terrain-RGB DEM, Terrarium tiles) exist if you must stay
  off Mapbox.

## Visually dynamic & artistic styles

### Standard presets — free, it's the default style

One style, many distinct looks via `setConfigProperty("basemap", …)` (no reload, custom
layers preserved):

- **`lightPreset`** — `"dawn"|"day"|"dusk"|"night"`. `night` lights building windows and
  streetlights; `dusk`/`dawn` cast long shadows. Pair with camera pitch for drama.
- **`theme`** — `"default"|"faded"|"monochrome"`. `monochrome` is a single-hue minimalist
  base (excellent under dataviz); `faded` desaturates so overlays pop.
- Mix `theme` × `lightPreset` for a wide range from a single style.

```js
map.on("style.load", () => {
  map.setConfigProperty("basemap", "lightPreset", "dusk");
  map.setConfigProperty("basemap", "theme", "monochrome");
});
```

### Weather & atmosphere effects (GL JS ≥ 3.7)

Animated, genuinely dynamic — particles over the 3D scene:

```js
map.setRain({ density:0.5, intensity:1.0, color:"#a8adbc", opacity:0.7 });
map.setSnow({ density:0.85, intensity:1.0, flakeSize:0.71 });
map.setRain(null); map.setSnow(null);     // clear
```

Best with camera pitch + Standard `night`/`dusk`. Fog/haze (`setFog`) for globe/terrain
depth lives in [dataviz-and-3d.md](dataviz-and-3d.md#sky--atmosphere). All three are
runtime calls, independent of the chosen style.

### Third-party artistic basemaps

Pass these as **style-JSON URLs** to `style:` / `setStyle()`. They use their **own** key +
attribution (not a Mapbox token) and can't pull Mapbox-hosted DEM/contours
([see Mixing](#custom--third-party-styles)).

| Source | Standout looks | Key? |
|---|---|---|
| **Stadia / Stamen** | **Watercolor** (hand-painted), **Toner** (high-contrast B&W), Terrain | key (free tier) |
| **CARTO** | Positron, **Dark Matter**, Voyager — clean dataviz classics | no key (attribution) |
| **Thunderforest** | **Spinal Map** (Tron-like), **Atlas** (vintage sepia), Pioneer, Transport | key (freemium) |
| **Protomaps** | light/dark/white/black/grayscale/**contrast**; single-file PMTiles | no key (self-host) |
| **OpenFreeMap** | Liberty, Bright, Positron | no key |
| **MapTiler** | Backdrop, Dataviz, Toner, Topo, **Winter**, **Ocean**, Bright | key |

Stamen **Watercolor** and Thunderforest **Atlas** are the showstoppers for a painterly /
vintage look; CARTO **Dark Matter** + glowing data is the canonical "dashboard at night".
Exact style URLs live in [../assets/style-catalog.json](../assets/style-catalog.json).

### Roll your own dramatic look (e.g. synthwave / neon)

For a bespoke neon/synthwave style (à la a night flight-sim), start from a near-black
base and lean on glow: `line-color` in magenta/cyan with a wide, low-opacity `line-blur`
casing under a bright thin line; `fill-extrusion` buildings in a dark hue with a neon
edge; `setFog` with a saturated `high-color`. Build it in Studio (publish → `mapbox://`)
or hand-roll the style JSON (next section). This composes with camera pitch + a `night`
`lightPreset` for the full effect.

## Hand-rolled style JSON

A style is just JSON (spec **version 8**): `sources`, `layers`, plus `sprite`, `glyphs`,
and optional `light`/`fog`/`terrain`/`projection`. Build a bespoke base by passing an
object instead of a URL:

```js
const map = new mapboxgl.Map({ container:"map", style:{
  version: 8,
  glyphs: "mapbox://fonts/mapbox/{fontstack}/{range}.pbf",   // REQUIRED for any text label
  sources: { osm: { type:"raster", tiles:["https://tile.openstreetmap.org/{z}/{x}/{y}.png"], tileSize:256 } },
  layers: [
    { id:"bg", type:"background", paint:{ "background-color":"#e8ebe0" } },
    { id:"osm", type:"raster", source:"osm" }
  ]
}});
```

To tweak an existing base instead of starting blank: fetch its style JSON
(`https://api.mapbox.com/styles/v1/mapbox/light-v11?access_token=…`), edit, and pass the
object.

## Gotchas

- **`version: 8`** is mandatory in a hand-rolled style; anything else fails to load.
- **No `glyphs` URL → no text labels** render (silent). **No `sprite` → no icon-image**
  sprite icons.
- `satellite-v9` is imagery only — no labels/roads; use `satellite-streets` for context.
- Switching styles loses custom layers — always re-add on `style.load`
  ([lifecycle.md](lifecycle.md)).
- classic vs standard changes which techniques apply ([v3-standard-style.md](v3-standard-style.md)).
