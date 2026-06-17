# Lifecycle, resize, teardown, tokens

## `setStyle` wipes your custom layers

`map.setStyle(url)` replaces the **entire** style — every `addSource`/`addLayer`/
`addImage` you made is gone. (The default `{diff:true}` only preserves things when
diffing *within* a style; switching base styles is a full swap.) Re-install on the
`style.load` event, driven by one idempotent installer you also call at init:

```js
function installCustom() {
  if (!map.getSource("pts")) map.addSource("pts", {/* … */});
  if (!map.getLayer("pts"))  map.addLayer({/* … */});
  // re-register images too — they're cleared with the style
}
map.on("load", installCustom);
map.on("style.load", installCustom);   // fires after every setStyle
map.setStyle("mapbox://styles/mapbox/dark-v11");   // triggers style.load
```

Guard every re-add with `getSource`/`getLayer`/`hasImage` so the init path and the
style-swap path share one function without double-add errors.

## The 0×0 / half-rendered map → `map.resize()`

A map initialised in a container that was `display:none`, in a collapsed flexbox cell, or
inside a tab/accordion shown *after* init, renders at the wrong size (blank, clipped, or
offset clicks). Call **`map.resize()`** once the container has real dimensions:

```js
new ResizeObserver(() => map.resize()).observe(document.getElementById("mapwrap"));
// or after revealing a tab:  showTab(); map.resize();
```

## Teardown — `map.remove()` and the WebGL-context cap

Browsers allow only **~16 live WebGL contexts**. An SPA that mounts a map on each route
without disposing leaks contexts → eventually *"Too many active WebGL contexts"* and maps
go blank. Always dispose:

```js
// React: useEffect cleanup. Vue: onBeforeUnmount. Plain: before removing the container.
map.remove();   // frees the GL context, sources, workers, and listeners
```

`map.remove()` also drops all event handlers, so you don't need to unbind them first; but
do clear external observers (the `ResizeObserver` above) and any `setInterval`/RAF loops.

## Tokens — web security

- Web pages use a **public token** (`pk.…`). **Restrict it by URL** in your Mapbox
  account so a copied token can't be used off your domains.
- **Never ship a secret token** (`sk.…`) in client code — it can create/delete tokens and
  styles. Secret tokens are for server/build/upload only.
- Rotating a leaked `pk.` token is a dashboard click; a leaked `sk.` is an incident.

## Map readiness signals

- `'load'` — style + first viewport loaded (add sources/layers after this). May be
  missed in a background tab → also bind `'idle'` once (see
  [verification.md](verification.md)).
- `'idle'` — no more loading/rendering pending (good "everything settled" signal).
- `'style.load'` — fires after each `setStyle`.
- `map.loaded()` / `map.isStyleLoaded()` — synchronous checks for headless waits.
