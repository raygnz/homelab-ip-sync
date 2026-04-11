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
// Cloudflare
variable "cloudflare_zone_id" {
  type        = string
  description = "Cloudflare Zone ID for the DNS zone"
}

variable "cloudflare_record_id" {
  type        = string
  description = "Cloudflare Record ID for the DNS record"
}


