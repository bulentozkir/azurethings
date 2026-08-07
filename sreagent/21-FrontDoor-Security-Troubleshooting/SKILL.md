---
name: azure-front-door-security-troubleshooting
description: >
  Diagnose Azure Front Door Standard/Premium security, WAF, bot, abuse, access,
  origin-health, latency, DNS, TLS, 4xx, 5xx, cache-bypass, and suspicious
  traffic issues. Use Azure Monitor access, WAF, and health-probe logs, WAF
  Monitor Workbook v3, metrics, Resource Graph, and Activity Log evidence.
tools:
  - RunAzCliReadCommands
  - execute_kusto_query
  - AzureMCP/*
  - MicrosoftLearnMCP/*
---

# Azure Front Door Security Troubleshooting

> **Required MCP grounding:** Before conclusions, use `AzureMCP/*` for live Azure evidence and `MicrosoftLearnMCP/*` for current authoritative guidance. If either connector is unavailable, report a blocking evidence gap instead of relying on model memory.
## Purpose
Correlate Front Door Standard/Premium configuration, metrics, access/WAF/probe
logs, Activity Log changes, and origin signals before assigning root cause.
## When to use this skill
- WAF blocks/false positives, bot or brute-force activity, probing, JA4 reuse
- Suspicious paths/geographies, cache abuse, weak TLS, 4xx/5xx or origin incidents
- Origin-bypass, WAF posture, telemetry, routing or Workbook v3 reviews

- KQL targets Standard/Premium `AzureDiagnostics` and validated workspace fields.
- For classic, use its schema and report the March 31, 2027 retirement.
- Compare thresholds with healthy and business-approved baselines.
## Guardrails
- Use read-only Azure MCP, Resource Graph, metrics, Activity Log, and KQL calls.
- Never change WAF/routing/origin/DNS/TLS/monitoring or actively test traffic.
- Mask IPs, JA4, URIs, headers, tracking references, and WAF match details.
- Run payload query 6b only for an approved narrow window; redact all sensitive data.
- Do not label indicators malicious alone; account for NAT, proxies and tests.
- A blocked request proves a WAF action, not successful exploitation.
- Bound raw output to 200 rows; aggregate before projecting sensitive fields.
- Record UTC scope/window, freshness and redactions.
## Pre-check

| Field | Required value |
|-------|----------------|
| Scope/window | Subscription, profile, domains/routes, UTC incident and baseline |
| Design | SKU, origins/groups, probes, host header, timeout, cache and failover |
| WAF | Policy mode/state, DRS/Bot, custom/rate rules, exclusions, associations |
| Traffic | Expected paths, methods, countries, clients, rates and object sizes |
| Evidence | Workspace/categories, freshness/retention, changes, SIEM and owners |
### Step 1: Inventory live Front Door and WAF state
Use Azure MCP/Resource Graph to inventory profiles, endpoints, domains, routes,
origins/groups, security/WAF policies, diagnostics, identity, TLS and health. Verify:
- Branch by SKU: validate DRS, Bot Manager, and Private Link only on Premium;
  assess Standard custom rules without flagging unsupported Premium capabilities.
- WAF is enabled and prevention is used after workload-specific tuning.
- Custom-rule priority, action, rate window, geo logic, and exclusions are narrow.
- Origins reject direct bypass through Private Link or both
  `AzureFrontDoor.Backend` filtering and `X-Azure-FDID` validation.
- Host/SNI/certificate, probe, priority/weight, timeout and affinity match design.
### Step 2: Validate telemetry and schema
Use Azure MCP Monitor workspace/table/log/metric/activity tools. Confirm all three
diagnostic categories target the expected workspace; they are off by default.
Inspect sample rows or `getschema`; missing fields are `Not assessed`, not healthy.

- WAF uses `clientIP_s`; access logs use `clientIp_s`.
- Access-log `timeTaken_d` is measured in seconds. Query 15 uses `> 10`.
- Health-probe latency values are strings and must be cast before comparison.
- Use `trackingReference_s` / `X-Azure-Ref` for end-to-end correlation.

### Step 3: Use WAF Monitor Workbook v3
Use Workbook v3 for WAF logs, rule/action metrics and JS Challenge outcomes,
filtered by workspace/time/type/instance. Do not deploy it without approval.
Record source commit/date and reconcile its normalized actions with raw KQL.

### Step 4: Run the query catalog
Run relevant groups only; add approved time, `ResourceId`, profile and domain
filters. Record duration/rows and retain all limits on raw-feed queries.

## WAF log queries

#### 1. Blocked or anomaly-scored request spike
```kusto
AzureDiagnostics
| where Category == "FrontDoorWebApplicationFirewallLog"
| where TimeGenerated > ago(24h)
| where action_s in~ ("Block", "Blocked", "AnomalyScoring", "logandscore")
| summarize Count = count() by clientIP_s, ruleName_s, action_s, bin(TimeGenerated, 1h)
| where Count > 20
| sort by Count desc
```

#### 2. Top blocked IPs with rule detail
```kusto
AzureDiagnostics
| where Category == "FrontDoorWebApplicationFirewallLog"
| where TimeGenerated > ago(24h)
| where action_s in~ ("Block", "Blocked")
| extend Path = tostring(parse_url(requestUri_s).Path)
| summarize BlockCount = count(), Rules = make_set(ruleName_s, 20) by clientIP_s, Path
| top 50 by BlockCount desc
```

#### 3. Transactions matching three or more distinct WAF rules
```kusto
AzureDiagnostics
| where Category == "FrontDoorWebApplicationFirewallLog"
| where TimeGenerated > ago(24h)
| where isnotempty(trackingReference_s)
| summarize Events = count(), DistinctRules = dcount(ruleName_s),
    Rules = make_set(ruleName_s, 20), Actions = make_set(action_s)
    by trackingReference_s, clientIP_s
| where DistinctRules >= 3
| sort by DistinctRules desc, Events desc
```

#### 4. Detection-mode and custom Log-action exposure
```kusto
AzureDiagnostics
| where Category == "FrontDoorWebApplicationFirewallLog"
| where TimeGenerated > ago(24h)
| where policyMode_s =~ "Detection"
    or (action_s =~ "Log" and isnotempty(ruleName_s) and ruleName_s !startswith "Microsoft_")
| summarize Events = count(), Requests = dcount(trackingReference_s),
    Clients = dcount(clientIP_s) by policy_s, policyMode_s, ruleName_s, action_s
| sort by Requests desc
```

#### 5. Custom-rule outcomes, including configured rate-limit rules
```kusto
AzureDiagnostics
| where Category == "FrontDoorWebApplicationFirewallLog"
| where TimeGenerated > ago(24h)
| where isnotempty(ruleName_s) and ruleName_s !startswith "Microsoft_"
| summarize Events = count(), Requests = dcount(trackingReference_s),
    Clients = dcount(clientIP_s) by policy_s, ruleName_s, action_s
| sort by Events desc
```

#### 6. SQLi, XSS, RCE, LFI, and RFI triggers
```kusto
AzureDiagnostics
| where Category == "FrontDoorWebApplicationFirewallLog"
| where TimeGenerated > ago(24h)
| where ruleName_s has_any ("SQLI", "XSS", "RCE", "LFI", "RFI")
| summarize Count = count() by clientIP_s, ruleName_s, action_s
| sort by Count desc
```

#### 6b. WAF match detail and triggering excerpt
```kusto
AzureDiagnostics
| where Category == "FrontDoorWebApplicationFirewallLog"
| where TimeGenerated > ago(24h)
| where action_s in~ ("Block", "Blocked")
| project TimeGenerated, clientIP_s, ruleName_s, details_matches_s, details_msg_s, details_data_s
| sort by TimeGenerated desc
| take 200
```

## Access log queries

#### 7. Suspicious user-agent or scanner signatures
```kusto
AzureDiagnostics
| where Category == "FrontDoorAccessLog"
| where TimeGenerated > ago(24h)
| where userAgent_s has_any ("sqlmap", "nikto", "nmap", "curl", "python-requests", "masscan", "gobuster", "dirbuster", "wpscan")
| project TimeGenerated, clientIp_s, requestUri_s, userAgent_s, httpStatusCode_d, hostName_s
| sort by TimeGenerated desc
| take 200
```

#### 8. Elevated 4xx/5xx volume and error rate by host
```kusto
AzureDiagnostics
| where Category == "FrontDoorAccessLog"
| where TimeGenerated > ago(1h)
| summarize Requests = count(), Errors = countif(httpStatusCode_d >= 400),
    ServerErrors = countif(httpStatusCode_d >= 500 or httpStatusCode_d == 0)
    by hostName_s, bin(TimeGenerated, 5m)
| extend ErrorRate = 100.0 * Errors / Requests
| where Errors > 50 and ErrorRate > 5
| sort by ErrorRate desc, Errors desc
```

#### 9. Credential stuffing or brute force
```kusto
AzureDiagnostics
| where Category == "FrontDoorAccessLog"
| where TimeGenerated > ago(1h)
| where requestUri_s matches regex @"(?i)/(login|signin|auth|oauth)(/|\?|$)"
| where httpStatusCode_d in (401, 403)
| summarize AttemptCount = count(), DistinctPaths = dcount(requestUri_s) by clientIp_s, bin(TimeGenerated, 15m)
| where AttemptCount > 30
| sort by AttemptCount desc
```

#### 10. Country distribution on sensitive paths
```kusto
AzureDiagnostics
| where Category == "FrontDoorAccessLog"
| where TimeGenerated > ago(24h)
| where requestUri_s matches regex @"(?i)/(admin|api/internal|wp-admin)(/|\?|$)"
    or requestUri_s contains "/.env" or requestUri_s contains "/config"
| extend Path = tostring(parse_url(requestUri_s).Path)
| summarize Requests = count(), Clients = dcount(clientIp_s)
    by clientCountry_s, Path, httpStatusCode_d
| top 100 by Requests desc
```

#### 11. Distributed request pattern that can evade per-IP controls
```kusto
AzureDiagnostics
| where Category == "FrontDoorAccessLog"
| where TimeGenerated > ago(1h)
| extend Path = tostring(parse_url(requestUri_s).Path)
| summarize DistinctIPs = dcount(clientIp_s), TotalRequests = count() by Path, userAgent_s
| where DistinctIPs > 100 and TotalRequests > 500
| sort by TotalRequests desc
```

#### 12. Unusual HTTP methods
```kusto
AzureDiagnostics
| where Category == "FrontDoorAccessLog"
| where TimeGenerated > ago(24h)
| where httpMethod_s !in ("GET", "POST", "HEAD", "OPTIONS")
| extend Path = tostring(parse_url(requestUri_s).Path)
| summarize Count = count(), Clients = dcount(clientIp_s) by httpMethod_s, Path
| sort by Count desc
```

#### 13. Path traversal or directory enumeration
```kusto
AzureDiagnostics
| where Category == "FrontDoorAccessLog"
| where TimeGenerated > ago(24h)
| where requestUri_s contains "../"
    or requestUri_s contains "..%2f"
    or requestUri_s contains "%2e%2e"
    or requestUri_s contains "/etc/passwd"
    or requestUri_s contains "\\windows\\system32"
| project TimeGenerated, clientIp_s, requestUri_s, httpStatusCode_d
| sort by TimeGenerated desc
| take 200
```

#### 14. Query-string churn with cache-miss evidence
```kusto
AzureDiagnostics
| where Category == "FrontDoorAccessLog"
| where TimeGenerated > ago(1h)
| extend Path = tostring(parse_url(requestUri_s).Path),
    Query = extract(@"\?(.*)$", 1, requestUri_s)
| where isnotempty(Query)
| summarize DistinctQueries = dcount(Query), Requests = count(),
    OriginTrips = countif(cacheStatus_s in~ ("MISS", "CACHE_NOCONFIG", "PRIVATE_NOSTORE"))
    by clientIp_s, Path
| where DistinctQueries > 200 and OriginTrips > 100
| sort by OriginTrips desc
```

#### 15. Slow-response concentration by client
`timeTaken_d` is seconds, so `P95Latency > 10` is a p95 above 10 seconds.
```kusto
AzureDiagnostics
| where Category == "FrontDoorAccessLog"
| where TimeGenerated > ago(1h)
| where isnotempty(timeTaken_d)
| summarize AvgLatency = avg(timeTaken_d), P95Latency = percentile(timeTaken_d, 95),
    Count = count() by clientIp_s, hostName_s
| where P95Latency > 10 and Count > 20
| sort by P95Latency desc
```

#### 16. Large response or possible exfiltration pattern
```kusto
AzureDiagnostics
| where Category == "FrontDoorAccessLog"
| where TimeGenerated > ago(24h)
| where sentBytes_d > 50000000 and httpStatusCode_d between (200 .. 299)
| extend Path = tostring(parse_url(requestUri_s).Path)
| project TimeGenerated, clientIp_s, Path, sentBytes_d, httpStatusCode_d
| sort by sentBytes_d desc
| take 200
```

## Health probe log queries

#### 17. Origin failures by result type
```kusto
AzureDiagnostics
| where Category == "FrontDoorHealthProbeLog"
| where TimeGenerated > ago(24h)
| where isnotempty(result_s) and result_s !~ "Success"
| extend LatencyMs = toreal(totalLatencyMilliseconds_s)
| summarize FailureCount = count(), AvgLatencyMs = avg(LatencyMs)
    by originName_s, pop_s, result_s, httpStatusCode_s
| sort by FailureCount desc
```

#### 18. Recent origin health failures
```kusto
AzureDiagnostics
| where Category == "FrontDoorHealthProbeLog"
| where TimeGenerated > ago(1h)
| where isnotempty(result_s) and result_s !~ "Success"
| project TimeGenerated, originName_s, pop_s, result_s, httpStatusCode_s, totalLatencyMilliseconds_s
| sort by TimeGenerated desc
| take 200
```

#### 19. DNS latency anomaly on health probes
```kusto
AzureDiagnostics
| where Category == "FrontDoorHealthProbeLog"
| where TimeGenerated > ago(24h)
| extend DNSLatencyMicroseconds = toreal(DNSLatencyMicroseconds_s)
| where DNSLatencyMicroseconds > 500000
| project TimeGenerated, originName_s, pop_s, DNSLatencyMicroseconds, result_s
| sort by DNSLatencyMicroseconds desc
| take 200
```

## Cross-category correlation queries

#### 20. WAF-logged request followed by a 5xx
```kusto
AzureDiagnostics
| where Category == "FrontDoorAccessLog"
| where TimeGenerated > ago(24h) and isnotempty(trackingReference_s)
| where httpStatusCode_d == 0 or httpStatusCode_d >= 500
| join kind=inner (
    AzureDiagnostics
    | where Category == "FrontDoorWebApplicationFirewallLog"
    | where TimeGenerated > ago(24h) and isnotempty(trackingReference_s)
    | where action_s in~ ("Log", "AnomalyScoring", "logandscore")
    | summarize arg_max(TimeGenerated, ruleName_s) by trackingReference_s
) on $left.trackingReference_s == $right.trackingReference_s
| project TimeGenerated, clientIp_s, requestUri_s, ruleName_s, httpStatusCode_d
| sort by TimeGenerated desc
| take 200
```

#### 21. TLS JA4 fingerprint reuse across rotating IPs
```kusto
AzureDiagnostics
| where Category == "FrontDoorAccessLog"
| where TimeGenerated > ago(6h)
| extend LegacyJA4 = tostring(column_ifexists("clientJA4FingerPrint_s", "")),
    CurrentJA4 = tostring(column_ifexists("sslJA4_s", ""))
| extend JA4 = iff(isnotempty(LegacyJA4), LegacyJA4, CurrentJA4)
| where isnotempty(JA4)
| summarize DistinctIPs = dcount(clientIp_s), RequestCount = count()
    by JA4Hash = hash_sha256(JA4)
| where DistinctIPs > 10
| sort by DistinctIPs desc
| take 200
```

#### 22. Observed diagnostic activity and freshness
```kusto
let Expected = datatable(Category:string)
    ["FrontDoorAccessLog", "FrontDoorWebApplicationFirewallLog", "FrontDoorHealthProbeLog"];
Expected
| join kind=leftouter (
    AzureDiagnostics
    | where TimeGenerated > ago(7d)
    | summarize Events24h = countif(TimeGenerated > ago(24h)),
        LastEvent = max(TimeGenerated),
        Resources = dcount(ResourceId) by Category
) on Category
| extend Interpretation = case(Events24h > 0, "Observed",
    Category == "FrontDoorAccessLog", "Verify diagnostics or expected traffic",
    "No matching events; verify diagnostics, but this can be healthy")
| project Category, Events24h = coalesce(Events24h, 0), Resources, LastEvent,
    IngestionLagMinutes = datetime_diff("minute", now(), LastEvent), Interpretation
```

#### 23. WAF action anomaly against a 14-day hourly baseline
```kusto
AzureDiagnostics
| where Category == "FrontDoorWebApplicationFirewallLog"
| where TimeGenerated > ago(14d)
| where action_s in~ ("Block", "Blocked", "AnomalyScoring", "logandscore")
| make-series Events = count() default=0 on TimeGenerated
    from ago(14d) to now() step 1h by policy_s, action_s
| extend (Anomaly, Score, Baseline) = series_decompose_anomalies(Events, 3.0, -1, "linefit")
| mv-expand TimeGenerated to typeof(datetime), Events to typeof(long),
    Baseline to typeof(real), Anomaly to typeof(long), Score to typeof(real)
| where TimeGenerated > ago(24h) and Anomaly != 0
| project TimeGenerated, policy_s, action_s, Events, Baseline, Score
```

#### 24. JavaScript Challenge outcomes
```kusto
AzureDiagnostics
| where Category == "FrontDoorWebApplicationFirewallLog"
| where TimeGenerated > ago(24h)
| where action_s startswith "JSChallenge" or action_s contains "JS Challenge"
| summarize Events = count(), Requests = dcount(trackingReference_s),
    Clients = dcount(clientIP_s) by policy_s, ruleName_s, action_s
| sort by Events desc
```

#### 25. Front Door and origin error attribution
```kusto
AzureDiagnostics
| where Category == "FrontDoorAccessLog"
| where TimeGenerated > ago(1h)
| where httpStatusCode_d == 0 or httpStatusCode_d >= 500
    or errorInfo_s !in~ ("", "NoError")
| summarize Requests = count(), Clients = dcount(clientIp_s),
    P95Seconds = percentile(timeTaken_d, 95)
    by hostName_s, originName_s, errorInfo_s, httpStatusCode_d,
       bin(TimeGenerated, 5m)
| sort by Requests desc
```

#### 26. Deprecated client TLS protocols
```kusto
AzureDiagnostics
| where Category == "FrontDoorAccessLog"
| where TimeGenerated > ago(24h)
| where securityProtocol_s in~ ("SSLv3", "TLSv1", "TLSv1.1")
| summarize Requests = count(), Clients = dcount(clientIp_s)
    by hostName_s, securityProtocol_s, bin(TimeGenerated, 1h)
| sort by Requests desc
```

#### 27. WAF Log/anomaly events that returned success
```kusto
let WafSignals = AzureDiagnostics
| where Category == "FrontDoorWebApplicationFirewallLog"
| where TimeGenerated > ago(24h) and isnotempty(trackingReference_s)
| where action_s in~ ("Log", "AnomalyScoring", "logandscore")
| project trackingReference_s, WafRule = ruleName_s;
AzureDiagnostics
| where Category == "FrontDoorAccessLog"
| where TimeGenerated > ago(24h) and isnotempty(trackingReference_s)
| where httpStatusCode_d between (200 .. 299)
| extend Path = tostring(parse_url(requestUri_s).Path)
| join kind=inner WafSignals on trackingReference_s
| summarize Requests = dcount(trackingReference_s), Clients = dcount(clientIp_s),
    Rules = make_set(WafRule, 20) by hostName_s, Path, httpStatusCode_d
| top 100 by Requests desc
```

#### 28. Attribute 403 responses to WAF or non-WAF sources
```kusto
let WafBlocks = AzureDiagnostics
| where Category == "FrontDoorWebApplicationFirewallLog"
| where TimeGenerated > ago(24h) and isnotempty(trackingReference_s)
| where action_s in~ ("Block", "Blocked")
| distinct WafRef = trackingReference_s;
AzureDiagnostics
| where Category == "FrontDoorAccessLog"
| where TimeGenerated > ago(24h) and httpStatusCode_d == 403
| join kind=leftouter WafBlocks on $left.trackingReference_s == $right.WafRef
| extend Source = iff(isnotempty(WafRef), "WAF", "Non-WAF or unknown")
| summarize Responses = count(), Clients = dcount(clientIp_s)
    by hostName_s, Source, bin(TimeGenerated, 15m)
| sort by Responses desc
```

### Step 5: Correlate and test hypotheses
Join WAF/access/origin evidence with `trackingReference_s` and `X-Azure-Ref`.
Corroborate attacks with application/SIEM evidence, false positives with known-good
transactions, bot abuse with identity/baseline data, and origin failures with
multi-PoP probes, metrics, DNS/TLS, Activity Log, Resource Health and Service Health.
Separate edge, WAF, route/cache, origin and application behavior on one timeline.

### Step 6: Rank and report
Use **Critical** for confirmed exploitation/data exposure, origin bypass, or broad
security outage; **High** for impactful attacks/prevention gaps/repeated origin
failure; **Medium** for suspicious or degraded behavior; **Low** for weak signals.
High confidence requires two independent sources and no material counterevidence.
Stale/missing telemetry is `Not assessed`.

Output an **Azure Front Door Security Troubleshooting Report** with scope/window,
WAF and telemetry posture, Workbook version/filters, user impact, timeline,
query/metric findings, ranked hypotheses and counterevidence, approval-gated
containment, durable remediation/rollback, verification/alerts, and evidence gaps.
Each finding includes masked indicators, rule/action, route/origin/PoP, baseline,
impact, severity, confidence, owner, evidence and next validation.

## Remediation guidance
- Suggest only; never execute changes from this skill.
- Prefer narrow exclusions; never disable WAF, a full rule set, or broad rule group.
- Tune in Detection, validate flows, then stage Prevention with rollback.
- Set bot/rate/JS/geo controls only after NAT, baselines and business traffic review.
- Use Private Link or `AzureFrontDoor.Backend` plus `X-Azure-FDID` for origins.
- Validate probe/DNS/SNI/certificate/host/timeout/capacity before changing health.
- Use approved log scrubbing, retention, alerting and SIEM change control.
- Migrate Front Door classic before March 31, 2027.

## References
- Front Door monitoring: https://learn.microsoft.com/azure/frontdoor/monitor-front-door
- Monitoring reference: https://learn.microsoft.com/azure/frontdoor/monitor-front-door-reference
- WAF monitoring: https://learn.microsoft.com/azure/web-application-firewall/afds/waf-front-door-monitor
- WAF tuning: https://learn.microsoft.com/azure/web-application-firewall/afds/waf-front-door-tuning
- Secure origins: https://learn.microsoft.com/azure/frontdoor/origin-security
- WAF Workbook v3: https://github.com/Azure/Azure-Network-Security/tree/master/Azure%20WAF/Workbook%20-%20WAF%20Monitor%20Workbook
