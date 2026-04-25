// Resource Group
resource "azurerm_resource_group" "rg" {
  name     = "rg-${var.application_name}-${var.environment_name}"
  location = var.primary_location
}

// Storage Account for Function App
resource "azurerm_storage_account" "func_sa" {
  name                     = var.storage_account_name
  resource_group_name      = azurerm_resource_group.rg.name
  location                 = azurerm_resource_group.rg.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  account_kind             = "StorageV2"
  min_tls_version          = "TLS1_2"
}

// Storage Container for Function App code
resource "azurerm_storage_container" "func_container" {
  name                  = "function-releases"
  storage_account_id    = azurerm_storage_account.func_sa.id
  container_access_type = "private"
}

// App Service Plan
resource "azurerm_service_plan" "plan" {
  name                = "${var.application_name}-${var.environment_name}-plan"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  os_type             = "Linux"
  sku_name            = "FC1"
}

// key vault data source to retrieve secrets for the Function App
data "azurerm_key_vault" "bootstrap" {
  name                = var.bootstrap_key_vault_name
  resource_group_name = var.bootstrap_key_vault_resource_group_name
}

// Retrieve Cloudflare API token from Key Vault
data "azurerm_key_vault_secret" "cloudflare_token" {
  name         = var.cloudflare_api_token_secret_name
  key_vault_id = data.azurerm_key_vault.bootstrap.id
}

// Data source for the target Key Vault whose firewall rules will be managed by the function
data "azurerm_key_vault" "target" {
  name                = var.target_key_vault_name
  resource_group_name = var.target_key_vault_resource_group_name
}

// Storage account managed by Terraform
resource "azurerm_storage_account" "ipsync" {
  name                     = "sahomelabipsyncprod"
  resource_group_name      = "rg-homelab-ip-sync-prod"
  location                 = var.primary_location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  account_kind             = "StorageV2"
  min_tls_version          = "TLS1_2"
}

// Reference backend storage account (do not manage)
data "azurerm_storage_account" "backend" {
  name                = "sahomelabbackendprod"
  resource_group_name = "rg-homelab-backend-prod"
}

// Shared-access signature for the deployment package
data "azurerm_storage_account_blob_container_sas" "function_package" {
  connection_string = azurerm_storage_account.func_sa.primary_connection_string
  container_name    = azurerm_storage_container.func_container.name
  https_only        = true
  start             = timestamp()
  expiry            = timeadd(timestamp(), "8760h")

  permissions {
    read   = true
    add    = false
    create = false
    write  = false
    delete = false
    list   = false
  }
}

// Function App (Flex Consumption)
resource "azurerm_function_app_flex_consumption" "func" {
  site_config {
    # Add any required settings here. This block is required even if empty.
  }
  name                        = "${var.application_name}-${var.environment_name}"
  resource_group_name         = azurerm_resource_group.rg.name
  location                    = azurerm_resource_group.rg.location
  service_plan_id             = azurerm_service_plan.plan.id
  storage_container_type      = "blobContainer"
  storage_container_endpoint  = azurerm_storage_container.func_container.id
  storage_authentication_type = "SystemAssignedIdentity"
  runtime_name                = "python"
  runtime_version             = "3.10"
  https_only                  = true
  identity {
    type = "SystemAssigned"
  }
  app_settings = {
    "SUBSCRIPTION_ID"         = var.subscription_id
    "TARGET_STORAGE_ACCOUNTS" = jsonencode(var.target_storage_accounts)
    "TARGET_KEY_VAULT"        = var.target_key_vault_name
    "TARGET_KEY_VAULT_RG"     = var.target_key_vault_resource_group_name

    // Cloudflare
    "CF_ZONE_ID"   = var.cloudflare_zone_id
    "CF_RECORD_ID" = var.cloudflare_record_id
    "CF_API_TOKEN" = data.azurerm_key_vault_secret.cloudflare_token.value

    "FUNCTIONS_WORKER_RUNTIME"       = "python"
    "WEBSITE_RUN_FROM_PACKAGE"       = "${azurerm_storage_blob.function_zip.url}${data.azurerm_storage_account_blob_container_sas.function_package.sas}"
    "SCM_DO_BUILD_DURING_DEPLOYMENT" = "true"
  }
}

// Role Assignment for the Function App managed identity on the target storage account
resource "azurerm_role_assignment" "target_storage_network_contrib" {
  for_each = {
    sahomelabipsyncprod  = azurerm_storage_account.ipsync.id
    sahomelabbackendprod = data.azurerm_storage_account.backend.id
  }
  scope                = each.value
  role_definition_name = "SA KV Network Rules Contributor"
  principal_id         = azurerm_function_app_flex_consumption.func.identity[0].principal_id
}
resource "azurerm_role_assignment" "target_keyvault_network_contrib" {
  scope                = data.azurerm_key_vault.target.id
  role_definition_name = "SA KV Network Rules Contributor"
  principal_id         = azurerm_function_app_flex_consumption.func.identity[0].principal_id
}
// Archive Function App code
data "archive_file" "function_zip" {
  type        = "zip"
  source_dir  = "${path.module}/function"
  output_path = "${path.module}/function.zip"
}

// Upload Function App code to blob
resource "azurerm_storage_blob" "function_zip" {
  name                   = "function.zip"
  storage_account_name   = azurerm_storage_account.func_sa.name
  storage_container_name = azurerm_storage_container.func_container.name
  type                   = "Block"
  source                 = data.archive_file.function_zip.output_path
}
