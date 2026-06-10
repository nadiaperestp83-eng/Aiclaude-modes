# GraphQL, Headless & Plugin Development (Craft 5)

Load this for decoupled/headless setups or when building a plugin/module.

## GraphQL / headless

Craft ships a first-party GraphQL API. Flow:

1. **Define a schema** in the Control Panel (GraphQL → Schemas). Scope it to the sections, entry types, asset volumes, etc. the frontend may read.
2. **Generate a token** per schema. The **public schema** serves anonymous requests; private schemas require a Bearer token.
3. **Endpoint**: `/api` by default (configurable). POST GraphQL queries; auth via `Authorization: Bearer <token>`.
4. **CORS**: set allowed origins for the headless frontend (Next.js/Nuxt/Astro).

Example query against entries (note the Craft 5 entry/entry-type model):

```graphql
query Posts {
  entries(section: "blog", limit: 10, orderBy: "postDate DESC") {
    title
    slug
    ... on blog_article_Entry {
      postDate
      featuredImage { url }
      author { fullName }
    }
  }
}
```

The fragment type name follows `{section}_{entryType}_Entry`. Nested Matrix entries resolve as their own entry types under the Matrix field.

### When NOT to use GraphQL

- Small number of fixed endpoints → the **Element API** plugin (custom JSON routes) is simpler.
- Server-rendered Twig site → no API layer needed at all.

## Plugin vs module

| Build a… | When |
|----------|------|
| **Module** | Project-specific code, no distribution (`modules/` in the app) |
| **Plugin** | Reusable/distributable via the Plugin Store (Composer package) |

Both extend Craft via Yii 2 components: services, controllers, element types, field types, widgets, behaviors, events.

## Plugin anatomy

```
my-plugin/
├── composer.json          # type: craft-plugin, autoload PSR-4
├── src/
│   ├── Plugin.php         # init(), registers services & event handlers
│   ├── services/          # business logic (injectable)
│   ├── controllers/       # CP + site request handlers
│   ├── elements/          # custom element types
│   ├── fields/            # custom field types
│   └── migrations/        # install + content migrations
└── README.md
```

Key registration patterns in `Plugin::init()`:

```php
// Register a service
$this->setComponents(['myService' => MyService::class]);

// Hook an event
Event::on(
    Entries::class,
    Entries::EVENT_AFTER_SAVE_ENTRY,
    function (EntryEvent $e) { /* ... */ }
);

// Register a Twig extension
Craft::$app->view->registerTwigExtension(new MyTwigExtension());
```

Follow the official [coding guidelines](https://craftcms.com/docs/5.x/extend/coding-guidelines.html) — namespacing, service-layer separation, and event-driven extension are expected idioms.

## Migrations

| Migration kind | Purpose |
|----------------|---------|
| **Install migration** | Schema a plugin needs on install (`migrations/Install.php`) |
| **Plugin migration** | Schema changes between plugin versions |
| **Content migration** | Project data transformations (`php craft migrate/create`) — version-controlled, run via `php craft up` |

Always test migrations on a staging clone before production.

## Integration points

| Concern | Common choices |
|---------|----------------|
| Frontend frameworks | Next.js, Nuxt, Astro, Gatsby via GraphQL / Element API |
| Hosting | Servd, Fortrabbit, Laravel Forge; DDEV for local |
| Assets | AWS S3, Google Cloud Storage, Imgix transforms |
| Search | Algolia, Elasticsearch via plugins |
| Commerce | Craft Commerce |
| Caching | Blitz (static pages), Redis, Cloudflare |
