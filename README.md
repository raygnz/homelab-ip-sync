# homelab-ip-sync

## Overview

`homelab-ip-sync` is an Azure-based automation solution that keeps your Azure Key Vault and (optionally) target Storage Account firewall rules in sync with the current public IP address assigned to a DNS record managed by Cloudflare.

**The function app’s own storage account is never restricted or managed by the function, ensuring compatibility with Flex Consumption plans.**

## Key Features

- **Azure Function App**: Runs on a schedule to check the current IP address of a specified Cloudflare DNS record.
- **Cloudflare Integration**: Uses the Cloudflare API to read the IP address of a DNS record (e.g., an A record for your home network).
- **Azure Storage/Key Vault Firewall Sync**: Updates a target Azure Storage Account (not the function app's own storage) and Key Vault firewall to allow access from the current Cloudflare IP, ensuring secure and dynamic access.
- **Key Vault Integration**: Retrieves sensitive secrets (like the Cloudflare API token) from Azure Key Vault for enhanced security.
- **Managed Identity Authentication**: Uses the Function App system-assigned managed identity to update the target storage account and Key Vault.
- **Infrastructure as Code**: All resources are provisioned and managed using Terraform for repeatability and easy management.

## How It Works

1. **Scheduled Trigger**: An Azure Function App is triggered on a schedule (e.g., every hour).
2. **Cloudflare DNS Lookup**: The function queries the Cloudflare API to get the current IP address of a specified DNS record.
3. **Azure Authentication**: The function authenticates to Azure using its managed identity.
4. **Firewall Update**: If the IP address has changed, the function updates the target Azure Key Vault and (optionally) target Storage Account firewall rules while preserving unrelated existing allowlist entries.  
	**The function app’s own storage account is never restricted or managed by the function.**
5. **Secret Management**: The Cloudflare API token is read from Azure Key Vault during Terraform deployment and injected as an app setting.

## Files and Structure

- `main.tf`: Terraform configuration for all Azure resources, package deployment, role assignments, and integration with Key Vault and Cloudflare.
- `variables.tf`: Input variables for customization (application name, environment, Cloudflare details, etc.).
- `outputs.tf`: Useful outputs such as resource names and endpoints.
- `provider.tf`: Provider configuration for Azure, archive packaging, and random naming.
- `backend.tf`: Remote state configuration for Terraform.
- `function/`: Contains the Python Azure Function project, including `host.json`, `requirements.txt`, and `function_app.py` (Python v2 decorator model, all triggers in this file).

## Azure Function App Settings & Environment Variables

The following environment variables must be set for the Function App (managed by Terraform):

- `SUBSCRIPTION_ID`: Azure subscription ID
- `CF_ZONE_ID`: Cloudflare zone ID
- `CF_RECORD_ID`: Cloudflare DNS record ID
- `CF_API_TOKEN`: Cloudflare API token (injected from Key Vault)
- `TARGET_STORAGE_ACCOUNTS`: JSON string mapping storage account names to resource group names (should **not** include the function app's own storage account)
- `TARGET_KEY_VAULT`: Name of the Key Vault to manage
- `TARGET_KEY_VAULT_RG`: Resource group of the Key Vault
- `FUNCTION_APP_NAME`: Name of the Function App
- `FUNC_STORAGE_ACCOUNT_NAME`: Name of the function app's own storage account (used to ensure the function never modifies its own storage account)
- `RESOURCE_GROUP`: Resource group of the Function App

**App Settings required for Flex Consumption Python v2:**

- `FUNCTIONS_WORKER_RUNTIME=python`
- `PYTHON_ISOLATE_WORKER_DEPENDENCIES=1`
- `FUNCTIONS_EXTENSION_VERSION=~4`
- `WEBSITE_RUN_FROM_PACKAGE=1`

## Prerequisites

- Azure subscription with permissions to create resource groups, storage accounts, function apps, and Key Vault.
- Cloudflare account with API token (with DNS:Read permission for the relevant zone).
- Terraform installed and configured.

## Setup Instructions

1. **Clone the repository** and navigate to the `homelab-ip-sync` directory.
2. **Configure variables** in `terraform.tfvars` (see variables in `variables.tf`).
3. **Store the Cloudflare API token** in the Key Vault identified by `bootstrap_key_vault_name` and `bootstrap_key_vault_resource_group_name`.
4. **Initialize Terraform**:
	```sh
	terraform init
	```
5. **Plan and apply** the deployment:
	```sh
	terraform plan -var-file=terraform.tfvars
	terraform apply -var-file=terraform.tfvars
	```
6. **Verify** that the Azure Function App is running and updating the Key Vault and (optionally) storage account firewall as expected.

## Security Notes

- The Cloudflare API token should have only DNS:Read permission for least privilege.
- Use Azure Key Vault to store sensitive secrets securely.
- The Function App uses a managed identity with the `Storage Account Contributor` and `Key Vault Secrets User` roles on the target storage account and Key Vault.
- **Do not include the function app's own storage account in `TARGET_STORAGE_ACCOUNTS`.**
- The function app's own storage account is always left open (no firewall restrictions) for Flex Consumption compatibility.
- The function uses the `FUNC_STORAGE_ACCOUNT_NAME` environment variable to ensure it never modifies its own storage account.
- For initial deployment, you may want to allow your deployer IP in Key Vault or target storage account rules (see Terraform data source example in `main.tf`).

## Troubleshooting

- If the function does not load or shows "0 functions found", check:
	- All required environment variables are set and correctly named.
	- The structure: all triggers must be in `function_app.py` at the root of the `function/` folder.
	- Dependency issues: pin versions in `requirements.txt` if needed.
	- App settings for Flex Consumption are present (see above).
- Check the Azure Function App logs for errors if the firewall is not updating.
- Ensure the Function App managed identity has the correct role assignment on the target storage account and Key Vault.
- Verify that the Cloudflare API token is valid and has the required permissions.

## Current Security Model and Flex Consumption Notes

- The Azure Function App (Flex Consumption) **never restricts its own storage account**. This is required for reliable operation and deployment.
- Only target storage accounts (e.g., for tfstate) and Key Vault are managed by the function for IP/firewall rules.
- The function uses the `FUNC_STORAGE_ACCOUNT_NAME` environment variable to ensure it never modifies its own storage account.
- For initial deployment, you may want to allow your deployer IP in Key Vault or target storage account rules (see Terraform data source example).

## License

MIT License

---

This project automates secure, dynamic access to Azure resources for homelab and self-hosted environments using modern cloud-native practices.
