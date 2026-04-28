output "storage_account_name" {
  description = "Storage account used by the Function App"
  value       = azurerm_storage_account.func_sa.name
}

output "function_app_name" {
  value = azurerm_function_app_flex_consumption.func.name
}

output "resource_group_name" {
  description = "Resource group of the Function App"
  value       = azurerm_resource_group.rg.name
}

output "function_app_identity_principal_id" {
  description = "Managed identity principal ID for the Function App"
  value       = azurerm_function_app_flex_consumption.func.identity[0].principal_id
}

output "target_storage_account_ids" {
  description = "IDs of storage accounts whose firewall rules are managed"
  value       = { for k, v in data.azurerm_storage_account.target : k => v.id }
}
