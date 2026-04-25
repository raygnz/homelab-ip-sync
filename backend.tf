terraform {
  backend "azurerm" {
    resource_group_name  = "rg-homelab-backend-prod"
    storage_account_name = "sahomelabbackendprod"
    container_name       = "tfstate"
    key                  = "homelab-ip-sync.tfstate"
  }
}
