---
name: dotnet-core-app-troubleshooting
description: >
  Diagnose .NET and .NET Core startup, crash, HTTP 5xx, latency, CPU, memory,
  OOM, dependency, and telemetry problems across App Service, Container Apps,
  AKS, and Azure VMs during incidents, regressions, and root-cause analysis.
tools:
  - RunAzCliReadCommands
  - execute_kusto_query
  - AzureMCP/*
  - MicrosoftLearnMCP/*
---

# .NET Core Application Troubleshooting

> **Required MCP grounding:** Before conclusions, use `AzureMCP/*` for live Azure evidence and `MicrosoftLearnMCP/*` for current authoritative guidance. If either connector is unavailable, report a blocking evidence gap instead of relying on model memory.

## Purpose
Run a safe, evidence-driven investigation of a .NET or .NET Core application
incident on Azure. Correlate application telemetry, platform health, resource
metrics, deployment changes, dependencies, and runtime symptoms. Produce a
ranked root-cause assessment with immediate mitigation options, durable fixes,
and explicit verification criteria.

## When to use this skill
- The application has startup failures, HTTP 5xx, crashes, restarts, or OOM kills
- Requests are slow, timing out, or showing abnormal CPU, memory, GC, or thread-pool behavior
- SQL, HTTP, DNS, TLS, identity, or another dependency is failing
- Application Insights or OpenTelemetry data is missing or incomplete
- A recent deployment or configuration change might have caused a regression
- The user requests .NET application troubleshooting, incident triage, or RCA

## Guardrails
- Use read-only commands and queries during investigation.
- Do not restart, redeploy, scale, swap slots, change configuration, rotate credentials, or collect a dump without explicit user approval.
- Do not list application-setting or connection-string values; query configuration metadata only.
- Do not expose request bodies, query strings, cookies, tokens, user identifiers, connection strings, or full exception payloads; redact log samples.
- Treat missing telemetry as an observability gap, not evidence that the application is healthy.
- Use UTC for all investigation windows and report timestamps.
- Preserve evidence before recommending a restart because it can remove volatile runtime state.
- Separate facts, inferences, and hypotheses; never claim a root cause from temporal correlation alone.

## Pre-check
Collect or infer the following:

| Field | Required value |
|-------|----------------|
| Scope | Subscription, resource group, resource name or resource ID |
| Hosting platform | App Service, Container Apps, AKS, or VM |
| Symptom | Error, latency, CPU, memory, restart, startup, dependency, or telemetry |
| Incident window | Start and end in UTC |
| Impact | Affected routes, roles, regions, instances, and users if known |
| Baseline | A comparable healthy period |
| Changes | Deployment, configuration, scale, networking, identity, or dependency changes |
| Telemetry | Application Insights resource and/or Log Analytics workspace |

If the user does not provide an incident window, start with the last 60 minutes
and compare it with the preceding 60 minutes. Expand to 24 hours only when the
initial window does not explain the symptom.

If multiple resources match the name, stop and ask the user to select the exact
resource. Do not combine production and non-production evidence.

## Investigation procedure

### Step 1: Confirm scope and current state
Resolve the exact resource ID and record its type, region, provisioning state,
and tags relevant to environment or ownership.

```bash
az resource show --ids <resource-id> --query "{name:name,type:type,location:location,resourceGroup:resourceGroup,provisioningState:properties.provisioningState,tags:tags}" -o json
```

Run the matching platform command.

**Azure App Service**

```bash
az webapp show --resource-group <resource-group> --name <app-name> --query "{state:state,availabilityState:availabilityState,kind:kind,httpsOnly:httpsOnly,serverFarmId:serverFarmId,identityType:identity.type}" -o json
az webapp config show --resource-group <resource-group> --name <app-name> --query "{alwaysOn:alwaysOn,healthCheckPath:healthCheckPath,http20Enabled:http20Enabled,linuxFxVersion:linuxFxVersion,netFrameworkVersion:netFrameworkVersion,use32BitWorkerProcess:use32BitWorkerProcess,numberOfWorkers:numberOfWorkers}" -o json
az webapp list-instances --resource-group <resource-group> --name <app-name> -o table
```

For a deployment slot, add `--slot <slot-name>` to every supported App Service
command and keep slot evidence separate from production.

**Azure Container Apps**

```bash
az containerapp show --resource-group <resource-group> --name <app-name> --query "{provisioningState:properties.provisioningState,runningStatus:properties.runningStatus,latestRevisionName:properties.latestRevisionName,latestReadyRevisionName:properties.latestReadyRevisionName,minReplicas:properties.template.scale.minReplicas,maxReplicas:properties.template.scale.maxReplicas}" -o json
az containerapp revision list --resource-group <resource-group> --name <app-name> --query "[].{name:name,active:properties.active,created:properties.createdTime,healthState:properties.healthState,replicas:properties.replicas,trafficWeight:properties.trafficWeight}" -o table
```

**Azure Kubernetes Service**

```bash
az aks show --resource-group <resource-group> --name <cluster-name> --query "{provisioningState:provisioningState,powerState:powerState.code,kubernetesVersion:kubernetesVersion,nodeResourceGroup:nodeResourceGroup,identityType:identity.type}" -o json
az aks nodepool list --resource-group <resource-group> --cluster-name <cluster-name> --query "[].{name:name,state:provisioningState,powerState:powerState.code,count:count,min:minCount,max:maxCount,version:orchestratorVersion}" -o table
```

**Azure virtual machine**

```bash
az vm get-instance-view --resource-group <resource-group> --name <vm-name> --query "{powerState:instanceView.statuses[-1].displayStatus,provisioningState:provisioningState,computerName:osProfile.computerName}" -o json
```

### Step 2: Build the change and health timeline
Query the Azure Activity Log for the incident window and include a 30-minute
lead-in. Focus on writes, deployments, restarts, scale actions, health events,
identity changes, networking changes, and diagnostic-setting changes.

```bash
az monitor activity-log list --resource-id <resource-id> --start-time <start-utc> --end-time <end-utc> --query "[].{time:eventTimestamp,operation:operationName.localizedValue,status:status.localizedValue,correlationId:correlationId}" -o table
```

Check resource-group deployments when the resource activity log indicates a
change or the symptom began after a release.

```bash
az deployment group list --resource-group <resource-group> --query "[?properties.timestamp >= '<start-utc>'].{name:name,time:properties.timestamp,state:properties.provisioningState,correlationId:properties.correlationId}" -o table
```

Record exact timestamps. A deployment near the incident is a candidate cause,
not proof.

### Step 3: Inspect metrics without guessing metric names
Discover metrics supported by the target resource before querying them.

```bash
az monitor metrics list-definitions --resource <resource-id> --query "[].{name:name.value,unit:unit,primaryAggregation:primaryAggregationType}" -o table
```

Query only available metrics. Prefer five-minute bins for the initial
investigation and one-minute bins around a narrow failure window.

```bash
az monitor metrics list --resource <resource-id> --metric <metric-name> --start-time <start-utc> --end-time <end-utc> --interval PT5M --aggregation Average Maximum Total -o json
```

Prioritize metrics that represent:

| Symptom | Signals |
|---------|---------|
| Availability | Requests, failed requests, HTTP 5xx, health status |
| Latency | Average duration, p95/p99 application duration, dependency duration |
| CPU | CPU percentage/time, request rate, instance or replica count |
| Memory | Working set, memory percentage, GC heap, restart or OOM count |
| Saturation | Queue length, thread-pool queue, connections, throttling |
| Restarts | Instance count, replica health, container/pod restart count |

Do not compare percentages across different resource types as if they have the
same denominator.

### Step 4: Confirm telemetry routing
Check whether diagnostic settings send platform logs and metrics to the
expected destination.

```bash
az monitor diagnostic-settings list --resource <resource-id> -o json
```

If the required table is absent, state which diagnostic setting or application
instrumentation is missing. Do not silently switch to unrelated resources in a
shared workspace.

Application Insights has two query schemas:

| Query context | Request table | Exception table | Dependency table | Trace table |
|---------------|---------------|-----------------|------------------|-------------|
| Log Analytics workspace | `AppRequests` | `AppExceptions` | `AppDependencies` | `AppTraces` |
| Application Insights resource | `requests` | `exceptions` | `dependencies` | `traces` |

The queries below use the Log Analytics schema. When the connected Kusto tool
targets an Application Insights resource, translate table and column names to
that schema rather than reporting a false telemetry gap.

### Step 5: Establish request health
Run the request trend query. Add an `AppRoleName` filter when the workspace is
shared by multiple applications.

```kusto
AppRequests
| where TimeGenerated >= ago(60m)
| summarize
    Requests = sum(ItemCount),
    Failures = sumif(ItemCount, Success == false),
    P50Ms = percentile(DurationMs, 50),
    P95Ms = percentile(DurationMs, 95),
    P99Ms = percentile(DurationMs, 99)
  by bin(TimeGenerated, 5m), AppRoleName
| extend FailureRatePct = round(100.0 * Failures / Requests, 2)
| order by TimeGenerated asc
```

Identify the operations and result codes contributing most to the failure.

```kusto
AppRequests
| where TimeGenerated >= ago(60m)
| summarize
    Requests = sum(ItemCount),
    Failures = sumif(ItemCount, Success == false),
    P95Ms = percentile(DurationMs, 95)
  by AppRoleName, OperationName, ResultCode
| extend FailureRatePct = round(100.0 * Failures / Requests, 2)
| top 20 by Failures desc
```

Compare the incident window with the baseline. Distinguish a traffic-driven
increase in failures from a true increase in failure rate.

### Step 6: Analyze exceptions and dependencies
Group exceptions by stable identifiers. Do not paste complete stack traces or
messages into the final report.

```kusto
AppExceptions
| where TimeGenerated >= ago(60m)
| summarize
    Occurrences = sum(ItemCount),
    FirstSeen = min(TimeGenerated),
    LastSeen = max(TimeGenerated),
    SampleOperationId = any(OperationId)
  by AppRoleName, OperationName, ExceptionType, ProblemId
| top 20 by Occurrences desc
```

Find failing or slow downstream calls.

```kusto
AppDependencies
| where TimeGenerated >= ago(60m)
| summarize
    Calls = sum(ItemCount),
    Failures = sumif(ItemCount, Success == false),
    P95Ms = percentile(DurationMs, 95)
  by AppRoleName, Target, DependencyType, Name, ResultCode
| extend FailureRatePct = round(100.0 * Failures / Calls, 2)
| top 20 by Failures desc
```

Use a representative `OperationId` to correlate one failed request with its
dependencies, exceptions, and traces. Report only the fields required to
explain the failure and redact sensitive values.

### Step 7: Inspect platform-specific logs

**App Service HTTP logs**

Run only if `AppServiceHTTPLogs` exists in the target workspace.

```kusto
AppServiceHTTPLogs
| where TimeGenerated >= ago(60m)
| where _ResourceId =~ "<resource-id>"
| summarize Requests=count(), ServerErrors=countif(ScStatus >= 500), P95TimeTakenMs=percentile(TimeTaken, 95) by bin(TimeGenerated, 5m), ScStatus, ScSubStatus
| order by TimeGenerated asc
```

Use status and substatus together. For startup failures, correlate 502/503
responses with process-start exceptions and deployment timestamps.

**Container Apps**

Read a bounded number of system and console log lines. Do not follow the stream
indefinitely.

```bash
az containerapp logs show --resource-group <resource-group> --name <app-name> --type system --tail 200
az containerapp logs show --resource-group <resource-group> --name <app-name> --type console --tail 200
```

Correlate unhealthy revisions, replica changes, startup probes, scale-to-zero,
image pulls, and process exit codes with the incident window.

**AKS pod inventory**

```kusto
KubePodInventory
| where TimeGenerated >= ago(60m)
| where ClusterName == "<cluster-name>"
| where Namespace == "<namespace>"
| where Name startswith "<pod-prefix>"
| summarize arg_max(TimeGenerated, *) by Name, ContainerName
| project TimeGenerated, Name, ContainerName, PodStatus, ContainerStatus, ContainerStatusReason, ContainerRestartCount
| order by ContainerRestartCount desc
```

**AKS container logs**

```kusto
ContainerLogV2
| where TimeGenerated >= ago(60m)
| where PodNamespace == "<namespace>"
| where PodName startswith "<pod-prefix>"
| where LogLevel in~ ("CRITICAL", "ERROR", "WARNING")
    or tostring(LogMessage) has_any ("exception", "failed", "timeout", "oom")
| project TimeGenerated, PodName, ContainerName, LogLevel, LogSource, LogMessage
| order by TimeGenerated desc
| take 200
```

If Container Insights is not enabled or the tables are absent, record the gap.
Do not interpret missing pod logs as zero restarts.

### Step 8: Follow the symptom decision path

| Symptom | Required investigation |
|---------|------------------------|
| Startup failure or 502/503 | Confirm the revision ever became healthy; find the first startup exception or exit code; check runtime, architecture, startup command, port, health path, and dependency reachability; compare with the last healthy release; separate app failure from platform capacity or routing. |
| HTTP 500 or exception spike | Quantify failure rate by operation, result code, role, and version; group by `ProblemId` and `ExceptionType`; correlate a sample operation; determine whether the exception is new or traffic-amplified. |
| High latency or timeout | Compare request p95/p99 with dependency p95 and volume; isolate operation, instance, region, or dependency; check retries, throttling, pools, and queues; investigate blocking, thread-pool starvation, locks, GC, or CPU when dependencies do not explain the delay. |
| High CPU | Correlate CPU with volume, version, and instance count; check whether one instance is hot; test retry storms, exception loops, serialization, regex, compression, and GC; recommend a bounded trace only if telemetry cannot identify the hot path. |
| Memory, leak, OOM, or restart | Determine whether memory is monotonic, load-correlated, or GC-recoverable; align memory with OOM/restarts and version; inspect limits and worker size; separate managed heap from native/cache growth; use counters before dumps. |
| Thread-pool starvation | Look for latency with unsaturated CPU, queued work, rising thread count, slow completions, blocking calls, and synchronous-over-async; trace only after counters support the hypothesis. |
| Dependency, DNS, TLS, or identity | Group by target, type, result code, and operation; determine unavailable, slow, throttled, or unauthorized; correlate network, DNS, certificate, managed identity, RBAC, and Key Vault changes; redact sensitive URLs. |
| Missing telemetry | Verify destination, diagnostic settings, and ingestion; check sampling, role mismatch, clock skew, schema, and release instrumentation; list conclusions blocked until telemetry is restored. |

### Step 9: Test competing hypotheses
For every leading hypothesis:

1. State the expected evidence if it is true.
2. State the evidence that was observed.
3. Identify contradicting evidence.
4. Compare at least one plausible alternative.
5. Assign the confidence score below.

Do not stop at the first correlated event. Prefer a causal chain such as:

`deployment -> new exception/dependency behavior -> resource saturation or
failed requests -> user impact`

### Step 10: Decide whether deep runtime diagnostics are justified
Use runtime artifacts only when normal telemetry cannot isolate the cause:

| Symptom | Preferred next artifact |
|---------|-------------------------|
| High CPU | Short `dotnet-trace` sample |
| Managed memory growth | `dotnet-counters`, then `dotnet-gcdump` |
| OOM or native memory | Process dump near the failure |
| Hang or deadlock | Process dump |
| Thread-pool starvation | Runtime counters, then trace |
| Repeated unhandled crash | Crash dump or Snapshot Debugger |

Before collection, confirm platform support, runtime/tool compatibility,
acceptable overhead, user approval, protected storage, and sensitive handling.
Dumps and traces can contain credentials, personal data, and payloads.

Do not execute collection commands through this skill. Provide the least
invasive collection plan and the official documentation link.

## Scoring
Score the leading root-cause candidate, not the health of the application.

| Evidence dimension | Points |
|--------------------|--------|
| Direct failure evidence identifies the mechanism | 0-25 |
| Timing aligns with incident start and recovery | 0-20 |
| Independent logs, metrics, or instances corroborate it | 0-15 |
| Mechanism explains the observed symptom and impact | 0-20 |
| Plausible alternative causes were tested | 0-10 |
| Recovery or reproduction validates the causal link | 0-10 |
| **Total** | **0-100** |

Interpretation:

| Score | Classification | Required wording |
|-------|----------------|------------------|
| 90-100 | Confirmed | Root cause confirmed by direct and validating evidence |
| 70-89 | High confidence | Most likely root cause; state remaining uncertainty |
| 40-69 | Probable | Working diagnosis; more evidence is required |
| 0-39 | Hypothesis | Do not present as root cause |

Missing telemetry contributes zero points. Do not increase confidence because
an alternative could not be observed.

## Accepted exceptions
If the user provides expected conditions or known exceptions, do not treat them
as incident causes without contradictory evidence.

Examples:

| Condition | Reason |
|-----------|--------|
| Two pod restarts at 02:00 UTC | Planned node image upgrade |
| Elevated 404 rate on `/health-probe-test` | Synthetic negative test |
| CPU spike during 12:00-12:15 UTC | Approved load test |
| Scale-to-zero outside business hours | Intended Container Apps configuration |

List accepted exceptions in the report with the reason and evidence used to
exclude them. If an accepted condition behaves outside its expected window or
scope, investigate it normally.

## Expected output

### Report header - mandatory

## .NET Application Troubleshooting Report

| Field | Value |
|-------|-------|
| Subscription | Name and ID |
| Resource | Name, type, resource group, and region |
| Hosting platform | App Service / Container Apps / AKS / VM |
| Incident window | Start to end UTC |
| Symptom | Concise description |
| Current status | Ongoing / Mitigated / Resolved / Unknown |
| Root-cause confidence | Score and classification |

### Report structure
1. **Executive summary** - impact, current state, leading cause, and confidence
2. **Timeline** - changes, first anomaly, alerts, failures, mitigation, recovery
3. **Scope and impact** - affected operations, roles, instances, and error rate
4. **Evidence** - facts with source, timestamp, and what each fact proves
5. **Diagnosis** - causal chain, competing hypotheses, and contradictions
6. **Immediate mitigations** - suggestions only, ordered by risk and reversibility
7. **Durable fixes** - code, configuration, capacity, dependency, and observability
8. **Verification plan** - measurable success criteria and observation window
9. **Telemetry gaps** - missing data and conclusions blocked by each gap
10. **Accepted exceptions** - supplied exceptions and why they were excluded
11. **Commands and queries used** - read-only evidence collection for reproducibility
12. **References** - relevant Microsoft Learn links

When evidence is insufficient, say `Root cause not established` and provide the
next discriminating query or artifact. Never force a single-cause conclusion.

## Remediation guidance
For each recommendation:

1. Label it **Immediate mitigation**, **Permanent fix**, or **Observability**.
2. State expected impact, operational risk, and rollback approach.
3. Prefer the smallest reversible mitigation during an active incident.
4. Do not suggest a restart as the first action when it would destroy evidence,
   unless restoring service takes priority and the tradeoff is explicit.
5. Validate any suggested Azure CLI write command with `GetAzCliHelp` when that
   tool is available. Never execute it from this skill.
6. Include a measurable verification query, metric, or health check.
7. Link to official Microsoft Learn documentation.

## References
- Create an Azure SRE Agent skill: https://learn.microsoft.com/azure/sre-agent/create-skill
- Diagnose App Service applications: https://learn.microsoft.com/azure/app-service/overview-diagnostics
- Troubleshoot ASP.NET Core on App Service and IIS: https://learn.microsoft.com/aspnet/core/test/troubleshoot-azure-iis
- Capture App Service memory dumps: https://learn.microsoft.com/troubleshoot/azure/app-service/capture-memory-dumps-app-service
- Application Insights data model: https://learn.microsoft.com/azure/azure-monitor/app/data-model-complete
- AppRequests table: https://learn.microsoft.com/azure/azure-monitor/reference/tables/apprequests
- AppExceptions table: https://learn.microsoft.com/azure/azure-monitor/reference/tables/appexceptions
- AppDependencies table: https://learn.microsoft.com/azure/azure-monitor/reference/tables/appdependencies
- .NET diagnostics overview: https://learn.microsoft.com/dotnet/core/diagnostics/
- Debug high CPU in .NET: https://learn.microsoft.com/dotnet/core/diagnostics/debug-highcpu
- Debug a .NET memory leak: https://learn.microsoft.com/dotnet/core/diagnostics/debug-memory-leak
- Debug thread-pool starvation: https://learn.microsoft.com/dotnet/core/diagnostics/debug-threadpool-starvation
- Container Apps logs: https://learn.microsoft.com/azure/container-apps/log-monitoring
- Query AKS Container Insights logs: https://learn.microsoft.com/azure/azure-monitor/containers/container-insights-log-query

## Sample output

> Redacted example with illustrative names and identifiers.

## .NET Application Troubleshooting Report

| Field | Value |
|-------|-------|
| Subscription | contoso-prod (00000000-0000-0000-0000-000000000000) |
| Resource | orders-api / App Service / rg-orders-prod / westeurope |
| Hosting platform | Azure App Service - Linux |
| Incident window | 2026-07-20 14:00-15:00 UTC |
| Symptom | HTTP 500 spike and p95 latency regression |
| Current status | Mitigated |
| Root-cause confidence | 85/100 - High confidence |

### Executive summary
Six minutes after deployment `orders-api-20260720.3`, `POST /orders` failures
rose from 0.2% to 18.4%. A new `SqlException` group and 31% SQL dependency
failure rate indicate a command-timeout regression in the release.

### Timeline

| Time UTC | Event | Source |
|----------|-------|--------|
| 14:06 | Deployment completed | Azure Activity Log |
| 14:14 | `POST /orders` failures exceeded 10% | AppRequests |
| 14:47 | Error rate returned below 1% | AppRequests |

### Leading diagnosis
`deployment -> SQL timeout -> request failures -> HTTP 500 and latency increase`.
Requests, exceptions, dependencies, and rollback recovery corroborate the cause;
CPU and memory remained within baseline.

### Recommendations

| Type | Recommendation | Verification |
|------|----------------|--------------|
| Immediate mitigation | Keep the last healthy release active while the query change is reviewed | Failure rate below 1% for 30 minutes |
| Permanent fix | Profile and optimize the changed query; confirm indexes and cancellation behavior | SQL dependency p95 below 750 ms under representative load |

**Telemetry gap:** Runtime counters were unavailable, so thread-pool starvation
was not measured directly. **Accepted exception:** A planned 14:00 UTC recycle
was excluded because it completed before the first failure.
