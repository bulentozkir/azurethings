---
name: functions-troubleshooting
description: >
  Diagnose Azure Functions and hosting plans using the
  azure-functions-issues-workbook. Use for host startup, missing functions,
  trigger sync, invocation failures, timeouts, retries, cold starts, scaling,
  storage, networking, deployment slots, runtime/version, Application Insights,
  Linux Consumption retirement, Advisor, and Resource Health issues.
tools:
  - RunAzCliReadCommands
  - execute_kusto_query
  - AzureMCP/*
  - MicrosoftLearnMCP/*
---

# Azure Functions Troubleshooting

> **Required MCP grounding:** Before conclusions, use `AzureMCP/*` for live Azure evidence and `MicrosoftLearnMCP/*` for current authoritative guidance. If either connector is unavailable, report a blocking evidence gap instead of relying on model memory.

## Purpose
Combine the Functions workbook's fleet configuration and retirement checks with
runtime, trigger, scale, dependency, and Application Insights diagnostics.

## Workbook source
The two local copies are byte-identical. Use:

`azure-functions-workbook/azure-functions-issues-workbook.json`

Record SHA-256, scope filters, and assessment date. The workbook uses Resource
Graph only and excludes Logic Apps Standard (`workflowapp`).

## Guardrails
- Do not restart, sync triggers, swap slots, scale, change app settings, migrate
  plans, replay messages, purge Durable state, or modify networking.
- Never print app-setting values, storage keys, connection strings, function
  keys, host keys, payloads, or Durable inputs/outputs.
- Query setting names/presence only.
- Preserve host and invocation evidence before restarting.

## Pre-check
Capture app/slot, plan/OS/tier, runtime/worker model, triggers, incident window,
deployment, Application Insights, storage/dependencies, and migration deadlines.

### Step 1: Run workbook posture checks
Use Azure MCP `functionapp_get` and Resource Graph for:

- Linux Consumption retirement exposure
- HTTPS-only, state/enabled, managed identity
- Availability/usage state
- Always On for nonserverless plans
- Public network access without VNet integration
- HTTP/2, daily memory quota, and client certificate posture
- Plan SKU/capacity/zone redundancy
- Runtime stack, scale limit, slots, Advisor, and Resource Health

Workbook triage is count-based: Critical is Linux Consumption plus at least
three findings; High is Linux Consumption or 5+; Medium 2-4; Low 1. Use this
only for triage, not final incident priority.

### Step 2: Validate deep configuration
Resource Graph doesn't reliably expose minimum TLS, FTPS, CORS, health path,
remote debugging, IP restrictions, or `Microsoft.Web/sites/config`. Retrieve
these through read-only ARM/CLI.

Check presence, not value, for:
- `FUNCTIONS_EXTENSION_VERSION`
- `FUNCTIONS_WORKER_RUNTIME`
- `AzureWebJobsStorage`
- package/deployment settings
- trigger-specific connection settings

Validate hosting plan semantics: Consumption, Flex Consumption, Elastic Premium,
Dedicated/App Service, or Container Apps hosting where applicable.

### Step 3: Address retirement exposure
Workbook criteria for retiring Linux Consumption:

- App Service plan tier `Dynamic` / Y1
- Linux (`properties.reserved == true`)

Deadlines:

| Date | Event |
|------|-------|
| 2026-09-30 | End-of-life v3 runtime apps on Linux Consumption stop running |
| 2028-09-30 | Linux Consumption plan retires |

Windows Consumption isn't retiring and Flex Consumption is Linux-only. Validate
runtime, trigger, networking, deployment, region, zone, scaling, concurrency,
and feature compatibility before recommending migration to Flex Consumption.

### Step 4: Build change and health timeline

```bash
az functionapp show --resource-group <rg> --name <app> -o json
az monitor activity-log list --resource-id <app-resource-id> --start-time <start-utc> --end-time <end-utc> -o table
az monitor diagnostic-settings list --resource <app-resource-id> -o json
```

Use deployment-history APIs that don't return credentials. Correlate deployment,
runtime, scale, networking, storage, and platform changes.

### Step 5: Inspect Application Insights

```kusto
AppRequests
| where TimeGenerated >= ago(60m)
| summarize Invocations=sum(ItemCount), Failures=sumif(ItemCount, Success == false),
            P95Ms=percentile(DurationMs, 95)
  by bin(TimeGenerated, 5m), OperationName, ResultCode
| order by TimeGenerated asc
```

```kusto
AppExceptions
| where TimeGenerated >= ago(60m)
| summarize Occurrences=sum(ItemCount) by OperationName, ExceptionType, ProblemId
| top 20 by Occurrences desc
```

Also inspect dependencies, traces, host logs, scale-controller logs when
available, trigger backlog, and sampling. Redact payloads and messages.

### Step 6: Follow the symptom path

| Symptom | Required investigation |
|---------|------------------------|
| Host initialization | Runtime/worker mismatch, storage reachability, package, extension bundle, startup exception |
| No functions found | Deployment contents, metadata generation, worker model, entry points, disabled functions |
| Trigger not firing | Trigger sync state, connection presence, source backlog, permissions, host locks, disabled flag |
| Invocation failure | Exception group, retry policy, poison/dead-letter path, idempotency, dependency |
| Timeout | Plan timeout, long operation, dependency, Durable pattern, CPU/memory |
| Cold start | Plan, always-ready/prewarmed instances, package size, initialization, VNet/dependencies |
| Scale lag | Trigger scale behavior, concurrency, scale limit, backlog, storage, quota/capacity |
| Duplicate processing | At-least-once delivery, retries, visibility/lock timeout, idempotency |
| Durable issue | Hub/storage, orchestration history, deterministic code, versioning, poison activity |
| Network | VNet integration, private DNS, route-all, firewall/NSG, storage/Key Vault access |
| Deployment/slot | Slot settings, trigger behavior, warmup, package, rollback, in-flight work |

### Step 7: Hosting-plan diagnosis
For Dedicated/Premium plans, inspect plan CPU, memory, workers, queue, and noisy
neighbors. For Flex/Consumption, inspect trigger-driven scaling, concurrency,
cold start, memory quota, and regional limits. Never apply Dedicated-plan
Always On assumptions to serverless plans.

### Step 8: Test hypotheses
Compare host, trigger, source, dependency, plan, deployment, and network causes.
Example:

`deployment omitted generated function metadata -> host starts with zero
functions -> trigger never registers`.

## Scoring
Direct host/trigger evidence 25, timeline 20, telemetry 15, mechanism 20,
alternatives 10, validation 10. Use 90/70/40 confidence bands.

## Accepted exceptions
Record expected timer gaps, scale-to-zero, load tests, maintenance, disabled
nonproduction functions, or planned migration with owner and review date.

## Expected output

## Azure Functions Troubleshooting Report

Include app/slot/plan/runtime, retirement status, window, timeline, trigger/host
evidence, telemetry, diagnosis, mitigation, durable fix, verification, gaps,
exceptions, and commands/queries.

## Remediation guidance
- Suggest only and preserve messages/state before replay or restart.
- Require idempotency before retry/replay changes.
- Use slots/rings and migration validation for runtime or plan changes.
- Never expose or rotate storage/function keys from this skill.

## References
- Workbook: `azure-functions-workbook/azure-functions-issues-workbook.json`
- Functions monitoring: https://learn.microsoft.com/azure/azure-functions/monitor-functions
- Error handling/retries: https://learn.microsoft.com/azure/azure-functions/functions-bindings-error-pages
- Performance/reliability: https://learn.microsoft.com/azure/azure-functions/performance-reliability
- Consumption-to-Flex migration: https://learn.microsoft.com/azure/azure-functions/migration/migrate-plan-consumption-to-flex
- WAF service guide: https://learn.microsoft.com/azure/well-architected/service-guides/azure-functions

## Sample output

`storage private DNS regression -> host cannot acquire listener lease -> queue
trigger stops while HTTP health remains green`. Confidence: 91/100. No trigger,
storage, app, or plan change was executed.
