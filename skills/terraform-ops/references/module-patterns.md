# Module Patterns

Modules are Terraform's unit of reuse. Most module pain comes from treating them like classes (inheritance, deep nesting, wrapping) instead of functions (flat composition, explicit inputs/outputs).

## Root vs Child Modules

| | Root module | Child module |
|---|---|---|
| What | The directory you run `terraform` in | Anything called via `module` block |
| Backend block | Yes — exactly one | **Never** |
| Provider config (`provider "aws" {}`) | Yes | **Never** — declare `required_providers` only |
| tfvars | Yes | No (inputs come from the caller) |
| State | Owns one state file | Lives inside the caller's state |

```hcl
# modules/network/versions.tf — child module declares NEEDS, not config
terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0, < 8.0"     # modules use RANGES; roots pin tighter
    }
  }
}
```

A child module with a `provider` block can't be used with `for_each`/`count`/`depends_on` and can't be removed cleanly. Pass aliased providers explicitly when needed:

```hcl
module "dns" {
  source    = "../../modules/dns"
  providers = { aws = aws.us_east_1 }   # ACM certs for CloudFront, etc.
}
```

## Composition Over Inheritance

Build small single-purpose modules; compose them in the root by wiring outputs to inputs.

```hcl
# Root composes — dependencies are explicit data flow
module "network" {
  source = "../../modules/network"
  cidr   = "10.0.0.0/16"
}

module "database" {
  source     = "../../modules/database"
  subnet_ids = module.network.private_subnet_ids   # output -> input wiring
  vpc_id     = module.network.vpc_id
}

module "app" {
  source            = "../../modules/app-service"
  subnet_ids        = module.network.private_subnet_ids
  db_connection_arn = module.database.connection_secret_arn
}
```

Rules of thumb:

- **Nesting depth ≤ 2.** Root → module → (occasionally) submodule. Deeper means you're rebuilding inheritance and debugging through four layers of variable plumbing.
- A module should manage a *cohesive* set of resources with a clear lifecycle (a VPC and its subnets/routes — yes; "everything for the app" — no).
- If a module takes 40 variables and most callers set 3, split it.
- Don't create a module for a single resource unless it encodes real policy (e.g. an S3 module that enforces encryption + public-access-block on every bucket — that's policy, not wrapping).

### Anti-pattern: thin wrapper modules

```hcl
# modules/our-vpc/main.tf — adds NOTHING
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"
  name    = var.vpc_name        # renamed from `name`. why.
  cidr    = var.network_cidr    # renamed from `cidr`. why.
}
```

Costs: a second version to bump (wrapper lags upstream), a second docs surface, every upstream feature needs a wrapper variable added before anyone can use it, and `moved`-block refactors in upstream don't propagate. **Call the upstream module directly from the root.** A wrapper earns its existence only when it enforces organizational policy (mandatory tags, forced encryption, restricted instance types) — and then it should *say so* in its README.

## Variable Design

### Validation — fail at plan, not mid-apply

```hcl
variable "environment" {
  type        = string
  description = "Deployment environment."
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "cidr" {
  type = string
  validation {
    condition     = can(cidrhost(var.cidr, 0)) && tonumber(split("/", var.cidr)[1]) <= 24
    error_message = "cidr must be a valid IPv4 CIDR no smaller than /24."
  }
}
```

Since TF 1.9, `condition` can reference *other* variables and data — cross-field validation lives on the variable, not buried in a `precondition`.

### optional() + nullable

```hcl
variable "logging" {
  description = "Access-logging config. Omit fields for defaults."
  type = object({
    enabled       = optional(bool, true)
    bucket        = optional(string)          # null when omitted
    prefix        = optional(string, "logs/")
    sample_rate   = optional(number, 1.0)
  })
  default  = {}
  nullable = false      # caller may omit the variable, but may NOT pass logging = null
}
```

- `optional(type, default)` lets callers pass partial objects — the killer feature for config-object variables. Without defaults you'd force every caller to spell out every field.
- `nullable = false` means an explicit `null` is rejected and the variable's own `default` is used instead. Use it on almost every variable: it converts "caller passed null, module exploded on `var.x.enabled`" into a plan-time error.
- Gotcha: `optional(string)` with no default yields `null` — guard with `coalesce(...)` or `try(...)` before interpolating.

### Variable hygiene

