#!/usr/bin/env bash
# =============================================================================
# teardown.sh — removes the lab so it stops costing money.
#   ./teardown.sh            delete Azure resources, keep Entra user/group
#   ./teardown.sh --all      also delete the Entra help desk user and group
# =============================================================================
set -euo pipefail

RG="${RG:-rg-jontapia-az104-lab}"
VAULT="jt-az104-rsv"
VM="jt-az104-vm01"
LAB_USER_ALIAS="jontapia.helpdesk"
GROUP_NAME="SG-Helpdesk-Tier1"

say() { printf '\n\033[1;33m==> %s\033[0m\n' "$*"; }

if [[ "$(az group exists -n "$RG")" == "true" ]]; then
  # A vault holding backup data blocks resource group deletion,
  # so stop protection and purge the recovery points first.
  if az backup vault show -g "$RG" -n "$VAULT" -o none 2>/dev/null; then
    say "Stopping backup and deleting backup data for $VM"
    az backup protection disable \
      -g "$RG" --vault-name "$VAULT" \
      --container-name "$VM" --item-name "$VM" \
      --backup-management-type AzureIaasVM --workload-type VM \
      --delete-backup-data true --yes -o none || true

    for _ in $(seq 1 20); do
      left=$(az backup item list -g "$RG" --vault-name "$VAULT" --query "length(@)" -o tsv)
      [[ "$left" == "0" ]] && break
      echo "Waiting for backup item removal..."; sleep 15
    done
  fi

  say "Deleting resource group $RG (runs in background, ~5-10 min)"
  az group delete -n "$RG" --yes --no-wait
else
  echo "Resource group $RG not found — nothing to delete."
fi

if [[ "${1:-}" == "--all" ]]; then
  say "Removing Entra ID lab user and group"
  DOMAIN=$(az rest --method get --url "https://graph.microsoft.com/v1.0/domains" \
    --query "value[?isDefault].id | [0]" -o tsv)
  az ad user delete --id "${LAB_USER_ALIAS}@${DOMAIN}" 2>/dev/null || true
  GROUP_ID=$(az ad group list --display-name "$GROUP_NAME" --query "[0].id" -o tsv)
  [[ -n "$GROUP_ID" ]] && az ad group delete --group "$GROUP_ID"
fi

say "Teardown started. Confirm with:  az group exists -n $RG"
