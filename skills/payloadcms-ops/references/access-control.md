# Access Control — deep dive (Payload 3)

Load when designing authorization: RBAC, multi-tenant isolation, or field-level locks.

Access functions run uniformly across the Local API, REST, and GraphQL. They return either
a `boolean` (can the user do this operation at all?) or a **query constraint** object
(row-level: *which* documents). Returning a constraint from `read`/`update`/`delete` is the
mechanism for per-tenant / per-owner data isolation — `true` alone means "all rows".

## Operation-level (collection) access

```typescript
import type { CollectionConfig } from 'payload'

export const Posts: CollectionConfig = {
  slug: 'posts',
  access: {
    read:   ({ req }) => {
      if (!req.user) return { status: { equals: 'published' } } // anon sees published only
      if (req.user.role === 'admin') return true
      return { author: { equals: req.user.id } }                // authors see their own
    },
    create: ({ req }) => Boolean(req.user),
    update: ({ req }) => req.user?.role === 'admin'
      ? true
      : { author: { equals: req.user?.id } },
    delete: ({ req }) => req.user?.role === 'admin',
  },
  fields: [/* ... */],
}
```

| Access fn | Controls | Returns |
|-----------|----------|---------|
| `read` | Listing + reading docs | bool or `where` constraint |
| `create` | New docs | bool |
| `update` | Editing | bool or `where` constraint |
| `delete` | Removal | bool or `where` constraint |
| `admin` | Whether user can access the admin panel (auth collection) | bool |
| `unlock`, `readVersions` | Auth/versioning specifics | bool |

## Field-level access

Lock or hide individual fields independent of the document:

```typescript
{
  name: 'internalNotes',
  type: 'textarea',
  access: {
    read:   ({ req }) => req.user?.role === 'admin',
    update: ({ req }) => req.user?.role === 'admin',
    create: ({ req }) => req.user?.role === 'admin',
  },
}
```

Field-level `read` false → field omitted from output. `update`/`create` false → field is
read-only / cannot be set even if the document is writable.

## RBAC pattern

Store a `role` (or `roles` hasMany) on the Users (auth) collection, then branch in access
functions. Centralize predicates so they're reused, not copy-pasted:

```typescript
// access/isAdmin.ts
import type { Access } from 'payload'
export const isAdmin: Access = ({ req }) => req.user?.role === 'admin'
export const isAdminOrSelf: Access = ({ req }) =>
  req.user?.role === 'admin' ? true : { author: { equals: req.user?.id } }
```

## Multi-tenant isolation

Two routes:

1. **`@payloadcms/plugin-multi-tenant`** — adds a tenant field + scoping automatically.
   Prefer this for standard cases.
2. **Custom constraints** — add a `tenant` relationship field, then enforce in every
   collection's access:

   ```typescript
   read: ({ req }) => ({ tenant: { equals: req.user?.tenant } }),
   ```

   Apply the same constraint to `create` (force-set tenant in a `beforeChange` hook),
   `update`, and `delete`. Test that a user from tenant A genuinely cannot read/modify
   tenant B's rows — this is the #1 access bug.

## Rules

- **Never bypass access control in custom endpoints.** Route through the Local API with
  access enabled. Reserve `overrideAccess: true` for trusted server-side jobs that
  *intentionally* run as system.
- A `read` that returns `true` exposes every row. If data should be scoped, return a
  constraint, not a boolean.
- Field access runs *in addition* to collection access — both must pass.
- Access functions can be async (e.g. look up tenant membership) — return a Promise.
