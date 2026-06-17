# Interaction & performance

## Hover/select via `feature-state`, NOT `setData`

Re-running `source.setData(...)` to highlight a feature re-parses and re-tiles the whole
collection every mouse-move — janky on anything but tiny data. Instead set **feature
state** and read it in a paint expression (see [expressions.md](expressions.md)):

```js
map.addSource("pts", { type:"geojson", data: fc, generateId: true });  // stable ids
map.addLayer({ id:"pts", type:"circle", source:"pts",
  paint:{ "circle-color":
    ["case",["boolean",["feature-state","hover"],false], "#ff0", "#3887be"] }});

let hovered = null;
map.on("mousemove", "pts", (e) => {
  if (hovered !== null) map.setFeatureState({source:"pts", id:hovered}, {hover:false});
  hovered = e.features[0].id;
  map.setFeatureState({source:"pts", id:hovered}, {hover:true});
});
map.on("mouseleave", "pts", () => {
  if (hovered !== null) map.setFeatureState({source:"pts", id:hovered}, {hover:false});
  hovered = null;
});
```

Ids: `generateId:true` assigns sequential ids; **`promoteId:"myKey"`** uses an existing
property as the id (survives `setData`, unlike generated ids). Feature-state needs one.
Vector-tile sources need `promoteId` keyed per source-layer.

## `queryRenderedFeatures` caveats

- Returns only features **currently rendered in the viewport** — nothing off-screen,
  nothing in a hidden layer. Not a data query.
- Returns **duplicates** for features spanning tile boundaries → **dedupe by id**.
- Bare `map.queryRenderedFeatures(point)` hits every layer; pass `{layers:[...]}`.
- For all loaded features regardless of viewport use `querySourceFeatures(source,
  {sourceLayer})` — but it's unordered and may return tile-clipped fragments.

## Clustering

```js
map.addSource("pois", { type:"geojson", data: fc, cluster:true,
  clusterRadius:45, clusterMaxZoom:12,
  // aggregate per cluster — sum/any/etc. over member features
  clusterProperties:{ photos:["+",["case",["has","photo"],1,0]] } });
```

Click a cluster → expand to the zoom that breaks it up:

```js
map.on("click","clusters",(e)=>{
  const f = map.queryRenderedFeatures(e.point,{layers:["clusters"]})[0];
  map.getSource("pois").getClusterExpansionZoom(f.properties.cluster_id,(err,z)=>{
    if(!err) map.easeTo({center:f.geometry.coordinates, zoom:z});
  });
});
```

Gotcha: **feature-state doesn't propagate to clustered children** — hover/select on the
unclustered points layer, not the cluster circles.

## GeoJSON source performance

- Prefer **one source updated by setData** over many small sources; batch updates.
- `tolerance` (default 0.375) simplifies geometry — raise it for dense lines you view
  zoomed out; lower for crisp detail.
- For very large static data, serve **vector tiles** (tippecanoe → `.mbtiles` →
  hosted/`pmtiles`) instead of a megabyte GeoJSON; GL JS streams only visible tiles.
- `buffer` and `lineMetrics:true` (needed for `line-gradient`) cost memory — enable only
  when used.

## Event hygiene

- Layer-scoped `map.on("click", layerId, fn)` only fires for that layer's features;
  map-wide `map.on("click", fn)` fires everywhere (use for "click empty map to deselect").
- Pointer cursor: `mouseenter`/`mouseleave` per interactive layer toggling
  `map.getCanvas().style.cursor`.
- Remove listeners on teardown (see [lifecycle.md](lifecycle.md)); anonymous handlers
  can't be removed — keep named refs if the layer is transient.
