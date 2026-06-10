# State Management

Terraform/OpenTofu state is the mapping between config addresses and real infrastructure. It is the single most dangerous file in the project: lose it and Terraform forgets your infra; corrupt it and applies destroy the wrong things; leak it and every secret a provider ever returned is exposed.

## Remote Backends

Never keep state local for anything shared or production. Remote backends give durability, locking, and team access.

### S3 (AWS) — current recommended shape

```hcl
terraform {
  backend "s3" {
    bucket       = "myorg-tfstate"
    key          = "prod/network/terraform.tfstate"   # one key per root module
    region       = "ap-southeast-2"
    encrypt      = true                # SSE; pair with bucket-default SSE-KMS
    use_lockfile = true               # S3-native locking (TF >= 1.10)
  }
}
```

- **`use_lockfile = true` replaces the DynamoDB lock table** (Terraform ≥ 1.10, OpenTofu ≥ 1.10). It uses S3 conditional writes to create a `.tflock` object next to the state key. The old `dynamodb_table` argument still works and was the standard for a decade — you'll see it everywhere — but new setups don't need the extra table. During migration you can set both; remove `dynamodb_table` once all collaborators are ≥ 1.10.
- Bucket hygiene: versioning **on** (state history = your undo), default SSE-KMS, block public access, lifecycle rule to expire old noncurrent versions after ~90 days, bucket policy restricting to the CI role + break-glass humans.
- One bucket per org/account is fine; isolation comes from `key` prefixes + IAM conditions on the prefix.

### azurerm

```hcl
terraform {
  backend "azurerm" {
    resource_group_name  = "rg-tfstate"
    storage_account_name = "myorgtfstate"
    container_name       = "tfstate"
    key                  = "prod.network.tfstate"
    use_azuread_auth     = true        # RBAC instead of storage keys
  }
}
```

Locking is native via blob leases — nothing extra to configure. Prefer `use_azuread_auth = true` so CI uses OIDC-federated identity, not storage account keys.

### gcs

```hcl
terraform {
  backend "gcs" {
    bucket = "myorg-tfstate"
    prefix = "prod/network"
  }
}
```

Locking native via Cloud Storage generation preconditions. Enable object versioning on the bucket. Use workload identity federation in CI.

### HCP Terraform / Terraform Cloud

```hcl
terraform {
  cloud {
    organization = "myorg"
    workspaces { name = "prod-network" }
  }
}
```

State hosted, encrypted, versioned, locked by the platform; runs can execute remotely. Free tier covers ≤ 500 managed resources. Note: OpenTofu cannot use HCP Terraform as a backend (it can use the generic `remote` backend against compatible APIs).

### Backend selection

| Backend | Locking | Encryption at rest | Best when |
|---|---|---|---|
| `s3` + `use_lockfile` | S3 conditional writes | SSE-KMS | AWS shops (default) |
| `s3` + `dynamodb_table` | DynamoDB | SSE-KMS | Legacy / mixed TF < 1.10 teams |
| `azurerm` | Blob lease (built-in) | Platform + CMK | Azure shops |
| `gcs` | Generation precondition (built-in) | Platform + CMEK | GCP shops |
| HCP Terraform | Platform | Platform | Want managed runs/policies too |
| `pg` / `consul` / `kubernetes` | Yes | Varies | Niche; self-hosted constraints |

### Migrating backends

```bash
# 1. Add/replace the backend block, then:
terraform init -migrate-state          # copies state old -> new, prompts
# 2. Verify: terraform state list shows everything
# 3. Delete the old state only after a clean plan
```

## State Locking

Locking prevents two concurrent applies corrupting state. It is **not** optional for teams.

- `terraform apply` acquires the lock automatically; a crash can leave it stuck.
- `terraform force-unlock <LOCK_ID>` — only after confirming no run is actually live (check CI). The lock ID is printed in the error.
- `-lock-timeout=5m` in CI lets queued runs wait instead of failing instantly.
- Locking protects against concurrent *writes*; it does not serialize plans — two PRs can both plan green and conflict at apply. Solve at the orchestration layer (Atlantis dir-locks, Actions concurrency groups — see cicd-pipelines.md).

## Declarative State Changes: moved / import / removed

These blocks are the modern, code-reviewable replacements for CLI state surgery. They live in config, show up in diffs, and execute as part of a normal plan/apply.

### `moved` — refactor without destroy

```hcl
# Renamed a resource
moved {
  from = aws_instance.web
  to   = aws_instance.frontend
}

# Moved a resource into a module
moved {
  from = aws_vpc.main
  to   = module.network.aws_vpc.main
}

# count -> for_each migration
moved {
  from = aws_subnet.private[0]
  to   = aws_subnet.private["ap-southeast-2a"]
}
```

