terraform {
  required_version = ">= 1.11"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.12"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.10"
    }
  }
}

provider "azurerm" {
  features {}

  subscription_id     = var.subscription_id
  storage_use_azuread = true

  resource_providers_to_register = [
    "Microsoft.AlertsManagement",
    "Microsoft.Insights",
    "Microsoft.KeyVault",
    "Microsoft.OperationalInsights",
    "Microsoft.OperationsManagement",
    "Microsoft.PolicyInsights",
    "Microsoft.ResourceGraph",
    "Microsoft.SecurityInsights",
    "Microsoft.Storage",
    "Microsoft.Web",
  ]
}

variable "subscription_id" {
  type = string
}

variable "github_repository" {
  description = "owner/name of the repository allowed to federate into Azure."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$", var.github_repository))
    error_message = "github_repository must look like owner/name."
  }
}

variable "location" {
  type    = string
  default = "eastus2"
}

variable "prefix" {
  type    = string
  default = "cmpl"

  validation {
    condition     = can(regex("^[a-z0-9]{2,6}$", var.prefix))
    error_message = "prefix must be 2-6 lowercase letters or digits (it ends up in storage account names)."
  }
}

variable "environment" {
  type    = string
  default = "prod"

  validation {
    condition     = can(regex("^[a-z0-9]{2,5}$", var.environment))
    error_message = "environment must be 2-5 lowercase letters or digits."
  }
}

data "azurerm_client_config" "current" {}

data "azurerm_subscription" "current" {
  subscription_id = var.subscription_id
}

locals {
  name = "${var.prefix}-${var.environment}"
  tags = { project = "compliance-pipeline", environment = var.environment }
}

resource "azurerm_resource_group" "tfstate" {
  name     = "${local.name}-tfstate-rg"
  location = var.location
  tags     = local.tags
}

resource "azurerm_storage_account" "tfstate" {
  name                            = "st${var.prefix}tf${substr(sha1(var.subscription_id), 0, 6)}"
  resource_group_name             = azurerm_resource_group.tfstate.name
  location                        = azurerm_resource_group.tfstate.location
  account_tier                    = "Standard"
  account_replication_type        = "ZRS"
  shared_access_key_enabled       = false
  default_to_oauth_authentication = true
  allow_nested_items_to_be_public = false
  tags                            = local.tags

  blob_properties {
    versioning_enabled = true

    delete_retention_policy {
      days = 30
    }

    container_delete_retention_policy {
      days = 30
    }
  }
}

resource "azurerm_storage_container" "tfstate" {
  name               = "tfstate"
  storage_account_id = azurerm_storage_account.tfstate.id
}

resource "azurerm_resource_group" "workload" {
  name     = "${local.name}-rg"
  location = var.location
  tags     = local.tags
}

locals {
  federation = {
    plan_pull_request = { app = "plan", subject = "pull_request" }
    plan_main         = { app = "plan", subject = "ref:refs/heads/main" }
    deploy_production = { app = "deploy", subject = "environment:production" }
  }
}

resource "azuread_application" "ci" {
  for_each     = toset(["plan", "deploy"])
  display_name = "${local.name}-github-${each.key}"
  owners       = [data.azurerm_client_config.current.object_id]
}

resource "azuread_service_principal" "ci" {
  for_each  = azuread_application.ci
  client_id = each.value.client_id
}

resource "azuread_application_federated_identity_credential" "ci" {
  for_each       = local.federation
  application_id = azuread_application.ci[each.value.app].id
  display_name   = replace(each.key, "_", "-")
  audiences      = ["api://AzureADTokenExchange"]
  issuer         = "https://token.actions.githubusercontent.com"
  subject        = "repo:${var.github_repository}:${each.value.subject}"
}

locals {
  plan_sp   = azuread_service_principal.ci["plan"].object_id
  deploy_sp = azuread_service_principal.ci["deploy"].object_id

  delegable = {
    subscription = ["Reader"]
    workload     = ["Key Vault Secrets User", "Key Vault Secrets Officer", "Storage Blob Data Owner"]
  }

  rbac_condition = <<-EOT
    ((!(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})) OR (@Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {%[1]s}))
    AND
    ((!(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'})) OR (@Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {%[1]s}))
  EOT

  scopes = {
    subscription = data.azurerm_subscription.current.id
    workload     = azurerm_resource_group.workload.id
    state        = azurerm_storage_container.tfstate.id
  }

  assignments = {
    plan_reader        = { principal = local.plan_sp, scope = "subscription", role = "Reader" }
    plan_state         = { principal = local.plan_sp, scope = "state", role = "Storage Blob Data Reader" }
    deploy_contributor = { principal = local.deploy_sp, scope = "workload", role = "Contributor" }
    deploy_state       = { principal = local.deploy_sp, scope = "state", role = "Storage Blob Data Contributor" }
    deploy_policy      = { principal = local.deploy_sp, scope = "subscription", role = "Resource Policy Contributor" }
  }
}

data "azurerm_role_definition" "delegable" {
  for_each = toset(flatten(values(local.delegable)))
  name     = each.value
  scope    = data.azurerm_subscription.current.id
}

resource "azurerm_role_assignment" "ci" {
  for_each             = local.assignments
  scope                = local.scopes[each.value.scope]
  role_definition_name = each.value.role
  principal_id         = each.value.principal
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "deploy_rbac_admin" {
  for_each             = local.delegable
  scope                = local.scopes[each.key]
  role_definition_name = "Role Based Access Control Administrator"
  principal_id         = local.deploy_sp
  principal_type       = "ServicePrincipal"
  condition_version    = "2.0"
  condition = format(local.rbac_condition, join(", ", [
    for role in each.value : data.azurerm_role_definition.delegable[role].role_definition_id
  ]))
}

resource "azurerm_role_definition" "plan_config_reader" {
  name              = "${local.name} Terraform plan config reader"
  scope             = azurerm_resource_group.workload.id
  assignable_scopes = [azurerm_resource_group.workload.id]

  permissions {
    actions = [
      "Microsoft.Web/sites/config/list/action",
      "Microsoft.OperationalInsights/workspaces/sharedKeys/action",
    ]
  }
}

resource "azurerm_role_assignment" "plan_config_reader" {
  scope              = azurerm_resource_group.workload.id
  role_definition_id = azurerm_role_definition.plan_config_reader.role_definition_resource_id
  principal_id       = local.plan_sp
  principal_type     = "ServicePrincipal"
}

output "gh_cli_commands" {
  description = "Run inside the repository clone to set the repository variables the pipeline reads. None are secrets."
  value = join("\n", [for k, v in {
    AZURE_TENANT_ID         = data.azurerm_client_config.current.tenant_id
    AZURE_SUBSCRIPTION_ID   = var.subscription_id
    AZURE_PLAN_CLIENT_ID    = azuread_application.ci["plan"].client_id
    AZURE_DEPLOY_CLIENT_ID  = azuread_application.ci["deploy"].client_id
    PLAN_PRINCIPAL_ID       = local.plan_sp
    DEPLOY_PRINCIPAL_ID     = local.deploy_sp
    TFSTATE_RESOURCE_GROUP  = azurerm_resource_group.tfstate.name
    TFSTATE_STORAGE_ACCOUNT = azurerm_storage_account.tfstate.name
    TFSTATE_CONTAINER       = azurerm_storage_container.tfstate.name
    WORKLOAD_RESOURCE_GROUP = azurerm_resource_group.workload.name
  } : "gh variable set ${k} --repo ${var.github_repository} --body '${v}'"])
}
