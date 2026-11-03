terraform {
  required_version = ">= 1.11"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.12"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.14"
    }
  }

  backend "azurerm" {
    use_azuread_auth = true
  }
}

provider "azurerm" {
  features {
    key_vault {
      purge_soft_delete_on_destroy = false
    }
  }

  subscription_id                 = var.subscription_id
  storage_use_azuread             = true
  resource_provider_registrations = "none"
}

variable "subscription_id" {
  type = string
}

variable "resource_group_name" {
  description = "Workload resource group created by bootstrap."
  type        = string
}

variable "plan_principal_id" {
  description = "Object ID of the read-only CI identity."
  type        = string
}

variable "deploy_principal_id" {
  description = "Object ID of the deploy CI identity."
  type        = string
}

variable "prefix" {
  description = "Must match bootstrap."
  type        = string
  default     = "cmpl"

  validation {
    condition     = can(regex("^[a-z0-9]{2,6}$", var.prefix))
    error_message = "prefix must be 2-6 lowercase letters or digits."
  }
}

variable "environment" {
  description = "Must match bootstrap."
  type        = string
  default     = "prod"

  validation {
    condition     = can(regex("^[a-z0-9]{2,5}$", var.environment))
    error_message = "environment must be 2-5 lowercase letters or digits."
  }
}

variable "scan_schedule" {
  description = "NCRONTAB (six fields, UTC). The alert windows assume roughly hourly scans."
  type        = string
  default     = "0 0 * * * *"
}

variable "alert_email_addresses" {
  type = list(string)

  validation {
    condition     = length(var.alert_email_addresses) > 0
    error_message = "Provide at least one email address."
  }
}

variable "enable_sentinel" {
  description = "Onboard Microsoft Sentinel (billed per GB ingested) and add the analytics rule."
  type        = bool
  default     = false
}

variable "baseline_policies" {
  description = "Built-in Audit policies assigned to the subscription, as assignment name => definition GUID."
  type        = map(string)
  default = {
    "storage-secure-transfer"      = "404c3081-a854-4457-ae30-26a93ef643f9"
    "storage-no-shared-key"        = "8c6a50c6-9ffd-4ae7-986f-5fa6111f9a54"
    "keyvault-deletion-protection" = "0b60c0b2-2dc2-4e1c-b5c9-abbed971de53"
    "functionapp-https-only"       = "6d555dd1-86f2-4f1c-8ed7-5abae7c6cbab"
  }
}

data "azurerm_client_config" "current" {}

data "azurerm_resource_group" "main" {
  name = var.resource_group_name
}

locals {
  name     = "${var.prefix}-${var.environment}"
  rg       = data.azurerm_resource_group.main.name
  location = data.azurerm_resource_group.main.location
  suffix   = substr(sha1("${var.subscription_id}/${var.environment}"), 0, 6)
  tags     = { project = "compliance-pipeline", environment = var.environment }
}

resource "azurerm_log_analytics_workspace" "main" {
  name                         = "log-${local.name}"
  resource_group_name          = local.rg
  location                     = local.location
  retention_in_days            = var.enable_sentinel ? 90 : 31
  local_authentication_enabled = false
  tags                         = local.tags
}

resource "azurerm_application_insights" "main" {
  name                = "appi-${local.name}"
  resource_group_name = local.rg
  location            = local.location
  workspace_id        = azurerm_log_analytics_workspace.main.id
  application_type    = "other"
  tags                = local.tags
}

resource "azurerm_monitor_diagnostic_setting" "key_vault" {
  name                       = "to-log-analytics"
  target_resource_id         = azurerm_key_vault.main.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.main.id

  enabled_log {
    category_group = "audit"
  }
}

resource "azurerm_key_vault" "main" {
  name                       = "kv-${local.name}-${local.suffix}"
  resource_group_name        = local.rg
  location                   = local.location
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  rbac_authorization_enabled = true
  purge_protection_enabled   = true
  tags                       = local.tags
}

