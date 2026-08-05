---
name: java-app-troubleshooting
description: >
  Diagnose Java application availability, startup, HTTP errors, latency, high
  CPU, memory leaks, OOM, garbage collection, thread contention, deadlocks,
  connection pools, dependencies, and missing telemetry on Azure. Use
  Application Insights APM, Azure Monitor metrics and diagnostic logs, AppLens,
  JVM metrics, traces, and approved Java runtime artifacts across App Service,
  AKS, Container Apps, VMs, and other Java hosting platforms.
tools:
  - RunAzCliReadCommands
  - execute_kusto_query
  - AzureMCP/*
  - MicrosoftLearnMCP/*
  - applens_resource_diagnose
  - applicationinsights_recommendation_list
---

# Java Application Troubleshooting

> **Required MCP grounding:** Before conclusions, use `AzureMCP/*` for live Azure evidence and `MicrosoftLearnMCP/*` for current authoritative guidance. If either connector is unavailable, report a blocking evidence gap instead of relying on model memory.

## Purpose
Run a safe, evidence-driven investigation of Java applications hosted on Azure.
Correlate:

- AppLens platform diagnostics
- Application Insights requests, dependencies, exceptions, traces, metrics,
  distributed traces, Application Map, failures, and performance views
- Azure resource metrics, activity changes, and diagnostic logs
- JVM, garbage collector, thread, heap, connection-pool, and runtime behavior
- Hosting evidence from App Service, AKS, Container Apps, or VM/VMSS

Produce a ranked root-cause assessment, reversible mitigation options, durable
fixes, and measurable verification criteria.

## When to use this skill
- The Java app is down, slow, timing out, or returning HTTP 5xx
- The JVM fails to start or the application fails after deployment
- CPU, heap, native memory, GC, threads, or connection pools are abnormal
- Containers or workers restart, recycle, or become OOMKilled
- SQL, HTTP, messaging, DNS, TLS, identity, or another dependency fails
- Application Insights data is missing, duplicated, sampled, or uncorrelated
- A deployment, JVM/runtime update, configuration, or traffic change regressed health

## Guardrails
- Use read-only Azure commands, KQL, logs, metrics, and JVM evidence collection.
- Do not restart, redeploy, scale, change JVM flags, alter sampling, update the
  Java agent, import certificates, kill threads, or modify application settings.
- Never print connection strings, credentials, tokens, cookies, request/response
  bodies, query parameters, user identifiers, or sensitive custom dimensions.
- Treat thread dumps, Java Flight Recorder (JFR), heap dumps, profiler output,
  and core dumps as sensitive because they can contain application data.
- Require explicit approval, protected storage, overhead analysis, and retention
  limits before runtime-artifact collection.
- Preserve volatile evidence before recommending restart or scale.
- Use UTC and distinguish facts, inferences, and hypotheses.

## Pre-check

| Field | Required value |
|-------|----------------|
| Scope | Subscription, resource, app/role, environment, region |
| Hosting | App Service, AKS, Container Apps, VM/VMSS, or other |
| Java stack | JDK/vendor/version, framework, server, container/image |
| APM | Java agent or Azure Monitor OpenTelemetry, version, role name |
| Symptom | Availability, error, latency, CPU, memory, GC, thread, dependency |
| Window | Incident start/end UTC and comparable healthy baseline |
| Change | Deployment, image, runtime, flags, agent, config, traffic, dependency |
| Targets | Availability, p95/p99, throughput, error and saturation limits |

If no window is supplied, begin with the last 60 minutes and preceding 60-minute
baseline.

## Investigation procedure

### Step 1: Run AppLens first
For an active performance or functionality issue, call
`applens_resource_diagnose` before manually investigating metrics or logs.
Provide the exact resource and a question containing:

- Symptom and incident window
- Deployment/change timestamp
- Affected endpoint, role, instance, pod, or revision
- Expected and observed behavior

Treat AppLens output as a diagnostic hypothesis. Correlate detectors and
recommendations with APM, platform, and JVM evidence.

For App Service, also use the App Service diagnostic detector list and run the
most relevant detector for availability, CPU, memory, container recycle,
networking, or configuration.

### Step 2: Confirm resource and Java runtime state
Record:

- Azure resource ID/type, plan/SKU, instances/replicas, zones, and health
- Deployment/image digest, app version, role name, and instance identity
- JDK distribution/version, heap flags, GC, framework, and application server
- Container CPU/memory requests/limits or App Service plan resources
- Startup command, listening port, probes/health check, and dependencies

Use hosting-specific read-only commands from:

- `16-appservices-troubleshooting`
- `14-azure-aks-acr-troubleshooting`
- `15-azure-aca-aci-acr-troubleshooting`

Correlate Azure Activity Log and deployment records with the first anomaly.

### Step 3: Verify Java APM instrumentation
Identify exactly one intended telemetry path:

| Instrumentation | Validation |
|-----------------|------------|
| Application Insights Java 3.x agent | Agent JAR/path, supported version, `-javaagent`, configuration, self-diagnostics |
| Azure Monitor OpenTelemetry Distro | Distro/starter/exporter version, resource attributes, exporter and endpoint |
| Platform auto-instrumentation | Hosting setting, runtime support, injected agent, effective configuration |

Avoid accidental double instrumentation from multiple Java agents, SDKs, or
OpenTelemetry exporters.

For Application Insights Java 3.x:

1. Check `applicationinsights.log` first.
2. If absent, confirm write permission beside the agent JAR and inspect stdout.
3. Confirm the agent JAR exists and isn't corrupt.
4. Confirm the connection string is present without printing its value.
5. Review self-diagnostic warnings/errors, sampling, disabled instrumentations,
   role-name/resource attributes, and logging thresholds.
6. Validate outbound DNS/TLS/proxy/firewall access to ingestion and Live Metrics.
7. Check Java truststore, SNI, cipher, and certificate errors.

For OpenTelemetry, review exporter diagnostics, resource detection, sampling,
processor/exporter configuration, and duplicate providers.

### Step 4: Establish request health
These queries use workspace-based Application Insights tables. Add an
`AppRoleName` filter in shared resources.

```kusto
AppRequests
| where TimeGenerated >= ago(60m)
| summarize
    Requests=sum(ItemCount),
    Failures=sumif(ItemCount, Success == false),
    P50Ms=percentile(DurationMs, 50),
    P95Ms=percentile(DurationMs, 95),
    P99Ms=percentile(DurationMs, 99)
  by bin(TimeGenerated, 5m), AppRoleName, AppVersion
| extend FailureRatePct=round(100.0 * Failures / Requests, 2)
| order by TimeGenerated asc
```

```kusto
AppRequests
| where TimeGenerated >= ago(60m)
| summarize Requests=sum(ItemCount),
            Failures=sumif(ItemCount, Success == false),
            P95Ms=percentile(DurationMs, 95)
  by AppRoleName, AppVersion, OperationName, ResultCode
| extend FailureRatePct=round(100.0 * Failures / Requests, 2)
| top 25 by Failures desc
```

Compare incident and baseline by operation, role, version, region, and instance.
Distinguish traffic growth from failure-rate or latency regression.

### Step 5: Analyze exceptions and dependencies

```kusto
AppExceptions
| where TimeGenerated >= ago(60m)
| summarize Occurrences=sum(ItemCount),
            FirstSeen=min(TimeGenerated),
            LastSeen=max(TimeGenerated),
            SampleOperationId=any(OperationId)
  by AppRoleName, AppVersion, OperationName, ExceptionType, ProblemId
| top 25 by Occurrences desc
```

```kusto
AppDependencies
| where TimeGenerated >= ago(60m)
| summarize Calls=sum(ItemCount),
            Failures=sumif(ItemCount, Success == false),
            P95Ms=percentile(DurationMs, 95)
  by AppRoleName, AppVersion, Target, DependencyType, Name, ResultCode
| extend FailureRatePct=round(100.0 * Failures / Calls, 2)
| top 25 by Failures desc
```

Use one representative `OperationId` to correlate request, dependency,
exception, and trace events. Report stable exception/problem identifiers and
redacted summaries, not full stack traces or SQL/URLs.

Java logging exceptions can appear in `AppExceptions` rather than `AppTraces`.
Search both before declaring logs missing.

### Step 6: Discover JVM and application metrics
First enumerate metric names:

```kusto
AppMetrics
| where TimeGenerated >= ago(60m)
| summarize Samples=count(), LastSeen=max(TimeGenerated)
  by AppRoleName, Name
| order by Samples desc
```

Then query the available Java agent, JMX, Micrometer, or OpenTelemetry metrics
for:

- Process/JVM CPU and load
- Heap used/committed/max by pool
- Nonheap/metaspace and direct buffers
- GC pause duration/count and allocation rate
- Live threads, daemon threads, peak threads, blocked/waiting threads
- Class loading/unloading
- Tomcat/Jetty/Netty threads, sessions, requests, and connections
- JDBC/Hikari active, idle, pending, timeout, and max connections
- Executor queue, messaging backlog, cache, and framework-specific health

Do not assume metric names; instrumentation and semantic conventions vary.

### Step 7: Correlate Azure platform metrics and logs
Discover resource metric definitions before querying. Review hosting CPU/memory,
restarts, workers/nodes/replicas, requests, network, filesystem, queue/backlog,
and health signals. Compare JVM heap to container/worker memory:

- Heap near max with GC pressure suggests managed-heap pressure.
- Container/worker memory growth with stable heap suggests native memory,
  direct buffers, metaspace, thread stacks, mmap, or another process.

Inspect bounded platform/application/container logs and deployment events.
Avoid returning full logs when grouped evidence is enough.

### Step 8: Follow the Java symptom path

| Symptom | Required investigation |
|---------|------------------------|
| JVM/app startup | Agent JAR/path/corruption, JVM flags, classpath, framework/server logs, port, dependencies |
| Missing telemetry | Self-diagnostic log, connection string presence, endpoint DNS/TLS, sampling, role name, exporter, double instrumentation |
| HTTP 5xx | Operation/result, exception type/problem ID, deployment version, dependency failure |
| High latency | Request vs dependency p95/p99, thread/executor queue, pool waits, GC pause, locks, CPU |
| High CPU | Request rate, hot operation, retry loop, GC, serialization, regex, crypto, logging, JIT |
| Heap/OOM | Heap pools, allocation/GC, retained cache/collections, item size, `Xmx`, leak pattern |
| Native/container OOM | Direct buffers, metaspace, threads/stacks, native library, container limit |
| GC pauses | Collector, heap sizing, allocation rate, promotion, full GC, JFR/GC logs |
| Thread starvation | Pool active/max/queue, blocked/waiting threads, sync-over-async, slow dependency |
| Deadlock | Repeated blocked-thread cycle, lock ownership, thread dump evidence |
| JDBC pool exhaustion | Active/pending/max, connection leak, slow SQL, transaction age, timeout/retry |
| Dependency/TLS | Target, DNS, truststore, certificate, proxy, timeout, connection pool, retries |
| Restart/recycle | Exit code, OOM, liveness/health, platform event, deployment, agent overhead |

### Step 9: Apply hosting-specific checks

**App Service**
- Run AppLens/App Service detectors.
- Correlate app and App Service plan CPU/memory, worker instance, health check,
  startup, container logs, deployment, VNet/DNS/SNAT, and Java/Tomcat/JBoss logs.

**AKS**
- Inspect pod events, previous logs, exit code, OOMKilled, probes, requests and
  limits, node pressure, DNS/network, autoscaling, and image digest.

**Container Apps**
- Inspect revision/replica system and console logs, target port, probes,
  resource limits, KEDA scaling, Dapr, traffic, and ACR pull path.

**VM/VMSS**
- Inspect process/OS metrics, disk, network, agent health, service manager logs,
  image/JDK drift, and instance-specific behavior.

### Step 10: Decide whether runtime artifacts are justified
Use the least invasive artifact that discriminates the remaining hypotheses:

| Problem | Preferred artifact |
|---------|--------------------|
| Thread starvation/deadlock | Several thread dumps over time |
| High CPU | JFR or sampling profiler during symptom |
| GC pause/allocation | GC logs and JFR |
| Heap growth/leak | Class histogram, then heap dump if required |
| Native memory/OOM | Native memory tracking, container/OS evidence, core only if required |

Before collection, confirm tool/JDK support, process access, disk space, CPU and
pause overhead, sensitive-data handling, encryption, retention, and user
approval. Never collect a heap/core dump merely because memory is high.

### Step 11: Test competing hypotheses
For every leading cause:

1. State expected evidence.
2. State observed and contradicting evidence.
3. Compare at least one plausible alternative.
4. Explain the causal chain from change or workload to user impact.
5. Assign confidence.

Example:

`deployment -> JDBC connection leak -> Hikari pending threads -> request queue ->
p99 latency and timeout increase`

## Scoring
Score the leading root-cause candidate:

| Evidence dimension | Points |
|--------------------|--------|
| Direct APM/JVM/log evidence | 0-25 |
| Timeline and metric alignment | 0-20 |
| Independent platform/dependency corroboration | 0-15 |
| Mechanism explains user impact | 0-20 |
| Alternatives tested | 0-10 |
| Recovery or reproduction validates cause | 0-10 |

90-100 Confirmed; 70-89 High confidence; 40-69 Probable; below 40 Hypothesis.
Missing telemetry contributes zero points.

## Accepted exceptions
Record expected load tests, batch jobs, startup warmup, GC maintenance, scheduled
restarts, deployment windows, or sampling choices with owner, scope, reason, and
review date.

## Expected output

## Java Application Troubleshooting Report

| Field | Value |
|-------|-------|
| Resource/hosting | Resource, platform, region |
| Java stack | JDK, framework/server, app version |
| Instrumentation | Java agent/OpenTelemetry and version |
| Incident window | Start/end UTC |
| Symptom/status | Description and current state |
| Root-cause confidence | Score/classification |

Required sections:
1. Executive summary
2. Timeline and deployment/change correlation
3. Request, exception, dependency, and trace evidence
4. JVM/resource metrics and saturation
5. Hosting-platform evidence
6. Diagnosis and alternatives
7. Immediate mitigation and durable fix
8. Verification plan
9. Telemetry/artifact gaps and accepted exceptions
10. Commands, queries, and references

If evidence is insufficient, state `Root cause not established` and specify the
next discriminating metric, query, thread dump, JFR, or heap analysis.

## Remediation guidance
- Suggest only; never execute runtime or platform changes.
- State impact, risk, prerequisites, rollback, and success criteria.
- Prefer code/pool/retry fixes over adding capacity when saturation is secondary.
- Test Java agent/runtime upgrades and model telemetry changes before production.
- Revalidate p95/p99, failures, GC, pools, CPU/memory, and cost after remediation.

## References
- Java agent troubleshooting: https://learn.microsoft.com/troubleshoot/azure/azure-monitor/app-insights/telemetry/java-standalone-troubleshoot
- Java agent configuration: https://learn.microsoft.com/azure/azure-monitor/app/java-standalone-config
- OpenTelemetry Java troubleshooting: https://learn.microsoft.com/troubleshoot/azure/azure-monitor/app-insights/telemetry/opentelemetry-troubleshooting-java
- Application Insights data model: https://learn.microsoft.com/azure/azure-monitor/app/data-model-complete
- App Service Java logging/debugging: https://learn.microsoft.com/azure/app-service/configure-language-java-deploy-run
- Java dumps and JFR: https://learn.microsoft.com/azure/spring-apps/basic-standard/how-to-capture-dumps
- Java on AKS with Azure SRE Agent: https://learn.microsoft.com/azure/sre-agent/troubleshoot-java-aks

## Sample output

> Redacted example.

## Java Application Troubleshooting Report

| Field | Value |
|-------|-------|
| Hosting | AKS / orders-api |
| Java stack | Java 21, Spring Boot, HikariCP |
| Symptom | p99 latency and timeout regression |
| Confidence | 88/100 - High confidence |

APM and JVM metrics show `JDBC connection leak -> pool saturation -> request
thread queue -> timeout`. CPU and GC remain at baseline, contradicting a compute
or heap cause. No pod, JVM, pool, or platform change was executed.