| Rule | Why |
|---|---|
| Every variable has `description` | It's the module's API doc (`terraform-docs` renders it) |
| `sensitive = true` on secret inputs | Keeps values out of CLI output (NOT out of state — see security-and-secrets.md) |
| Prefer typed objects over `map(any)` | `any` defers errors to deep inside the module |
| No "pass-through everything" variables | A `extra_settings = any` variable is an API you can never change |
| Defaults = safe choice, not common choice | Default to encrypted/private/protected; make callers opt *out* loudly |

## Output Contracts

Outputs are the module's public API. Consumers wire them into other modules and remote-state reads — changing one is a breaking change.

```hcl
output "vpc_id" {
  description = "ID of the created VPC."
  value       = aws_vpc.main.id
}

output "private_subnet_ids" {
  description = "Private subnet IDs, keyed by AZ."
  value       = { for k, s in aws_subnet.private : k => s.id }
}

output "db_endpoint" {
  description = "Writer endpoint. SENSITIVE: contains hostname only, no creds."
  value       = aws_rds_cluster.main.endpoint
}
```

- Output the **identifiers consumers need** (IDs, ARNs, endpoints, security-group IDs) — not whole resource objects (`value = aws_vpc.main` couples consumers to the provider schema and bloats state).
- `sensitive = true` propagates: an output derived from a sensitive value must itself be marked sensitive or plan errors.
- Treat output removal/rename like an API break: semver-major the module, or keep the old output as an alias for one cycle.

## Versioning and Pinning

```hcl
# Registry module — minor-float
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"        # >= 6.0.0, < 7.0.0
}

# Git module — pin a TAG (never a branch)
module "internal" {
  source = "git::https://github.com/myorg/tf-modules.git//network?ref=v2.3.1"
}
```

| Constraint | Meaning | Use for |
|---|---|---|
| `~> 6.0` | ≥ 6.0, < 7.0 | Registry modules/providers in shared modules |
| `~> 6.12.0` | ≥ 6.12.0, < 6.13.0 | Conservative prod roots |
| `= 6.12.1` / `?ref=v2.3.1` | Exact | Prod roots wanting byte-identical builds |
| `>= 6.0` (open-ended) | Anything newer | **Never in prod** — a breaking major auto-arrives |

- **Commit `.terraform.lock.hcl`.** It pins exact provider versions + hashes; `terraform init -upgrade` is the deliberate act of moving within constraints. This is the same supply-chain posture as any other lockfile: a pin only protects you if it pre-dates a compromise and you don't run unconstrained upgrades in CI.
- Run `terraform providers lock -platform=linux_amd64 -platform=darwin_arm64 -platform=windows_amd64` so the lockfile carries hashes for every platform your team + CI uses (OpenTofu 1.12 does this automatically at init).
- Internal module registries: HCP Terraform private registry, or plain git tags + a `modules/` monorepo. Git tags are fine; the registry's value is the version-constraint syntax and docs rendering.

## Module Repo Layout

```
terraform-aws-network/            # one module per repo (registry-publishable), or modules/ monorepo
├── main.tf
├── variables.tf
├── outputs.tf
├── versions.tf
├── README.md                     # terraform-docs generated
├── examples/
│   └── complete/                 # a runnable root that exercises the module — doubles as docs + test fixture
│       └── main.tf
└── tests/
    └── network.tftest.hcl        # native tests (see SKILL.md Testing section)
```

`terraform-docs markdown table . > README.md` keeps docs honest — wire it as a pre-commit hook or CI check.

## count vs for_each (the index-shift footgun)

```hcl
# BAD: count over a list
resource "aws_subnet" "private" {
  count      = length(var.subnet_cidrs)        # remove element 0 ->
  cidr_block = var.subnet_cidrs[count.index]   # every subnet re-addresses -> destroy cascade
}

# GOOD: for_each over a map with stable keys
resource "aws_subnet" "private" {
  for_each   = var.subnets                      # { "ap-southeast-2a" = "10.0.1.0/24", ... }
  cidr_block = each.value
  availability_zone = each.key
}
```

`count` is fine for "0 or 1 of this" conditionals (`count = var.enabled ? 1 : 0`) — though even there, `for_each = var.enabled ? { main = true } : {}` keeps addresses stable if it might ever become "n of this". Migrating existing `count` resources to `for_each`: write `moved` blocks for each index→key pair (see state-management.md) so nothing is destroyed.
