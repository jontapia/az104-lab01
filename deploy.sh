#!/usr/bin/env bash
# =============================================================================
# deploy.sh — builds the jontapia AZ-104 lab end to end.
# Run in Azure Cloud Shell (Bash):  ./deploy.sh
#
# 1. Creates an Entra ID help desk user + security group (Microsoft Graph)
# 2. Creates the resource group
# 3. Deploys main.bicep (network, VM, RBAC, storage, backup, monitoring)
# =============================================================================
set -euo pipefail

LOCATION="${LOCATION:-westus2}"   # East US was restricted on my free trial
RG="${RG:-rg-jontapia-az104-lab}"
VM_SIZE="${VM_SIZE:-Standard_B2als_v2}"   # override if a size is out of capacity: VM_SIZE=Standard_B2ms ./deploy.sh
LAB_USER_ALIAS="jontapia.helpdesk"
LAB_USER_DISPLAY="Jon Tapia (Tier 1 Help Desk)"
GROUP_NAME="SG-Helpdesk-Tier1"
GROUP_NICK="sg-helpdesk-tier1"

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

az account show --query "{subscription:name, tenant:tenantId}" -o table \
  || { echo "Not signed in. Run: az login"; exit 1; }

# --- Inputs ------------------------------------------------------------------
read -rp "Your home public IP (search 'what is my ip' on your PC, NOT Cloud Shell): " MYIP
if [[ ! "$MYIP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  echo "That doesn't look like an IPv4 address."; exit 1
fi
read -rp "Email for Azure Monitor alerts: " ALERT_EMAIL
read -rsp "VM admin password for user 'jontapia' (12+ chars, upper/lower/number/symbol): " VM_PASS
echo

# --- Resource providers (new / free-trial subscriptions often lack these) ----
say "Registering resource providers"
for ns in Microsoft.Compute Microsoft.Network Microsoft.Storage \
          Microsoft.RecoveryServices Microsoft.OperationalInsights \
          Microsoft.Insights Microsoft.DevTestLab; do
  az provider register --namespace "$ns" --wait -o none
done

# --- Entra ID: user + group --------------------------------------------------
say "Creating Entra ID help desk identity"
DOMAIN=$(az rest --method get --url "https://graph.microsoft.com/v1.0/domains" \
  --query "value[?isDefault].id | [0]" -o tsv)
UPN="${LAB_USER_ALIAS}@${DOMAIN}"

if az ad user show --id "$UPN" -o none 2>/dev/null; then
  echo "User $UPN already exists — skipping."
else
  TEMP_PASS="Jt!$(openssl rand -hex 6)Az1"
  az ad user create \
    --display-name "$LAB_USER_DISPLAY" \
    --user-principal-name "$UPN" \
    --password "$TEMP_PASS" \
    --force-change-password-next-sign-in true -o none
  echo "Created $UPN"
  echo "Temporary password (must change at first sign-in): $TEMP_PASS"
fi
USER_ID=$(az ad user show --id "$UPN" --query id -o tsv)

GROUP_ID=$(az ad group list --display-name "$GROUP_NAME" --query "[0].id" -o tsv)
if [[ -z "$GROUP_ID" ]]; then
  GROUP_ID=$(az ad group create \
    --display-name "$GROUP_NAME" \
    --mail-nickname "$GROUP_NICK" \
    --description "Tier 1 help desk — VM operator rights on the AZ-104 lab" \
    --query id -o tsv)
  echo "Created group $GROUP_NAME"
  echo "Waiting 30s for Entra ID replication before assigning RBAC..."
  sleep 30
fi

if [[ "$(az ad group member check --group "$GROUP_ID" --member-id "$USER_ID" --query value -o tsv)" != "true" ]]; then
  az ad group member add --group "$GROUP_ID" --member-id "$USER_ID"
fi

# --- Resource group + Bicep deployment ---------------------------------------
say "Creating resource group $RG in $LOCATION"
az group create -n "$RG" -l "$LOCATION" \
  --tags owner=jontapia project=az104-lab environment=lab -o none

say "Deploying main.bicep (about 10-15 minutes)"
az deployment group create \
  -g "$RG" \
  -n "az104-lab-$(date +%Y%m%d-%H%M)" \
  --template-file main.bicep \
  --parameters \
    allowedRdpSource="${MYIP}/32" \
    helpdeskGroupObjectId="$GROUP_ID" \
    alertEmail="$ALERT_EMAIL" \
    adminPassword="$VM_PASS" \
    vmSize="$VM_SIZE" \
  --query "properties.outputs" -o jsonc

say "Done. RDP to the vmPublicIp above as 'jontapia'. VM auto-shuts down at 7 PM ET."
echo "Tear down when finished:  ./teardown.sh"
