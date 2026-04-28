import json
import logging
import os

import azure.functions as func
import requests
from azure.identity import DefaultAzureCredential
from azure.mgmt.storage import StorageManagementClient
from azure.mgmt.storage.models import (
    IPRule,
    NetworkRuleSet,
    StorageAccountUpdateParameters,
)

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

    # TARGET_STORAGE_ACCOUNTS is a JSON map of {"account_name": "resource_group"}
    target_storage_accounts = json.loads(os.environ["TARGET_STORAGE_ACCOUNTS"])

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
    client = StorageManagementClient(credential, subscription_id)

    # --- Update firewall on each target storage account ---
    for storage_account, resource_group in target_storage_accounts.items():
        logging.info(f"Processing storage account: {storage_account} in {resource_group}")

        try:
            sa = client.storage_accounts.get_properties(resource_group, storage_account)
            rules = sa.network_rule_set.ip_rules or []

            if len(rules) > 1:
                logging.warning(
                    f"{storage_account}: {len(rules)} IP rules found — only the first is managed by this function"
                )

            current_ip = rules[0].ip_address_or_range if rules else None
            logging.info(f"{storage_account}: current firewall IP: {current_ip}")

            if current_ip == resolved_ip and sa.network_rule_set.default_action == "Deny":
                logging.info(f"{storage_account}: IP unchanged and default action is Deny, no update needed")
                continue

            client.storage_accounts.update(
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