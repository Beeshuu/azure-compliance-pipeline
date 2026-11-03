# Azure compliance pipeline

A Python Azure Function checks every hour for resources that don't comply with Azure Policy. Azure Monitor emails you about what it finds, and Microsoft Sentinel can raise incidents if you turn it on. GitHub Actions deploys everything with Terraform and signs in to Azure over OIDC, so GitHub holds no secrets.

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
| `bootstrap/main.tf` | One-time admin step: state storage, the workload resource group, and the GitHub OIDC identities with their RBAC |
| `infra/main.tf` | The workload: function app, Key Vault, monitoring, alerts, policy assignments, Sentinel |
| `infra/terraform.tfvars` | Alert email, scan schedule, Sentinel toggle |
| `function_app/` | The scanner and its tests |
| `.github/workflows/pipeline.yml` | Pull requests: test, validate, and post the plan as a comment. `main`: the same steps, then wait for approval, apply, and deploy the code |

## Security model

| Identity | Access |
|---|---|
| **plan** (pull requests and `main`) | Reader on the subscription, read-only state access, Key Vault Secrets User, and the two `list` actions that Terraform refresh needs. It runs plans with `-lock=false`. |
| **deploy** (`production` environment only) | Contributor on the workload RG, state write, and Resource Policy Contributor. ABAC conditions limit the roles it can assign to *Reader* on the subscription and *Key Vault Secrets User*, *Key Vault Secrets Officer* or *Storage Blob Data Owner* on the workload RG. |
| **Function app** (system-assigned) | Reader on the subscription, Storage Blob Data Owner on its storage account, Key Vault Secrets User |

Key Vault uses RBAC only and holds one secret, the App Insights connection string. The app reads it through a Key Vault reference. Storage accounts have shared keys disabled, and Log Analytics has local auth disabled.

Pull requests from forks get no OIDC token. The deploy job applies the saved plan that reviewers approved, not a new one.

## Setup

You need Terraform 1.11 or later, the Azure CLI, the GitHub CLI, **Owner** on the subscription, and permission to create Entra app registrations.

1. Run the bootstrap once from your own machine. The `gh api` command prints the owner and repository IDs to put in `terraform.tfvars`. Keep the `terraform.tfstate` that the apply creates, because you need it to change the identities later.
   ```bash
   az login
   cd bootstrap
   gh api repos/your-org/azure-compliance-pipeline -q '"owner id: \(.owner.id)  repo id: \(.id)"'
   cat > terraform.tfvars <<'EOF'
   subscription_id      = "00000000-0000-0000-0000-000000000000"
   github_repository    = "your-org/azure-compliance-pipeline"
   github_owner_id      = 0 # from the gh command above
   github_repository_id = 0 # from the gh command above
   EOF
   terraform init && terraform apply
   ```
2. Set the GitHub repository variables from the bootstrap outputs:
   ```bash
   terraform output -raw gh_cli_commands | bash
   ```
3. In GitHub, go to Settings → Environments, create a `production` environment, and add required reviewers.
4. Push to `main`. The pipeline plans, waits for approval, then applies and deploys the code.

## What to expect

- **Results take time.** Azure takes about 30 minutes to evaluate a new policy assignment and rescans about every 24 hours. The scanner reports whatever state Azure has recorded.
- **One early alert.** The *scanner has not completed a scan* alert will likely fire once before the first hourly run, then clear on its own.
- **Two emails per assignment.** Findings alerts are stateful and split by policy assignment. You get one email when an assignment starts failing and another when it clears.
- **Listing findings.** `terraform -chdir=infra output -raw findings_query` prints a query that lists current findings in Log Analytics.

## Sentinel

To turn Sentinel on, set `enable_sentinel = true` in `infra/terraform.tfvars`.

Sentinel raises one alert for each resource and policy pair that hasn't appeared in the previous 24 hours, and groups incidents by resource. It is billed per GB ingested. Log retention rises from 31 to 90 days, and Sentinel includes those 90 days.

## Trade-offs

- **Public endpoints.** Key Vault and storage accept public traffic because GitHub-hosted runners need to reach them. Every request still has to authenticate with Entra ID.
- **The plan identity can read the secret.** Terraform refresh calls `GetSecret`, so the plan identity needs read access to Key Vault. The only secret is the App Insights connection string, which can send telemetry but not read it.
- **Saved plans contain sensitive attributes.** The pipeline keeps the plan artifact for one day.
- **Provider workaround.** On Flex apps, azurerm 5.12 always writes an `AzureWebJobsStorage` connection string with an empty key. That setting overrides the managed-identity settings and breaks host storage, so the deploy job deletes it after every apply.

## Local development

Run the tests and linters from `function_app/`:

```bash
cd function_app
python3.12 -m venv .venv && . .venv/bin/activate
pip install -r requirements.txt pytest ruff
pytest && ruff check . && ruff format --check .
```
