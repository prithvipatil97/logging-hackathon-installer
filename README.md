# Logging 6.6 Hackathon Installer

Automated installer for Red Hat OpenShift Logging 6.6 and Loki Operator 6.6 (staging builds) for hackathon testing.

## Prerequisites

- **OpenShift cluster**: OCP 4.20, 4.21, or 4.22
- **`oc` CLI**: Logged in with cluster-admin privileges
- **`jq`**: JSON processor (`sudo dnf install jq`)
- **Stage registry token**: Base64-encoded credentials for `registry.stage.redhat.io`

## Obtaining the Registry Token

1. Get the service account credentials (ask your team lead or check the internal wiki)
2. Base64-encode the credentials:
   ```bash
   echo -n '<username>:<password>' | base64 -w 0
   ```
3. Use the resulting token when running the script

## Quick Start

```bash
git clone https://github.com/prithvipatil97/logging-hackathon-installer.git
cd logging-hackathon-installer
./install-logging-66.sh --email <your-kerberos-id>
# You will be prompted to paste your registry token
```

## Usage

```bash
# Install (prompts for email and token)
./install-logging-66.sh

# Install with email (prompts for token only)
./install-logging-66.sh --email pripatil

# Install with token via environment variable (no prompts)
export STAGE_REGISTRY_TOKEN="<your-base64-token>"
./install-logging-66.sh --email pripatil

# Install with token via flag
./install-logging-66.sh --email pripatil --token "<your-base64-token>"

# Preview what will happen (no changes made)
./install-logging-66.sh --email pripatil --dry-run

# Custom MCP timeout (default 30 minutes)
./install-logging-66.sh --email pripatil --timeout 45

# Uninstall everything (interactive - asks before deleting CRs)
./install-logging-66.sh --uninstall
```

## What It Does

The script automates the following steps:

| Step | Action |
|------|--------|
| 0 | Pre-flight checks (oc login, OCP version, jq) |
| 0.5 | Collect registry credentials (prompt or env var) |
| 1 | Updates pull-secret with `registry.stage.redhat.io` credentials |
| 2 | Creates CatalogSources for CLO and Loki staging catalogs |
| 3 | Creates ImageDigestMirrorSet to mirror from stage registry |
| 4 | Validates CatalogSources are READY |
| 5 | Cleans up any stale unpack jobs from previous attempts |
| 6 | Creates OperatorGroup + Subscription for Cluster Logging Operator |
| 7 | Creates OperatorGroup + Subscription for Loki Operator |
| 8 | Waits for both operator CSVs to reach Succeeded phase |
| 9 | Prints final validation summary |

## Uninstall Behavior

When running `--uninstall`, the script will:

1. **Detect Custom Resources** (ClusterLogForwarder, LokiStack, UIPlugin) and ask for confirmation before deleting each
2. Remove Subscriptions, CSVs, OperatorGroups
3. Remove CatalogSources (clo-stage, lo-stage)
4. Remove ImageDigestMirrorSet
5. Clean up failed marketplace jobs
6. Wait for MCP to stabilize

The pull-secret is NOT automatically reverted (instructions are printed for manual cleanup).

## Features

- **No hardcoded credentials**: Token is provided at runtime (prompt, flag, or env var)
- **Idempotent**: Safe to re-run (skips already-completed steps)
- **Dry-run mode**: Preview changes without executing
- **Uninstall mode**: Clean teardown with interactive CR confirmation
- **Duplicate OperatorGroup guard**: Detects and fixes the common "multiple OperatorGroup" issue
- **Stale job cleanup**: Removes failed unpack jobs that block retries
- **JSON validation**: Validates pull-secret before applying
- **Progress logging**: Timestamped log file at `/tmp/logging-hackathon-install-*.log`

## Troubleshooting

### MCP timeout
If MCP takes longer than default 30 minutes, increase with `--timeout 60`.

### Operator stuck in Pending
Check the subscription and unpack jobs:
```bash
oc get sub -n openshift-logging -o yaml
oc get pods -n openshift-marketplace
oc get events -n openshift-marketplace --sort-by='.lastTimestamp' | tail -20
```

### Re-running after failure
The script is idempotent. Simply run it again - it will skip completed steps and retry failed ones.

### Full cleanup and fresh start
```bash
./install-logging-66.sh --uninstall
./install-logging-66.sh --email <your-id>
```

## Updating for Future Versions

When a new logging version is released (e.g., 6.7):
1. Update `CLO_CATALOG_IMAGE` and `LOKI_CATALOG_IMAGE` at the top of the script
2. Update CSV names (`cluster-logging.v6.7.0`, `loki-operator.v6.7.0`)
3. Update the channel (`stable-6.7`)
4. Commit and push

## Compatible Versions

| Logging | Loki | OCP |
|---------|------|-----|
| 6.6.0 | 6.6.0 | 4.20, 4.21, 4.22 |