Plan shows `# aws_instance.web has moved to aws_instance.frontend` instead of destroy+create. Keep `moved` blocks around for at least one release cycle of a shared module so downstream consumers also get the move; then prune.

### `import` — adopt existing infrastructure (TF ≥ 1.5)

```hcl
import {
  to = aws_s3_bucket.legacy
  id = "myorg-legacy-bucket"
}
```

```bash
# Generate matching config for resources you haven't written yet:
terraform plan -generate-config-out=generated.tf
# Review generated.tf, clean it up (it's verbose), move into proper files, apply.
```

Why blocks beat `terraform import` CLI: the import is planned (you see exactly what will be adopted and whether config matches reality) and reviewed in the PR. The CLI command mutates state immediately with no plan. Import blocks also support `for_each` (TF ≥ 1.7) for bulk adoption.

After a successful apply, delete the `import` blocks — they're one-shot.

### `removed` — forget without destroying (TF ≥ 1.7, OpenTofu ≥ 1.8)

```hcl
removed {
  from = aws_db_instance.legacy
  lifecycle {
    destroy = false      # remove from state, leave the real DB alone
  }
}
```

Use when handing a resource to another team/state, or un-managing something Terraform should no longer own. The declarative version of `terraform state rm`. OpenTofu 1.12 additionally allows `lifecycle { destroy = false }` directly on a resource being deleted from config.

## State Surgery (CLI) — and when NOT to

```bash
terraform state list                      # enumerate addresses (safe)
terraform state show aws_vpc.main         # inspect one resource (safe)
terraform state pull > backup.tfstate     # ALWAYS do this first
terraform state mv aws_x.a aws_x.b        # immediate, unreviewed rename
terraform state mv aws_x.a 'module.m.aws_x.a'
terraform state rm aws_x.a                # forget (does NOT destroy)
terraform state push fixed.tfstate        # overwrite remote state (extreme)
```

**Decision rule:** if a `moved`, `removed`, or `import` block can express the change — use the block. Reasons:

1. Blocks are planned and reviewed; CLI mutations are instant and invisible to reviewers.
2. Blocks are idempotent across the team; a CLI command run by one person leaves everyone else's mental model stale.
3. A typo in `state mv` orphans a real resource: Terraform now plans to *create* a duplicate while the original drifts unmanaged.

**Legitimate CLI surgery:**

- Splitting one state into two roots (`state mv -state-out=...` or pull/edit/push between backends).
- Recovering from a half-failed migration or a provider bug that wedged an address.
- Anything on Terraform < 1.5 (no blocks available).

**Protocol for any surgery:** `state pull` a timestamped backup → make the change → `terraform plan` must come back clean (or exactly the expected diff) → only then walk away.

## Drift Detection

Infrastructure changes outside Terraform (console edits, autoscaling, other tooling). Detect it before it bites an apply.

```bash
terraform plan -detailed-exitcode -lock=false
# exit 0 -> no changes (clean)
# exit 1 -> error
# exit 2 -> changes pending (drift OR un-applied config)
```

- `-lock=false` so a read-only drift check never blocks a real apply.
- `terraform plan -refresh-only` shows only *state vs reality* differences without proposing config-driven changes — cleaner signal for "who touched the console".
- Cron it: nightly scheduled CI job, alert on exit 2 (recipe in cicd-pipelines.md).
- Chronic drift on specific attributes → either codify the external process or `lifecycle { ignore_changes = [...] }` deliberately (document why).

## State File Hygiene

| Rule | Why |
|---|---|
| `*.tfstate*` in `.gitignore` | Local state in git = secrets in git history forever |
| One state per blast-radius unit | Network / data / app split — a bad apply can't take everything |
| Keep states small (< ~100 resources guideline) | Plan time, lock contention, blast radius all scale with state size |
| Versioned backend bucket | `state push` mistakes become a revert, not a rebuild |
| Treat state as secret | Provider attributes (DB passwords, certs) sit in plaintext JSON — see security-and-secrets.md |
| OpenTofu: consider state encryption | Client-side AES-GCM, keys via PBKDF2/KMS — defence even if the bucket leaks |

```hcl
# OpenTofu >= 1.7 only — state + plan encryption
terraform {
  encryption {
    key_provider "aws_kms" "main" {
      kms_key_id = "arn:aws:kms:...:key/..."
      key_spec   = "AES_256"
    }
    method "aes_gcm" "main" {
      keys = key_provider.aws_kms.main
    }
    state { method = method.aes_gcm.main }
    plan  { method = method.aes_gcm.main }
  }
}
```
