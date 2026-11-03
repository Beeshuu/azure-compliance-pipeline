# Azure compliance pipeline

A Python Azure Function finds resources that are non-compliant with Azure Policy. Azure Monitor emails you about them, and Microsoft Sentinel can optionally raise incidents. Terraform deploys everything from GitHub Actions over OIDC, so GitHub holds no secrets.

```
 GitHub Actions ──OIDC──► plan identity (read-only)       : plans on PRs and main
                    └───► deploy identity (approval-gated): apply saved plan, deploy code
 ┌──────────────────────────── workload resource group ────────────────────────────┐
 │  Function App (Flex Consumption, Python, managed identity)                      │
 │    hourly ─► Azure Resource Graph (policy states) ─► logs one line per finding  │
 │       │ Key Vault reference                                                     │
 │  Key Vault (RBAC, purge protection) ── audit logs ──┐                           │
 │  Application Insights ──► Log Analytics ◄───────────┘                           │
 │                              ├─► Azure Monitor alerts ─► email                  │
 │                              └─► Sentinel analytics rule (optional) ─► incidents│
 └─────────────────────────────────────────────────────────────────────────────────┘
```

| Path | Purpose |
|---|---|
| `bootstrap/main.tf` | One-time admin step: state storage, workload resource group, GitHub OIDC identities and their RBAC |
| `infra/main.tf` | The workload: function app, Key Vault, monitoring, alerts, policy assignments, Sentinel |
| `infra/terraform.tfvars` | Alert email, scan schedule, Sentinel toggle |
| `function_app/` | The detector and its tests |
| `.github/workflows/pipeline.yml` | PRs: test, validate, plan as a comment. `main`: the same, then approval, apply, deploy |

## Security model

| Identity | Access |
|---|---|
| **plan** (pull requests and `main`) | Reader on the subscription, read-only state access, Key Vault Secrets User, and two `list` actions Terraform refresh needs. Plans run with `-lock=false`. |
| **deploy** (only the `production` environment) | Contributor on the workload RG, state write, Resource Policy Contributor. It may only assign *Reader* (subscription) and *Key Vault Secrets User/Officer* or *Storage Blob Data Owner* (workload RG), enforced by ABAC conditions. |
| **Function app** (system-assigned) | Reader on the subscription, Blob Data Owner on its storage, Key Vault Secrets User |

Key Vault uses RBAC only. The App Insights connection string, its one secret, reaches the app as a Key Vault reference. Storage accounts have shared keys disabled, and Log Analytics has local auth disabled. Fork PRs get no OIDC token, and the deploy job applies exactly the reviewed plan.

## Setup

You need Terraform ≥ 1.11, the Azure CLI, the GitHub CLI, **Owner** on the subscription, and permission to create Entra app registrations.

1. Bootstrap, once, from your machine. Keep the resulting `terraform.tfstate`; you need it to change the identities later.
   ```bash
   az login
   cd bootstrap
   cat > terraform.tfvars <<'EOF'
   subscription_id   = "00000000-0000-0000-0000-000000000000"
   github_repository = "your-org/azure-compliance-pipeline"
   EOF
   terraform init && terraform apply
   ```
2. Set the GitHub repository variables:
   ```bash
   terraform output -raw gh_cli_commands | bash
   ```
3. In GitHub → Settings → Environments, create `production` and add required reviewers.
4. Push to `main`. The pipeline plans, waits for approval, then applies and deploys the code.

## What to expect

- **Delay before results.** New policy assignments take about 30 minutes to evaluate, and Azure rescans about every 24 hours. The detector reports whatever state Azure has recorded.
- **One early alert.** The *scanner has not completed a scan* alert will likely fire once before the first hourly run, then clear on its own.
- **Email pattern.** Findings alerts are stateful and split per policy assignment: one email when an assignment starts failing, one when it clears.
- **Seeing the list.** `terraform -chdir=infra output -raw findings_query` prints a query that lists current findings in Log Analytics.

## Sentinel

Set `enable_sentinel = true` in `infra/terraform.tfvars`.

- **What it adds:** one alert per resource/policy pair not seen in the previous 24 hours. Incidents are grouped per resource.
- **Cost:** billed per GB ingested. Log retention rises from 31 to 90 days, which Sentinel includes.

## Trade-offs

- **Public endpoints.** Key Vault and storage accept public traffic, but every request must be authenticated with Entra ID. GitHub-hosted runners need to reach them.
- **Plan identity can read the secret.** It has Key Vault read access because Terraform refresh calls `GetSecret`. The one secret is the App Insights connection string, which can send telemetry but not read it.
- **Saved plans contain sensitive attributes.** The artifact is kept for one day.

## Local development

```bash
cd function_app
python3.12 -m venv .venv && . .venv/bin/activate
pip install -r requirements.txt pytest ruff
pytest && ruff check . && ruff format --check .
```
