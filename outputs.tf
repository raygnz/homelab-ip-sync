output "storage_account_name" {
  value = azurerm_storage_account.func_sa.name
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
