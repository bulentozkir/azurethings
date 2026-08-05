---
name: azure-aca-aci-acr-troubleshooting
description: >
  Diagnose Azure Container Apps, Azure Container Instances, and Azure Container
  Registry deployment, revision, replica, ingress, probes, scaling, Dapr,
  networking, DNS, identity, image pull, restart, quota, logging, and registry
  issues. Use for active incidents and container-platform root-cause analysis.
tools:
  - RunAzCliReadCommands
  - execute_kusto_query
  - AzureMCP/*
  - MicrosoftLearnMCP/*
---

# Azure ACA, ACI, and ACR Troubleshooting

> **Required MCP grounding:** Before conclusions, use `AzureMCP/*` for live Azure evidence and `MicrosoftLearnMCP/*` for current authoritative guidance. If either connector is unavailable, report a blocking evidence gap instead of relying on model memory.

## Purpose
Correlate Container Apps environment/app/revision evidence, Container Instances
group/container evidence, and ACR identity/network/repository evidence without
changing runtime state.

## Guardrails
- Do not restart, stop, redeploy, activate/deactivate revisions, change traffic,
  scale, update secrets, delete containers/images, or modify registry/networking.
- Never print secrets, registry credentials, environment values, or payload logs.
- Bound log output and preserve failed-revision/container evidence.

## Pre-check
Capture subscription, resource group, environment/group, app/container, revision,
registry, image digest, incident window, workload targets, and recent change.

### Step 1: Inventory ACA, ACI, and ACR
Use Azure MCP `containerapps_list`, `acr_registry_list`, and repository listing.

```bash
az containerapp show --resource-group <rg> --name <app> -o json
az containerapp revision list --resource-group <rg> --name <app> -o json
az containerapp replica list --resource-group <rg> --name <app> --revision <revision> -o json
az container show --resource-group <rg> --name <group> -o json
az acr show --resource-group <rg> --name <registry> -o json
```

Record environment/workload profile, zones, ingress/target port, revisions,
traffic, replicas, scale rules, probes, Dapr, identities, registry config,
volumes, ACI restart policy, IP/DNS/VNet, provisioning state, and events.

### Step 2: Build timeline and collect logs

```bash
az monitor activity-log list --resource-id <resource-id> --start-time <start-utc> --end-time <end-utc> -o table
az containerapp logs show --resource-group <rg> --name <app> --type system --tail 200
az containerapp logs show --resource-group <rg> --name <app> --type console --tail 200
az container logs --resource-group <rg> --name <group> --container-name <container>
```

Use `ContainerAppSystemLogs_CL`, `ContainerAppConsoleLogs_CL`, Azure Monitor
metrics, ACI events, and resource health when available. Separate platform
system logs from application console logs.

### Step 3: ACA deployment workflow

| Phase | Evidence |
|-------|----------|
| Before revision | Provisioning error, image pull, registry auth, secret/config validation |
| Revision created, not ready | Container exit, probes, target port, command, dependencies |
| Revision ready, no traffic | Traffic weights, labels, ingress, activation mode |
| Runtime degradation | Replicas, resource limits, probes, ingress, Dapr, dependencies |
| Scale failure | KEDA trigger/auth, min/max, cooldown, metric source, quota/capacity |

Validate target port equals the application listening port and the app listens
on the correct interface. Probe failures can be symptoms of dependency or
startup issues, not probe defects.

### Step 4: ACA symptom paths

| Symptom | Check |
|---------|-------|
| Failed deployment | System logs, provisioning state, image reference, identity, ACR/DNS |
| Restart loop | Exit code, previous replica logs, limits, probes, command |
| 404/502/503 | Ingress, target port, traffic, readiness, replica count, custom domain/TLS |
| Scale to zero/slow start | Min replicas, startup time, trigger, cold start, dependencies |
| No scale out | KEDA event source, auth, metric, max replicas, workload-profile quota |
| Dapr failure | Sidecar state, app port/id, component scope, secret store, mTLS |
| Network | Environment type, private endpoint, DNS, UDR/firewall/NSG, SNAT/egress |

### Step 5: ACI deployment/runtime paths
Review container group `instanceView.events`, per-container current/previous
state, exit code, restart count, restart policy, image, command, resources,
volumes, IP/DNS, subnet delegation, identity, and region quota.

| Symptom | Check |
|---------|-------|
| DeploymentFailed | Region/SKU/quota, image pull, subnet, DNS label, policy |
| InaccessibleImage | Exact image, registry auth, firewall/private DNS, architecture |
| Container terminates | Exit code, command, logs, restart policy, OOM/resources |
| Group stuck | Events, provisioning, volume mount, network profile, dependency |
| No connectivity | IP/FQDN, ports, protocol, NSG/UDR/firewall, private DNS |

ACI restart policy (`Always`, `OnFailure`, `Never`) determines expected lifecycle;
a completed container isn't necessarily unhealthy.

### Step 6: ACR shared pull path

```bash
az acr check-health --name <registry> --ignore-errors --yes
az acr repository show-tags --name <registry> --repository <repository> --orderby time_desc --top 20 -o table
az role assignment list --scope <acr-resource-id> -o table
```

Validate exact digest/tag, identity/RBAC or ABAC, registry admin dependency,
network/firewall/private endpoint, private DNS/data endpoint, egress, repository
and manifest, OS/architecture, and registry health. Correlate pull events with
deployment time.

### Step 7: Metrics and capacity
Discover metrics before querying. Review requests, replicas, restarts, CPU,
memory, network, response codes, ingress latency, KEDA scaling, ACI CPU/memory,
and registry storage/pull/throttling. Avoid averaging across revisions.

### Step 8: Test hypotheses
Compare image, identity, network, configuration, resource, and application causes.
Example: `new revision -> readiness fails because target port mismatched -> zero
healthy replicas -> ingress 503`.

## Scoring
Direct platform/container evidence 25, timeline 20, metrics/logs 15, mechanism
20, alternatives 10, validation 10. Use standard 90/70/40 confidence bands.

## Accepted exceptions
Record expected scale-to-zero, batch completion, Spot-like interruption,
maintenance, load tests, or public ingress with owner and review date.

## Expected output

## Azure ACA, ACI, and ACR Troubleshooting Report

Include resource/image/revision scope, window, timeline, logs/events, pull path,
network/scale evidence, diagnosis, mitigation, durable fix, verification, gaps,
exceptions, and commands.

## Remediation guidance
- Suggest only and preserve failed revision/container evidence.
- Use revision-based rollback and staged traffic for ACA.
- Validate ACI restart-policy semantics before any restart.
- Prefer managed identity for ACR pulls and least privilege.

## References
- ACA deployment failures: https://learn.microsoft.com/azure/container-apps/troubleshoot-deployment-errors
- ACA image pulls: https://learn.microsoft.com/azure/container-apps/troubleshoot-image-pull-failures
- ACA troubleshooting: https://learn.microsoft.com/azure/container-apps/troubleshooting
- ACI troubleshooting: https://learn.microsoft.com/azure/container-instances/container-instances-troubleshooting
- ACR health: https://learn.microsoft.com/azure/container-registry/container-registry-check-health
- ACA WAF guide: https://learn.microsoft.com/azure/well-architected/service-guides/azure-container-apps

## Sample output

`managed identity lacks repository pull permission -> revision creation fails
before app start`. Confidence: 89/100. No revision, identity, or registry change
was executed.
