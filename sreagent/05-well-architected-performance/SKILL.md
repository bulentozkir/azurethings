---
name: well-architected-performance
description: >
  Run an Azure Well-Architected Performance Efficiency review covering
  performance targets, capacity planning, service selection, measurement,
  scaling, partitioning, load testing, code and infrastructure optimization,
  data performance, critical-flow prioritization, operational interference,
  live performance response, and continuous optimization.
tools:
  - RunAzCliReadCommands
  - execute_kusto_query
  - AzureMCP/*
  - MicrosoftLearnMCP/*
---

# Azure Well-Architected Performance Efficiency

> **Required MCP grounding:** Before conclusions, use `AzureMCP/*` for live Azure evidence and `MicrosoftLearnMCP/*` for current authoritative guidance. If either connector is unavailable, report a blocking evidence gap instead of relying on model memory.

## Purpose
Assess whether an Azure workload maintains efficient interactions as demand
changes. Evaluate all Microsoft Well-Architected `PE:01` through `PE:12`
controls and produce an evidence-based scalability and optimization roadmap.

## Guardrails
- Use read-only metrics, logs, traces, configuration, quota, and test evidence.
- Do not scale, resize, repartition, reindex, change cache, run load tests, or
  alter production settings without approval.
- Never expose payloads, query parameters, customer data, or secrets.
- Don't optimize noncritical components before identifying the actual bottleneck.
- Treat correlation as hypothesis until tested.

## Pre-check

| Field | Required value |
|-------|----------------|
| Flows | Critical user/system flows and business priorities |
| Targets | Throughput, latency percentiles, concurrency, freshness, error rate |
| Demand | Baseline, peak, seasonality, growth, campaigns, and failure load |
| Architecture | Components, scale units, partitions, dependencies, regions |
| Capacity | SKU/tier, quota, regional/zone capacity, autoscale bounds |
| Telemetry | End-to-end traces, resource metrics, profiles, query/store metrics |
| Tests | Load, stress, spike, soak, failover, and scalability evidence |
| Changes | Deployments, maintenance, data growth, and operational tasks |

Use complete, representative periods. Average values alone are insufficient.

## Assessment procedure

### Step 1: PE:01 - Define performance targets
For every critical flow define:

- p50/p95/p99 end-to-end latency and server/client boundaries
- Throughput, concurrency, queue/backlog, and data freshness
- Error/timeout/throttling limits
- Recovery after a spike or dependency slowdown
- Target by geography, device/client, and workload tier
- Test conditions, measurement method, and owner

Targets must be numerical, business-aligned, and compatible with SLOs and budget.

### Step 2: PE:02 - Capacity planning
Model:

`forecast demand + failure/maintenance demand + growth buffer`

Review seasonal/event peaks, data growth, tenant growth, deployments, batch
windows, zone/region failure, retry amplification, and downstream limits.

Use Azure quota and regional availability tools to validate vCPU, IP, storage,
database, messaging, container, AI, and other service limits. Quota is not a
capacity guarantee.

### Step 3: PE:03 - Select the right services
For each component validate:

- Service model, tier, SKU, region, and deployment type
- Native scaling, partitioning, caching, batching, and asynchronous features
- SLA/limits, startup time, throughput, latency, and data residency
- Operational complexity and cost-performance
- Preview/retirement and future growth constraints

Identify components that require custom scaling because the selected service
doesn't match workload behavior.

### Step 4: PE:04 - Measure consistently
Use Azure Monitor MCP to discover metric definitions and query metrics/logs.
Require:

- End-to-end distributed traces with deployment/version correlation
- RED signals for services: rate, errors, duration
- USE signals for resources: utilization, saturation, errors
- Queue/backlog, connection pool, thread, GC, disk, network, cache, and data
- Percentiles and histograms, not only averages
- Per-region, instance, partition, tenant, operation, and dependency dimensions
- Baselines, anomaly detection, retention, and dashboard/runbook ownership

Validate telemetry overhead, sampling, cardinality, and missing-data behavior.

### Step 5: PE:05 - Scale and partition
Review:

- Horizontal versus vertical scaling and scale-unit boundaries
- Autoscale signal, minimum/maximum, cooldown, warmup, and hysteresis
- Scale-out speed versus demand ramp and queue buffering
- Zone/region capacity and one-failure-domain operation
- Partition-key cardinality, skew, hotspots, rebalancing, and growth
- Sharding/routing, tenant isolation, and noisy-neighbor controls
- Stateful migration, consistency, and failover behavior

Scaling a bottleneck can move it downstream. Validate the entire critical flow.

### Step 6: PE:06 - Performance testing
Require production-like:

| Test | Purpose |
|------|---------|
| Baseline | Confirm target under normal demand |
| Load | Validate expected peak |
| Stress | Find saturation and graceful degradation |
| Spike | Validate scale-out and queue behavior |
| Soak | Find leaks, fragmentation, drift, and cumulative backlog |
| Failover | Validate reduced-capacity performance |
| Scalability | Confirm throughput increases with added capacity |

Use representative data, request mix, regions, dependencies, cache state,
authentication, and deployment configuration. Define stop conditions and never
run against production without explicit authorization.

### Step 7: PE:07 - Optimize code and infrastructure
Profile before changing. Check:

- Algorithmic complexity, allocations, serialization, compression, regex
- Synchronous blocking, locks, thread/connection pools, retries, and timeouts
- Chatty calls, N+1 patterns, payload size, batching, and pagination
- Runtime/SDK versions, compilation, GC, and native dependencies
- Network hops, TLS, DNS, SNAT, and proxy/load-balancer behavior
- CPU/memory/disk/network ratios and specialized hardware
- Offload to managed platform capabilities when simpler and measurable

Avoid micro-optimization without end-to-end impact.

### Step 8: PE:08 - Optimize data
Evaluate:

- Query plans, indexes, statistics, partitioning, and data distribution
- Read/write ratio, consistency, transactions, lock contention, and replicas
- Connection pooling, prepared/parameterized queries, batching, and retries
- Cache policy, TTL, invalidation, hit rate, stampede, and stale-data tolerance
- Item/row/document size, compression, lifecycle, and archival
- Cross-region latency, replication, and data locality
- Backup, reindex, vacuum, compaction, and maintenance interference

Measure query cost and application latency together.

### Step 9: PE:09 - Prioritize critical flows
Map every bottleneck and optimization to business flow. Reserve capacity and
performance isolation for critical flows. Define degraded modes, admission
control, priority queues, and load shedding so low-priority work can't exhaust
critical capacity.

### Step 10: PE:10 - Control operational interference
Measure performance impact of deployments, backups, scans, secret/certificate
rotation, patching, reindexing, data movement, autoscale, failover, and tests.
Schedule, throttle, isolate, or redesign tasks that violate flow targets.

### Step 11: PE:11 - Respond to live issues
Define:

1. Detection and severity
2. Performance incident commander and specialists
3. Baseline/change comparison
4. Bottleneck isolation across client, app, dependency, and platform
5. Safe mitigation with rollback
6. Recovery verification against targets
7. Profile/trace preservation
8. Post-incident preventive action

Distinguish demand increase, regression, dependency, saturation, and telemetry
artifacts before scaling.

### Step 12: PE:12 - Continuously optimize
Track trend deterioration, data growth, quota headroom, SKU evolution, runtime
updates, service retirements, cost per transaction, and technical debt.

Maintain an optimization backlog with expected benefit, evidence, owner,
experiment, risk, and measured outcome. Remove changes that don't improve the
target.

### Step 13: Correlate bottlenecks
For each candidate cause state:

- Expected evidence
- Observed and contradictory evidence
- Demand and change timeline
- Saturated resource and waiting work
- Downstream/upstream effects
- Test or profile that discriminates alternatives

Use a causal chain such as:

`traffic spike -> connection pool max -> request queue -> p99 latency -> timeout
retry amplification`.

## Scoring
Score `PE:01`-`PE:12` from 0 to 5:

| Score | Meaning |
|-------|---------|
| 5 | Measured, tested, automated, and continuously optimized |
| 3 | Implemented with material gaps |
| 1 | Ad hoc or reactive |
| 0 | Absent or not assessed |
| N/A | Demonstrably not applicable |

Overall score is earned/applicable points * 100. Maturity: 90+ Optimized,
70-89 Managed, 40-69 Developing, below 40 Initial.

## Accepted exceptions
Require exact control/flow, reason, target impact, compensating control, owner,
expiry/review date, and test evidence.

## Expected output

## Azure Performance Efficiency Review Report

Include scope, targets, scorecard, demand/capacity model, telemetry quality,
bottleneck map, scale/partition analysis, test evidence, code/data findings,
operational interference, incident readiness, prioritized experiments,
exceptions, and references.

Every finding includes PE code, flow, metric evidence, target gap, bottleneck,
recommendation, cost/tradeoff, owner, expected gain, and verification.

## Remediation guidance
- Suggest only; optimize after measurement.
- Change one material variable per experiment when practical.
- Validate production-like load, failure mode, cost, and rollback.
- Don't scale before identifying partition/query/client bottlenecks.

## References
- Checklist: https://learn.microsoft.com/azure/well-architected/performance-efficiency/checklist
- Principles: https://learn.microsoft.com/azure/well-architected/performance-efficiency/principles
- Performance targets: https://learn.microsoft.com/azure/well-architected/performance-efficiency/performance-targets
- Capacity planning: https://learn.microsoft.com/azure/well-architected/performance-efficiency/capacity-planning
- Performance testing: https://learn.microsoft.com/azure/well-architected/performance-efficiency/performance-test
- Scaling/partitioning: https://learn.microsoft.com/azure/well-architected/performance-efficiency/scale-partition

## Sample output

| Field | Value |
|-------|-------|
| Score | 61/100 - Developing |
| Target gap | Checkout p99 3.8s versus 1.5s |
| Bottleneck | Database pool saturation |

Recommended experiment: increase pool efficiency and remove N+1 calls before
adding compute; verify p99, throughput, errors, and cost under peak load.
