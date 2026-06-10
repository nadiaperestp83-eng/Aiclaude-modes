# Browser Performance & Security Reference

Browser-side patterns — DOM performance, rate limiting user events, and client-side security hardening.

---

## DOM Performance

### Batch DOM Updates

Every DOM read after a write forces a synchronous layout (reflow). Batch reads together, then writes.

```javascript
// BAD — interleaved read/write forces layout thrashing
elements.forEach(el => {
  const height = el.offsetHeight;     // read (forces layout)
  el.style.height = `${height * 2}px`; // write (invalidates layout)
});

// GOOD — read everything, then write everything
const heights = elements.map(el => el.offsetHeight); // all reads
elements.forEach((el, i) => {
  el.style.height = `${heights[i] * 2}px`;           // all writes
});

// GOOD — build off-DOM, insert once
const fragment = document.createDocumentFragment();
for (const item of items) {
  const li = document.createElement('li');
  li.textContent = item.name;
  fragment.append(li);
}
list.append(fragment); // single reflow
```

### Cache DOM Queries

```javascript
// BAD — re-queries the DOM on every call
function updateCounter(value) {
  document.querySelector('#counter').textContent = value;
}

// GOOD — query once, reuse the reference
const counter = document.querySelector('#counter');
function updateCounter(value) {
  counter.textContent = value;
}
```

### requestAnimationFrame for Visual Updates

```javascript
// Sync visual updates to the browser's paint cycle — never setInterval for animation
function animate(timestamp) {
  element.style.transform = `translateX(${computePosition(timestamp)}px)`;
  if (!done) requestAnimationFrame(animate);
}
requestAnimationFrame(animate);

// Coalesce rapid events (scroll, resize, mousemove) to one update per frame
let scheduled = false;
window.addEventListener('scroll', () => {
  if (scheduled) return;
  scheduled = true;
  requestAnimationFrame(() => {
    updateScrollIndicator();
    scheduled = false;
  });
});
```

---

## Event Delegation

Attach one listener to a common ancestor instead of one per element — essential for dynamic lists where children come and go.

```javascript
// BAD — N listeners, breaks for elements added later
document.querySelectorAll('.item button').forEach(btn => {
  btn.addEventListener('click', handleClick);
});

// GOOD — one listener handles all current AND future children
document.querySelector('#list').addEventListener('click', (event) => {
  const button = event.target.closest('button[data-action]');
  if (!button) return;

  switch (button.dataset.action) {
    case 'delete': deleteItem(button.closest('.item')); break;
    case 'edit':   editItem(button.closest('.item'));   break;
  }
});
```

**Cleanup discipline:** every `addEventListener` needs a removal path. Prefer `{ signal }` for bulk cleanup:

```javascript
const controller = new AbortController();
window.addEventListener('resize', onResize, { signal: controller.signal });
window.addEventListener('scroll', onScroll, { signal: controller.signal });

// Tear down everything at once
controller.abort();
```

---

## Debounce and Throttle

| Pattern | Behavior | Use For |
|---------|----------|---------|
| Debounce | Fires once after events STOP for N ms | Search-as-you-type, form validation, resize-end |
| Throttle | Fires at most once per N ms while events continue | Scroll handlers, mousemove, drag, analytics pings |

```javascript
function debounce(fn, ms) {
  let timer;
  return function (...args) {
    clearTimeout(timer);
    timer = setTimeout(() => fn.apply(this, args), ms);
  };
}

function throttle(fn, ms) {
  let last = 0;
  let trailing;
  return function (...args) {
    const now = Date.now();
    const remaining = ms - (now - last);
    if (remaining <= 0) {
      last = now;
      fn.apply(this, args);
    } else {
      // Trailing call so the final event isn't dropped
      clearTimeout(trailing);
      trailing = setTimeout(() => {
        last = Date.now();
        fn.apply(this, args);
      }, remaining);
    }
  };
}

// Usage
searchInput.addEventListener('input', debounce(e => search(e.target.value), 300));
window.addEventListener('scroll', throttle(updatePosition, 100));
```

