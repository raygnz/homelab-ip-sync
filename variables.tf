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
  description = "Primary location for the resources"
}
variable "tenant_id" {
  type        = string
  description = "Tenant ID for the Azure subscription"
}
variable "subscription_id" {
  type        = string
  description = "Subscription ID for the Azure subscription"
}

variable "target_storage_account_name" {
  type        = string
  description = "Name of the existing Azure Storage Account whose firewall rules should be synced to the Cloudflare DNS record IP"
}

variable "target_storage_account_resource_group_name" {
  type        = string
  description = "Resource group containing the target storage account; defaults to the resource group created by this module when null"
  default     = null
}

variable "bootstrap_key_vault_name" {
  type        = string
  description = "Name of the Key Vault containing the Cloudflare API token secret"
}

variable "bootstrap_key_vault_resource_group_name" {
  type        = string
  description = "Resource group containing the bootstrap Key Vault"
}

variable "cloudflare_api_token_secret_name" {
  type        = string
  description = "Name of the Key Vault secret storing the Cloudflare API token"
  default     = "cloudflare-api-token"
}

// Cloudflare
variable "cloudflare_zone_id" {
  type        = string
  description = "Cloudflare Zone ID for the DNS zone"
}

variable "cloudflare_record_id" {
  type        = string
  description = "Cloudflare Record ID for the DNS record"
}


