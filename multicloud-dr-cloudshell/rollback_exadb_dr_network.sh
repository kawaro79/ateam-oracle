#!/usr/bin/env bash
set -euo pipefail

# OCI Cloud Shell quick start:
# 1. Default rollback: ./rollback_exadb_dr_network.sh
# 2. Explicit rollback: ./rollback_exadb_dr_network.sh ./exadb_dr_network_state_<timestamp>.env
#
# Manual verification checklist:
# - Exadata VCN route-table rules added by setup are removed.
# - Hub DRG-attachment and LPG route-table rules added by setup are removed.
# - RPC DRG route-table rules added by setup are removed.
# - Created NSGs are deleted.
# - Created RPCs, DRG attachments, LPGs, hub route tables, DRGs, and hub VCNs are deleted.
# - Rollback skips missing resources cleanly after partial setup failures.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="$SCRIPT_DIR/exadb_dr_network.log"
STATE_ARG="${1:-}"
BUNDLE_VERSION="2026-03-16-rollback-parallel-regions-v1"
OCI_TIMEOUT_SECONDS="${OCI_TIMEOUT_SECONDS:-15}"
DELETE_WAIT_ATTEMPTS="${DELETE_WAIT_ATTEMPTS:-36}"
DELETE_WAIT_DELAY_SECONDS="${DELETE_WAIT_DELAY_SECONDS:-5}"
TMP_FILES=()
RPC_DELETE_PID=""

export OCI_CLI_SUPPRESS_FILE_PERMISSIONS_WARNING=True

touch "$LOG_FILE"

log() {
  local level="$1"
  shift
  printf '%s [%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$level" "$*" | tee -a "$LOG_FILE"
}

fail() {
  log "ERROR" "$*"
  exit 1
}

cleanup_tmp() {
  if ((${#TMP_FILES[@]} > 0)); then
    rm -f "${TMP_FILES[@]}"
  fi
}

trap cleanup_tmp EXIT

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || fail "Required command not found: $cmd"
}

oci_quick() {
  local region="$1"
  shift
  timeout "${OCI_TIMEOUT_SECONDS}s" oci --max-retries 0 --region "$region" "$@"
}

oci_quick_json() {
  local region="$1"
  shift
  oci_quick "$region" "$@" --output json
}

make_tmp_json() {
  local tmp
  tmp="$(mktemp "$SCRIPT_DIR/exadb_dr_network_tmp_XXXXXX.json")"
  TMP_FILES+=("$tmp")
  printf '%s\n' "$tmp"
}

find_latest_state_file() {
  local latest=""
  latest="$(ls -1t "$SCRIPT_DIR"/exadb_dr_network_state_*.env 2>/dev/null | head -n 1 || true)"
  [[ -n "$latest" ]] || fail "No exadb_dr_network_state_*.env file found in $SCRIPT_DIR"
  printf '%s\n' "$latest"
}

resource_exists() {
  local region="$1"
  local kind="$2"
  local ocid="$3"
  case "$kind" in
    route-table) oci_quick "$region" network route-table get --rt-id "$ocid" >/dev/null 2>&1 ;;
    drg-route-table) oci_quick "$region" network drg-route-table get --drg-route-table-id "$ocid" >/dev/null 2>&1 ;;
    nsg) oci_quick "$region" network nsg get --nsg-id "$ocid" >/dev/null 2>&1 ;;
    rpc) oci_quick "$region" network remote-peering-connection get --remote-peering-connection-id "$ocid" >/dev/null 2>&1 ;;
    drg-attachment) oci_quick "$region" network drg-attachment get --drg-attachment-id "$ocid" >/dev/null 2>&1 ;;
    lpg) oci_quick "$region" network local-peering-gateway get --local-peering-gateway-id "$ocid" >/dev/null 2>&1 ;;
    drg) oci_quick "$region" network drg get --drg-id "$ocid" >/dev/null 2>&1 ;;
    vcn) oci_quick "$region" network vcn get --vcn-id "$ocid" >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

