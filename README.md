# Logging 6.7 Hackathon Installer

Automated installer for Red Hat OpenShift Logging 6.7 and Loki Operator 6.7 (staging builds) for hackathon testing.

This is the Logging 6.6 installer flow, pointed at the official 6.7 staging catalogs. **This repository does not contain registry credentials.** Encode the stage token locally and paste it when the script prompts.

## Prerequisites

- **OpenShift cluster**: OCP **4.21**, **4.22**, or **5.0**
- **`oc` CLI**: Logged in with cluster-admin privileges
- **`jq`**: JSON processor (`sudo dnf install jq`)
- **Stage registry token**: Base64-encoded credentials for `registry.stage.redhat.io` (provided in the internal hackathon email, not in this repo)

## Catalog images

Official 6.7 staging FBC images (v4.22 tags on 4.21, 4.22, and 5.0 clusters):

```
quay.io/redhat-user-workloads/ocp-art-tenant/art-fbc:logging-6.7__v4.22__cluster-logging-rhel9-operator
quay.io/redhat-user-workloads/ocp-art-tenant/art-fbc:logging-6.7__v4.22__loki-rhel9-operator
```

## Quick Start

```bash
git clone https://github.com/prithvipatil97/logging-hackathon-installer.git
cd logging-hackathon-installer
./install-logging-67.sh --email <your-kerberos-id>
# When prompted, paste the base64-encoded registry token
```

## Obtaining the Registry Token

Generate the token on your machine (credentials come from the internal email):

```bash
echo -n '<username>:<password>' | base64 -w 0
```

Copy the output. The installer will ask you to paste it.

## Usage

```bash
# Install (prompts for email and token)
./install-logging-67.sh

# Install with email (prompts for token only)
./install-logging-67.sh --email pripatil

# Preview what will happen (no changes made)
./install-logging-67.sh --email pripatil --dry-run

# Custom MCP timeout (default 30 minutes)
./install-logging-67.sh --email pripatil --timeout 45

# Uninstall everything (interactive - asks before deleting CRs)
./install-logging-67.sh --uninstall
```

## What It Does

| Step | Action |
|------|--------|
| 0 | Pre-flight checks (`oc` login, OCP 4.21 / 4.22 / 5.0, `jq`) |
| 0.5 | Collect registry token (prompt, `--token`, or `STAGE_REGISTRY_TOKEN`) |
| 1 | Updates pull-secret with `registry.stage.redhat.io` credentials |
| 2 | Recreates CatalogSources `clo-stage` and `lo-stage` (latest FBC tag) |
| 3 | Creates ImageDigestMirrorSet `logging-stage` |
| 4 | Waits until CatalogSources are READY |
| 5 | Cleans failed marketplace unpack jobs |
| 6 | OperatorGroup + Subscription for Cluster Logging (`stable-6.7`) |
| 7 | OperatorGroup + Subscription for Loki (`stable-6.7`) |
| 8 | Waits for both CSVs to reach Succeeded |
| 9 | Prints final validation summary |

## Uninstall Behavior

When running `--uninstall`, the script will:

1. Detect Custom Resources (ClusterLogForwarder, LokiStack, UIPlugin) and ask before deleting each
2. Remove Subscriptions, CSVs, OperatorGroups
3. Remove CatalogSources (`clo-stage`, `lo-stage`)
4. Remove ImageDigestMirrorSet
5. Clean up failed marketplace jobs
6. Wait for MCP to stabilize

The pull-secret is NOT automatically reverted (instructions are printed for manual cleanup).

## Features

- **No hardcoded credentials**: Token is provided at runtime
- **Idempotent**: Safe to re-run
- **Dry-run mode**: Preview changes without executing
- **Uninstall mode**: Clean teardown with interactive CR confirmation
- **Duplicate OperatorGroup guard**
- **Stale job cleanup** and CatalogSource recreate for floating FBC tags
- **JSON validation** of pull-secret before apply
- **Progress logging**: `/tmp/logging-hackathon-install-*.log`

## Verify

In the OpenShift Web Console: **Ecosystem → Installed Operators**

- Red Hat OpenShift Logging Operator v6.7
- Loki Operator v6.7

## Hackathon test scripts

| Script | What it checks | Notes |
|--------|----------------|-------|
| `test-67-hardening-validation.sh` | LOG-9354 hardening (LFME, ubi-micro, NetworkPolicy, CLO requests) | Read-only |
| `test-boltdb-loki4-migration.sh` | LOG-9510 BoltDB / Loki 4.0 migration | Creates and deletes test LokiStacks |
| `test-clf-not-ready-alert.sh` | LOG-7717 ClusterLogForwarderNotReady alert | Creates and deletes a CLF |
| `test-67-must-gather.sh` | LOG-9008 must-gather as a Go binary | Runs `oc adm must-gather` unless `--skip-gather`. Prints Why / What / Pass means before each check. |

```bash
./test-67-must-gather.sh                 # image checks + full gather
./test-67-must-gather.sh --skip-gather   # image packaging only
./test-67-must-gather.sh --keep          # keep the gather directory
```

`test-67-must-gather.sh` is the LOG-9008 check. Logging must-gather used to be shell scripts that called `oc`. In 6.7 it is a Go binary in the Cluster Logging Operator image (`/usr/bin/must-gather`, symlink `/usr/bin/gather`, no `oc`). The script explains each step as it runs: inspect that packaging inside the CLO pod, run the customer `oc adm must-gather` command, then confirm the dump has `gather-debug.log`, `namespaces/openshift-logging`, `cluster-scoped-resources`, collector SUCCESS lines, and no ELK leftovers.

## Compatible Versions

| Logging | Loki | OCP |
|---------|------|-----|
| 6.7.0 | 6.7.0 | 4.21, 4.22, 5.0 |

The previous 6.6 installer is still in this repo as `install-logging-66.sh`.
