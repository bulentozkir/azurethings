---
name: azure-postgresql-dba-troubleshooting
description: >
  Diagnose Azure Database for PostgreSQL Flexible Server availability,
  connectivity, CPU, memory, storage, IOPS, locks, long transactions, slow
  queries, autovacuum, bloat, temporary files, connection exhaustion, replicas,
  high availability, backup, and failover issues. Use for active incidents,
  performance regressions, database health reviews, and DBA root-cause analysis.
tools:
  - RunAzCliReadCommands
  - execute_kusto_query
  - AzureMCP/*
  - MicrosoftLearnMCP/*
---

# Azure PostgreSQL DBA Troubleshooting

> **Required MCP grounding:** Before conclusions, use `AzureMCP/*` for live Azure evidence and `MicrosoftLearnMCP/*` for current authoritative guidance. If either connector is unavailable, report a blocking evidence gap instead of relying on model memory.

## Purpose
Run a safe, evidence-driven investigation of Azure Database for PostgreSQL
Flexible Server. Correlate Azure configuration, platform metrics, logs, activity
changes, and bounded read-only PostgreSQL queries. Produce a ranked diagnosis,
reversible mitigation options, durable fixes, and verification criteria.

## When to use this skill
- Connections fail, reset, time out, or reach the server limit
- CPU, memory, storage, IOPS, temporary files, or WAL usage is abnormal
- Queries regress, block, deadlock, spill, or run for too long
- Autovacuum falls behind, tables bloat, or transaction IDs are at risk
- A read replica lags or high availability/failover is unhealthy
- Backup, restore, maintenance, or version changes affect reliability

## Guardrails
- Use read-only Azure commands, KQL, and SQL `SELECT` statements.
- Prefer Microsoft Entra authentication; never obtain or print passwords.
- Do not terminate sessions, cancel queries, vacuum, reindex, analyze, change
  parameters, scale, restart, fail over, restore, or modify networking.
- Never expose query parameters, row data, connection strings, or sensitive SQL.
- Use query IDs/hashes and redacted summaries in reports.
- Use UTC and separate facts, hypotheses, and accepted conditions.
- Preserve evidence before recommending a restart or failover.

## Pre-check

| Field | Required value |
|-------|----------------|
| Scope | Subscription, resource group, server, database |
| Architecture | Tier/SKU, storage, HA mode, replicas, networking |
| Symptom | Error, latency, CPU, memory, IO, locks, vacuum, replica, HA |
| Window | Incident start/end UTC and comparable baseline |
| Changes | Deployments, schema, parameters, scale, maintenance, network |
| Telemetry | Azure Monitor metrics, diagnostic workspace, server logs |
| Access | Approved least-privilege read-only database identity |

Default to the last 60 minutes and preceding 60-minute baseline when no window
is supplied.

## Investigation procedure

### Step 1: Confirm server state and configuration
Use the PostgreSQL Azure MCP `postgres_list`, `postgres_server_config_get`, and
`postgres_server_param_get` commands when available. Otherwise use read-only CLI:

```bash
az postgres flexible-server show --resource-group <rg> --name <server> -o json
az postgres flexible-server replica list --resource-group <rg> --name <server> -o json
az postgres flexible-server parameter list --resource-group <rg> --server-name <server> -o json
```

Record version, tier, vCores, memory class, storage, IOPS, autogrow, backup
retention, geo-redundancy, HA state, maintenance window, authentication, and
network mode. Do not print firewall details beyond what proves the finding.

### Step 2: Build the change and platform timeline

```bash
az monitor activity-log list --resource-id <server-resource-id> --start-time <start-utc> --end-time <end-utc> --query "[].{time:eventTimestamp,operation:operationName.localizedValue,status:status.localizedValue,correlationId:correlationId}" -o table
az monitor diagnostic-settings list --resource <server-resource-id> -o json
```

Correlate scale, restart, failover, maintenance, parameter, HA, networking, and
diagnostic changes with the first anomaly.

### Step 3: Establish resource pressure
Discover supported metrics before querying them:

```bash
az monitor metrics list-definitions --resource <server-resource-id> -o table
az monitor metrics list --resource <server-resource-id> --metric <metric-name> --start-time <start-utc> --end-time <end-utc> --interval PT5M --aggregation Average Maximum Total -o json
```

Prioritize CPU, memory, active/failed connections, storage percent, storage used,
IOPS/throughput, IO consumption, network, temporary files, transaction log/WAL,
replica lag, and HA health. A saturated metric identifies a constrained resource,
not the workload that caused it.

### Step 4: Inspect platform and PostgreSQL logs
Verify diagnostic categories and table freshness before querying. In
`AzureDiagnostics`, filter by the exact resource ID and
`MICROSOFT.DBFORPOSTGRESQL`. Summarize errors without returning statement text:

```kusto
AzureDiagnostics
| where TimeGenerated between (datetime(<start-utc>) .. datetime(<end-utc>))
| where ResourceProvider =~ "MICROSOFT.DBFORPOSTGRESQL"
| where _ResourceId =~ "<server-resource-id>"
| summarize Events=count(), FirstSeen=min(TimeGenerated),
            LastSeen=max(TimeGenerated)
  by Category, Level, errorLevel_s
| order by Events desc
```

Look for authentication failures, connection resets, out-of-memory, disk-full,
checkpoint/WAL, deadlock, lock timeout, statement timeout, autovacuum, replica,
HA, and maintenance events. Treat missing logs as an observability gap.

### Step 5: Inspect live database state
Use `postgres_database_query` with an approved read-only identity. Bound every
query and avoid SQL text unless explicitly authorized.

**Connections and long-running activity**

```sql
SELECT datname, state, wait_event_type, wait_event,
       count(*) AS sessions,
       max(EXTRACT(EPOCH FROM (clock_timestamp() - query_start)))
         FILTER (WHERE state = 'active') AS max_active_query_seconds,
       max(EXTRACT(EPOCH FROM (clock_timestamp() - xact_start))) AS max_xact_seconds
FROM pg_stat_activity
WHERE pid <> pg_backend_pid()
GROUP BY datname, state, wait_event_type, wait_event
ORDER BY sessions DESC
LIMIT 100;
```

**Database workload**

```sql
SELECT datname, numbackends, xact_commit, xact_rollback,
       blks_read, blks_hit, temp_files, temp_bytes,
       deadlocks, conflicts
FROM pg_stat_database
ORDER BY temp_bytes DESC
LIMIT 100;
```

**Blocking relationships**

```sql
SELECT blocked.pid AS blocked_pid,
       blocker.pid AS blocker_pid,
       blocked.wait_event_type,
       blocked.wait_event,
       EXTRACT(EPOCH FROM (clock_timestamp() - blocked.query_start)) AS blocked_query_age_seconds,
       EXTRACT(EPOCH FROM (clock_timestamp() - blocker.xact_start)) AS blocker_xact_seconds
FROM pg_stat_activity blocked
JOIN LATERAL unnest(pg_blocking_pids(blocked.pid)) AS b(pid) ON true
JOIN pg_stat_activity blocker ON blocker.pid = b.pid
ORDER BY blocked_query_age_seconds DESC
LIMIT 50;
```

**Top statements when `pg_stat_statements` is enabled**

```sql
SELECT queryid, calls, total_exec_time, mean_exec_time,
       rows, shared_blks_read, shared_blks_hit,
       temp_blks_read, temp_blks_written
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 25;
```

`total_exec_time` and `mean_exec_time` require PostgreSQL 13 or later. On
PostgreSQL 12 and earlier, use `total_time` and `mean_time` instead.

**Vacuum health**

```sql
SELECT schemaname, relname, n_live_tup, n_dead_tup,
       last_autovacuum, last_autoanalyze,
       autovacuum_count, autoanalyze_count
FROM pg_stat_user_tables
ORDER BY n_dead_tup DESC
LIMIT 50;
```

If an extension/view is unavailable, record the gap; don't enable it.

### Step 6: Follow the symptom path

| Symptom | Required investigation |
|---------|------------------------|
| High CPU | Connections, top statement IDs, plan changes, scans, sorting, parallelism, autovacuum, checkpoint activity |
| High memory | Connections, `work_mem` multiplication, sorts/hashes, cache behavior, extensions, query concurrency |
| High IO/IOPS | Cache hit, reads/writes, checkpoints, vacuum, scans, temp files, storage limits |
| Connection exhaustion | Active/idle sessions, pool sizing, idle transactions, retry storm, `max_connections`, PgBouncer |
| Blocking/deadlock | Head blocker, transaction age, lock type, application access order, retry behavior |
| Slow queries | Query Store/QPI or statement IDs, execution/plan change, indexes, estimates, temp spill, dependency latency |
| Autovacuum/bloat | Dead tuples, long transactions, blockers, scale factors, wraparound risk, write rate |
| Replica lag | WAL generation, replay lag, long queries, network/region, replica sizing, slot retention |
| HA/failover | HA sync health, DNS/retry behavior, maintenance/activity events, connection recovery time |
| Storage | Growth, WAL/temp files, autogrow, backup impact; storage cannot be scaled down |

### Step 7: Test competing hypotheses
For each candidate cause state expected, observed, and contradicting evidence;
compare at least one alternative; and explain the causal chain to user impact.

## Scoring
Score the leading root-cause candidate:

| Evidence | Points |
|----------|--------|
| Direct engine/log evidence | 0-25 |
| Metric and timeline alignment | 0-20 |
| Independent corroboration | 0-15 |
| Mechanism explains impact | 0-20 |
| Alternatives tested | 0-10 |
| Recovery/reproduction validation | 0-10 |

90-100 Confirmed; 70-89 High confidence; 40-69 Probable; below 40 Hypothesis.

## Accepted exceptions
List approved load tests, maintenance, expected replicas, long jobs, or
intentional configuration with reason, owner, scope, and review date. Do not use
an exception outside its approved window.

## Expected output

## Azure PostgreSQL DBA Troubleshooting Report

Include scope/configuration, incident window, impact, current status, confidence,
timeline, metrics, engine evidence, diagnosis, immediate mitigations, durable
fixes, verification, telemetry gaps, exceptions, and commands/queries used.
When evidence is insufficient, state `Root cause not established`.

## Remediation guidance
- Suggest only; never execute changes.
- Identify impact, lock/restart requirement, rollback, and verification.
- Never recommend killing a session without head-blocker and rollback analysis.
- Never recommend an index from one query sample alone.
- Validate parameter changes against current Azure PostgreSQL documentation.

## References
- Troubleshooting guides: https://learn.microsoft.com/azure/postgresql/troubleshoot/concepts-troubleshooting-guides
- High CPU: https://learn.microsoft.com/azure/postgresql/troubleshoot/how-to-high-cpu-utilization
- High memory: https://learn.microsoft.com/azure/postgresql/troubleshoot/how-to-high-memory-utilization
- Monitoring: https://learn.microsoft.com/azure/postgresql/flexible-server/concepts-monitoring
- Query Store: https://learn.microsoft.com/azure/postgresql/flexible-server/concepts-query-store
- Query Performance Insight: https://learn.microsoft.com/azure/postgresql/flexible-server/concepts-query-performance-insight
- PgBouncer: https://learn.microsoft.com/azure/postgresql/flexible-server/concepts-pgbouncer
- WAF service guide: https://learn.microsoft.com/azure/well-architected/service-guides/postgresql

## Sample output

> Redacted example.

## Azure PostgreSQL DBA Troubleshooting Report

| Field | Value |
|-------|-------|
| Server | pg-orders-prod / General Purpose |
| Incident | 2026-08-05 05:00-06:00 UTC |
| Symptom | Connection timeout and latency |
| Confidence | 84/100 - High confidence |

`long transaction -> autovacuum blocked -> dead tuples and IO growth ->
connection backlog -> request timeouts`

The report recommends shortening the transaction and validating autovacuum
recovery; no session, parameter, or server change was executed.
