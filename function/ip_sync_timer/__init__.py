import logging
import os
import json
import azure.functions as func
import requests
from azure.identity import DefaultAzureCredential
from azure.mgmt.storage import StorageManagementClient
from azure.mgmt.storage.models import IPRule, NetworkRuleSet, StorageAccountUpdateParameters
from azure.mgmt.keyvault import KeyVaultManagementClient
from azure.mgmt.keyvault.models import NetworkRuleSet as KVNetworkRuleSet, VaultPatchParameters

MANAGED_IP_TAG_NAME = "homelab-ip-sync-last-ip"

def _build_updated_ip_rules(existing_rules, previous_managed_ip, resolved_ip):
    updated_rules = []
    resolved_ip_present = False
    for rule in existing_rules:
        ip_address = rule.ip_address_or_range
        if previous_managed_ip and ip_address == previous_managed_ip and ip_address != resolved_ip:
            continue
        if ip_address == resolved_ip:
            resolved_ip_present = True
        updated_rules.append(IPRule(ip_address_or_range=ip_address, action=getattr(rule, "action", "Allow")))
    if not resolved_ip_present:
        updated_rules.append(IPRule(ip_address_or_range=resolved_ip, action="Allow"))
    return updated_rules

def main(mytimer: func.TimerRequest) -> None:
    logging.info("Starting Cloudflare IP sync function")
    if mytimer.past_due:
        logging.warning("Timer is past due, running anyway")

    subscription_id = os.environ["SUBSCRIPTION_ID"]
    cf_zone_id = os.environ["CF_ZONE_ID"]
    cf_record_id = os.environ["CF_RECORD_ID"]
    cf_api_token = os.environ["CF_API_TOKEN"]

    # Get storage accounts (map of name: resource_group) and key vault from env
    storage_accounts_json = os.environ.get("TARGET_STORAGE_ACCOUNTS", "{}")
    try:
        storage_accounts = json.loads(storage_accounts_json)
    except Exception as e:
        logging.error(f"Failed to parse TARGET_STORAGE_ACCOUNTS: {e}")
        storage_accounts = {}
    key_vault_name = os.environ.get("TARGET_KEY_VAULT")
    key_vault_rg = os.environ.get("TARGET_KEY_VAULT_RG")

    # --- Cloudflare: fetch current DNS record IP ---
    cf_url = f"https://api.cloudflare.com/client/v4/zones/{cf_zone_id}/dns_records/{cf_record_id}"
    headers = {
        "Authorization": f"Bearer {cf_api_token}",
        "Content-Type": "application/json",
    }
    try:
        response = requests.get(cf_url, headers=headers, timeout=10)
        response.raise_for_status()
        data = response.json()
        if not data.get("success"):
            logging.error(f"Cloudflare API returned failure: {data.get('errors')}")
            return
        resolved_ip = data["result"]["content"]
        logging.info(f"Cloudflare DNS IP: {resolved_ip}")
    except Exception as e:
        logging.error(f"Cloudflare API request failed: {e}")
        return

    credential = DefaultAzureCredential()

    # --- Update all storage accounts ---
    storage_client = StorageManagementClient(credential, subscription_id)
    for sa_name, sa_rg in storage_accounts.items():
        try:
            sa = storage_client.storage_accounts.get_properties(sa_rg, sa_name)
            network_rule_set = sa.network_rule_set or NetworkRuleSet(default_action="Deny", bypass="AzureServices")
            rules = network_rule_set.ip_rules or []
            tags = dict(sa.tags or {})
            previous_managed_ip = tags.get(MANAGED_IP_TAG_NAME)
            updated_ip_rules = _build_updated_ip_rules(rules, previous_managed_ip, resolved_ip)
            tags[MANAGED_IP_TAG_NAME] = resolved_ip
            storage_client.storage_accounts.update(
                sa_rg,
                sa_name,
                StorageAccountUpdateParameters(
                    tags=tags,
                    network_rule_set=NetworkRuleSet(
                        bypass=network_rule_set.bypass,
                        default_action=network_rule_set.default_action,
                        ip_rules=updated_ip_rules,
                        virtual_network_rules=getattr(network_rule_set, "virtual_network_rules", None),
                        resource_access_rules=getattr(network_rule_set, "resource_access_rules", None),
                        ipv6_rules=getattr(network_rule_set, "ipv6_rules", None),
                    )
                ),
            )
            logging.info(f"Updated firewall IP rules for storage account {sa_name} in {sa_rg}")
        except Exception as e:
            logging.error(f"Failed to update storage account {sa_name} in {sa_rg}: {e}")

    # --- Update Key Vault network rules ---
    if key_vault_name and key_vault_rg:
        try:
            kv_client = KeyVaultManagementClient(credential, subscription_id)
            kv = kv_client.vaults.get(key_vault_rg, key_vault_name)
            kv_rules = kv.properties.network_acls or KVNetworkRuleSet(default_action="Deny", bypass="AzureServices", ip_rules=[])
            kv_ip_rules = kv_rules.ip_rules or []
            # Remove old managed IP, add new one
            kv_ip_rules = [rule for rule in kv_ip_rules if rule.value != resolved_ip]
            kv_ip_rules.append({"value": resolved_ip})
            kv_patch = VaultPatchParameters(
                properties={
                    "network_acls": KVNetworkRuleSet(
                        bypass=kv_rules.bypass,
                        default_action=kv_rules.default_action,
                        ip_rules=kv_ip_rules,
                        virtual_network_rules=getattr(kv_rules, "virtual_network_rules", None),
                    )
                }
            )
            kv_client.vaults.update(key_vault_rg, key_vault_name, kv_patch)
            logging.info(f"Updated firewall IP rules for Key Vault {key_vault_name}")
        except Exception as e:
            logging.error(f"Failed to update Key Vault {key_vault_name}: {e}")