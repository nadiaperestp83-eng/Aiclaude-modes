# Twig & Element Queries — deep dive (Craft 5)

Load this when writing non-trivial templates, debugging N+1, or building pagination.

## Element query parameter catalog

Every element type (entries, assets, users, categories, tags) shares a query builder. Common parameters for `craft.entries()`:

| Parameter | Purpose | Example |
|-----------|---------|---------|
| `.section()` | One or more section handles | `.section(['blog','news'])` |
| `.type()` | Entry type handle | `.type('article')` |
| `.id()` | Specific element id(s) | `.id(42)` |
| `.slug()` | By slug | `.slug('about')` |
| `.status()` | `live`, `pending`, `expired`, `disabled` | `.status(['live','expired'])` |
| `.orderBy()` | Sort | `.orderBy('postDate DESC')` |
| `.limit()` / `.offset()` | Slice | `.limit(10).offset(20)` |
| `.search()` | Full-text via search index | `.search('keyword')` |
| `.relatedTo()` | Relationship queries | `.relatedTo(category)` |
| `.with()` | Eager-load relations | `.with(['author','image'])` |
| `.site()` | Target a specific site (multi-site) | `.site('en')` |
| `.unique()` | Dedupe across sites | `.unique()` |

Terminators: `.all()`, `.one()`, `.count()`, `.exists()`, `.ids()`, `.nth(n)`, `.collect()` (returns a Collection).

## Eager loading (kill N+1)

The single most common Craft performance bug is querying relations inside a loop. Always eager-load:

```twig
{# BAD — one query per entry for author #}
{% for entry in craft.entries().section('blog').all() %}
  {{ entry.author.one().fullName }}
{% endfor %}

{# GOOD — eager-load up front #}
{% set posts = craft.entries().section('blog').with(['author']).all() %}
{% for entry in posts %}
  {{ entry.author.fullName }}
{% endfor %}
```

Nested paths work: `.with(['author.userPhoto', 'categories', 'body'])`.

### Eager-loading nested Matrix entries (Craft 5)

Matrix content is now nested *entries*. Eager-load the Matrix field, then branch on `block.type.handle`:

```twig
{% set page = craft.entries().section('pages').slug(slug).with(['body']).one() %}
{% for block in page.body.all() %}
  {% switch block.type.handle %}
    {% case 'richText' %}
      {{ block.text }}
    {% case 'imageBlock' %}
      {% set img = block.image.one() %}
      {% if img %}<img src="{{ img.url }}" alt="{{ img.alt }}">{% endif %}
    {% case 'callout' %}
      <aside>{{ block.body }}</aside>
  {% endswitch %}
{% endfor %}
```

To eager-load relations *inside* nested entries, use a nested path through the Matrix handle (e.g. `.with(['body.image'])`).

## Pagination

```twig
{% set query = craft.entries().section('blog').orderBy('postDate DESC') %}
{% paginate query.limit(12) as pageInfo, entries %}

{% for entry in entries %}
  {{ entry.title }}
{% endfor %}

{% if pageInfo.prevUrl %}<a href="{{ pageInfo.prevUrl }}">Previous</a>{% endif %}
{% if pageInfo.nextUrl %}<a href="{{ pageInfo.nextUrl }}">Next</a>{% endif %}
```

`pageInfo` exposes `.currentPage`, `.totalPages`, `.total`, `.first`, `.last`, `.getRangeUrls()`.

## Template organization

| Convention | Detail |
|------------|--------|
| Private templates | Prefix `_` (`_layouts/`, `_partials/`, `_macros/`) so Craft won't route to them directly |
| Layout inheritance | `{% extends '_layouts/base' %}`, fill `{% block %}` regions |
| Includes | `{% include '_partials/card' with { entry } only %}` — `only` isolates scope |
| Macros | `{% macro %}` / `{% import %}` for repeated markup helpers |
| Embeds | `{% embed %}` when you need to override blocks inside an included template |

## Caching

```twig
{% cache %}
  {# expensive, rarely-changing markup #}
{% endcache %}

{% cache unless craft.app.config.general.devMode %}...{% endcache %}
{% cache for 1 week %}...{% endcache %}
{% cache using key entry.id %}...{% endcache %}
```

Rules:
- Cache *after* eager-loading and query optimization, never instead of it.
- `{% cache %}` does not cache the query result tags it wraps if they contain `{% nocache %}` regions.
- For full static-page caching with smart invalidation, reach for **Blitz** rather than hand-rolled `{% cache %}`.

## Multi-site

| Need | Approach |
|------|----------|
| Query a specific site | `.site('handle')` |
| Query all sites | `.site('*')` then `.unique()` to dedupe shared elements |
| Current site in template | `craft.app.sites.currentSite` |
| Localized URLs | `entry.url` resolves per-site; `craft.entries().id(x).site('fr').one().url` for the other locale |

Content can be propagated or per-site editable per field/section setting; design the section's propagation method up front.