resource "azurerm_role_assignment" "deployer_secrets_officer" {
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = var.deploy_principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "plan_secrets_user" {
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = var.plan_principal_id
  principal_type       = "ServicePrincipal"
}

resource "time_sleep" "rbac_propagation" {
  create_duration = "90s"
  depends_on      = [azurerm_role_assignment.deployer_secrets_officer]
}

resource "azurerm_key_vault_secret" "appinsights_connection_string" {
  name             = "appinsights-connection-string"
  key_vault_id     = azurerm_key_vault.main.id
  value_wo         = azurerm_application_insights.main.connection_string
  value_wo_version = parseint(substr(sha1(azurerm_application_insights.main.id), 0, 8), 16)
  depends_on       = [time_sleep.rbac_propagation]
}

resource "azurerm_storage_account" "function" {
  name                            = "st${var.prefix}fn${local.suffix}"
  resource_group_name             = local.rg
  location                        = local.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  shared_access_key_enabled       = false
  default_to_oauth_authentication = true
  allow_nested_items_to_be_public = false
  tags                            = local.tags
}

resource "azurerm_storage_container" "deployment" {
  name               = "app-package"
  storage_account_id = azurerm_storage_account.function.id
}

resource "azurerm_service_plan" "function" {
  name                = "asp-${local.name}"
  resource_group_name = local.rg
  location            = local.location
  os_type             = "Linux"
  sku_name            = "FC1"
  tags                = local.tags
}

resource "azurerm_function_app_flex_consumption" "main" {
  name                                           = "func-${local.name}-${local.suffix}"
  resource_group_name                            = local.rg
  location                                       = local.location
  service_plan_id                                = azurerm_service_plan.function.id
  runtime_name                                   = "python"
  runtime_version                                = "3.12"
  instance_memory_in_mb                          = 512
  storage_container_type                         = "blobContainer"
  storage_container_endpoint                     = "${azurerm_storage_account.function.primary_blob_endpoint}${azurerm_storage_container.deployment.name}"
  storage_authentication_type                    = "SystemAssignedIdentity"
  https_only                                     = true
  webdeploy_publish_basic_authentication_enabled = false

  identity {
    type = "SystemAssigned"
  }

  site_config {
    application_insights_connection_string = "@Microsoft.KeyVault(SecretUri=${azurerm_key_vault_secret.appinsights_connection_string.versionless_id})"
  }

  app_settings = {
    AzureWebJobsStorage__accountName = azurerm_storage_account.function.name
    AzureWebJobsStorage__credential  = "managedidentity"
    SCAN_SUBSCRIPTION_IDS            = var.subscription_id
    SCAN_SCHEDULE                    = var.scan_schedule
  }

  tags = local.tags
}

locals {
  function_principal_id = azurerm_function_app_flex_consumption.main.identity[0].principal_id
}

resource "azurerm_role_assignment" "function_storage" {
  scope                = azurerm_storage_account.function.id
  role_definition_name = "Storage Blob Data Owner"
  principal_id         = local.function_principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "function_secrets_user" {
  scope                = azurerm_key_vault.main.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = local.function_principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "function_reader" {
  scope                = "/subscriptions/${var.subscription_id}"
  role_definition_name = "Reader"
  principal_id         = local.function_principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_subscription_policy_assignment" "baseline" {
  for_each = var.baseline_policies

  name                 = "${local.name}-${each.key}"
  display_name         = "[${local.name}] ${each.key}"
  subscription_id      = "/subscriptions/${var.subscription_id}"
  policy_definition_id = "/providers/Microsoft.Authorization/policyDefinitions/${each.value}"
}

locals {
  finding_marker = "COMPLIANCE_FINDING "
  scan_marker    = "COMPLIANCE_SCAN_COMPLETED "

  findings_kql = <<-KQL
    AppTraces
    | where Message startswith "${local.finding_marker}"
    | extend f = parse_json(substring(Message, strlen("${local.finding_marker}")))
    | project TimeGenerated,
        ResourceId = tostring(f.resourceId),
        ResourceType = tostring(f.resourceType),
        ResourceGroup = tostring(f.resourceGroup),
        PolicyAssignment = tostring(f.policyAssignment),
        PolicyDefinition = tostring(f.policyDefinitionName),
        Effect = tostring(f.policyDefinitionAction)
  KQL
}

resource "azurerm_monitor_action_group" "compliance" {
  name                = "ag-${local.name}-compliance"
  resource_group_name = local.rg
  short_name          = "compliance"
  tags                = local.tags

  dynamic "email_receiver" {
    for_each = var.alert_email_addresses

    content {
      name                    = "email-${email_receiver.key}"
      email_address           = email_receiver.value
      use_common_alert_schema = true
    }
  }
}

resource "azurerm_monitor_scheduled_query_rules_alert_v2" "non_compliant" {
  name                    = "alert-${local.name}-non-compliant"
  display_name            = "Non-compliant Azure resources detected"
  description             = "Open the query results for the list of resources."
  resource_group_name     = local.rg
  location                = local.location
  scopes                  = [azurerm_log_analytics_workspace.main.id]
  severity                = 2
  evaluation_frequency    = "PT1H"
  window_duration         = "PT2H"
  auto_mitigation_enabled = true
  skip_query_validation   = true

  criteria {
    query                   = "${chomp(local.findings_kql)}\n| summarize NonCompliantResources = dcount(ResourceId) by PolicyAssignment"
    time_aggregation_method = "Maximum"
    metric_measure_column   = "NonCompliantResources"
    operator                = "GreaterThan"
    threshold               = 0

    dimension {
      name     = "PolicyAssignment"
      operator = "Include"
      values   = ["*"]
    }
  }

  action {
    action_groups = [azurerm_monitor_action_group.compliance.id]
  }

  tags = local.tags
}

resource "azurerm_monitor_scheduled_query_rules_alert_v2" "scanner_silent" {
  name                    = "alert-${local.name}-scanner-silent"
  display_name            = "Compliance scanner has not completed a scan"
  description             = "No successful scan in 3 hours. Check the function app's exceptions in Application Insights."
  resource_group_name     = local.rg
  location                = local.location
  scopes                  = [azurerm_log_analytics_workspace.main.id]
  severity                = 1
  evaluation_frequency    = "PT1H"
  window_duration         = "PT3H"
  auto_mitigation_enabled = true
  skip_query_validation   = true

  criteria {
    query                   = "AppTraces\n| where Message startswith \"${local.scan_marker}\"\n| summarize CompletedScans = count()"
    time_aggregation_method = "Total"
    metric_measure_column   = "CompletedScans"
    operator                = "LessThan"
    threshold               = 1
  }

  action {
    action_groups = [azurerm_monitor_action_group.compliance.id]
  }

  tags = local.tags
}

resource "azurerm_sentinel_log_analytics_workspace_onboarding" "main" {
  count        = var.enable_sentinel ? 1 : 0
  workspace_id = azurerm_log_analytics_workspace.main.id
}

resource "azurerm_sentinel_alert_rule_scheduled" "new_non_compliant_resource" {
  count = var.enable_sentinel ? 1 : 0

  name                       = "compliance-new-non-compliant-resource"
  log_analytics_workspace_id = azurerm_sentinel_log_analytics_workspace_onboarding.main[0].workspace_id
  display_name               = "Resource became non-compliant with Azure Policy"
  severity                   = "Medium"
  query_frequency            = "PT1H"
  query_period               = "PT26H"
  trigger_operator           = "GreaterThan"
  trigger_threshold          = 0

  query = <<-KQL
    let findings = ${chomp(local.findings_kql)};
    let previous = findings
        | where TimeGenerated between (ago(26h) .. ago(2h))
        | distinct ResourceId, PolicyDefinition;
    findings
    | where TimeGenerated > ago(2h)
    | summarize arg_max(TimeGenerated, *) by ResourceId, PolicyDefinition
    | join kind=leftanti previous on ResourceId, PolicyDefinition
  KQL

  event_grouping {
    aggregation_method = "AlertPerResult"
  }

  entity_mapping {
    entity_type = "AzureResource"

    field_mapping {
      identifier  = "ResourceId"
      column_name = "ResourceId"
    }
  }

  custom_details = {
    PolicyAssignment = "PolicyAssignment"
    PolicyDefinition = "PolicyDefinition"
    Effect           = "Effect"
  }

  incident {
    create_incident_enabled = true

    grouping {
      enabled                = true
      lookback_duration      = "P1D"
      entity_matching_method = "AllEntities"
    }
  }
}

output "function_app_name" {
  value = azurerm_function_app_flex_consumption.main.name
}

output "findings_query" {
  description = "Paste into Log Analytics to see the latest findings."
  value       = "${chomp(local.findings_kql)}\n| summarize arg_max(TimeGenerated, *) by ResourceId, PolicyDefinition"
}
