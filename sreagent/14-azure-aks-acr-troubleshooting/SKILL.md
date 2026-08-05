---
name: azure-aks-acr-troubleshooting
description: >
  Diagnose Azure Kubernetes Service and Azure Container Registry issues,
  including cluster and node-pool health, Pending or CrashLoopBackOff pods,
  OOMKilled, autoscaling, DNS, networking, ingress, identity, upgrades, image
  pulls, registry authentication, private endpoints, repository access, and
  supply-chain failures. Use for active incidents and AKS/ACR root-cause analysis.
tools:
  - RunAzCliReadCommands
  - execute_kusto_query
  - AzureMCP/*
  - MicrosoftLearnMCP/*
---

# Azure AKS and ACR Troubleshooting

> **Required MCP grounding:** Before conclusions, use `AzureMCP/*` for live Azure evidence and `MicrosoftLearnMCP/*` for current authoritative guidance. If either connector is unavailable, report a blocking evidence gap instead of relying on model memory.

## Purpose
Run a read-only investigation across AKS control plane, node pools, Kubernetes
workloads, Azure networking, Azure Monitor, and ACR. Correlate platform and
in-cluster evidence before assigning root cause.

## Guardrails
- Use read-only Azure and Kubernetes commands.
- Do not restart/delete pods, drain/cordon nodes, scale, upgrade, rotate
  certificates, change RBAC/networking, attach ACR, or import/delete images.
- Do not print Kubernetes Secrets, registry tokens, pull secrets, kubeconfigs,
  environment values, or image vulnerability details outside approved scope.
- Treat `kubectl describe`, events, previous logs, and manifests as sensitive.
- Preserve evidence before any workload or node restart.

## Pre-check

| Field | Required value |
|-------|----------------|
| Scope | Subscription, cluster, namespace, workload, ACR |
| Symptom | API, node, scheduling, crash, memory, DNS, network, ingress, pull |
| Window | Incident and healthy baseline UTC |
| Architecture | Regions/zones, pools, CNI, egress, ingress, identities |
| Change | Deployment, image, config, node image, upgrade, policy, network |
| Telemetry | Container Insights, Prometheus, control-plane logs, ACR logs |

### Step 1: Inspect cluster, pools, and registry
Use Azure MCP `aks_cluster_get`, `aks_nodepool_get`, `acr_registry_list`, and
`acr_registry_repository_list`.

```bash
az aks show --resource-group <rg> --name <cluster> -o json
az aks nodepool list --resource-group <rg> --cluster-name <cluster> -o json
az acr show --resource-group <rg> --name <registry> -o json
az monitor activity-log list --resource-id <cluster-resource-id> --start-time <start-utc> --end-time <end-utc> -o table
```

Record Kubernetes/version support, provisioning/power state, SKU, zones, node
images, autoscaler bounds, identities, private API, authorized ranges, network
plugin/policy, outbound type, DNS, maintenance, ACR SKU/network/local auth, and
private endpoints.

### Step 2: Establish Azure health and telemetry
Query Resource Health, metrics, activity changes, and diagnostic settings for
cluster, node pools/VMSS, load balancers, public IPs, and registry.

Inspect Container Insights tables:

```kusto
KubePodInventory
| where TimeGenerated >= ago(60m)
| where ClusterName == "<cluster>"
| summarize arg_max(TimeGenerated, *) by Namespace, Name, ContainerName
| project Namespace, Name, ContainerName, PodStatus, ContainerStatus,
          ContainerStatusReason, ContainerRestartCount
| order by ContainerRestartCount desc
```

```kusto
ContainerLogV2
| where TimeGenerated >= ago(60m)
| where PodNamespace == "<namespace>"
| where LogLevel in~ ("CRITICAL","ERROR","WARNING")
   or tostring(LogMessage) has_any ("exception","failed","timeout","oom")
| project TimeGenerated, PodName, ContainerName, LogLevel, LogSource, LogMessage
| order by TimeGenerated desc
| take 200
```

Use managed Prometheus/Container Insights metrics for node/pod CPU, memory,
disk, restarts, readiness, unschedulable pods, autoscaler, and API latency.

### Step 3: Inspect Kubernetes state
With approved cluster read access:

```bash
kubectl get nodes -o wide
kubectl get pods -A -o wide
kubectl get events -A --sort-by=.lastTimestamp
kubectl describe pod <pod> -n <namespace>
kubectl logs <pod> -n <namespace> --all-containers --tail=200
kubectl logs <pod> -n <namespace> --all-containers --previous --tail=200
kubectl top nodes
kubectl top pods -A --containers
```

Inspect deployments/statefulsets/daemonsets, replica sets, jobs, HPA, PDB,
services, endpoints, ingresses, network policies, PVC/PV, resource quota,
limit ranges, priority classes, taints, tolerations, and node conditions.
Never output Secret data.

### Step 4: Follow the workload symptom

| Symptom | Required investigation |
|---------|------------------------|
| Pending | Events, requests/limits, quota, taints, affinity, PVC, IP exhaustion, autoscaler |
| CrashLoopBackOff | Exit code, previous logs, probes, config/secret presence, dependencies, command |
| OOMKilled | Container limit, working set, node pressure, request/limit, leak/load, QoS |
| NotReady node | Conditions, kubelet, disk/PID/memory pressure, CNI, image, VMSS/health |
| DNS | CoreDNS pods/logs, service/endpoints, upstream DNS, egress, custom DNS |
| Network | CNI/IP capacity, routes, NSGs, firewall, policy, SNAT, LB/ingress health |
| Autoscale | HPA signal, requests, unschedulable reason, pool max, quota/capacity |
| API unavailable | Private DNS/path, authorized ranges, control-plane health, identity |
| Upgrade | Supported skew, deprecated API, PDB, pool surge, quota, maintenance events |

Separate cluster/platform, node, Kubernetes scheduling, and application causes.

### Step 5: Troubleshoot ACR image pulls
Understand the path:

`kubelet identity -> Entra token -> ACR data endpoint -> repository manifest ->
blob layers -> node runtime`

Check:

```bash
az acr check-health --name <registry> --ignore-errors --yes
az role assignment list --assignee <kubelet-object-id> --scope <acr-resource-id> -o table
az acr repository show-tags --name <registry> --repository <repo> --orderby time_desc --top 20 -o table
```

Validate:
- Exact registry/repository/tag or digest
- Kubelet identity and `AcrPull`/ABAC repository permissions
- Cross-tenant identity constraints
- Admin user and imagePullSecrets aren't unintended dependencies
- ACR firewall/private endpoint, private DNS, data endpoint, trusted services
- Node egress, proxy/firewall, TLS, and DNS
- Manifest architecture/OS and image availability
- ACR health, throttling, repository/manifest existence, and pull events

Do not infer authorization from a role assignment alone; confirm scope and ACR
permission mode.

### Step 6: Analyze supply chain and changes
Correlate image digest, deployment revision, Helm/GitOps change, admission
policy, Defender scan, signing/provenance, base image, and registry retention.
Do not expose vulnerability details unless authorized.

### Step 7: Test hypotheses
State expected, observed, and contradicting evidence and compare at least one
alternative. Use causal chains such as:

`new image -> startup probe fails -> pod unavailable -> service endpoint loss`.

## Scoring
Direct Kubernetes/ACR evidence 25, Azure timeline/health 20, logs/metrics 15,
mechanism 20, alternatives 10, recovery validation 10. Classify at
90/70/40 as Confirmed/High confidence/Probable/Hypothesis.

## Accepted exceptions
Record approved Spot eviction, maintenance, chaos tests, transient rollout
restarts, expected jobs, or intentionally public registry/network behavior with
owner and review date.

## Expected output

## Azure AKS and ACR Troubleshooting Report

Include cluster/pool/registry scope, incident window, impact, timeline, Azure
health, Kubernetes evidence, ACR pull path, diagnosis, mitigations, durable fixes,
verification, telemetry gaps, exceptions, and commands/queries.

## Remediation guidance
- Suggest only; use rollout/rollback and disruption budgets.
- Never delete pods as root-cause remediation without preserving evidence.
- Validate capacity, quota, PDB, and zone impact before pool changes.
- Use managed identity/Entra for ACR and least privilege.

## References
- AKS troubleshooting: https://learn.microsoft.com/azure/aks/troubleshooting
- CrashLoopBackOff: https://learn.microsoft.com/troubleshoot/azure/azure-kubernetes/create-upgrade-delete/pod-stuck-crashloopbackoff-mode
- OOMKilled: https://learn.microsoft.com/troubleshoot/azure/azure-kubernetes/availability-performance/troubleshoot-oomkilled-aks-clusters
- AKS/ACR pulls: https://learn.microsoft.com/troubleshoot/azure/azure-kubernetes/connectivity/cannot-pull-image-from-acr-to-aks-cluster
- ACR health: https://learn.microsoft.com/azure/container-registry/container-registry-check-health
- AKS WAF guide: https://learn.microsoft.com/azure/well-architected/service-guides/azure-kubernetes-service

## Sample output

> Redacted example.

`new image digest -> arm64-only manifest on amd64 pool -> ImagePull/Run failure ->
deployment unavailable`. Confidence: 92/100. No pod, deployment, pool, or
registry change was executed.
