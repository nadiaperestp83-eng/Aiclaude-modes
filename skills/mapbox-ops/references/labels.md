# Symbol-layer text labels

## Labels that never hide the icon (AllTrails style)

Put `text-field` on the **same symbol layer** as the icon, with `text-optional: true`
+ `text-allow-overlap: false`. The result: **icons always render**; labels auto-hide
only where they would collide, and **reappear as you zoom in**. No data is lost.

```js
map.addLayer({ id:"poi-glyph", type:"symbol", source:"pois",
  layout:{
    "icon-image":["get","_iconimg"], "icon-anchor":"center", "icon-allow-overlap":true,
    // label centred BELOW the marker:
    "text-field":["coalesce",["get","_label"],""],
    "text-size":11.5, "text-anchor":"top", "text-offset":[0,0.9],
    "text-justify":"center", "text-max-width":8,
    "text-optional":true,            // icon stays even if label is dropped
    "text-allow-overlap":false       // labels declutter against each other
  },
  paint:{ "text-color":"#3f4035", "text-halo-color":"#fff", "text-halo-width":1.6 }});
```

Key combination:
- `text-anchor:"top"` + `text-offset:[0, Y]` → label sits **centred below** the marker.
- `text-optional:true` is what protects the icon — without it, a dropped label drops
  the whole symbol (icon included).
- `text-allow-overlap:false` (the default) lets crowded labels declutter.

## Line labels (trail name along the path)

```js
map.addLayer({ id:"trail-label", type:"symbol", source:"trail",
  layout:{ "symbol-placement":"line", "text-field":["coalesce",["get","Name"],""],
           "text-size":12, "text-letter-spacing":0.02 },
  paint:{ "text-color":"#753c1c", "text-halo-color":"#fff", "text-halo-width":2 }});
```

## Toggle labels on/off at runtime

Set `text-field` to `""` to hide, restore the expression to show — no layer rebuild:

```js
map.setLayoutProperty("poi-glyph", "text-field",
  showLabels ? ["coalesce",["get","_label"],""] : "");
```
