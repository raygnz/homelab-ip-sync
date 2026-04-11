terraform {
  backend "azurerm" {
    resource_group_name  = "rg-homelab-backend-prod"
    storage_account_name = "stquht6a84zm"
    container_name       = "tfstate"
    key                  = "homelab-ip-sync.tfstate"
  }
}
