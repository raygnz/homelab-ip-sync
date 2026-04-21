output "storage_account_name" {
  value = azurerm_storage_account.func_sa.name
}

output "function_app_name" {
  value = azurerm_linux_function_app.func.name
}

output "resource_group_name" {
  value = azurerm_resource_group.rg.name
}

output "container_name" {
  value = azurerm_storage_container.func_container.name
}

output "primary_blob_endpoint" {
  value = azurerm_storage_account.func_sa.primary_blob_endpoint
}

output "target_storage_account_id" {
  value = data.azurerm_storage_account.target.id
}
