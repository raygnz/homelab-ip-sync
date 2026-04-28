variable "application_name" {
  type        = string
  description = "Application name for resource naming"
}

variable "environment_name" {
  type        = string
  description = "Environment name (e.g., dev, staging, prod)"
}

variable "primary_location" {
  type        = string
  description = "Primary Azure region for resources"
}

variable "subscription_id" {
  type        = string
  description = "Azure subscription ID"
}

variable "tenant_id" {
  type        = string
  description = "Azure tenant ID"
}

variable "storage_account_name" {
  type        = string
  description = "Storage account name for the Function App"
}

variable "target_storage_accounts" {
  type        = map(string)
  description = "Map of storage account names to their resource group names"
}

variable "target_key_vault_name" {
  type        = string
  description = "Name of the Key Vault whose firewall rules will be managed"
}

variable "target_key_vault_resource_group_name" {
  type        = string
  description = "Resource group of the target Key Vault"
}

variable "bootstrap_key_vault_name" {
  type        = string
  description = "Name of the Key Vault containing the Cloudflare API token"
}

variable "bootstrap_key_vault_resource_group_name" {
  type        = string
  description = "Resource group of the bootstrap Key Vault"
}

variable "cloudflare_api_token_secret_name" {
  type        = string
  description = "Name of the secret storing the Cloudflare API token"
  default     = "cloudflare-api-token"
}

variable "cloudflare_zone_id" {
  type        = string
  description = "Cloudflare Zone ID"
}

variable "cloudflare_record_id" {
  type        = string
  description = "Cloudflare DNS record ID"
}
