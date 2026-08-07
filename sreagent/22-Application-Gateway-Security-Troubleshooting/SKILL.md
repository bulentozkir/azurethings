---
name: application-gateway-security-troubleshooting
description: >
  Diagnose Azure Application Gateway v2 and Application Gateway for Containers
  security, WAF, access, backend health, TLS, certificate, latency, capacity,
  routing, and availability issues. Prefer AGW and AGC resource-specific logs,
  verified workbook queries, Azure Monitor metrics, Azure MCP, and Microsoft Learn.
tools:
  - RunAzCliReadCommands
  - execute_kusto_query
  - AzureMCP/*
  - MicrosoftLearnMCP/*
---

# Azure Application Gateway Security Troubleshooting

> **Required MCP grounding:** Before conclusions, use `AzureMCP/*` for live Azure evidence and `MicrosoftLearnMCP/*` for current authoritative guidance. If either connector is unavailable, report a blocking evidence gap instead of relying on model memory.

## Purpose
Run a read-only investigation across Application Gateway v2, WAF, listeners,
routes, probes, backends, certificates, networking, metrics, and resource-specific
logs. When in scope, investigate Application Gateway for Containers (AGC), its
traffic controller, ALB Controller, Kubernetes routes, WAF, and backend targets.

## Resource-specific logging requirement
Prefer:

| Platform | Access | WAF | Performance |
|----------|--------|-----|-------------|
| Application Gateway | `AGWAccessLogs` | `AGWFirewallLogs` | `AGWPerformanceLogs` (v1 only) |
| AGC | `AGCAccessLogs` | `AGCFirewallLogs` | Azure Monitor metrics |

**Warn the user** when current Application Gateway diagnostic settings use legacy
`AzureDiagnostics` instead of `logAnalyticsDestinationType: Dedicated`. Legacy
mode has a wide shared schema and less predictable queries. Historical legacy
rows can remain after migration, and parallel settings can intentionally send
both modes, so verify the current setting through Azure MCP/ARM. Empty tables
mean `Not observable` until settings, scope, workspace, retention, and ingestion
are verified. Initial population can take about 30 minutes for Application
Gateway and up to one hour for AGC.

## Guardrails
- Use read-only Azure MCP, Resource Graph, Monitor, Activity Log, KQL, and
  approved Kubernetes reads.
- Do not change WAF policies, rules, exclusions, listeners, routes, probes,
  certificates, Key Vault, NSGs, UDRs, DNS, scale settings, diagnostics, or alerts.
- Do not replay WAF payloads, scan endpoints, or generate security traffic.
- Mask client IPs, hosts, URIs, transaction/tracking IDs, payload excerpts, and
  certificate identifiers in distributed reports.
- One request can emit many WAF rows. Count `TransactionId` or `TrackingId` for
  requests and use row count only for rule events.
- `Matched`/`Detected` is not a block or proof of attack; Detection mode allows.
- Bound raw drill-downs to one approved transaction and at most 200 rows.
- Use UTC and record resource ID, workspace, query window, ingestion freshness,
  workbook commit/date, assumptions, and redactions.

## Pre-check

| Field | Required value |
|-------|----------------|
| Scope | Gateway/traffic controller, listeners/frontends, routes, WAF policy |
| Incident | UTC window, healthy baseline, user impact, sample status/ID |
| Backends | Pools/settings or Kubernetes services/endpoints, probes and health |
| Security | Public/private exposure, TLS, identity, Key Vault, NSG/UDR/DNS |
| Capacity | SKU, zones, autoscale limits, subnet headroom, connection profile |
| Telemetry | Workspace, destination mode, tables, metrics, retention, freshness |
| Changes | Gateway/WAF/cert/network/app/Kubernetes deployments and Activity Log |

## Investigation procedure

### Step 1: Inventory and posture
Use Azure MCP and Resource Graph to inspect provisioning/resource health, SKU,
zones, autoscale, subnet, frontends, listeners, rules, URL maps, backend pools,
settings, probes, redirects, rewrite sets, WAF attachments, identities, Private
Link, diagnostic settings, and recent changes.

Validate:
- WAF is attached to intended listeners/routes; Prevention follows safe tuning.
- Managed rule/Bot versions, custom-rule priority/actions, and exclusions are current.
- TLS 1.2+, listener certificate chain/expiry, backend SNI/root trust, and Key
  Vault identity/firewall/private DNS are valid.
- Backends are `Healthy`; distinguish `Unhealthy`, `Unknown`, and permission gaps.
- Dedicated subnet/AGC association, address headroom, NSG, UDR, DNS, and egress
  support maximum scale and certificate revocation checks.
- AGC ALB Controller, workload identity/RBAC, `Gateway`/`HTTPRoute`,
  `ReferenceGrant`, endpoint readiness, frontend association, and policy scope.

### Step 2: Validate logs and units
Use Azure MCP Monitor workspace/table/log/metric/activity tools. Application
Gateway access timing fields are **seconds**; queries convert to milliseconds.
AGC timing fields are already **milliseconds**. AGC correlation uses `TrackingId`
(`x-request-id`); Application Gateway uses `TransactionId`.

### Step 3: Use supplied workbooks
Use the resource-specific App Gateway WAF Monitor workbook for action/rule/URI/
client/transaction views. Use the AGC WAF Triage workbook for policy scope and
triage intent, but replace its legacy suffixed fields and mixed-table access
logic with current `AGCAccessLogs`, `AGCFirewallLogs`, and `TrackingId`. AGC uses
Microsoft DRS/Bot Manager, so do not generate OWASP CRS links for AGC rules.

## Verified query catalog
Replace placeholders and narrow the time window. Queries are corrected from the
referenced workbooks and current Microsoft Learn resource-specific schemas.

#### 1. Detect recent legacy versus resource-specific storage
```kusto
let lookback = 24h;
union isfuzzy=true
(AzureDiagnostics
 | where TimeGenerated >= ago(lookback)
 | where Category in ("ApplicationGatewayAccessLog","ApplicationGatewayFirewallLog",
     "ApplicationGatewayPerformanceLog","TrafficControllerAccessLog","TrafficControllerFirewallLog")
 | project TimeGenerated, _ResourceId, StorageMode="Legacy AzureDiagnostics", Category),
(AGWAccessLogs | where TimeGenerated >= ago(lookback)
 | project TimeGenerated, _ResourceId, StorageMode="Resource-specific", Category="AGWAccessLogs"),
(AGWFirewallLogs | where TimeGenerated >= ago(lookback)
 | project TimeGenerated, _ResourceId, StorageMode="Resource-specific", Category="AGWFirewallLogs"),
(AGWPerformanceLogs | where TimeGenerated >= ago(lookback)
 | project TimeGenerated, _ResourceId, StorageMode="Resource-specific", Category="AGWPerformanceLogs"),
(AGCAccessLogs | where TimeGenerated >= ago(lookback)
 | project TimeGenerated, _ResourceId, StorageMode="Resource-specific", Category="AGCAccessLogs"),
(AGCFirewallLogs | where TimeGenerated >= ago(lookback)
 | project TimeGenerated, _ResourceId, StorageMode="Resource-specific", Category="AGCFirewallLogs")
| summarize Rows=count(), LastSeen=max(TimeGenerated) by _ResourceId, StorageMode, Category
```

### Application Gateway v2

#### 2. WAF actions
```kusto
let rid = "<RESOURCE_ID>";
AGWFirewallLogs
| where TimeGenerated >= ago(24h) and _ResourceId =~ rid
| summarize Events=count(), Requests=dcount(TransactionId) by Action
| order by Requests desc
```

#### 3. Most blocked hosts and URIs
```kusto
let rid = "<RESOURCE_ID>";
AGWFirewallLogs
| where TimeGenerated >= ago(24h) and _ResourceId =~ rid and Action =~ "Blocked"
| summarize BlockedRequests=dcount(TransactionId), WafEvents=count()
    by Hostname, RequestUri
| top 40 by BlockedRequests desc
```

#### 4. Triggered rules
```kusto
let rid = "<RESOURCE_ID>";
AGWFirewallLogs
| where TimeGenerated >= ago(24h) and _ResourceId =~ rid
| summarize Requests=dcount(TransactionId), Events=count()
    by RuleSetType, RuleSetVersion, RuleId, Message, Action
| top 50 by Requests desc
```

#### 5. Rule trend
```kusto
let rid = "<RESOURCE_ID>";
AGWFirewallLogs
| where TimeGenerated >= ago(24h) and _ResourceId =~ rid
| summarize Requests=dcount(TransactionId)
    by bin(TimeGenerated, 15m), RuleId, Action
| order by TimeGenerated asc
```

#### 6. Approved transaction drill-down
```kusto
let rid = "<RESOURCE_ID>";
let transactionId = "<TRANSACTION_ID>";
AGWFirewallLogs
| where TimeGenerated >= ago(24h)
| where _ResourceId =~ rid and TransactionId == transactionId
| project TimeGenerated, TransactionId, ClientIp, Hostname, RequestUri,
    Action, RuleId, RuleSetType, RuleSetVersion, Message, DetailedMessage,
    DetailedData, FileDetails, LineDetails, PolicyId, PolicyScope, PolicyScopeName
| order by TimeGenerated asc
| take 200
```

#### 7. Correlate WAF and access outcome
```kusto
let rid = "<RESOURCE_ID>";
let transactionId = "<TRANSACTION_ID>";
let fw = AGWFirewallLogs
| where TimeGenerated >= ago(24h) and _ResourceId =~ rid and TransactionId == transactionId
| summarize WafActions=make_set(Action,20), Rules=make_set(RuleId,100),
    WafEvents=count() by TransactionId;
fw
| join kind=leftouter (AGWAccessLogs
 | where TimeGenerated >= ago(24h) and _ResourceId =~ rid and TransactionId == transactionId
 | project TransactionId, AccessTime=TimeGenerated, ClientIp, OriginalHost,
     OriginalRequestUriWithArgs, HttpMethod, HttpStatus, ServerStatus, ErrorInfo,
     ListenerName, BackendPoolName, ServerRouted) on TransactionId
| order by AccessTime desc
| take 200
```

#### 8. Detection-mode tuning candidates
```kusto
let rid = "<RESOURCE_ID>";
AGWFirewallLogs
| where TimeGenerated >= ago(24h) and _ResourceId =~ rid
| where Action in~ ("Matched","Detected") and isnotempty(TransactionId)
| join kind=inner (AGWAccessLogs
 | where TimeGenerated >= ago(24h) and _ResourceId =~ rid
 | where WafMode =~ "Detection" and HttpStatus between (200 .. 399)
 | project TransactionId) on TransactionId
| summarize SuccessfulRequests=dcount(TransactionId)
    by RuleId, Message, Hostname, RequestUri
| where SuccessfulRequests >= 20
| order by SuccessfulRequests desc
| take 50
```

#### 9. Top blocked clients
```kusto
let rid = "<RESOURCE_ID>";
AGWFirewallLogs
| where TimeGenerated >= ago(24h) and _ResourceId =~ rid and Action =~ "Blocked"
| summarize BlockedRequests=dcount(TransactionId), Hosts=dcount(Hostname),
    URIs=dcount(RequestUri), Rules=make_set(RuleId,50) by ClientIp
| top 20 by BlockedRequests desc
```

#### 10. Access status and errors
```kusto
let rid = "<RESOURCE_ID>";
AGWAccessLogs
| where TimeGenerated >= ago(24h) and _ResourceId =~ rid
| summarize Requests=count(), P95TotalMs=1000.0*percentile(TimeTaken,95)
    by HttpStatus, ErrorInfo, ListenerName
| order by Requests desc
```

#### 11. Gateway/backend status divergence
```kusto
let rid = "<RESOURCE_ID>";
AGWAccessLogs
| where TimeGenerated >= ago(24h) and _ResourceId =~ rid
| where HttpStatus >= 400 or ServerStatus >= 400
| summarize Requests=count() by HttpStatus, ServerStatus, ErrorInfo,
    BackendPoolName, BackendSettingName, ServerRouted
| order by Requests desc
```

#### 12. Latency decomposition
```kusto
let rid = "<RESOURCE_ID>";
AGWAccessLogs
| where TimeGenerated >= ago(24h) and _ResourceId =~ rid
| summarize Requests=count(), P95TotalMs=1000.0*percentile(TimeTaken,95),
    P95ConnectMs=1000.0*percentile(ServerConnectTime,95),
    P95HeaderMs=1000.0*percentile(ServerHeaderTime,95),
    P95BackendMs=1000.0*percentile(ServerResponseLatency,95)
    by ListenerName, BackendPoolName, BackendSettingName
| order by P95TotalMs desc
```

#### 13. Client and backend TLS inventory
```kusto
let rid = "<RESOURCE_ID>";
AGWAccessLogs
| where TimeGenerated >= ago(24h) and _ResourceId =~ rid
| summarize Requests=count(), LastSeen=max(TimeGenerated)
    by ListenerName, SslEnabled, SslProtocol, SslCipher,
       BackendSslProtocol, BackendSslCipher, SslClientVerify
| order by Requests desc
```

#### 14. WAF evaluation latency
```kusto
let rid = "<RESOURCE_ID>";
AGWAccessLogs
| where TimeGenerated >= ago(24h) and _ResourceId =~ rid
| summarize Requests=count(),
    P50WafMs=1000.0*percentile(WafEvaluationTime,50),
    P95WafMs=1000.0*percentile(WafEvaluationTime,95),
    P99WafMs=1000.0*percentile(WafEvaluationTime,99)
    by ListenerName, WafMode, WafPolicyId
| order by P95WafMs desc
```

### Application Gateway for Containers

#### 15. Policy scope and action
```kusto
let rid = "<RESOURCE_ID>";
AGCFirewallLogs
| where TimeGenerated >= ago(24h) and _ResourceId =~ rid
| summarize Requests=dcount(TrackingId), Events=count()
    by PolicyId, PolicyScope, PolicyScopeName, Action
| order by Requests desc
```

#### 16. Triggered AGC rules
```kusto
let rid = "<RESOURCE_ID>";
AGCFirewallLogs
| where TimeGenerated >= ago(24h) and _ResourceId =~ rid
| summarize Requests=dcount(TrackingId), Events=count()
    by RuleSetType, RuleSetVersion, RuleId, Message, Action,
       FileDetails, LineDetails
| top 50 by Requests desc
```

#### 17. Host and path hotspots
```kusto
let rid = "<RESOURCE_ID>";
AGCFirewallLogs
| where TimeGenerated >= ago(24h) and _ResourceId =~ rid
| summarize Requests=dcount(TrackingId),
    BlockedRequests=dcountif(TrackingId, Action =~ "Blocked"),
    Rules=make_set(RuleId,50) by Hostname, RequestUri
| top 50 by Requests desc
```

#### 18. AGC firewall-to-access correlation
```kusto
let rid = "<RESOURCE_ID>";
let trackingId = "<TRACKING_ID>";
let fw = AGCFirewallLogs
| where TimeGenerated >= ago(24h) and _ResourceId =~ rid and TrackingId == trackingId
| summarize WafActions=make_set(Action,20), Rules=make_set(RuleId,100),
    WafEvents=count() by TrackingId;
fw
| join kind=leftouter (AGCAccessLogs
 | where TimeGenerated >= ago(24h) and _ResourceId =~ rid and TrackingId == trackingId
 | project TrackingId, AccessTime=TimeGenerated, ClientIp, FrontendName,
     HostName, HttpMethod, RequestUri, HttpStatusCode, BackendHost,
     BackendResponseLatency, TimeTaken) on TrackingId
| order by AccessTime desc
| take 200
```

#### 19. Approved AGC tracking-ID drill-down
```kusto
let rid = "<RESOURCE_ID>";
let trackingId = "<TRACKING_ID>";
union
(AGCAccessLogs
 | where TimeGenerated >= ago(24h) and _ResourceId =~ rid and TrackingId == trackingId
 | project TimeGenerated, RecordType="Access", TrackingId, ClientIp,
     Host=HostName, RequestUri, Action="", RuleId="", Message="",
     HttpStatusCode, BackendHost, TimeTaken),
(AGCFirewallLogs
 | where TimeGenerated >= ago(24h) and _ResourceId =~ rid and TrackingId == trackingId
 | project TimeGenerated, RecordType="Firewall", TrackingId, ClientIp,
     Host=Hostname, RequestUri, Action, RuleId, Message,
     HttpStatusCode=int(null), BackendHost="", TimeTaken=real(null))
| order by TimeGenerated asc
| take 200
```

#### 20. AGC tuning candidates
```kusto
let rid = "<RESOURCE_ID>";
AGCFirewallLogs
| where TimeGenerated >= ago(24h) and _ResourceId =~ rid
| where Action in~ ("Matched","Detected") and isnotempty(TrackingId)
| join kind=inner (AGCAccessLogs
 | where TimeGenerated >= ago(24h) and _ResourceId =~ rid
 | where HttpStatusCode between (200 .. 399)
 | project TrackingId) on TrackingId
| summarize SuccessfulRequests=dcount(TrackingId)
    by RuleId, Message, Hostname, RequestUri, PolicyScopeName
| where SuccessfulRequests >= 20
| order by SuccessfulRequests desc
| take 50
```

#### 21. AGC response and latency
```kusto
let rid = "<RESOURCE_ID>";
AGCAccessLogs
| where TimeGenerated >= ago(24h) and _ResourceId =~ rid
| summarize Requests=count(), P50TotalMs=percentile(TimeTaken,50),
    P95TotalMs=percentile(TimeTaken,95),
    P95BackendFirstByteMs=percentile(BackendResponseLatency,95),
    P95BackendTransferMs=percentile(BackendTimeTaken,95)
    by FrontendName, HttpStatusCode, BackendHost
| order by Requests desc
```

#### 22. AGC TLS inventory
```kusto
let rid = "<RESOURCE_ID>";
AGCAccessLogs
| where TimeGenerated >= ago(24h) and _ResourceId =~ rid
| summarize Requests=count(), LastSeen=max(TimeGenerated)
    by FrontendName, FrontendPort, TlsProtocol, TlsCipher
| order by Requests desc
```

#### 23. AGC top blocked clients
```kusto
let rid = "<RESOURCE_ID>";
AGCFirewallLogs
| where TimeGenerated >= ago(24h) and _ResourceId =~ rid and Action =~ "Blocked"
| summarize BlockedRequests=dcount(TrackingId), Hosts=dcount(Hostname),
    Paths=dcount(RequestUri), Rules=make_set(RuleId,50) by ClientIp
| top 20 by BlockedRequests desc
```

## Metrics and interpretation
For Application Gateway v2 inspect `TotalRequests`, `FailedRequests`,
`ResponseStatus`, backend health/status, total/backend latency, `CapacityUnits`,
`ComputeUnits`, connections, throughput, TLS protocol, and WAF rule/custom/Bot/
JS Challenge metrics. Correlate capacity, latency, health, subnet headroom, and
autoscale; a new instance can take several minutes.

For AGC inspect total/backend response status, healthy targets, connection
timeouts, WAF totals, managed/custom matches, and controller/backend health.
Missing AGC metrics can mean no relevant traffic; AGC always autoscales and
capacity/connection draining can take several minutes.

## Severity, confidence, and report
- **Critical:** confirmed bypass/exploitation, all production backends unavailable,
  disabled listener/certificate failure, or sustained capacity loss with impact.
- **High:** sustained 5xx/unhealthy targets, widespread legitimate WAF blocking,
  imminent certificate expiry, or active-incident telemetry blind spot.
- **Medium:** localized degradation, suspicious traffic, weak TLS, or low headroom.
- **Low:** tuning candidate, expected scale event, or hygiene issue.

High confidence requires control-plane state plus corroborating logs/metrics.
Output scope/window, impact/timeline, telemetry mode/freshness and legacy warning,
WAF posture/findings, backend/routing/TLS/network/capacity findings, AGC findings,
ranked hypotheses/counterevidence, approval-gated remediation/rollback,
verification/alerts, exact queries, redactions, gaps, and references.

## Remediation guidance
- Suggest only; never execute changes from this skill.
- Prefer the narrowest rule or match-variable exclusion; never disable the WAF,
  an entire managed rule set, or a broad rule group to clear a false positive.
- Tune in Detection, validate known-good flows, then stage Prevention with
  monitoring and a rollback plan.
- Fix backend health at the source: probe path/status, host header, SNI,
  certificate trust, timeouts, and capacity before relaxing probe sensitivity.
- Keep TLS 1.2+ with current listener/backend certificates, valid chains, and a
  reachable Key Vault using an authorized managed identity.
- Size the subnet and autoscale bounds for peak plus scaling headroom.
- Migrate diagnostic settings to resource-specific tables through approved
  change control, and never expose raw WAF payloads in tickets.

## References
- Application Gateway monitoring: https://learn.microsoft.com/azure/application-gateway/monitor-application-gateway
- Resource-specific tables: https://learn.microsoft.com/azure/application-gateway/application-gateway-diagnostics
- WAF monitoring: https://learn.microsoft.com/azure/web-application-firewall/ag/application-gateway-waf-metrics
- Backend health: https://learn.microsoft.com/troubleshoot/azure/application-gateway/application-gateway-backend-health-troubleshooting
- TLS: https://learn.microsoft.com/azure/application-gateway/ssl-overview
- AGC diagnostics: https://learn.microsoft.com/azure/application-gateway/for-containers/diagnostics
- App Gateway workbook: https://github.com/Azure/Azure-Network-Security/tree/master/Azure%20WAF/Workbook%20-%20App%20GW%20WAF%20Monitor%20-%20Resource%20Specific
- AGC workbook: https://github.com/Azure/Azure-Network-Security/tree/master/Azure%20WAF/Workbook%20-%20AGC%20WAF%20Triage%20Workbook