wait_until_resource_gone() {
  local region="$1"
  local kind="$2"
  local ocid="$3"
  local attempts="${4:-$DELETE_WAIT_ATTEMPTS}"
  local delay="${5:-$DELETE_WAIT_DELAY_SECONDS}"
  local attempt

  if [[ -z "${region:-}" || -z "${ocid:-}" ]]; then
    return 0
  fi

  for ((attempt = 1; attempt <= attempts; attempt++)); do
    if ! resource_exists "$region" "$kind" "$ocid"; then
      return 0
    fi
    sleep "$delay"
  done

  fail "Timed out waiting for $kind $ocid in region $region to be fully deleted."
}

drg_route_rule_ids_to_remove() {
  local region="$1"
  local drg_route_table_id="$2"
  local destination_csv="$3"
  local next_hop_attachment_id="$4"
  local rules_json=""
  rules_json="$(oci_quick_json "$region" network drg-route-rule list --drg-route-table-id "$drg_route_table_id" --all 2>/dev/null || true)"
  if [[ -z "$rules_json" ]]; then
    printf '\n'
    return 0
  fi
  printf '%s' "$rules_json" | python3 -c 'import json, sys
raw = sys.stdin.read().strip()
if not raw:
    print("")
    raise SystemExit(0)
payload = json.loads(raw)
destinations = {item for item in sys.argv[1].split(",") if item}
next_hop = sys.argv[2]
items = payload.get("data", payload if isinstance(payload, list) else [])
ids = []
for item in items:
    if item.get("destination") in destinations and item.get("next-hop-drg-attachment-id") == next_hop:
        rule_id = item.get("id")
        if rule_id:
            ids.append(rule_id)
print(",".join(ids))
' "$destination_csv" "$next_hop_attachment_id"
}

route_rules_filtered_file() {
  local current_rules_json="$1"
  local destination_csv="$2"
  local network_entity_id="$3"
  local description_token="$4"
  local out_file="$5"
  python3 -c 'import json, sys
rules = json.loads(sys.argv[1])
destinations = {item for item in sys.argv[2].split(",") if item}
entity = sys.argv[3]
token = sys.argv[4]
out_file = sys.argv[5]
if not isinstance(rules, list):
    raise SystemExit("Route rules payload was not a list")
filtered = []
for item in rules:
    description = item.get("description", "")
    managed = (
        item.get("network-entity-id") == entity and
        item.get("destination") in destinations and
        token in description
    )
    if not managed:
        filtered.append(item)
with open(out_file, "w", encoding="utf-8") as handle:
    json.dump(filtered, handle, indent=2, sort_keys=True)
' "$current_rules_json" "$destination_csv" "$network_entity_id" "$description_token" "$out_file"
}

remove_managed_route_rules() {
  local region="$1"
  local route_table_id="$2"
  local destination_csv="$3"
  local network_entity_id="$4"
  local description_token="$5"
  local current_rules_json
  local filtered_file

  if [[ -z "$region" || -z "$route_table_id" || -z "$network_entity_id" ]]; then
    log "INFO" "Skipping route-table cleanup because route table or target gateway is unset."
    return 0
  fi
  if ! resource_exists "$region" "route-table" "$route_table_id"; then
    log "INFO" "Skipping missing route table $route_table_id in region $region."
    return 0
  fi

  current_rules_json="$(oci_quick_json "$region" network route-table get --rt-id "$route_table_id" --query 'data."route-rules"')"
  filtered_file="$(make_tmp_json)"
  route_rules_filtered_file "$current_rules_json" "$destination_csv" "$network_entity_id" "$description_token" "$filtered_file"
  oci_quick "$region" network route-table update --rt-id "$route_table_id" --route-rules "file://$filtered_file" --force >/dev/null
  log "INFO" "Removed managed route rules from route table $route_table_id in region $region."
}

