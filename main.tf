# ---------------------------------------------------------
# Resource Group
# ---------------------------------------------------------
resource "azurerm_resource_group" "rg" {
  name     = "rg-${var.application_name}-${var.environment_name}"
  location = var.primary_location
}

# ---------------------------------------------------------
# Storage Account for Function App (Flex infra requirement)
# ---------------------------------------------------------
resource "azurerm_storage_account" "func_sa" {
  name                     = var.storage_account_name
  resource_group_name      = azurerm_resource_group.rg.name
  location                 = azurerm_resource_group.rg.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  account_kind             = "StorageV2"
  min_tls_version          = "TLS1_2"
  network_rules {
    default_action = "Allow"
    bypass         = ["AzureServices"]
    # No ip_rules or virtual_network_subnet_ids, so all networks are allowed
  }
}

# ---------------------------------------------------------
# Storage Container for Flex Consumption deployment
# ---------------------------------------------------------
resource "azurerm_storage_container" "func_container" {
  name                  = "function-releases"
  storage_account_id    = azurerm_storage_account.func_sa.id
  container_access_type = "private"
}

# ---------------------------------------------------------
# Flex Consumption Plan
# ---------------------------------------------------------
resource "azurerm_service_plan" "plan" {
  name                = "${var.application_name}-${var.environment_name}-plan"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  os_type             = "Linux"
  sku_name            = "FC1"
}

# ---------------------------------------------------------
# Bootstrap Key Vault (Cloudflare token)
# ---------------------------------------------------------
data "azurerm_key_vault" "bootstrap" {
  name                = var.bootstrap_key_vault_name
  resource_group_name = var.bootstrap_key_vault_resource_group_name
}

data "azurerm_key_vault_secret" "cloudflare_token" {
  name         = var.cloudflare_api_token_secret_name
  key_vault_id = data.azurerm_key_vault.bootstrap.id
}

# ---------------------------------------------------------
# Target Key Vault (firewall managed by function)
# ---------------------------------------------------------
data "azurerm_key_vault" "target" {
  name                = var.target_key_vault_name
  resource_group_name = var.target_key_vault_resource_group_name
}

# ---------------------------------------------------------
# Target Storage Accounts (looked up from the map variable)
# ---------------------------------------------------------
data "azurerm_storage_account" "target" {
  for_each            = var.target_storage_accounts
  name                = each.key
  resource_group_name = each.value
}

# ---------------------------------------------------------
# Function App (Flex Consumption, Python v2)
# ---------------------------------------------------------
resource "azurerm_function_app_flex_consumption" "func" {
  name                = "${var.application_name}-${var.environment_name}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  service_plan_id     = azurerm_service_plan.plan.id

  storage_container_type      = "blobContainer"
  storage_container_endpoint  = "${azurerm_storage_account.func_sa.primary_blob_endpoint}${azurerm_storage_container.func_container.name}"
  storage_authentication_type = "StorageAccountConnectionString"
  storage_access_key          = azurerm_storage_account.func_sa.primary_access_key

  runtime_name    = "python"
  runtime_version = "3.12"

  https_only = true

  identity {
    type = "SystemAssigned"
  }

  site_config {}

  app_settings = {
    "PYTHONPATH"                = "/home/site/wwwroot/.python_packages/lib/site-packages"
    "FUNCTION_APP_NAME"         = "sync_cloudflare_ip"
    "SUBSCRIPTION_ID"           = var.subscription_id
    "FUNC_STORAGE_ACCOUNT_NAME" = azurerm_storage_account.func_sa.name
    "TARGET_STORAGE_ACCOUNTS"   = jsonencode(var.target_storage_accounts)
    "TARGET_KEY_VAULT"          = var.target_key_vault_name
    "TARGET_KEY_VAULT_RG"       = var.target_key_vault_resource_group_name
    "RESOURCE_GROUP"            = azurerm_resource_group.rg.name
    "CF_ZONE_ID"                = var.cloudflare_zone_id
    "CF_RECORD_ID"              = var.cloudflare_record_id
    "CF_API_TOKEN"              = data.azurerm_key_vault_secret.cloudflare_token.value
  }
}



# ---------------------------------------------------------
# Role Assignments — managed identity on target storage accounts
# ---------------------------------------------------------

# Role on the function app's own storage account (sahomelabipsyncprod)
resource "azurerm_role_assignment" "func_sa_network_contrib" {
  scope                = azurerm_storage_account.func_sa.id
  role_definition_name = "Storage Account Contributor"
  principal_id         = azurerm_function_app_flex_consumption.func.identity[0].principal_id
}

# Roles on any additional target storage accounts from the map variable
resource "azurerm_role_assignment" "target_storage_network_contrib" {
  for_each = {
    for k, v in data.azurerm_storage_account.target : k => v
    if k != azurerm_storage_account.func_sa.name
  }
  scope                = each.value.id
  role_definition_name = "Storage Account Contributor"
  principal_id         = azurerm_function_app_flex_consumption.func.identity[0].principal_id
}

# Role on target Key Vault
resource "azurerm_role_assignment" "target_keyvault_network_contrib" {
  scope                = data.azurerm_key_vault.target.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_function_app_flex_consumption.func.identity[0].principal_id
}

# Role on target Function App
resource "azurerm_role_assignment" "target_func_network_contrib" {
  scope                = azurerm_function_app_flex_consumption.func.id
  role_definition_name = "Contributor"
  principal_id         = azurerm_function_app_flex_consumption.func.identity[0].principal_id
}
