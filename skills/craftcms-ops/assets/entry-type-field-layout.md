# Content-modeling starter — Craft 5 (section + entry type + Matrix-as-entries)

A known-good shape for modeling a "flexible content page" in Craft 5. Adapt the handles.
Craft 5 stores this in **Project Config** (`config/project/*.yaml`) — build it in the
Control Panel, then commit the generated YAML. This file documents the *intended shape*;
it is not itself applied.

## Target structure

```
Section: "Pages"  (type: Structure — nestable, ordered)
└── Entry Type: "page"
    ├── Field: title            (built-in)
    ├── Field: heading          (Plain Text, global, reusable)
    ├── Field: seoDescription   (Plain Text)
    └── Field: body             (Matrix — Craft 5: stores NESTED ENTRIES)
        ├── Entry Type: "richText"   → field: text   (CKEditor)
        ├── Entry Type: "imageBlock" → field: image  (Assets, limit 1)
        └── Entry Type: "callout"    → field: body   (Plain Text), style (Dropdown)
```

Key Craft 5 facts baked into this shape:

- **Matrix `body` holds entries, not "blocks".** Each nested entry has an **entry type**
  (`richText`, `imageBlock`, `callout`). Branch on `block.type.handle` in Twig.
- **Fields are global.** `heading`, `text`, `image` etc. are defined once and reused across
  any field layout. Reuse the same `text` field in multiple entry types rather than cloning.
- An entry type can be **shared across sections** with a per-section alias (name/handle
  override) if you want the same shape exposed in, say, both "Pages" and "Landing Pages".

## Rendering it (template `_layouts/page.twig` + section template)

```twig
{% set page = craft.entries().section('pages').slug(craft.app.request.segment(1)).with(['body']).one() %}
{% if not page %}{% exit 404 %}{% endif %}

<h1>{{ page.heading ?: page.title }}</h1>

{% for block in page.body.all() %}
  {% switch block.type.handle %}
    {% case 'richText' %}
      <div class="prose">{{ block.text }}</div>
    {% case 'imageBlock' %}
      {% set img = block.image.one() %}
      {% if img %}<figure><img src="{{ img.url }}" alt="{{ img.alt }}"></figure>{% endif %}
    {% case 'callout' %}
      <aside class="callout callout--{{ block.style.value }}">{{ block.body }}</aside>
  {% endswitch %}
{% endfor %}
```

## Project Config notes

- After creating the above in the CP, the schema lands in `config/project/` as YAML.
  Commit it. On deploy, `php craft up` applies it.
- Don't hand-edit Project Config YAML for structural changes — make them in the CP and let
  Craft serialize, to keep UIDs consistent.
- Environment-specific values (asset base URLs, API keys) belong in `.env` /
  `config/general.php`, never in Project Config.