remove_managed_drg_route_rules() {
  local region="$1"
  local drg_route_table_id="$2"
  local destination_csv="$3"
  local next_hop_attachment_id="$4"
  local rule_ids_csv
  local ids_file

  if [[ -z "$region" || -z "$drg_route_table_id" || -z "$next_hop_attachment_id" ]]; then
    log "INFO" "Skipping DRG route-table cleanup because the region, route table, or next hop attachment is unset."
    return 0
  fi
  if ! resource_exists "$region" "drg-route-table" "$drg_route_table_id"; then
    log "INFO" "Skipping missing DRG route table $drg_route_table_id in region $region."
    return 0
  fi

  rule_ids_csv="$(drg_route_rule_ids_to_remove "$region" "$drg_route_table_id" "$destination_csv" "$next_hop_attachment_id")"
  if [[ -z "$rule_ids_csv" ]]; then
    log "INFO" "No managed DRG route rules found in $drg_route_table_id for region $region."
    return 0
  fi

  ids_file="$(make_tmp_json)"
  python3 -c 'import json, sys
ids = [item for item in sys.argv[1].split(",") if item]
with open(sys.argv[2], "w", encoding="utf-8") as handle:
    json.dump(ids, handle, indent=2)
' "$rule_ids_csv" "$ids_file"
  oci_quick "$region" network drg-route-rule remove \
    --drg-route-table-id "$drg_route_table_id" \
    --route-rule-ids "file://$ids_file" >/dev/null
  log "INFO" "Removed managed DRG route rules from $drg_route_table_id in region $region."
}

delete_resource() {
  local region="$1"
  local kind="$2"
  local ocid="$3"
  if [[ -z "${region:-}" || -z "${ocid:-}" ]]; then
    log "INFO" "Skipping $kind deletion because the region or OCID is unset."
    return 0
  fi
  if ! resource_exists "$region" "$kind" "$ocid"; then
    log "INFO" "Skipping missing $kind $ocid in region $region."
    return 0
  fi

  case "$kind" in
    nsg)
      oci_quick "$region" network nsg delete --nsg-id "$ocid" --force >/dev/null
      ;;
    rpc)
      oci_quick "$region" network remote-peering-connection delete --remote-peering-connection-id "$ocid" --force >/dev/null
      ;;
    drg-attachment)
      oci_quick "$region" network drg-attachment delete --drg-attachment-id "$ocid" --force >/dev/null
      ;;
    lpg)
      oci_quick "$region" network local-peering-gateway delete --local-peering-gateway-id "$ocid" --force >/dev/null
      ;;
    route-table)
      oci_quick "$region" network route-table delete --rt-id "$ocid" --force >/dev/null
      ;;
    drg)
      oci_quick "$region" network drg delete --drg-id "$ocid" --force >/dev/null
      ;;
    vcn)
      oci_quick "$region" network vcn delete --vcn-id "$ocid" --force >/dev/null
      ;;
    *)
      fail "Unsupported delete kind: $kind"
      ;;
  esac
  wait_until_resource_gone "$region" "$kind" "$ocid"
  log "INFO" "Deleted $kind $ocid in region $region."
}

start_rpc_delete_background() {
  local primary_region="$1"
  local primary_rpc_id="$2"
  local standby_region="$3"
  local standby_rpc_id="$4"

  (
    delete_resource "$primary_region" "rpc" "$primary_rpc_id"
    delete_resource "$standby_region" "rpc" "$standby_rpc_id"
  ) &

  RPC_DELETE_PID="$!"
  log "INFO" "Started background remote peering connection deletion with PID $RPC_DELETE_PID."
}

wait_for_rpc_delete_background() {
  if [[ -z "${RPC_DELETE_PID:-}" ]]; then
    fail "Internal error: background RPC deletion PID is not set."
  fi

  log "INFO" "Waiting for background remote peering connection deletion to finish."
  if ! wait "$RPC_DELETE_PID"; then
    fail "Background remote peering connection deletion failed."
  fi
  log "INFO" "Background remote peering connection deletion finished successfully."
}

wait_for_bg_pid() {
  local pid="$1"
  local label="$2"
  if ! wait "$pid"; then
    fail "$label failed."
  fi
}

