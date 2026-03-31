# Exadata DR Network Bundle

This bundle automates the OCI networking-only portion of cross-region disaster recovery for Exadata Database on Oracle Database@Azure.

It does not configure databases, Data Guard, backups, compute, or applications. It creates and removes only the OCI networking components needed for the DR transit topology.

## What The Bundle Does

The setup script:
- validates the config and VCN ownership
- discovers the client and backup subnets by CIDR
- creates DRGs and remote peering connections
- peers the remote peering connections
- creates hub VCNs in both regions
- creates custom hub route tables
- creates and peers LPGs in both regions
- attaches each hub VCN to its DRG
- updates the hub, Exadata, and DRG route tables
- creates NSGs in the Exadata VCNs

The rollback script:
- removes the route rules added by setup
- deletes the NSGs
- deletes the remote peering connections
- deletes the DRG attachments
- deletes the LPGs
- deletes the created hub route tables
- deletes the DRGs
- deletes the hub VCNs

Both scripts are designed to tolerate partial runs and missing resources.

## Main Files

- `exadb_dr_network.conf`
- `setup_exadb_dr_network.sh`
- `rollback_exadb_dr_network.sh`
- `exadb_dr_network.log`

## Config File Overview

The config file contains these sections:

- `[primary_region_configuration]`
- `[standby_region_configuration]`
- `[hub_vcn_configuration]`
- `[database_listener_configuration]`
- `[global_optional_configuration]`

### Required Settings

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

### Optional Settings

Hub VCNs:
- `PRIMARY_HUB_VCN_CIDR`
- `STANDBY_HUB_VCN_CIDR`

If either hub CIDR is blank, the setup script auto-picks a small non-overlapping `/29` CIDR for the missing hub VCN. If you provide values, the script uses them as-is and validates overlap safety.

Database listener ports:
- `DB_TCP_LISTENER_PORT`
- `DB_TCPS_LISTENER_PORT`

If set, the setup script adds NSG listener rules for those ports. If blank, those listener rules are skipped.

Other optional values:
- `ALLOW_SSH`
- `NAME_PREFIX`

## Recommended Hub VCN Size

For this transit design, the hub VCN does not require subnets, so the hub CIDR can be very small. A `/29` is a practical size and matches the small transit CIDR style used in Oracle examples for this type of topology.

## How To Run

From OCI Cloud Shell:

```bash
unzip exadb_dr_network_flat_root.zip
chmod +x setup_exadb_dr_network.sh rollback_exadb_dr_network.sh
```

Edit the config:

```bash
vi exadb_dr_network.conf
```

Run setup:

```bash
./setup_exadb_dr_network.sh
```

Run rollback using the latest state file:

```bash
./rollback_exadb_dr_network.sh
```

Run rollback using a specific state file:

```bash
./rollback_exadb_dr_network.sh ./exadb_dr_network_state_<timestamp>.env
```

## What To Configure

At minimum, set:

```ini
[primary_region_configuration]
PRIMARY_REGION=""
PRIMARY_COMPARTMENT_OCID=""
PRIMARY_VCN_OCID=""
PRIMARY_CLIENT_SUBNET_CIDR=""
PRIMARY_BACKUP_SUBNET_CIDR=""

[standby_region_configuration]
STANDBY_REGION=""
STANDBY_COMPARTMENT_OCID=""
STANDBY_VCN_OCID=""
STANDBY_CLIENT_SUBNET_CIDR=""
STANDBY_BACKUP_SUBNET_CIDR=""
```

Optional hub CIDRs:

```ini
[hub_vcn_configuration]
PRIMARY_HUB_VCN_CIDR=""
STANDBY_HUB_VCN_CIDR=""
```

Optional listener ports:

```ini
[database_listener_configuration]
DB_TCP_LISTENER_PORT="1521"
DB_TCPS_LISTENER_PORT="2484"
```

Optional global values:

```ini
[global_optional_configuration]
ALLOW_SSH="false"
NAME_PREFIX="exadb-dr-network"
```

## Parallel Workstreams

The current implementation uses parallel workstreams where practical:

Setup:
- creates primary and standby DRG/RPC resources in parallel
- starts RPC peering in the background
- creates primary and standby local region artifacts in parallel
- performs post-peering routing and NSG configuration in parallel

Rollback:
- starts RPC deletion in the background
- performs per-region route cleanup in parallel
- performs per-region resource deletion in parallel after RPC deletion completes

## Manual Verification Checklist

After setup:
- verify primary LPG peering is `PEERED`
- verify standby LPG peering is `PEERED`
- verify cross-region RPC peering is `PEERED`
- verify Exadata route tables point remote client and backup CIDRs to the local LPG
- verify hub custom route tables are populated
- verify hub default route tables are populated
- verify RPC DRG route tables contain static routes to local client and backup CIDRs
- verify NSGs exist
- verify listener rules exist only when the listener config values were provided

After rollback:
- verify the RPCs are deleted
- verify DRG attachments are deleted
- verify LPGs are deleted
- verify created hub route tables are deleted
- verify DRGs are deleted
- verify hub VCNs are deleted

## Logs And State

The setup and rollback scripts append to:

- `exadb_dr_network.log`

Setup also creates a timestamped state file like:

- `exadb_dr_network_state_<timestamp>.env`

That state file is used by rollback to identify and remove only the resources created by setup.
