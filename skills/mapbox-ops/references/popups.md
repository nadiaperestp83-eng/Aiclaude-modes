# Popups

## Circular photo card needs `overflow: visible`

A circular photo popup (a disc with its own ring + drop-shadow) gets **square-clipped**
by the base `.mapboxgl-popup-content` rule, which sets `overflow: hidden`. That clips
the circle's drop-shadow into hard square corners. Override it on a custom class, make
the popup chrome transparent (the disc carries its own ring/shadow), and hide the tip:

```css
.pop-photo .mapboxgl-popup-content {
  background: transparent; box-shadow: none; padding: 0; border-radius: 0;
  overflow: visible;            /* essential — base rule clips the round shadow square */
}
.pop-photo .mapboxgl-popup-tip { display: none; }
.pop-circle {
  width: 228px; height: 228px; border-radius: 50%; overflow: hidden;
  border: 6px solid #355e3b; box-shadow: 0 6px 22px rgba(0,0,0,.30);
}
.pop-circle img { width: 100%; height: 100%; object-fit: cover; display: block; }
```

```js
new mapboxgl.Popup({ offset: photoPopupOffset(), closeButton:false,
                     closeOnClick:true, className:"pop-photo", maxWidth:"none" })
  .setLngLat(e.lngLat).setHTML(`<div class="pop-circle"><img src="${url}"></div>`).addTo(map);
```

## Scale the popup offset by icon-size

If the marker scales with zoom, a fixed popup `offset` leaves a gap that's wrong at
most zooms. Compute the offset from the current icon-size so the card **hugs** its
marker at every zoom. `Popup` offset accepts a per-anchor object so the gap is right
whether the card lands above, below, or beside the marker:

```js
function photoPopupOffset() {
  const clear = Math.round(40 * photoIconSize(map.getZoom()) + 6);  // tip→top + small gap
  return { bottom:[0,-clear], top:[0,14], left:[14,0], right:[-14,0] };
}
```

Where `photoIconSize(z)` mirrors the symbol layer's `icon-size` zoom ramp (interpolate
the same stops in JS), so the popup tracks the rendered marker exactly.

## Dismissal & cursor niceties

- `closeButton:false` + `closeOnClick:true` → no X button; click anywhere off the
  popup to dismiss (hide the default close button via
  `.mapboxgl-popup-close-button{display:none}` if a stray one appears).
- Pointer cursor on interactive layers:
  ```js
  for (const lyr of ["clusters","poi-glyph","poi-photo"]) {
    map.on("mouseenter", lyr, () => map.getCanvas().style.cursor = "pointer");
    map.on("mouseleave", lyr, () => map.getCanvas().style.cursor = "");
  }
  ```
- Animate only opacity (`@keyframes` on `.mapboxgl-popup`) — Mapbox owns the
  positioning `transform`, so don't animate transform or the popup jumps.