pre_cleanup_region_workstream() {
  local label="$1"
  local region="$2"
  local local_client_cidr="$3"
  local local_backup_cidr="$4"
  local remote_client_cidr="$5"
  local remote_backup_cidr="$6"
  local exadata_route_table_ids="$7"
  local exadata_lpg_id="$8"
  local hub_drg_route_table_id="$9"
  local hub_lpg_route_table_id="${10}"
  local hub_default_route_table_id="${11}"
  local hub_lpg_id="${12}"
  local drg_id="${13}"
  local rpc_drg_route_table_id="${14}"
  local drg_attachment_id="${15}"
  local description_token="${16}"
  local nsg_id="${17}"
  local route_table_id
  local local_destination_csv
  local remote_destination_csv

  local_destination_csv="$(printf '%s,%s' "$local_client_cidr" "$local_backup_cidr")"
  remote_destination_csv="$(printf '%s,%s' "$remote_client_cidr" "$remote_backup_cidr")"

  log "INFO" "[$label] Removing route rules from existing Exadata VCN route tables."
  for route_table_id in $exadata_route_table_ids; do
    remove_managed_route_rules "$region" "$route_table_id" "$remote_destination_csv" "$exadata_lpg_id" "$description_token"
  done

  log "INFO" "[$label] Removing route rules from created hub route tables."
  remove_managed_route_rules "$region" "$hub_drg_route_table_id" "$local_destination_csv" "$hub_lpg_id" "$description_token"
  remove_managed_route_rules "$region" "$hub_lpg_route_table_id" "$remote_destination_csv" "$drg_id" "$description_token"
  remove_managed_route_rules "$region" "$hub_default_route_table_id" "$local_destination_csv" "$hub_lpg_id" "$description_token"
  remove_managed_route_rules "$region" "$hub_default_route_table_id" "$remote_destination_csv" "$drg_id" "$description_token"

  log "INFO" "[$label] Removing managed DRG route rules from RPC route tables."
  remove_managed_drg_route_rules "$region" "$rpc_drg_route_table_id" "$local_destination_csv" "$drg_attachment_id"

  log "INFO" "[$label] Deleting NSG."
  delete_resource "$region" "nsg" "$nsg_id"
}

delete_region_artifacts_workstream() {
  local label="$1"
  local region="$2"
  local hub_lpg_id="$3"
  local exadata_lpg_id="$4"
  local drg_attachment_id="$5"
  local hub_lpg_route_table_id="$6"
  local hub_drg_route_table_id="$7"
  local drg_id="$8"
  local hub_vcn_id="$9"

  log "INFO" "[$label] Deleting DRG attachment."
  delete_resource "$region" "drg-attachment" "$drg_attachment_id"

  log "INFO" "[$label] Deleting LPGs."
  delete_resource "$region" "lpg" "$hub_lpg_id"
  delete_resource "$region" "lpg" "$exadata_lpg_id"

  log "INFO" "[$label] Deleting created hub route tables."
  delete_resource "$region" "route-table" "$hub_lpg_route_table_id"
  delete_resource "$region" "route-table" "$hub_drg_route_table_id"

  log "INFO" "[$label] Deleting DRG."
  delete_resource "$region" "drg" "$drg_id"

  log "INFO" "[$label] Deleting hub VCN."
  delete_resource "$region" "vcn" "$hub_vcn_id"
}

require_cmd bash
require_cmd oci
require_cmd python3
require_cmd timeout

STATE_FILE="${STATE_ARG:-$(find_latest_state_file)}"
[[ -f "$STATE_FILE" ]] || fail "State file not found: $STATE_FILE"

log "INFO" "Starting rollback using state file: $STATE_FILE"
log "INFO" "Bundle version: $BUNDLE_VERSION"
log "INFO" "OCI command timeout: ${OCI_TIMEOUT_SECONDS}s"
log "INFO" "Delete wait policy: ${DELETE_WAIT_ATTEMPTS} attempts, ${DELETE_WAIT_DELAY_SECONDS}s delay"

set -a
# shellcheck disable=SC1090
source "$STATE_FILE"
set +a

PRIMARY_REMOTE_DESTINATION_CSV="$(printf '%s,%s' "${STANDBY_CLIENT_SUBNET_CIDR:-}" "${STANDBY_BACKUP_SUBNET_CIDR:-}")"
STANDBY_REMOTE_DESTINATION_CSV="$(printf '%s,%s' "${PRIMARY_CLIENT_SUBNET_CIDR:-}" "${PRIMARY_BACKUP_SUBNET_CIDR:-}")"

