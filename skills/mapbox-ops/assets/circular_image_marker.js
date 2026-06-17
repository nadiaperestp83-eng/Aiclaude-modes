// Register a circular photo marker as a Mapbox GL JS map image.
//
// Why a canvas + ImageBitmap (not a DOM mapboxgl.Marker, not ctx.clip()):
//   - addImage symbol layers batch/cluster/GPU-draw — DOM markers don't.
//   - createImageBitmap() yields PREMULTIPLIED alpha → no white fringe at the AA edge
//     (a raw HTMLImageElement/ImageData fringes a halo).
//   - the disc is masked with destination-in (an anti-aliased arc FILL) on a scratch
//     canvas, NOT ctx.clip() (clip is a 1-bit hard mask → jagged circle).
//
// Namespace the name ("rcphoto-…") so it can't collide with a basemap sprite icon
// (an un-namespaced hasImage() can return true for the style's sprite and silently
// drop your image).
//
// Same-origin: the photo must be same-origin (or CORS-enabled) or the canvas taints
// and createImageBitmap throws.
//
// Usage:
//   await addCircularPhotoMarker(map, "rcphoto-falls", "photos/thumbs/falls.jpg");
//   map.addLayer({ id:"photo-pts", type:"symbol", source:"pts",
//     layout:{ "icon-image":"rcphoto-falls", "icon-anchor":"bottom",
//              "icon-offset":[0,8],            // tip on the point (8 units of pad below tip)
//              "icon-size":["interpolate",["linear"],["zoom"], 11,0.82, 14,1.23, 17,1.5],
//              "icon-allow-overlap":true } });

function addCircularPhotoMarker(map, name, photoUrl, opts = {}) {
  const {
    frameColor = "#355e3b",   // ring colour
    F = 6,                     // supersample factor (high DPI; never let icon-size > native)
    boxW = 44, boxH = 52,      // logical box; tip at (boxW/2, 44), 8 units of pad below
    cy = 21, rOut = 16.5, rPhoto = 13.1,
  } = opts;

  return new Promise((resolve) => {
    if (map.hasImage(name)) return resolve(name);
    const img = new Image();
    img.crossOrigin = "anonymous";              // allow CORS-served images
    img.onerror = () => resolve(null);
    img.onload = async () => {
      if (map.hasImage(name)) return resolve(name);
      const W = boxW * F, H = boxH * F;
      const c = document.createElement("canvas"); c.width = W; c.height = H;
      const ctx = c.getContext("2d");
      ctx.scale(F, F);                          // draw in logical (44×52) space
      ctx.imageSmoothingEnabled = true; ctx.imageSmoothingQuality = "high";
      const cx = boxW / 2, tipY = 44;

      // (1) faint contact shadow under the tip so the bubble reads as grounded
      ctx.save();
      ctx.translate(cx, tipY); ctx.scale(1, 0.36);
      const gnd = ctx.createRadialGradient(0, 0, 0, 0, 0, 13);
      gnd.addColorStop(0, "rgba(20,16,9,0.28)"); gnd.addColorStop(1, "rgba(20,16,9,0)");
      ctx.fillStyle = gnd; ctx.beginPath(); ctx.arc(0, 0, 13, 0, 2 * Math.PI); ctx.fill();
      ctx.restore();

      // bubble = circle + short downward spike to the tip (apex = the anchor point)
      const bubble = (r) => {
        const hb = r * 0.34;
        ctx.beginPath(); ctx.moveTo(cx - hb, cy); ctx.lineTo(cx + hb, cy);
        ctx.lineTo(cx, tipY); ctx.closePath(); ctx.fill();
        ctx.beginPath(); ctx.arc(cx, cy, r, 0, 2 * Math.PI); ctx.fill();
      };

      // (2) drop shadow on the frame body for lift (cleared before drawing the photo)
      ctx.save();
      ctx.shadowColor = "rgba(20,16,9,0.26)"; ctx.shadowBlur = 2.8; ctx.shadowOffsetY = 0.9;
      ctx.fillStyle = frameColor; bubble(rOut);
      ctx.restore();

      // (3) subtle top-lit sheen on the frame (AA arc fill)
      const sheen = ctx.createLinearGradient(0, cy - rOut, 0, cy + 2);
      sheen.addColorStop(0, "rgba(255,255,255,0.26)"); sheen.addColorStop(1, "rgba(255,255,255,0)");
      ctx.fillStyle = sheen; ctx.beginPath(); ctx.arc(cx, cy, rOut, 0, 2 * Math.PI); ctx.fill();

      // (4) cover-fit + AA-mask the photo into the inner disc via destination-in
      const pr = rPhoto * F;
      const sc = document.createElement("canvas"); sc.width = sc.height = pr * 2;
      const sx = sc.getContext("2d");
      sx.imageSmoothingEnabled = true; sx.imageSmoothingQuality = "high";
      const iw = img.naturalWidth || 1, ih = img.naturalHeight || 1;
      const scale = Math.max((pr * 2) / iw, (pr * 2) / ih);
      sx.drawImage(img, pr - (iw * scale) / 2, pr - (ih * scale) / 2, iw * scale, ih * scale);
      sx.globalCompositeOperation = "destination-in";        // AA circular mask (NOT clip())
      sx.beginPath(); sx.arc(pr, pr, pr, 0, 2 * Math.PI); sx.fill();
      ctx.drawImage(sc, cx - rPhoto, cy - rPhoto, rPhoto * 2, rPhoto * 2);

      // (5) register premultiplied (createImageBitmap) so the edge doesn't fringe
      try {
        const bmp = await createImageBitmap(c);
        if (!map.hasImage(name)) map.addImage(name, bmp, { pixelRatio: F });
      } catch (e) {
        // fallback: register the canvas directly (may fringe slightly)
        if (!map.hasImage(name)) map.addImage(name, c, { pixelRatio: F });
      }
      resolve(name);
    };
    img.src = photoUrl;
  });
}

if (typeof module !== "undefined" && module.exports) module.exports = { addCircularPhotoMarker };
