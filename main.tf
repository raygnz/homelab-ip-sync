// Resource Group
resource "azurerm_resource_group" "rg" {
  name     = "rg-${var.application_name}-${var.environment_name}"
  location = var.primary_location
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
  storage_account_name  = azurerm_storage_account.func_sa.name
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

// Create an Azure AD Application for the Function App
resource "azuread_application" "app" {
  display_name = "${var.application_name}-${var.environment_name}-app"
}

// Create a Service Principal for the Azure AD Application
resource "azuread_service_principal" "sp" {
  client_id = azuread_application.app.client_id
}

// Create a Service Principal Password for the Azure AD Application
resource "azuread_service_principal_password" "sp_secret" {
  service_principal_id = azuread_service_principal.sp.id
}

// Role Assignment for Storage Account Network Contributor
resource "azurerm_role_assignment" "storage_network_contrib" {
  scope                = azurerm_storage_account.func_sa.id
  role_definition_name = "Storage Account Network Contributor"
  principal_id         = azuread_service_principal.sp.id
}

// key vault data source to retrieve secrets for the Function App
data "azurerm_key_vault" "bootstrap" {
  name                = "kv-homelab-backend-prod"
  resource_group_name = "rg-homelab-backend-prod"
}

// Retrieve Cloudflare API token from Key Vault
data "azurerm_key_vault_secret" "cloudflare_token" {
  name         = "cloudflare-api-token"
  key_vault_id = data.azurerm_key_vault.bootstrap.id
}

// Role Assignment for Function App to read secrets from Key Vault
resource "azurerm_role_assignment" "function_kv_reader" {
  scope                = data.azurerm_key_vault.bootstrap.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_linux_function_app.func.identity[0].principal_id
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
    "TENANT_ID"       = var.tenant_id
    "CLIENT_ID"       = azuread_application.app.client_id
    "CLIENT_SECRET"   = azuread_service_principal_password.sp_secret.value
    "SUBSCRIPTION_ID" = var.subscription_id
    "RESOURCE_GROUP"  = azurerm_resource_group.rg.name
    "STORAGE_ACCOUNT" = azurerm_storage_account.func_sa.name

    // Cloudflare
    "CF_ZONE_ID"   = var.cloudflare_zone_id
    "CF_RECORD_ID" = var.cloudflare_record_id
    "CF_API_TOKEN" = data.azurerm_key_vault_secret.cloudflare_token.value

    "FUNCTIONS_WORKER_RUNTIME" = "python"
    "WEBSITE_RUN_FROM_PACKAGE" = "1"
  }

  identity {
    type = "SystemAssigned"
  }
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

// Deploy Function App from blob (slot)
resource "azurerm_linux_function_app_slot" "deploy" {
  name                       = "production"
  function_app_id            = azurerm_linux_function_app.func.id
  storage_account_name       = azurerm_storage_account.func_sa.name
  storage_account_access_key = azurerm_storage_account.func_sa.primary_access_key

  site_config {
    application_stack {
      python_version = "3.10"
    }
  }
  // App settings for the deployment slot
  app_settings = {
    "WEBSITE_RUN_FROM_PACKAGE" = azurerm_storage_blob.function_zip.url
  }
}