log "INFO" "Starting background deletion of remote peering connections."
start_rpc_delete_background "${PRIMARY_REGION:-}" "${PRIMARY_RPC_ID:-}" "${STANDBY_REGION:-}" "${STANDBY_RPC_ID:-}"

pre_cleanup_region_workstream "primary" "${PRIMARY_REGION:-}" "${PRIMARY_CLIENT_SUBNET_CIDR:-}" "${PRIMARY_BACKUP_SUBNET_CIDR:-}" "${STANDBY_CLIENT_SUBNET_CIDR:-}" "${STANDBY_BACKUP_SUBNET_CIDR:-}" "${PRIMARY_EXADATA_ROUTE_TABLE_IDS:-}" "${PRIMARY_EXADATA_LPG_ID:-}" "${PRIMARY_HUB_DRG_ROUTE_TABLE_ID:-}" "${PRIMARY_HUB_LPG_ROUTE_TABLE_ID:-}" "${PRIMARY_HUB_DEFAULT_ROUTE_TABLE_ID:-}" "${PRIMARY_HUB_LPG_ID:-}" "${PRIMARY_DRG_ID:-}" "${PRIMARY_RPC_DRG_ROUTE_TABLE_ID:-}" "${PRIMARY_DRG_ATTACHMENT_ID:-}" "${DESCRIPTION_TOKEN:-}" "${PRIMARY_NSG_ID:-}" &
PRIMARY_PRE_PID="$!"
pre_cleanup_region_workstream "standby" "${STANDBY_REGION:-}" "${STANDBY_CLIENT_SUBNET_CIDR:-}" "${STANDBY_BACKUP_SUBNET_CIDR:-}" "${PRIMARY_CLIENT_SUBNET_CIDR:-}" "${PRIMARY_BACKUP_SUBNET_CIDR:-}" "${STANDBY_EXADATA_ROUTE_TABLE_IDS:-}" "${STANDBY_EXADATA_LPG_ID:-}" "${STANDBY_HUB_DRG_ROUTE_TABLE_ID:-}" "${STANDBY_HUB_LPG_ROUTE_TABLE_ID:-}" "${STANDBY_HUB_DEFAULT_ROUTE_TABLE_ID:-}" "${STANDBY_HUB_LPG_ID:-}" "${STANDBY_DRG_ID:-}" "${STANDBY_RPC_DRG_ROUTE_TABLE_ID:-}" "${STANDBY_DRG_ATTACHMENT_ID:-}" "${DESCRIPTION_TOKEN:-}" "${STANDBY_NSG_ID:-}" &
STANDBY_PRE_PID="$!"
wait_for_bg_pid "$PRIMARY_PRE_PID" "Primary pre-cleanup workstream"
wait_for_bg_pid "$STANDBY_PRE_PID" "Standby pre-cleanup workstream"

wait_for_rpc_delete_background

delete_region_artifacts_workstream "primary" "${PRIMARY_REGION:-}" "${PRIMARY_HUB_LPG_ID:-}" "${PRIMARY_EXADATA_LPG_ID:-}" "${PRIMARY_DRG_ATTACHMENT_ID:-}" "${PRIMARY_HUB_LPG_ROUTE_TABLE_ID:-}" "${PRIMARY_HUB_DRG_ROUTE_TABLE_ID:-}" "${PRIMARY_DRG_ID:-}" "${PRIMARY_HUB_VCN_ID:-}" &
PRIMARY_DELETE_PID="$!"
delete_region_artifacts_workstream "standby" "${STANDBY_REGION:-}" "${STANDBY_HUB_LPG_ID:-}" "${STANDBY_EXADATA_LPG_ID:-}" "${STANDBY_DRG_ATTACHMENT_ID:-}" "${STANDBY_HUB_LPG_ROUTE_TABLE_ID:-}" "${STANDBY_HUB_DRG_ROUTE_TABLE_ID:-}" "${STANDBY_DRG_ID:-}" "${STANDBY_HUB_VCN_ID:-}" &
STANDBY_DELETE_PID="$!"
wait_for_bg_pid "$PRIMARY_DELETE_PID" "Primary deletion workstream"
wait_for_bg_pid "$STANDBY_DELETE_PID" "Standby deletion workstream"

log "INFO" "Rollback finished."
