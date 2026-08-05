---
name: appservices-troubleshooting
description: >
  Diagnose Azure App Service web apps, App Service plans, and App Service
  Environments, including startup, deployment, HTTP 5xx, latency, CPU, memory,
  worker recycle, health check, autoscale, slots, TLS, DNS, networking, SNAT,
  private endpoints, VNet integration, and plan or ASE saturation. Use for
  active incidents and App Service root-cause analysis.
tools:
  - RunAzCliReadCommands
  - execute_kusto_query
  - AzureMCP/*
  - MicrosoftLearnMCP/*
---

# Azure App Services Troubleshooting

> **Required MCP grounding:** Before conclusions, use `AzureMCP/*` for live Azure evidence and `MicrosoftLearnMCP/*` for current authoritative guidance. If either connector is unavailable, report a blocking evidence gap instead of relying on model memory.

## Purpose
Run an evidence-driven App Service investigation across app, deployment/slot,
worker instance, App Service plan, App Service Environment (ASE), network,
dependencies, and telemetry.

## Guardrails
- Do not restart/stop apps, scale plans, swap slots, change settings, network,
  certificates, health checks, or auto-heal.
- Don't retrieve app-setting or connection-string values. Query names/presence
  only when required.
- Preserve worker/process evidence before restart or recycle.
- Treat dumps and traces as sensitive and require approval.

## Pre-check
Capture app/slot, plan, ASE, runtime/container, incident/baseline windows,
critical endpoints, recent deployments, Application Insights, and dependencies.

### Step 1: Inventory app, plan, ASE, and deployment
Use Azure MCP `appservice_webapp_get`,
`appservice_webapp_deployment_get`, and diagnostic detector commands.

```bash
az webapp show --resource-group <rg> --name <app> --slot <slot> -o json
az webapp config show --resource-group <rg> --name <app> --slot <slot> -o json
az appservice plan show --resource-group <rg> --name <plan> -o json
az appservice ase list -o json
az webapp list-instances --resource-group <rg> --name <app> -o table
```

Record state, runtime/container, health path, Always On, 32/64-bit, worker count,
zone redundancy, autoscale, slots, VNet/private endpoint, outbound addresses,
ASE health/network, and deployment timestamps. Do not output secrets.

### Step 2: Run App Service Diagnostics
List detectors, choose one matching the symptom, and run it for the incident
window with `appservice_webapp_diagnostic_diagnose`.

Typical detector domains:
- Availability and HTTP errors
- CPU/memory and worker process
- Linux container startup/recycle
- Networking, DNS, SNAT, and dependencies
- Deployment and configuration
- Health check and auto-heal

Detector output is evidence, not automatic root cause. Correlate it with metrics,
logs, deployments, and application telemetry.

### Step 3: Build timeline and establish saturation

```bash
az monitor activity-log list --resource-id <app-resource-id> --start-time <start-utc> --end-time <end-utc> -o table
az monitor diagnostic-settings list --resource <app-resource-id> -o json
az monitor metrics list-definitions --resource <app-resource-id> -o table
```

Review requests, HTTP 2xx/4xx/5xx, response time, CPU time, average memory working
set, bytes, connections, health check, instance count, restarts, and filesystem.

Also query the **plan** for CPU/memory percentage, queue length, workers, and
apps sharing the plan. One noisy app can affect every app in the plan.

For ASE, inspect front-end/worker health, subnet capacity, internal load
balancer, DNS, routes, NSGs, firewall, certificates, and platform events.

### Step 4: Inspect logs and Application Insights
Use bounded App Service HTTP/application/container/platform logs and Application
Insights:

```kusto
AppRequests
| where TimeGenerated >= ago(60m)
| summarize Requests=sum(ItemCount), Failures=sumif(ItemCount, Success == false),
            P95Ms=percentile(DurationMs, 95)
  by bin(TimeGenerated, 5m), AppRoleName, ResultCode
| order by TimeGenerated asc
```

```kusto
AppExceptions
| where TimeGenerated >= ago(60m)
| summarize Occurrences=sum(ItemCount), FirstSeen=min(TimeGenerated),
            LastSeen=max(TimeGenerated)
  by AppRoleName, ExceptionType, ProblemId
| top 20 by Occurrences desc
```

Correlate dependency latency/failure, traces, deployments, version, role
instance, and one representative operation ID. Redact messages and URLs.

### Step 5: Follow the symptom path

| Symptom | Required investigation |
|---------|------------------------|
| Startup/502/503 | Runtime/image, startup command, port, dependency, deployment, container logs |
| HTTP 500 | Operation/result, exception group, deployment version, dependency |
| Latency | Request vs dependency p95/p99, plan saturation, queue, sync blocking |
| High CPU | Traffic, hot instance, code loop, retry storm, GC, plan noisy neighbor |
| High memory/recycle | Working set, instance, leak/cache, limit, dump need, auto-heal |
| Health-check removal | Path behavior, dependency depth, timeout, warmup, instance health |
| Deployment regression | Deployment log, slot config, warmup, package/image, rollback evidence |
| Network/DNS | VNet integration, route-all, DNS, private endpoint, NSG/UDR/firewall, SNAT |
| Scale failure | Tier/limit, autoscale signal, cooldown, quota/capacity, state/session affinity |
| ASE | Subnet addresses, ASE health, ILB/DNS, front ends/workers, certificates, network |

### Step 6: Validate configuration deeply
Resource Graph omits some site configuration. Use ARM/CLI metadata for minimum
TLS, HTTPS-only, FTPS, HTTP versions, remote debugging, health check, IP/access
restrictions, client certificates, SCM/basic auth, VNet routing, and slot
settings. Report values only when they support a finding.

### Step 7: Decide on runtime artifacts
Recommend counters/trace first, then dump only for unresolved high CPU, memory,
hang, deadlock, or repeated crash. Require user approval, protected storage,
overhead review, and retention plan.

## Scoring
Direct detector/log evidence 25, timeline 20, metrics 15, mechanism 20,
alternatives 10, recovery validation 10. Use 90/70/40 confidence bands.

## Accepted exceptions
Record planned load/deployment, warmup, recycling, maintenance, intentionally
public access, or single-instance nonproduction with owner/review date.

## Expected output

## Azure App Services Troubleshooting Report

Include app/slot/plan/ASE scope, window, deployment timeline, app and plan
metrics, detector/log/telemetry evidence, diagnosis, mitigations, durable fixes,
verification, evidence gaps, exceptions, and commands.

## Remediation guidance
- Suggest only; smallest reversible mitigation first.
- Preserve evidence before restart/scale/swap.
- Verify health, deployment, and network changes from every required path.
- Separate app fixes from plan/ASE capacity fixes.

## References
- App Service diagnostics: https://learn.microsoft.com/azure/app-service/overview-diagnostics
- Diagnostic logs: https://learn.microsoft.com/azure/app-service/troubleshoot-diagnostic-logs
- Performance degradation: https://learn.microsoft.com/troubleshoot/azure/app-service/troubleshoot-performance-degradation
- App Service monitoring: https://learn.microsoft.com/azure/app-service/monitor-app-service
- ASE networking: https://learn.microsoft.com/azure/app-service/environment/networking
- WAF service guide: https://learn.microsoft.com/azure/well-architected/service-guides/app-service-web-apps

## Sample output

`deployment -> one instance memory growth -> repeated worker recycle -> 503`.
Plan CPU remained healthy, excluding plan saturation. Confidence: 87/100.
