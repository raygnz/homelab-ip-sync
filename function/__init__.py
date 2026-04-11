import logging
import os

import azure.functions as func
import requests
from azure.identity import ClientSecretCredential
from azure.mgmt.storage import StorageManagementClient
from azure.mgmt.storage.models import (
    IPRule,
    NetworkRuleSet,
    StorageAccountUpdateParameters,
)


def main(mytimer: func.TimerRequest) -> None:
    logging.info("Starting Cloudflare IP sync function")

    if mytimer.past_due:
        logging.warning("Timer is past due, running anyway")

    tenant_id = os.environ["TENANT_ID"]
    client_id = os.environ["CLIENT_ID"]
    client_secret = os.environ["CLIENT_SECRET"]
    subscription_id = os.environ["SUBSCRIPTION_ID"]
    resource_group = os.environ["RESOURCE_GROUP"]
    storage_account = os.environ["STORAGE_ACCOUNT"]
    cf_zone_id = os.environ["CF_ZONE_ID"]
    cf_record_id = os.environ["CF_RECORD_ID"]
    cf_api_token = os.environ["CF_API_TOKEN"]

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

    # --- Azure: authenticate and get storage account ---
    credential = ClientSecretCredential(
        tenant_id=tenant_id,
        client_id=client_id,
        client_secret=client_secret,
    )
    client = StorageManagementClient(credential, subscription_id)

    sa = client.storage_accounts.get_properties(resource_group, storage_account)
    rules = sa.network_rule_set.ip_rules or []

    if len(rules) > 1:
        logging.warning(
            f"{len(rules)} IP rules found on storage account — only the first is managed by this function"
        )

    current_ip = rules[0].ip_address_or_range if rules else None
    logging.info(f"Current firewall IP: {current_ip}")

    if current_ip == resolved_ip:
        logging.info("IP unchanged, no update needed")
        return

    # --- Azure: update firewall rule ---
    try:
        client.storage_accounts.update(
            resource_group,
            storage_account,
            StorageAccountUpdateParameters(
                network_rule_set=NetworkRuleSet(
                    ip_rules=[IPRule(ip_address_or_range=resolved_ip, action="Allow")],
                    default_action=sa.network_rule_set.default_action,
                    bypass=sa.network_rule_set.bypass,
                )
            ),
        )
        logging.info(f"Updated firewall IP to {resolved_ip}")
    except Exception as e:
        logging.error(f"Failed to update storage account firewall: {e}")