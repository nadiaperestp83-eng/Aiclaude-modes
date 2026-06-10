# CI/CD Pipelines

The contract: **every change is planned on the PR, the plan is visible to the reviewer, and apply happens from CI with short-lived credentials.** Humans never run `apply` against shared environments from laptops.

Full workflow template: [../assets/github-actions-terraform.yml](../assets/github-actions-terraform.yml).

## Pipeline Shape

```
              ┌─ fmt -check ─┐
PR opened ──> ├─ validate    ├──> tflint ──> trivy/checkov ──> plan ──> plan as PR comment
              └─ (parallel)  ┘                                              │
                                                                   reviewer reads plan
PR merged ──> fresh plan ──> apply (OIDC role, environment gate)
Nightly   ──> plan -detailed-exitcode ──> exit 2 ⇒ drift alert
```

Key decisions baked into that shape:

1. **Plan on PR, apply on merge.** The merge re-plans rather than applying the stale PR plan artifact — simpler, and the `concurrency` group serializes applies. If you need apply-exactly-what-was-reviewed, upload `tfplan` as an artifact on the PR and apply that artifact on merge; accept the trade-off that the world may have moved (the apply will fail if so, which is the safe failure).
2. **One job per root module** (matrix or separate workflows). A monorepo with `environments/{dev,prod}` plans both on PR, applies dev on merge, applies prod behind a GitHub *environment* with required reviewers.
3. **`concurrency` group per state file** so two merges can't apply concurrently (backend locking would catch it, but failing fast in CI is cleaner).

## OIDC Cloud Auth — no long-lived keys

This is non-negotiable and matches the repo's supply-chain doctrine (short-lived tokens over standing credentials; a leaked workflow can't exfiltrate what doesn't exist). GitHub mints a signed JWT per job; the cloud trusts GitHub's issuer for *specific repos/branches* and returns temporary credentials.

### AWS

```yaml
permissions:
  id-token: write      # REQUIRED for OIDC
  contents: read

steps:
  - uses: aws-actions/configure-aws-credentials@v5
    with:
      role-to-assume: arn:aws:iam::123456789012:role/github-terraform-plan
      aws-region: ap-southeast-2
```

Trust policy on the role — scope it tight:

```json
{
  "Effect": "Allow",
  "Principal": { "Federated": "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com" },
  "Action": "sts:AssumeRoleWithWebIdentity",
  "Condition": {
    "StringEquals": { "token.actions.githubusercontent.com:aud": "sts.amazonaws.com" },
    "StringLike":   { "token.actions.githubusercontent.com:sub": "repo:myorg/infra:ref:refs/heads/main" }
  }
}
```

- **Two roles**: a read-only `plan` role (assumable from any branch/PR) and a write `apply` role (assumable only from `ref:refs/heads/main` or `environment:prod`). PR plans from forks then physically cannot mutate anything.
- Audit the trust federation periodically — stale OIDC subjects (deleted repos, renamed branches) with live trust are exactly the entry point the 2026 supply-chain worms abused. `zizmor` catches `pull_request_target` + OIDC misconfigs statically.

### Azure / GCP equivalents

```yaml
# Azure — federated credential on an app registration
- uses: azure/login@v2
  with:
    client-id: ${{ vars.AZURE_CLIENT_ID }}
    tenant-id: ${{ vars.AZURE_TENANT_ID }}
    subscription-id: ${{ vars.AZURE_SUBSCRIPTION_ID }}

# GCP — workload identity federation
- uses: google-github-actions/auth@v3
  with:
    workload_identity_provider: projects/123/locations/global/workloadIdentityPools/github/providers/myorg
    service_account: terraform@myproj.iam.gserviceaccount.com
```

## Plan as PR Comment

The reviewer must see the plan without leaving the PR. Minimal recipe (full version in the asset):

```yaml
- name: Plan
  id: plan
  run: terraform plan -no-color -input=false -out=tfplan 2>&1 | tee plan.txt

- name: Comment plan on PR
  uses: actions/github-script@v8
  with:
    script: |
      const fs = require('fs');
      const plan = fs.readFileSync('plan.txt', 'utf8').slice(0, 60000); // comment size cap
      const body = `### Terraform plan — \`prod\`\n<details><summary>Show plan</summary>\n\n\`\`\`hcl\n${plan}\n\`\`\`\n</details>`;
      // find-and-update existing comment instead of stacking new ones
      const { data: comments } = await github.rest.issues.listComments({ ...context.repo, issue_number: context.issue.number });
      const prev = comments.find(c => c.body.startsWith('### Terraform plan — `prod`'));
      if (prev) await github.rest.issues.updateComment({ ...context.repo, comment_id: prev.id, body });
      else await github.rest.issues.createComment({ ...context.repo, issue_number: context.issue.number, body });
