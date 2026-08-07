---
name: azure-sql-dba-troubleshooting
description: >
  Diagnose performance, availability, connectivity, capacity, query regression,
  timeout, blocking, deadlock, storage, worker, session, and elastic-pool issues
  in Azure SQL Database. Use for active incidents, degraded database performance,
  failed connections, high CPU or DTU, high data or log IO, and DBA root-cause
  analysis using Azure Monitor, Log Analytics, Intelligent Insights, and Query Store data.
tools:
  - RunAzCliReadCommands
  - execute_kusto_query
  - AzureMCP/*
  - MicrosoftLearnMCP/*
---

# DBA Troubleshooting for Azure SQL Database

> **Required MCP grounding:** Before conclusions, use `AzureMCP/*` for live Azure evidence and `MicrosoftLearnMCP/*` for current authoritative guidance. If either connector is unavailable, report a blocking evidence gap instead of relying on model memory.

## Purpose
Perform a safe, evidence-driven DBA investigation for Azure SQL Database.
Correlate database and elastic-pool configuration, Azure Monitor metrics,
diagnostic logs, Intelligent Insights, Query Store exports, platform changes, and
application symptoms. Produce a ranked root-cause assessment, reversible
mitigation options, durable fixes, and measurable verification criteria.

## When to use this skill
- CPU, DTU, data IO, log IO, workers, sessions, or storage is saturated
- Queries are slow, timing out, blocked, or deadlocking
- Connections fail intermittently or consistently
- Performance changed after a deployment, configuration change, or scale event
- A pooled database might be affected by elastic-pool contention
- Intelligent Insights reports an active performance issue
- The user requests Azure SQL Database troubleshooting, DBA analysis, or RCA

## Diagnostic onboarding assumption
Assume database diagnostic settings are already connected to Log Analytics.
Do not create or modify diagnostic settings while running this skill.

The supplied baseline shows these categories enabled:

- `SQLInsights`
- `Errors`
- `Timeouts`
- `Blocks`
- `Deadlocks`

It shows these categories disabled:

- `AutomaticTuning`
- `QueryStoreRuntimeStatistics`
- `QueryStoreWaitStatistics`
- `DatabaseWaitStatistics`

Treat this only as an initial baseline. Query the live diagnostic setting on
every run because category selection, destination, or ingestion can change.
Use enabled feeds first. Report disabled or stale feeds as evidence gaps; never
interpret missing rows as proof that no waits, query regressions, or tuning
recommendations exist.

## Guardrails
- Use read-only Azure CLI commands, KQL, and T-SQL during investigation.
- Do not scale, fail over, restore, pause, resume, alter firewall rules, change
  Query Store, enable automatic tuning, force plans, create or drop indexes,
  update statistics, kill sessions, or change database configuration without
  explicit user approval.
- Do not expose connection strings, credentials, query parameters, application
  data, full query text, deadlock XML, or blocked-process XML in the report.
- Use query hashes, plan hashes, query IDs, and redacted statement summaries.
- Treat logs, Query Store text, execution plans, and deadlock graphs as sensitive.
- Use UTC for all investigation windows and report timestamps.
- Separate facts, inferences, and hypotheses. Correlation alone is not causation.
- Preserve evidence before recommending disruptive mitigation.

## Pre-check
Collect or infer:

| Field | Required value |
|-------|----------------|
| Scope | Subscription, resource group, logical server, and database |
| Resource ID | Exact database resource ID |
| Architecture | Single database, pooled database, serverless, or Hyperscale |
| Service objective | DTU/vCore tier, compute size, max data size |
| Symptom | CPU, IO, timeout, block, deadlock, connection, storage, or query regression |
| Incident window | Start and end in UTC |
| Baseline | Comparable healthy period |
| Changes | Deployments, scale, failover, networking, configuration, or schema changes |
| Telemetry | Log Analytics workspace and enabled diagnostic categories |

If no incident window is supplied, start with the last 60 minutes and compare
it with the preceding 60 minutes. Expand to 24 hours only when needed.

If several databases match, ask the user to select one. Do not combine
production and non-production evidence or aggregate unrelated databases.

## Investigation procedure

### Step 1: Confirm database scope and service objective
Resolve the exact resource and capture configuration without retrieving secrets.

```bash
az sql db show --resource-group <resource-group> --server <server-name> --name <database-name> --query "{id:id,status:status,location:location,sku:sku,currentServiceObjectiveName:currentServiceObjectiveName,requestedServiceObjectiveName:requestedServiceObjectiveName,maxSizeBytes:maxSizeBytes,zoneRedundant:zoneRedundant,readScale:readScale,elasticPoolId:elasticPoolId,kind:kind,collation:collation}" -o json
az sql server show --resource-group <resource-group> --name <server-name> --query "{id:id,location:location,state:state,publicNetworkAccess:publicNetworkAccess,minimalTlsVersion:minimalTlsVersion,fullyQualifiedDomainName:fullyQualifiedDomainName}" -o json
```

If `elasticPoolId` is present, inspect the pool and query both database and pool
metrics. A healthy database-level percentage does not rule out pool contention.

```bash
az resource show --ids <elastic-pool-resource-id> --query "{id:id,name:name,location:location,sku:sku,properties:properties}" -o json
```

Interpret serverless auto-pause, Hyperscale replicas, read scale-out, and pooled
capacity according to their architecture; do not apply single-database
assumptions blindly.

### Step 2: Verify diagnostic routing and freshness
Inspect the database-level diagnostic setting. Each database requires its own
configuration; a logical-server setting does not prove database logs are routed.

```bash
az monitor diagnostic-settings list --resource <database-resource-id> -o json
```

Record:
- Destination workspace resource ID
- Enabled and disabled categories
- Whether metrics are exported
- Retention or destination differences from the expected configuration

Azure SQL Database resource logs are commonly stored in `AzureDiagnostics`.
Some workspaces or monitoring solutions can also expose normalized
`AzureSQL*` tables. Discover the actual storage shape before selecting queries.

```kusto
AzureDiagnostics
| where TimeGenerated >= ago(24h)
| where ResourceProvider =~ "MICROSOFT.SQL"
| where _ResourceId =~ "<database-resource-id>"
| summarize Rows=count(), FirstSeen=min(TimeGenerated), LastSeen=max(TimeGenerated) by Category
| order by Category asc
```

If this returns no rows, use `Usage` to check for `AzureSQL*` data types and
query a sample row from the relevant table. Check resource ID, database name,
workspace, time range, category enablement, permissions, and ingestion delay
before declaring a telemetry gap.

### Step 3: Build the platform and change timeline
Include a 30-minute lead-in before the incident.

```bash
az monitor activity-log list --resource-id <database-resource-id> --start-time <start-utc> --end-time <end-utc> --query "[].{time:eventTimestamp,operation:operationName.localizedValue,status:status.localizedValue,correlationId:correlationId,caller:caller}" -o table
```

Look for scale operations, restores, failovers, pause/resume events, firewall or
network changes, diagnostic-setting changes, and deployment correlation. Treat
an adjacent change as a candidate cause until workload evidence confirms it.

### Step 4: Establish resource saturation
Discover supported metrics before querying them.

```bash
az monitor metrics list-definitions --resource <database-resource-id> --query "[].{name:name.value,unit:unit,aggregation:primaryAggregationType,dimensions:dimensions}" -o table
```

Query available metrics at five-minute granularity, then narrow to one minute
around the failure. Include the pool resource when applicable.

```bash
az monitor metrics list --resource <database-resource-id> --metric <metric-name> --start-time <start-utc> --end-time <end-utc> --interval PT5M --aggregation Average Maximum Total -o json
```

Prioritize:

| Area | Metrics or signals |
|------|--------------------|
| Compute | `cpu_percent`, `dtu_consumption_percent`, CPU used/limit |
| Data IO | `physical_data_read_percent` |
| Transaction log | `log_write_percent`, log size and log-rate limits |
| Concurrency | `workers_percent`, `sessions_percent` |
| Capacity | `storage_percent`, storage used/limit |
| Reliability | `deadlock`, successful and failed connections |
| Pool | eDTU/CPU, data IO, log IO, workers, sessions, storage |

Determine whether saturation is sustained or a short spike and whether it
precedes or follows query failures. A metric at 100% identifies a constrained
resource, not the workload responsible for consuming it.

### Step 5: Analyze enabled diagnostic categories
Use the exact database resource ID in every query. The following queries target
the documented `AzureDiagnostics` shape.

**Intelligent Insights**

Use the `SQLInsights` resource-log category. This is Intelligent Insights, not
the retired Azure Monitor SQL Insights preview.

```kusto
AzureDiagnostics
| where TimeGenerated between (datetime(<start-utc>) .. datetime(<end-utc>))
| where ResourceProvider =~ "MICROSOFT.SQL"
| where _ResourceId =~ "<database-resource-id>" and Category == "SQLInsights"
| summarize Events=count(), FirstSeen=min(TimeGenerated), LastSeen=max(TimeGenerated) by status_s, rootCauseAnalysis_s
| order by LastSeen desc
```

Treat `Active` findings as hypotheses to verify against metrics and workload
evidence. Redact query text or identifiers embedded in insight details.

**Errors**

```kusto
AzureDiagnostics
| where TimeGenerated between (datetime(<start-utc>) .. datetime(<end-utc>))
| where ResourceProvider =~ "MICROSOFT.SQL"
| where _ResourceId =~ "<database-resource-id>" and Category == "Errors"
| extend ErrorNumber=tostring(column_ifexists("error_number_d", "")), Severity=tostring(column_ifexists("Severity", "")), QueryHash=tostring(column_ifexists("query_hash_s", ""))
| summarize Events=count(), FirstSeen=min(TimeGenerated), LastSeen=max(TimeGenerated) by ErrorNumber, Severity, QueryHash
| top 20 by Events desc
```

Classify errors as transient platform/connectivity, resource governance,
authentication/authorization, data/application, or query execution errors.
Do not report raw messages until sensitive values are redacted.

**Timeouts**

```kusto
AzureDiagnostics
| where TimeGenerated between (datetime(<start-utc>) .. datetime(<end-utc>))
| where ResourceProvider =~ "MICROSOFT.SQL"
| where _ResourceId =~ "<database-resource-id>" and Category == "Timeouts"
| extend QueryHash=tostring(column_ifexists("query_hash_s", "")), PlanHash=tostring(column_ifexists("query_plan_hash_s", "")), ErrorState=tostring(column_ifexists("error_state_d", ""))
| summarize Timeouts=count(), FirstSeen=min(TimeGenerated), LastSeen=max(TimeGenerated) by QueryHash, PlanHash, ErrorState
| top 20 by Timeouts desc
```

Distinguish command timeout, connection timeout, lock timeout, throttling, and
client cancellation when the evidence allows it.

**Blocking**

```kusto
AzureDiagnostics
| where TimeGenerated between (datetime(<start-utc>) .. datetime(<end-utc>))
| where ResourceProvider =~ "MICROSOFT.SQL"
| where _ResourceId =~ "<database-resource-id>" and Category == "Blocks"
| extend DurationMs=toreal(column_ifexists("duration_d", 0.0)) / 1000.0, LockMode=tostring(column_ifexists("lock_mode_s", "")), OwnerType=tostring(column_ifexists("resource_owner_type_s", ""))
| summarize Events=count(), MaxDurationMs=max(DurationMs), TotalDurationMs=sum(DurationMs) by LockMode, OwnerType
| top 20 by MaxDurationMs desc
```

`duration_d` is reported in microseconds, so the query converts it to milliseconds.

Do not print `blocked_process_filtered_s`. If deeper analysis is required,
handle the XML as sensitive and report only redacted session, resource, lock
mode, query-hash, and duration relationships.

**Deadlocks**

```kusto
AzureDiagnostics
| where TimeGenerated between (datetime(<start-utc>) .. datetime(<end-utc>))
| where ResourceProvider =~ "MICROSOFT.SQL"
| where _ResourceId =~ "<database-resource-id>" and Category == "Deadlocks"
| summarize Deadlocks=count(), FirstSeen=min(TimeGenerated), LastSeen=max(TimeGenerated) by bin(TimeGenerated, 5m)
| order by TimeGenerated asc
```

Do not print `deadlock_xml_s`. If graph analysis is approved, identify the
victim, competing access order, locked resources, isolation levels, transaction
scope, and query hashes without exposing statements or parameter values.

### Step 6: Use Query Store and wait data only when available
If the diagnostic categories are enabled and fresh, rank:

- Query Store runtime statistics by executions, CPU, duration, logical reads,
  log bytes, query hash, and plan hash
- Query Store waits by total wait time, max wait, wait category, query hash,
  and plan hash
- Database waits by total wait time, signal wait time, task count, and wait type

When normalized tables exist, use:

- `AzureSQLQueryStoreRuntimeStatistics`
- `AzureSQLQueryStoreWaitStatistics`
- `AzureSQLDatabaseWaitStatistics`

Do not claim a top query or dominant wait from these feeds when the screenshot's
disabled-category baseline still applies.

If an approved read-only database connection is available, check Query Store
state before using it:

```sql
SELECT actual_state_desc, desired_state_desc, readonly_reason,
       current_storage_size_mb, max_storage_size_mb, query_capture_mode_desc
FROM sys.database_query_store_options;
```

For current resource pressure:

```sql
SELECT TOP (60) end_time, avg_cpu_percent, avg_data_io_percent,
       avg_log_write_percent, max_worker_percent, max_session_percent
FROM sys.dm_db_resource_stats
ORDER BY end_time DESC;
```

For active blocking, omit query text and parameters:

```sql
SELECT session_id, blocking_session_id, status, wait_type,
       wait_time, wait_resource, command
FROM sys.dm_exec_requests
WHERE blocking_session_id <> 0 OR wait_type LIKE N'LCK%'
ORDER BY wait_time DESC;
```

If no approved data-plane connection exists, provide these as DBA-run queries
and mark the corresponding evidence as unavailable. Never attempt SQL
authentication with credentials found in configuration.

### Step 7: Follow the symptom decision path

| Symptom | Required investigation |
|---------|------------------------|
| High CPU or DTU | Correlate compute with executions and traffic; identify query/plan hashes, recompilation or non-parameterization, plan regression, parallelism, and pool pressure; compare with the healthy baseline. |
| High data IO | Identify read-heavy hashes and plan changes; examine scans, missing or ineffective indexes, stale estimates, and pool saturation; do not recommend indexes without workload and write-cost evidence. |
| High log IO | Check write volume, large transactions, batch size, index maintenance, log-rate governance, and blocking; distinguish workload demand from service-tier limits. |
| Workers or sessions | Correlate connection rate, pool behavior, blocking chains, long transactions, retry storms, and concurrency; do not assume more compute fixes a connection leak. |
| Timeout | Determine command vs connection vs lock timeout; correlate with blocking, saturation, query duration, errors, and client cancellation. |
| Blocking | Find the head blocker, transaction age, lock mode, resource, and blast radius; separate blocker from blocked victims before proposing action. |
| Deadlock | Analyze victim and resource cycle, access order, transaction scope, isolation, and retry behavior; prefer deterministic access order and shorter transactions. |
| Connectivity | Separate firewall/DNS/TLS/authentication, transient failover, resource governance, and client pool exhaustion; classify Azure SQL error numbers. |
| Storage | Compare used, allocated, and maximum size; identify growth trend and large objects; account for Hyperscale and elastic-pool behavior. |
| Pool contention | Compare database and pool metrics; identify simultaneous consumers and per-database min/max settings; do not attribute pool saturation to one database without evidence. |

### Step 8: Test competing hypotheses
For each leading hypothesis:

1. State the evidence expected if it is true.
2. State observed and contradicting evidence.
3. Compare at least one plausible alternative.
4. Explain the causal chain from workload or change to resource symptom and
   user impact.
5. Assign the confidence score below.

Do not stop at the first high metric, SQL Insight, or nearby deployment.

## Scoring
Score the leading root-cause candidate, not database health.

| Evidence dimension | Points |
|--------------------|--------|
| Direct SQL error, query, wait, block, or deadlock evidence | 0-25 |
| Timing aligns with incident start and recovery | 0-20 |
| Independent logs, metrics, pool data, or application evidence corroborate it | 0-15 |
| Mechanism explains the symptom and impact | 0-20 |
| Plausible alternatives were tested | 0-10 |
| Recovery, rollback, or reproduction validates the cause | 0-10 |
| **Total** | **0-100** |

| Score | Classification | Required wording |
|-------|----------------|------------------|
| 90-100 | Confirmed | Root cause confirmed by direct and validating evidence |
| 70-89 | High confidence | Most likely root cause; state remaining uncertainty |
| 40-69 | Probable | Working diagnosis; more evidence is required |
| 0-39 | Hypothesis | Do not present as root cause |

Disabled, stale, or inaccessible telemetry contributes zero points.

## Accepted exceptions
If the user provides known conditions, exclude them only within their documented
scope and time window.

| Condition | Example reason |
|-----------|----------------|
| CPU spike during a fixed window | Approved load test |
| Deadlock from a synthetic transaction | Monitoring validation |
| Planned scale or failover | Approved maintenance |
| Storage growth during bulk load | Expected migration activity |

List each accepted exception and the evidence used to exclude it. Investigate
behavior outside the accepted scope normally.

## Expected output

## Azure SQL DBA Troubleshooting Report

| Field | Value |
|-------|-------|
| Subscription | Name and ID |
| Database | Server/database, resource group, region |
| Architecture | Single / pooled / serverless / Hyperscale |
| Service objective | Tier and compute size |
| Incident window | Start to end UTC |
| Symptom | Concise description |
| Current status | Ongoing / Mitigated / Resolved / Unknown |
| Root-cause confidence | Score and classification |

Report sections:

1. **Executive summary** - impact, current state, leading cause, and confidence
2. **Timeline** - changes, first anomaly, failures, mitigation, and recovery
3. **Resource analysis** - database and elastic-pool saturation
4. **Workload evidence** - errors, timeouts, blocks, deadlocks, waits, and hashes
5. **Diagnosis** - causal chain, alternatives, and contradictions
6. **Immediate mitigations** - suggestions only, ordered by reversibility
7. **Durable fixes** - query, schema, transaction, connection, and capacity work
8. **Verification plan** - metrics, queries, thresholds, and observation window
9. **Telemetry gaps** - disabled/stale feeds and conclusions blocked by each
10. **Accepted exceptions**
11. **Commands and queries used**
12. **References**

If evidence is insufficient, state `Root cause not established` and identify
the next discriminating metric, log category, Query Store query, or DMV.

## Remediation guidance
For every recommendation:

1. Label it **Immediate mitigation**, **Permanent fix**, or **Observability**.
2. State impact, risk, prerequisites, rollback approach, and expected duration.
3. Prefer reversible workload mitigation before service-tier changes.
4. Never recommend killing a session without identifying the head blocker,
   transaction impact, and rollback cost.
5. Never recommend an index from one plan or one incident window alone.
6. Validate proposed Azure CLI write syntax with `GetAzCliHelp` when available.
7. Do not execute write commands from this skill.
8. Include measurable verification criteria and an official Microsoft Learn link.

## References
- Monitor and tune Azure SQL Database: https://learn.microsoft.com/azure/azure-sql/database/monitor-tune-overview
- Monitoring data reference: https://learn.microsoft.com/azure/azure-sql/database/monitoring-sql-database-azure-monitor-reference
- Export diagnostic telemetry: https://learn.microsoft.com/azure/azure-sql/database/metrics-diagnostic-telemetry-logging-streaming-export-configure
- Monitor metrics and alerts: https://learn.microsoft.com/azure/azure-sql/database/monitoring-metrics-alerts
- Troubleshoot high CPU: https://learn.microsoft.com/azure/azure-sql/database/high-cpu-diagnose-troubleshoot
- Monitor with DMVs: https://learn.microsoft.com/azure/azure-sql/database/monitoring-with-dmvs
- Query Store monitoring: https://learn.microsoft.com/sql/relational-databases/performance/monitoring-performance-by-using-the-query-store
- Intelligent Insights troubleshooting: https://learn.microsoft.com/azure/azure-sql/database/intelligent-insights-troubleshoot-performance
- Analyze and prevent deadlocks: https://learn.microsoft.com/azure/azure-sql/database/analyze-prevent-deadlocks
- Common errors: https://learn.microsoft.com/azure/azure-sql/database/troubleshoot-common-errors-issues
- Transient connectivity errors: https://learn.microsoft.com/azure/azure-sql/database/troubleshoot-common-connectivity-issues

## Sample output

> Redacted example with illustrative names and identifiers.

## Azure SQL DBA Troubleshooting Report

| Field | Value |
|-------|-------|
| Subscription | contoso-prod (00000000-0000-0000-0000-000000000000) |
| Database | sql-orders-prod/orders / rg-orders-prod / germanywestcentral |
| Architecture | Pooled database |
| Service objective | General Purpose, 4 vCores |
| Incident window | 2026-08-04 12:00-13:00 UTC |
| Symptom | Timeouts and p95 latency regression |
| Current status | Mitigated |
| Root-cause confidence | 82/100 - High confidence |

### Executive summary
Timeouts began at 12:14 UTC while database workers reached 98% and blocking
duration increased sharply. A deployment at 12:08 UTC introduced longer
transactions for one query hash. CPU remained below 55%, so compute saturation
is not the leading cause. The most likely cause is worker exhaustion caused by
a blocking chain after the deployment.

### Causal chain
`deployment -> longer transaction -> head blocker -> worker saturation ->
timeouts -> application latency`

| Evidence | Result |
|----------|--------|
| Workers | 98% for 11 minutes |
| Blocking | One lock mode accounted for 86% of blocked duration |
| Timeouts | Same query hash dominated the incident window |
| CPU | Below 55%, contradicting CPU saturation |
| Query Store export | Disabled; exact plan regression remains unverified |

### Recommendations

| Type | Recommendation | Verification |
|------|----------------|--------------|
| Immediate mitigation | Keep the last healthy application release active | Workers below 70% and no timeout events for 30 minutes |
| Permanent fix | Shorten the transaction and make object access order deterministic | Blocking duration below baseline under representative load |
| Observability | Enable Query Store runtime and wait export after change review | Fresh rows appear for the database and query hash |

### Telemetry gaps
- Query Store runtime, Query Store waits, and database waits were not exported,
  so the exact plan and wait distribution could not be confirmed.