---

## Memoization

Cache results of pure, expensive functions keyed by their arguments.

```javascript
function memoize(fn, keyFn = (...args) => JSON.stringify(args)) {
  const cache = new Map();
  return function (...args) {
    const key = keyFn(...args);
    if (!cache.has(key)) {
      cache.set(key, fn.apply(this, args));
    }
    return cache.get(key);
  };
}

const expensiveLayout = memoize(computeLayout);

// For object arguments, key on identity with WeakMap — entries GC with the object
function memoizeByRef(fn) {
  const cache = new WeakMap();
  return (obj) => {
    if (!cache.has(obj)) cache.set(obj, fn(obj));
    return cache.get(obj);
  };
}
```

**Caveats:** only memoize pure functions; bound caches (Map) grow forever — use `WeakMap`, an LRU, or explicit invalidation for long-lived apps.

---

## Lazy Loading

```javascript
// Native — images and iframes
// <img src="photo.jpg" loading="lazy" alt="...">

// IntersectionObserver — anything else (infinite scroll, deferred widgets)
const observer = new IntersectionObserver((entries) => {
  for (const entry of entries) {
    if (!entry.isIntersecting) continue;
    hydrateWidget(entry.target);
    observer.unobserve(entry.target); // one-shot
  }
}, { rootMargin: '200px' }); // start loading before it's visible

document.querySelectorAll('[data-lazy-widget]').forEach(el => observer.observe(el));
```

---

## Client-Side Security

### XSS — Never Interpolate Untrusted Data into HTML

```javascript
// BAD — untrusted string becomes live markup
element.innerHTML = `<p>${userComment}</p>`; // <img src=x onerror=...> executes

// GOOD — textContent never parses HTML
const p = document.createElement('p');
p.textContent = userComment;
element.append(p);

// GOOD — when HTML structure is required, sanitize first (DOMPurify)
element.innerHTML = DOMPurify.sanitize(userHtml);
```

Other injection sinks to treat the same way: `outerHTML`, `insertAdjacentHTML`, `document.write`, `eval`, `new Function(string)`, `setTimeout('string')`, and `javascript:` URLs in `href`/`src`.

### URL and Attribute Context

```javascript
// Validate URLs before assigning to href/src — block javascript: scheme
function safeUrl(raw) {
  try {
    const url = new URL(raw, location.origin);
    return ['https:', 'http:', 'mailto:'].includes(url.protocol) ? url.href : '#';
  } catch {
    return '#';
  }
}
link.href = safeUrl(userProvidedUrl);
```

### Content Security Policy

A CSP header is the backstop when an injection slips through — it blocks inline scripts and unauthorized sources.

```
Content-Security-Policy: default-src 'self';
  script-src 'self' 'nonce-{random}';
  object-src 'none';
  base-uri 'none'
```

- Prefer nonces or hashes over `'unsafe-inline'`
- `object-src 'none'` and `base-uri 'none'` close legacy vectors
- Start with `Content-Security-Policy-Report-Only` to find violations before enforcing

### Storage and Secrets

| Data | Where | Why |
|------|-------|-----|
| Session tokens | `httpOnly` + `Secure` + `SameSite` cookie | JS cannot read it — XSS can't exfiltrate |
| Non-sensitive prefs | `localStorage` | Fine — but any XSS can read it |
| Secrets / API keys | Never in client code | Bundles are public; proxy through a server |

```javascript
// localStorage values are untrusted on read — they survive across sessions
// and any prior XSS could have poisoned them
const raw = localStorage.getItem('prefs');
let prefs;
try {
  prefs = PrefsSchema.parse(JSON.parse(raw)); // validate, don't trust
} catch {
  prefs = DEFAULT_PREFS;
}
```
