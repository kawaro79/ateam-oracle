# OCI Cross-Region DR Networking Bundle for Exadata Database on Oracle Database@Azure

This repository contains a Cloud Shell-friendly automation bundle for the OCI networking portion of cross-region disaster recovery for Exadata Database on Oracle Database@Azure.

The bundle is intentionally limited to OCI networking. It does not configure databases, Data Guard, backups, compute, or application components.

## What This Bundle Creates

The setup workflow builds the networking transit path needed between a primary-region Exadata VCN and a standby-region Exadata VCN:

- one hub VCN in the primary region
- one hub VCN in the standby region
- local peering gateways between each Exadata VCN and its regional hub VCN
- one DRG in each region
- one remote peering connection attached to each DRG
- DRG peering between the two regions
- route table updates for Exadata VCNs, hub VCNs, and DRG routing
- NSGs for cross-region Oracle Net access

The rollback workflow removes only the artifacts created by the setup script and is designed to tolerate partial deployments.

## Repository Files

- `exadb_dr_network.conf`
- `setup_exadb_dr_network.sh`
- `rollback_exadb_dr_network.sh`

Generated at runtime:

- `exadb_dr_network.log`
- `exadb_dr_network_state_<timestamp>.env`

## Design Principles

- flat bundle layout suitable for OCI Cloud Shell
- Bash, OCI CLI, and standard Python only
- no external packages or helper frameworks
- separate primary and standby region configuration
- rollback-safe state tracking
- explicit peering verification for LPGs and DRGs
- parallel per-region workstreams where practical

## Prerequisites

Before running the scripts, make sure:

- OCI CLI is available in Cloud Shell
- your OCI identity has permission to manage VCN networking resources in both compartments
- the primary and standby Exadata VCNs already exist
- the client and backup subnet CIDRs you provide already exist in those VCNs
- the primary and standby regions are different

## Configuration

Edit `exadb_dr_network.conf` before running setup.

The config file uses these sections:

- `[primary_region_configuration]`
- `[standby_region_configuration]`
- `[hub_vcn_configuration]`
- `[database_listener_configuration]`
- `[global_optional_configuration]`

### Required values

Primary region:

- `PRIMARY_REGION`
- `PRIMARY_COMPARTMENT_OCID`
- `PRIMARY_VCN_OCID`
- `PRIMARY_CLIENT_SUBNET_CIDR`
- `PRIMARY_BACKUP_SUBNET_CIDR`

Standby region:

- `STANDBY_REGION`
- `STANDBY_COMPARTMENT_OCID`
- `STANDBY_VCN_OCID`
- `STANDBY_CLIENT_SUBNET_CIDR`
- `STANDBY_BACKUP_SUBNET_CIDR`

### Optional values

Hub VCN CIDRs:

- `PRIMARY_HUB_VCN_CIDR`
- `STANDBY_HUB_VCN_CIDR`

If these are left blank, the setup script auto-picks safe non-overlapping `/29` CIDRs.

Listener ports:

- `DB_TCP_LISTENER_PORT`
- `DB_TCPS_LISTENER_PORT`

If set, the setup script adds NSG rules for those listener ports. Common values are `1521` for TCP and `2484` for TCPS.

Other optional values:

- `ALLOW_SSH`
- `NAME_PREFIX`

## Recommended Hub VCN Sizing

Because the hub VCNs act as transit VCNs and do not require application subnets, a very small CIDR is sufficient. A `/29` is the recommended practical size for this design and is the default auto-selection target when hub CIDRs are not provided.

## Quick Start

1. Clone or upload the repository contents into OCI Cloud Shell.
2. Edit `exadb_dr_network.conf`.
3. Make the scripts executable.
4. Run setup.
5. Validate peering and routes.
6. Use rollback if you need to remove the deployment.

Example:

```bash
chmod +x setup_exadb_dr_network.sh rollback_exadb_dr_network.sh
vi exadb_dr_network.conf
./setup_exadb_dr_network.sh
```

Rollback using the latest state file:

```bash
./rollback_exadb_dr_network.sh
```

Rollback using a specific state file:

```bash
./rollback_exadb_dr_network.sh ./exadb_dr_network_state_<timestamp>.env
```

## Setup Workflow Summary

The setup script performs these high-level actions:

1. Validates config values and confirms both Exadata VCNs exist in the expected compartments.
2. Discovers the configured client and backup subnets by CIDR.
3. Resolves the hub VCN CIDRs, either from config or by auto-selection.
4. Creates DRGs and remote peering connections.
5. Creates hub VCN resources and LPGs in both regions.
6. Peers the LPGs in each region.
7. Peers the remote peering connections across regions and verifies the result.
8. Updates route tables so local and remote client and backup CIDRs route correctly.
9. Creates NSGs and optional listener and SSH rules.
10. Writes a timestamped state file for rollback.

## Rollback Workflow Summary

The rollback script:

1. locates the newest state file unless you provide one explicitly
2. starts remote peering connection cleanup first
3. removes route rules added by setup
4. removes NSGs created by setup
5. removes DRG attachments, LPGs, custom route tables, DRGs, and hub VCNs
6. skips resources that are already missing
7. tolerates partial state from failed or interrupted setup runs

## Manual Verification Checklist

After setup, verify:

- LPG peering is `PEERED` in the primary region
- LPG peering is `PEERED` in the standby region
- DRG remote peering is `PEERED` across regions
- Exadata VCN route tables send remote client and backup CIDRs to the local LPG
- hub route tables contain the expected local and remote static routes
- RPC DRG route tables contain static routes for local client and backup CIDRs
- NSGs were created in both Exadata VCNs
- listener port rules exist only if listener ports were configured

After rollback, verify:

- remote peering connections are gone
- DRG attachments are gone
- LPGs are gone
- created hub route tables are gone
- created DRGs are gone
- created hub VCNs are gone

## Logging And State

Both scripts write to:

- `exadb_dr_network.log`

The setup script also creates:

- `exadb_dr_network_state_<timestamp>.env`

That state file is used by rollback to delete only the resources created by setup.

## Scope Boundaries

This repository does not perform:

- database provisioning
- Data Guard configuration
- backup configuration
- compute provisioning
- Azure-side networking changes
- application failover configuration

## Notes

- Keep all bundle files in one folder when using OCI Cloud Shell.
- The scripts are intended to run non-interactively where OCI CLI supports it.
- The generated log and state files are runtime artifacts and usually should not be committed after execution.
