// Resource Group
resource "azurerm_resource_group" "rg" {
  name     = "rg-${var.application_name}-${var.environment_name}"
  location = var.primary_location
}

locals {
  target_storage_account_resource_group_name = coalesce(
    var.target_storage_account_resource_group_name,
    azurerm_resource_group.rg.name
  )
}

// Random suffix for unique storage account name
resource "random_string" "suffix" {
  length  = 10
  upper   = false
  special = false
}

// Storage Account for Function App
resource "azurerm_storage_account" "func_sa" {
  name                     = "st${random_string.suffix.result}"
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
  sku_name            = "Y1"
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

// Target storage account whose firewall rules will be managed by the function
data "azurerm_storage_account" "target" {
  name                = var.target_storage_account_name
  resource_group_name = local.target_storage_account_resource_group_name
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

// Function App
resource "azurerm_linux_function_app" "func" {
  name                       = "${var.application_name}-${var.environment_name}"
  resource_group_name        = azurerm_resource_group.rg.name
  location                   = azurerm_resource_group.rg.location
  service_plan_id            = azurerm_service_plan.plan.id
  storage_account_name       = azurerm_storage_account.func_sa.name
  storage_account_access_key = azurerm_storage_account.func_sa.primary_access_key
  https_only                 = true

  site_config {
    application_stack {
      python_version = "3.10"
    }
  }

  app_settings = {
    "SUBSCRIPTION_ID"        = var.subscription_id
    "TARGET_RESOURCE_GROUP"  = local.target_storage_account_resource_group_name
    "TARGET_STORAGE_ACCOUNT" = data.azurerm_storage_account.target.name

    // Cloudflare
    "CF_ZONE_ID"   = var.cloudflare_zone_id
    "CF_RECORD_ID" = var.cloudflare_record_id
    "CF_API_TOKEN" = data.azurerm_key_vault_secret.cloudflare_token.value

    "FUNCTIONS_WORKER_RUNTIME" = "python"
    "WEBSITE_RUN_FROM_PACKAGE" = "${azurerm_storage_blob.function_zip.url}${data.azurerm_storage_account_blob_container_sas.function_package.sas}"
  }

  identity {
    type = "SystemAssigned"
  }
}

// Role Assignment for the Function App managed identity on the target storage account
resource "azurerm_role_assignment" "target_storage_network_contrib" {
  scope                = data.azurerm_storage_account.target.id
  role_definition_name = "SA KV Network Rules Contributor"
  principal_id         = azurerm_linux_function_app.func.identity[0].principal_id
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