```

Notes:

- **Update-in-place** (find previous comment) or every push spams the PR.
- Truncate: GitHub comments cap at 65,536 chars. For huge plans link to the job log and post only the resource-change summary (`terraform show -json tfplan | jq -r '.resource_changes[] | "\(.change.actions | join(",")) \(.address)"'`).
- Plans can leak values — `sensitive = true` redacts in plan output, but data sources and resource attributes are not all marked. Treat the PR comment as visible to everyone with repo read.

## Policy Gates

| Tool | Layer | What it catches | Invocation |
|---|---|---|---|
| `terraform fmt -check -recursive` | style | Unformatted code | exit ≠ 0 fails CI |
| `terraform validate` | syntax | Type errors, bad references | needs `init` (use `-backend=false` for speed) |
| `tflint` | lint | Provider-aware errors: invalid instance types, deprecated syntax, unused declarations | `tflint --init && tflint --recursive` |
| `trivy config .` | security | Misconfig: public buckets, open SGs, unencrypted disks (absorbed tfsec's rule set) | exit codes; SARIF upload for code-scanning UI |
| `checkov -d .` | security | Same space as trivy; bigger policy library, more noise — pick ONE of trivy/checkov | `--soft-fail` while triaging |
| `conftest test tfplan.json` | org policy | YOUR rules in Rego/OPA: "no resources without tags", "only approved regions", "no IAM * actions" | run against `terraform show -json tfplan` |

```hcl
# .tflint.hcl
plugin "aws" {
  enabled = true
  version = "0.40.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}
rule "terraform_required_version" { enabled = true }
rule "terraform_naming_convention" { enabled = true }
```

```rego
# policy/tags.rego — conftest example against plan JSON
package main
deny[msg] {
  rc := input.resource_changes[_]
  rc.change.actions[_] == "create"
  not rc.change.after.tags.Environment
  msg := sprintf("%s: missing required tag 'Environment'", [rc.address])
}
```

Layering guidance: fmt/validate/tflint are table stakes on every PR. trivy *or* checkov as the misconfig gate (start `--soft-fail`, ratchet to hard once the baseline is clean). conftest/OPA only when you have genuinely org-specific rules the scanners can't express — it's the highest-maintenance layer.

## Workflow Hardening

Same doctrine as the rest of the repo's supply-chain rules:

- **Pin actions to commit SHAs** — `uses: actions/checkout@08c6903cd8c0fde910a37f88322edcfb5dd907a8 # v5.0.0`, not `@v5`. A hijacked tag is a hijacked pipeline with cloud credentials.
- `permissions:` block at workflow top, least privilege (`contents: read` default; `id-token: write` only on jobs that auth to cloud; `pull-requests: write` only on the comment job).
- **Never `pull_request_target` with checkout of PR head** for terraform repos — that's RCE-with-secrets for any fork.
- Plan jobs from forks: read-only role or no cloud auth at all (validate/lint only).
- `step-security/harden-runner` for egress allow-listing on apply jobs if you want runtime control.
- Pin the terraform version: `hashicorp/setup-terraform@<sha>` with `terraform_version: 1.15.5` (or `opentofu/setup-opentofu` with `tofu_version`), matching `required_version`.

## Drift Detection Job

```yaml
on:
  schedule: [{ cron: "17 18 * * *" }]   # nightly; odd minute avoids the top-of-hour stampede
jobs:
  drift:
    permissions: { id-token: write, contents: read }
    steps:
      # ... checkout, setup, OIDC auth (read-only role), init ...
      - name: Detect drift
        run: |
          set +e
          terraform plan -detailed-exitcode -lock=false -input=false -no-color
          code=$?
          if [ "$code" -eq 2 ]; then echo "::error::Drift detected"; exit 1; fi
          exit $code
```

Wire the failure to Slack/issue creation. Exit 2 means *either* console drift or merged-but-unapplied config — both are findings.

## Orchestrator Alternatives

| | Model | Locking | Policy | Cost | Pick when |
|---|---|---|---|---|---|
| **GitHub Actions (DIY)** | Workflows you own | `concurrency` groups | tflint/trivy/conftest steps | Free-ish | Default. Full control, template in assets/ |
| **Atlantis** | Self-hosted server; `atlantis plan` / `atlantis apply` PR comments | Per-directory PR locks (best-in-class) | Custom workflows + conftest | Server you run | Many roots, many PRs, comment-driven culture |
| **HCP Terraform** | Managed runs + state + UI | Workspace runs serialize | Sentinel / OPA | Free ≤ 500 resources, then $$ | Want managed everything; Sentinel policy; private registry |
| **Spacelift / env0 / Scalr** | Commercial SaaS orchestrators | Built-in | OPA-based | $$ | Enterprise multi-IaC (Pulumi/CFN too), RBAC needs |
| **Digger** | Runs inside *your* GitHub Actions | Orchestrated via PR | Pluggable | OSS core | Atlantis UX without hosting a server |

OpenTofu note: Atlantis, Spacelift, env0, Digger all support `tofu` as the binary. HCP Terraform does not run OpenTofu.
