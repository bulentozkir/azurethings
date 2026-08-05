---
name: azure-cosmosdb-dba-troubleshooting
description: >
  Diagnose Azure Cosmos DB availability, latency, 429 throttling, request units,
  hot partitions, partition-key design, indexing, queries, consistency,
  replication, failover, networking, SDK, backup, storage, and cost issues.
  Use for active incidents, performance regressions, capacity reviews, and
  database root-cause analysis.
tools:
  - RunAzCliReadCommands
  - execute_kusto_query
  - AzureMCP/*
  - MicrosoftLearnMCP/*
---

# Azure Cosmos DB DBA Troubleshooting

> **Required MCP grounding:** Before conclusions, use `AzureMCP/*` for live Azure evidence and `MicrosoftLearnMCP/*` for current authoritative guidance. If either connector is unavailable, report a blocking evidence gap instead of relying on model memory.

## Purpose
Run a read-only Azure Cosmos DB investigation by correlating account/container
configuration, Azure Monitor metrics, resource logs, SDK diagnostics, partition
distribution, queries, regions, and workload behavior.

The detailed procedures target Cosmos DB for NoSQL. For MongoDB, Cassandra,
Gremlin, or Table APIs, preserve the control-plane steps but use API-specific
drivers, diagnostics, query semantics, and limits.

## Guardrails
- Use read-only Azure, KQL, and bounded Cosmos queries.
- Prefer credential/managed-identity authentication over keys.
- Do not fail over, scale throughput, change indexing/partitioning/consistency,
  disable local auth, restore, or modify regions/networking.
- Do not sample documents or infer schema without explicit data-access approval.
- Never print document contents, partition-key values, tokens, or connection data.
- Capture SDK diagnostics metadata, not payloads.

## Pre-check

| Field | Required value |
|-------|----------------|
| Scope | Account, API, database, container, region |
| Workload | Critical flow, operation, SDK/language/version, deployment |
| Data model | Partition-key path, item size, indexing, TTL, consistency |
| Capacity | Provisioned/autoscale/serverless throughput and RU ownership |
| Reliability | Regions, write mode, failover, zones, backup mode |
| Window | Incident and healthy baseline UTC |
| Telemetry | Metrics, diagnostic tables, SDK diagnostics |

### Step 1: Inventory account and containers
Use Azure MCP `cosmos_list` with `auth-method=credential`.

```bash
az cosmosdb show --resource-group <rg> --name <account> -o json
az cosmosdb sql database list --resource-group <rg> --account-name <account> -o json
az cosmosdb sql container list --resource-group <rg> --account-name <account> --database-name <database> -o json
```

Record API kind, regions/priorities, multiple-write setting, automatic failover,
zone redundancy, default consistency, backup policy, network/local-auth state,
throughput ownership, partition key, indexing policy, TTL, and analytical store.

### Step 2: Build timeline and establish metrics

```bash
az monitor activity-log list --resource-id <account-resource-id> --start-time <start-utc> --end-time <end-utc> -o table
az monitor diagnostic-settings list --resource <account-resource-id> -o json
az monitor metrics list-definitions --resource <account-resource-id> -o table
```

Prioritize Total Requests, Total Request Units, Normalized RU Consumption, 429
count/rate, server-side latency, availability, storage/data/index usage,
replication latency, region, operation, status code, database, and collection
dimensions. Do not average away a hot partition or one failing region.

### Step 3: Inspect resource logs
Use resource-specific tables when present:

- `CDBDataPlaneRequests`
- `CDBPartitionKeyRUConsumption`
- `CDBQueryRuntimeStatistics`
- `CDBControlPlaneRequests`

Discover table freshness before querying. Example request summary:

```kusto
CDBDataPlaneRequests
| where TimeGenerated between (datetime(<start-utc>) .. datetime(<end-utc>))
| where _ResourceId =~ "<account-resource-id>"
| summarize Requests=count(), TotalRU=sum(RequestCharge),
            P95Ms=percentile(DurationMs, 95)
  by StatusCode, OperationName, RegionName, DatabaseName, CollectionName
| order by Requests desc
```

Do not project request bodies, queries, or partition-key values. If
resource-specific tables aren't used, inspect `AzureDiagnostics` categories and
record the schema.

### Step 4: Analyze 429 throttling
For 429 errors:

1. Confirm SDK retries and end-user success/latency.
2. Split by container, region, operation, physical partition, and time.
3. Compare Normalized RU Consumption and RU charge.
4. Determine account/container throughput ownership and autoscale maximum.
5. Distinguish healthy transient throttling from sustained user-visible impact.
6. Test hot-partition, inefficient-query, bulk-operation, and traffic-spike causes.

Some 429 responses are expected in a healthy workload because SDKs retry. Prioritize
failed requests, retry latency, and sustained high normalized consumption.

### Step 5: Detect partition and query inefficiency
Use partition-level RU telemetry to find skew without disclosing key values.
Evaluate:

- Cardinality and write/read distribution of the partition-key design
- Logical-partition storage limits and large-item patterns
- Cross-partition fan-out and unbounded scans
- Query RU charge, retrieved/output ratio, index utilization, and continuation
- Indexing paths, composite/spatial/vector/full-text indexes, and write cost
- Hot keys, synthetic/hierarchical keys, and immutable key requirements

When explicitly authorized, use Azure MCP item queries with projections,
partition-key scoping, filters, deterministic ordering, and small limits. Never
use `SELECT *` for troubleshooting.

### Step 6: Analyze SDK and connectivity
Require the complete SDK diagnostics string for representative failed/slow
operations, redacted for data. Check:

- SDK and runtime version
- Direct versus gateway mode and connection limits
- Preferred regions and endpoint discovery
- CPU/thread starvation, SNAT/port exhaustion, DNS, TLS, proxy, and firewall
- Request timeout, retry policy, client singleton lifetime, and concurrency
- 408/410/429/449/503 status and substatus patterns

Client-side timeout doesn't prove a Cosmos server failure. Correlate server
latency, SDK timeline, client resources, and network path.

### Step 7: Analyze reliability and consistency
Review:

- Single versus multiple write regions
- Automatic/service-managed failover
- Preferred region order in clients
- Availability zones and regional capacity
- Consistency level, session-token handling, and RPO tradeoffs
- Replication latency and regional health
- Continuous/periodic backup and restore requirements

Do not perform a failover test without explicit authorization and an end-to-end
application test/rollback plan.

### Step 8: Follow the symptom path

| Symptom | Required investigation |
|---------|------------------------|
| 429 | Normalized RU, partition skew, query RU, autoscale max, retries |
| High latency | Server latency vs SDK/network/client, region, consistency, item size |
| Timeout | SDK diagnostics, hot partition, client CPU/threads, DNS/SNAT, 429/503 |
| High RU/cost | Query fan-out, indexing, item size, retries, consistency, regions |
| Storage growth | Data/index size, TTL, change feed, backup/replication, large items |
| Availability | Region health, preferred regions, failover, SDK resilience, network |
| Conflict/data issue | Write regions, consistency, conflict policy, session tokens |

### Step 9: Test competing hypotheses
State expected, observed, and contradictory evidence and assign confidence.

## Scoring
Direct SDK/log evidence 25, metric/timeline 20, partition/query corroboration 15,
mechanism 20, alternatives 10, validation 10. Use Confirmed/High
confidence/Probable/Hypothesis at 90/70/40 thresholds.

## Accepted exceptions
Record approved load tests, intentional serverless latency, bounded 429 rates,
single-region designs, or indexing tradeoffs with owner and review date.

## Expected output

## Azure Cosmos DB Troubleshooting Report

Include account/container scope, API, window, impact, timeline, RU/partition
analysis, SDK evidence, diagnosis, mitigation, durable fix, verification,
telemetry gaps, exceptions, and read-only commands/queries.

## Remediation guidance
- Suggest only and preserve data/recovery semantics.
- Never change partition key or indexing without migration and RU testing.
- Never increase throughput before validating hot partitions and query cost.
- Validate client retry and region behavior under representative load.

## References
- 429 troubleshooting: https://learn.microsoft.com/azure/cosmos-db/troubleshoot-request-rate-too-large
- SDK timeouts: https://learn.microsoft.com/azure/cosmos-db/troubleshoot-dotnet-sdk-request-time-out
- Normalized RU: https://learn.microsoft.com/azure/cosmos-db/monitor-normalized-request-units
- Partitioning: https://learn.microsoft.com/azure/cosmos-db/partitioning-overview
- Resilient SDK apps: https://learn.microsoft.com/azure/cosmos-db/nosql/conceptual-resilient-sdk-applications
- WAF service guide: https://learn.microsoft.com/azure/well-architected/service-guides/cosmos-db

## Sample output

> Redacted example.

## Azure Cosmos DB Troubleshooting Report

| Field | Value |
|-------|-------|
| Scope | orders/account-db/orders |
| Symptom | 429 and p99 latency |
| Confidence | 86/100 - High confidence |

`single physical partition at 100% normalized RU -> retries -> p99 increase`.
No throughput, indexing, partition, failover, or data change was executed.
