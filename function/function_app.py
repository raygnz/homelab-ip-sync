import json
import logging
import os

import azure.functions as func
import requests
from azure.identity import DefaultAzureCredential
from azure.mgmt.keyvault import KeyVaultManagementClient
from azure.mgmt.keyvault.models import (
    IPRule as KVIPRule,
    NetworkRuleSet as KVNetworkRuleSet,
    VaultPatch,
    VaultProperties,
)
from azure.mgmt.storage import StorageManagementClient
from azure.mgmt.storage.models import (
    IPRule,
    NetworkRuleSet,
    StorageAccountUpdateParameters,
)
from azure.mgmt.web import WebSiteManagementClient
from azure.mgmt.web.models import IpSecurityRestriction, SiteConfig

app = func.FunctionApp()

@app.schedule(
    schedule="0 * * * *",  # every hour, on the hour
    arg_name="mytimer",
    run_on_startup=False,
)
def sync_cloudflare_ip(mytimer: func.TimerRequest) -> None:
    logging.info("Starting Cloudflare IP sync function")

    if mytimer.past_due:
        logging.warning("Timer is past due, running anyway")

    subscription_id = os.environ["SUBSCRIPTION_ID"]
    cf_zone_id = os.environ["CF_ZONE_ID"]
    cf_record_id = os.environ["CF_RECORD_ID"]
    cf_api_token = os.environ["CF_API_TOKEN"]
    target_storage_accounts = json.loads(os.environ["TARGET_STORAGE_ACCOUNTS"])
    target_key_vault = os.environ["TARGET_KEY_VAULT"]
    target_key_vault_rg = os.environ["TARGET_KEY_VAULT_RG"]
    function_app_name = os.environ["FUNCTION_APP_NAME"]
    function_app_rg = os.environ["RESOURCE_GROUP"]

    # --- Cloudflare: fetch current DNS record IP ---
    cf_url = f"https://api.cloudflare.com/client/v4/zones/{cf_zone_id}/dns_records/{cf_record_id}"
    headers = {
        "Authorization": f"Bearer {cf_api_token}",
        "Content-Type": "application/json",
    }

    try:
        response = requests.get(cf_url, headers=headers, timeout=10)
        response.raise_for_status()
    except requests.exceptions.RequestException as e:
        logging.error(f"Cloudflare API request failed: {e}")
        return

    data = response.json()
    if not data.get("success"):
        logging.error(f"Cloudflare API returned failure: {data.get('errors')}")
        return

    resolved_ip = data["result"]["content"]
    logging.info(f"Cloudflare DNS IP: {resolved_ip}")

    # --- Azure: authenticate using managed identity ---
    credential = DefaultAzureCredential()

    # --- Update firewall on each target storage account ---
    storage_client = StorageManagementClient(credential, subscription_id)

    for storage_account, resource_group in target_storage_accounts.items():
        logging.info(f"Processing storage account: {storage_account} in {resource_group}")
        try:
            sa = storage_client.storage_accounts.get_properties(resource_group, storage_account)
            rules = sa.network_rule_set.ip_rules or []

            if len(rules) > 1:
                logging.warning(
                    f"{storage_account}: {len(rules)} IP rules found — only the first is managed by this function"
                )

            current_ip = rules[0].ip_address_or_range if rules else None
            logging.info(f"{storage_account}: current firewall IP: {current_ip}")

            if current_ip == resolved_ip and sa.network_rule_set.default_action == "Deny":
                logging.info(f"{storage_account}: IP unchanged and default action is Deny, no update needed")
            else:
                storage_client.storage_accounts.update(
                    resource_group,
                    storage_account,
                    StorageAccountUpdateParameters(
                        network_rule_set=NetworkRuleSet(
                            ip_rules=[IPRule(ip_address_or_range=resolved_ip, action="Allow")],
                            default_action="Deny",
                            bypass=sa.network_rule_set.bypass,
                        )
                    ),
                )
                logging.info(f"{storage_account}: updated firewall IP to {resolved_ip} with default_action Deny")

        except Exception as e:
            logging.error(f"{storage_account}: failed to update firewall: {e}")

    # --- Update Key Vault network ACL ---
    logging.info(f"Processing Key Vault: {target_key_vault} in {target_key_vault_rg}")
    try:
        kv_client = KeyVaultManagementClient(credential, subscription_id)
        kv = kv_client.vaults.get(target_key_vault_rg, target_key_vault)
        kv_rules = kv.properties.network_acls.ip_rules if kv.properties.network_acls else []
        kv_current_ip = kv_rules[0].value.rstrip("/32") if kv_rules else None
        logging.info(f"{target_key_vault}: current firewall IP: {kv_current_ip}")

        if kv_current_ip == resolved_ip and kv.properties.network_acls.default_action == "Deny":
            logging.info(f"{target_key_vault}: IP unchanged and default action is Deny, no update needed")
        else:
            kv_client.vaults.update(
                target_key_vault_rg,
                target_key_vault,
                VaultPatch(
                    properties=VaultProperties(
                        network_acls=KVNetworkRuleSet(
                            default_action="Deny",
                            bypass="AzureServices",
                            ip_rules=[KVIPRule(value=f"{resolved_ip}/32")],
                        )
                    )
                ),
            )
            logging.info(f"{target_key_vault}: updated firewall IP to {resolved_ip} with default_action Deny")

    except Exception as e:
        logging.error(f"{target_key_vault}: failed to update Key Vault firewall: {e}")

    # --- Update Function App access restrictions ---
    logging.info(f"Processing Function App: {function_app_name} in {function_app_rg}")
    try:
        web_client = WebSiteManagementClient(credential, subscription_id)
        config = web_client.web_apps.get_configuration(function_app_rg, function_app_name)
        restrictions = config.ip_security_restrictions or []
        current_restriction_ip = restrictions[0].ip_address if restrictions else None
        logging.info(f"{function_app_name}: current access restriction IP: {current_restriction_ip}")

        if current_restriction_ip == f"{resolved_ip}/32":
            logging.info(f"{function_app_name}: IP unchanged, no update needed")
        else:
            web_client.web_apps.update_configuration(
                function_app_rg,
                function_app_name,
                SiteConfig(
                    ip_security_restrictions=[
                        IpSecurityRestriction(
                            ip_address=f"{resolved_ip}/32",
                            action="Allow",
                            priority=100,
                            name="cloudflare-home-ip",
                        )
                    ],
                    ip_security_restrictions_default_action="Deny",
                )
            )
            logging.info(f"{function_app_name}: updated access restriction IP to {resolved_ip}")

    except Exception as e:
        logging.error(f"{function_app_name}: failed to update Function App access restrictions: {e}")