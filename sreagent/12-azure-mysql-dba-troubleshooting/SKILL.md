---
name: azure-mysql-dba-troubleshooting
description: >
  Diagnose Azure Database for MySQL Flexible Server availability, connectivity,
  CPU, memory, storage, IOPS, slow queries, locks, transactions, connection
  exhaustion, replication lag, high availability, backup, and failover issues.
  Use for active incidents, performance regressions, health reviews, and DBA
  root-cause analysis.
tools:
  - RunAzCliReadCommands
  - execute_kusto_query
  - AzureMCP/*
  - MicrosoftLearnMCP/*
---

# Azure MySQL DBA Troubleshooting

> **Required MCP grounding:** Before conclusions, use `AzureMCP/*` for live Azure evidence and `MicrosoftLearnMCP/*` for current authoritative guidance. If either connector is unavailable, report a blocking evidence gap instead of relying on model memory.

## Purpose
Run a read-only investigation of Azure Database for MySQL Flexible Server by
correlating Azure configuration, metrics, logs, changes, and bounded
`performance_schema`, `sys`, and `information_schema` queries.

## When to use this skill
- Connections fail, abort, time out, or reach limits
- CPU, memory, storage, IO, or thread use is saturated
- Slow queries, locks, deadlocks, or long transactions affect service
- Read replicas lag or HA/failover is unhealthy
- Backup, maintenance, scale, or version changes correlate with impact

## Guardrails
- Use read-only Azure commands, KQL, and a single SQL `SELECT`.
- Prefer Microsoft Entra authentication and never print credentials.
- Do not kill sessions, change parameters, optimize tables, create indexes,
  scale, restart, fail over, restore, or modify networking.
- Redact SQL text, literals, row data, and connection details.
- Use UTC and preserve evidence before disruptive mitigation.

## Pre-check

| Field | Required value |
|-------|----------------|
| Scope | Subscription, resource group, server, database |
| Architecture | Version, tier/SKU, storage, HA, replicas, connectivity mode |
| Symptom/window | Error and incident/baseline windows |
| Changes | Deployment, schema, parameter, scale, maintenance, network |
| Telemetry | Metrics, logs, Query Performance Insight, slow/audit logs |
| Access | Approved read-only database identity |

### Step 1: Confirm server configuration
Use Azure MCP `mysql_list`, `mysql_server_config_get`, and
`mysql_server_param_get` where available.

```bash
az mysql flexible-server show --resource-group <rg> --name <server> -o json
az mysql flexible-server replica list --resource-group <rg> --name <server> -o json
az mysql flexible-server parameter list --resource-group <rg> --server-name <server> -o json
```

Record tier, vCores, memory, storage/autogrow, backup/geo-redundancy, HA mode,
maintenance, authentication, networking, and replica topology. Some choices,
including connectivity and zone-redundant HA, can be constrained after creation.

### Step 2: Build timeline and metric baseline

```bash
az monitor activity-log list --resource-id <server-resource-id> --start-time <start-utc> --end-time <end-utc> -o table
az monitor diagnostic-settings list --resource <server-resource-id> -o json
az monitor metrics list-definitions --resource <server-resource-id> -o table
```

Query CPU, memory, active/failed/aborted connections, threads, storage percent,
storage IO percent, IOPS, throughput, network, replication lag, HA IO/SQL status,
and backup/availability signals at five-minute and one-minute granularity.

### Step 3: Inspect server logs
Filter diagnostic data by exact resource ID and
`MICROSOFT.DBFORMYSQL`. Summarize errors without statement text:

```kusto
AzureDiagnostics
| where TimeGenerated between (datetime(<start-utc>) .. datetime(<end-utc>))
| where ResourceProvider =~ "MICROSOFT.DBFORMYSQL"
| where _ResourceId =~ "<server-resource-id>"
| summarize Events=count(), FirstSeen=min(TimeGenerated),
            LastSeen=max(TimeGenerated)
  by Category, Level, event_class_s
| order by Events desc
```

Use slow-query, audit, and error logs only when enabled and fresh. Treat missing
categories as observability gaps.

### Step 4: Inspect engine state
Use Azure MCP `mysql_database_query`; select only needed columns and apply limits.

**Connections**

```sql
SELECT COMMAND, STATE, COUNT(*) AS sessions,
       MAX(TIME) AS max_seconds
FROM information_schema.PROCESSLIST
WHERE ID <> CONNECTION_ID()
GROUP BY COMMAND, STATE
ORDER BY sessions DESC
LIMIT 100;
```

**Top statement digests**

```sql
SELECT DIGEST, COUNT_STAR, SUM_TIMER_WAIT, AVG_TIMER_WAIT,
       SUM_ROWS_EXAMINED, SUM_ROWS_SENT, SUM_CREATED_TMP_DISK_TABLES
FROM performance_schema.events_statements_summary_by_digest
WHERE DIGEST IS NOT NULL
ORDER BY SUM_TIMER_WAIT DESC
LIMIT 25;
```

**Long transactions**

```sql
SELECT trx_mysql_thread_id, trx_state,
       TIMESTAMPDIFF(SECOND, trx_started, NOW()) AS age_seconds,
       trx_tables_locked, trx_rows_locked, trx_rows_modified
FROM information_schema.innodb_trx
ORDER BY age_seconds DESC
LIMIT 50;
```

**Database sizes**

```sql
SELECT table_schema,
       ROUND(SUM(data_length + index_length) / 1024 / 1024, 2) AS size_mb
FROM information_schema.tables
WHERE table_schema NOT IN ('mysql','information_schema','performance_schema','sys')
GROUP BY table_schema
ORDER BY size_mb DESC
LIMIT 100;
```

Use `sys.statement_analysis`, `sys.schema_table_lock_waits`, and other sys schema
views when available. Record unavailable instrumentation instead of enabling it.

### Step 5: Follow the symptom path

| Symptom | Required investigation |
|---------|------------------------|
| High CPU | Connection spike, statement digests, scans, joins, sorts, missing indexes, plan/statistics change |
| Low memory | Connection/thread buffers, buffer pool, temp tables, query concurrency, memory tier |
| High IO | Buffer cache misses, scans, temp disk tables, writes, checkpoints, storage limits |
| Connection exhaustion | Active/sleeping sessions, pools, timeouts, retry storm, `max_connections` |
| Slow query | QPI/digest trend, rows examined/sent, index selectivity, temp tables, locks |
| Blocking/deadlock | Head blocker, transaction age, metadata/row locks, access order, retry |
| Storage pressure | Growth, binlogs, temp data, backups, autogrow; storage can't be reduced |
| Replica lag | Write volume, long transactions, primary keys, replica sizing, network/region |
| HA/failover | HA IO/SQL state, primary keys, DNS retry, maintenance/activity events |

Missing primary keys can degrade binary-log replay and failover. Validate schema
before recommending HA or replica remediation.

### Step 6: Test hypotheses
State expected, observed, and contradicting evidence for each cause; compare an
alternative; and assign confidence.

## Scoring
Direct engine/log evidence 25, timeline 20, corroboration 15, explanatory
mechanism 20, alternatives 10, validation 10. Classify 90+ Confirmed, 70-89 High
confidence, 40-69 Probable, below 40 Hypothesis.

## Accepted exceptions
List approved ETL jobs, load tests, maintenance, replica lag windows, or planned
storage growth with owner and review date.

## Expected output

## Azure MySQL DBA Troubleshooting Report

Include server/configuration, incident window, timeline, resource saturation,
engine evidence, diagnosis, mitigations, permanent fixes, verification,
telemetry gaps, exceptions, and read-only commands/queries.

## Remediation guidance
- Suggest only and identify restart/failover or permanence implications.
- Never kill sessions without transaction/rollback analysis.
- Never recommend an index from a single sample.
- Validate parameter changes and HA/backup constraints in current documentation.

## References
- Monitoring: https://learn.microsoft.com/azure/mysql/flexible-server/concepts-monitor-mysql
- Monitoring practices: https://learn.microsoft.com/azure/mysql/flexible-server/concept-monitor-best-practices
- High CPU: https://learn.microsoft.com/azure/mysql/flexible-server/how-to-troubleshoot-high-cpu-utilization
- Low memory: https://learn.microsoft.com/azure/mysql/flexible-server/how-to-troubleshoot-low-memory-issues
- Query Performance Insight: https://learn.microsoft.com/azure/mysql/flexible-server/tutorial-query-performance-insights
- Sys schema: https://learn.microsoft.com/azure/mysql/flexible-server/how-to-troubleshoot-sys-schema
- WAF service guide: https://learn.microsoft.com/azure/well-architected/service-guides/azure-database-for-mysql

## Sample output

> Redacted example.

## Azure MySQL DBA Troubleshooting Report

| Field | Value |
|-------|-------|
| Server | mysql-orders-prod / General Purpose |
| Symptom | CPU and command timeouts |
| Confidence | 81/100 - High confidence |

`connection surge + high-cost digest -> CPU saturation -> queueing -> timeouts`.
No query, parameter, connection, or server state was changed.
