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

        updated_rules.append(IPRule(ip_address_or_range=ip_address, action=rule.action or "Allow"))

    if not resolved_ip_present:
        updated_rules.append(IPRule(ip_address_or_range=resolved_ip, action="Allow"))

    return updated_rules


def main(mytimer: func.TimerRequest) -> None:
    logging.info("Starting Cloudflare IP sync function")

    if mytimer.past_due:
        logging.warning("Timer is past due, running anyway")

    subscription_id = os.environ["SUBSCRIPTION_ID"]
    resource_group = os.environ["TARGET_RESOURCE_GROUP"]
    storage_account = os.environ["TARGET_STORAGE_ACCOUNT"]
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
    credential = DefaultAzureCredential()
    client = StorageManagementClient(credential, subscription_id)

    sa = client.storage_accounts.get_properties(resource_group, storage_account)
    network_rule_set = sa.network_rule_set or NetworkRuleSet(
        default_action="Deny",
        bypass="AzureServices",
    )
    rules = network_rule_set.ip_rules or []
    tags = dict(sa.tags or {})
    previous_managed_ip = tags.get(MANAGED_IP_TAG_NAME)

    if previous_managed_ip:
        logging.info(f"Previously managed firewall IP: {previous_managed_ip}")

    if any(rule.ip_address_or_range == resolved_ip for rule in rules) and previous_managed_ip == resolved_ip:
        logging.info("IP unchanged, no update needed")
        return

    updated_ip_rules = _build_updated_ip_rules(rules, previous_managed_ip, resolved_ip)
    tags[MANAGED_IP_TAG_NAME] = resolved_ip

    # --- Azure: update firewall rule ---
    try:
        client.storage_accounts.update(
            resource_group,
            storage_account,
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
        logging.info(
            "Updated firewall IP rules; preserved existing entries and set managed IP to %s",
            resolved_ip,
        )
    except Exception as e:
        logging.error(f"Failed to update storage account firewall: {e}")