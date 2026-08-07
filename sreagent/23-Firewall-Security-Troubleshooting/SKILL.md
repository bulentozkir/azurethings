---
name: azure-firewall-security-troubleshooting
description: >
  Diagnose Azure Firewall Standard/Premium security, connectivity, rules, DNAT,
  threat intelligence, IDPS, TLS inspection, DNS proxy, SNAT, latency, capacity,
  forced tunneling, flow trace, and policy issues using resource-specific logs,
  Azure Monitor, Azure MCP, Microsoft Learn, and verified repository queries.
tools:
  - RunAzCliReadCommands
  - execute_kusto_query
  - AzureMCP/*
  - MicrosoftLearnMCP/*
---

# Azure Firewall Security Troubleshooting

> **Required MCP grounding:** Before conclusions, use `AzureMCP/*` for live Azure evidence and `MicrosoftLearnMCP/*` for current authoritative guidance. If either connector is unavailable, report a blocking evidence gap instead of relying on model memory.

## Purpose
Run a read-only investigation across Azure Firewall, Firewall Policy, rules,
routes, DNS, TLS, threat intelligence, IDPS, SNAT, metrics, health, diagnostics,
and network topology. Correlate control-plane state with typed telemetry before
assigning security, routing, availability, or performance root cause.

## Resource-specific logging requirement
Prefer all applicable dedicated tables:

`AZFWNetworkRule`, `AZFWApplicationRule`, `AZFWNatRule`, `AZFWThreatIntel`,
`AZFWIdpsSignature`, `AZFWDnsQuery`, `AZFWInternalFqdnResolutionFailure`,
`AZFWDnsFlowTrace`, `AZFWFlowTrace`, `AZFWFatFlow`,
`AZFWNetworkRuleAggregation`, `AZFWApplicationRuleAggregation`, and
`AZFWNatRuleAggregation`.

Warn when current diagnostic settings use legacy `AzureDiagnostics` instead of
`logAnalyticsDestinationType: Dedicated`. Legacy mode uses free-form `msg_s` and
does not cover all newer Premium/diagnostic categories. Initial dedicated-table
population can take about 30 minutes. Metrics exported to Log Analytics still
land in `AzureMetrics`; this is separate from the log table mode. Empty tables
are `Not observable` until settings, scope, plan, retention, and ingestion are
validated. Policy Analytics and Security Copilot require Analytics-plan tables.
Cross-table queries 1, 2, 3, 5, 9, 10, and 22 require Analytics-plan inputs.
For Basic/Auxiliary plans, run bounded single-table variants instead of joins or
multi-table unions and state the resulting correlation gap.

## Guardrails
- Use only read-only Azure MCP, Resource Graph, Monitor, Activity Log, and KQL.
- Do not change policies, rules, IP groups, routes, DNS, certificates,
  diagnostics, tables, alerts, or firewall allocation.
- Never enable flow trace, DNS flow trace, or fat-flow logs automatically; these
  are configuration changes and can add cost or CPU overhead.
- Do not run connection tests, test threat-intelligence domains, packet
  generation, route bypasses, or TLS probes without explicit authorization.
- Bound every query by resource/time, cap raw results, and mask IPs, URLs,
  certificate identifiers, payloads, and caller identities in distributed reports.
- Rule events are not packets/bytes. Denies can be intended. A TI/IDPS record
  must retain its actual mode/action; event count alone never proves compromise.
- Use UTC and record resource/workspace, query window, table plan/freshness,
  repository commit/date, gaps, assumptions, and redactions.

## Pre-check

| Field | Required value |
|-------|----------------|
| Scope | Firewall, policy hierarchy, rule collection groups, VNets and routes |
| Incident | UTC window, healthy baseline, impact, source/destination/port |
| SKU/features | Standard/Premium, TI, IDPS, TLS, DNS proxy, forced tunneling |
| Topology | Hub/spokes, peering, UDR/BGP, management NIC, public IP/NAT Gateway |
| Capacity | Zones, instances/capacity, throughput, connections, SNAT design |
| Telemetry | Diagnostic mode/categories, workspace, plans, retention, freshness |
| Changes | Firewall/policy/rule/route/DNS/certificate/deployment Activity Log |

## Investigation procedure

### Step 1: Inventory configuration and health
Use Azure MCP/Resource Graph to inspect provisioning/resource health, SKU, zones,
policy/parent policy, threat-intelligence mode, IDPS mode/overrides/bypass/private
ranges, DNS proxy/upstreams, TLS inspection certificate/identity, SNAT private
ranges, Policy Analytics, rule priorities/actions, IP configurations, public IPs,
management NIC, `AzureFirewallSubnet`, routes, peerings, NSGs, and recent changes.

Validate rule processing: threat intelligence, then **DNAT -> network ->
application**, parent policy before child, with terminating matches. Application
rules don't filter inbound flows. Forced tunneling needs management separation;
Internet DNAT is unsupported in asymmetric forced-tunnel designs.

### Step 2: Validate telemetry and metrics
Use Azure MCP Monitor tools and current table schemas before running KQL. Query
metrics `FirewallHealth`, `SNATPortUtilization`, `FirewallLatencyPng`,
`ObservedCapacity`, `Throughput`, `DataProcessed`, `NetworkRuleHit`, and
`ApplicationRuleHit`. SNAT above 95% is exhausted and can cause intermittent new
connection failure. Treat health 0%, latency spikes, or missing metrics in context;
correlate health, capacity, throughput, connection rate, Resource/Service Health.
Query `Throughput` through Azure MCP Metrics because it isn't exported to
`AzureMetrics`.

### Step 3: Use repository knowledge safely
Use the Azure Network Security resource-specific workbook and alert ideas, but
prefer Microsoft Learn schemas. The repository predates newer DNS/internal FQDN/
flow/fat-flow/aggregation tables, and several legacy alerts have window, parsing,
join, or severity defects. The corrected catalog below preserves valuable intent.

## Verified query catalog
Replace `<firewall-resource-id>` before execution. Use narrower windows where
possible and mask indicators outside the incident team.

#### 1. Telemetry coverage and freshness
```kusto
let FirewallId=tolower("<firewall-resource-id>");
union isfuzzy=true withsource=TableName
 AZFWNetworkRule, AZFWApplicationRule, AZFWNatRule, AZFWThreatIntel,
 AZFWIdpsSignature, AZFWDnsQuery, AZFWInternalFqdnResolutionFailure,
 AZFWDnsFlowTrace, AZFWFlowTrace, AZFWFatFlow, AZFWNetworkRuleAggregation,
 AZFWApplicationRuleAggregation, AZFWNatRuleAggregation
| where tolower(_ResourceId)==FirewallId and TimeGenerated>ago(24h)
| summarize Rows=count(), First=min(TimeGenerated), Last=max(TimeGenerated) by TableName
| order by Last desc
```

#### 2. Unified recent network/application decisions
```kusto
let FirewallId=tolower("<firewall-resource-id>");
let N=AZFWNetworkRule
| where TimeGenerated>ago(1h) and tolower(_ResourceId)==FirewallId
| project TimeGenerated,Kind="Network",Action,ActionReason,SourceIp,SourcePort,
 Destination=DestinationIp,DestinationPort,Protocol,RuleCollectionGroup,RuleCollection,Rule;
let A=AZFWApplicationRule
| where TimeGenerated>ago(1h) and tolower(_ResourceId)==FirewallId
| project TimeGenerated,Kind="Application",Action,ActionReason,SourceIp,SourcePort,
 Destination=coalesce(TargetUrl,Fqdn),DestinationPort,Protocol,RuleCollectionGroup,RuleCollection,Rule;
union N,A | order by TimeGenerated desc | take 200
```

#### 3. Default-action denies
```kusto
let FirewallId=tolower("<firewall-resource-id>");
union AZFWNetworkRule, AZFWApplicationRule
| where TimeGenerated>ago(24h) and tolower(_ResourceId)==FirewallId
| where Action=~"Deny" and ActionReason=~"Default Action"
| summarize Hits=count(),Sources=dcount(SourceIp) by Type,bin(TimeGenerated,15m)
| order by TimeGenerated desc
```

#### 4. Top denied application destinations
```kusto
let FirewallId=tolower("<firewall-resource-id>");
AZFWApplicationRule
| where TimeGenerated>ago(24h) and tolower(_ResourceId)==FirewallId and Action=~"Deny"
| summarize Hits=count(),Sources=dcount(SourceIp),LastSeen=max(TimeGenerated)
 by Fqdn,TargetUrl,WebCategory,RuleCollectionGroup,RuleCollection,Rule
| top 50 by Hits desc
```

#### 5. Rule usage and age
```kusto
let FirewallId=tolower("<firewall-resource-id>");
union AZFWNetworkRule, AZFWApplicationRule
| where TimeGenerated>ago(30d) and tolower(_ResourceId)==FirewallId
| summarize Hits=count(),LastHit=max(TimeGenerated)
 by Type,Policy,RuleCollectionGroup,RuleCollection,Rule,Action
| extend AgeSinceLastHit=now()-LastHit
| order by Hits asc
| take 200
```

#### 6. Top denied network tuples
```kusto
let FirewallId=tolower("<firewall-resource-id>");
AZFWNetworkRule
| where TimeGenerated>ago(24h) and tolower(_ResourceId)==FirewallId and Action=~"Deny"
| summarize Hits=count(),FirstSeen=min(TimeGenerated),LastSeen=max(TimeGenerated)
 by SourceIp,DestinationIp,DestinationPort,Protocol,ActionReason,
    RuleCollectionGroup,RuleCollection,Rule
| top 100 by Hits desc
```

#### 7. Port scan: many ports on one host
```kusto
let FirewallId=tolower("<firewall-resource-id>");
AZFWNetworkRule
| where TimeGenerated>ago(1h) and tolower(_ResourceId)==FirewallId
| where DestinationPort !in (80,443)
| summarize Ports=dcount(DestinationPort),PortSample=make_set(DestinationPort,100),
 Hits=count() by SourceIp,DestinationIp,bin(TimeGenerated,30s)
| where Ports>=100
| order by Ports desc
| take 100
```

#### 8. Port sweep: one port across many hosts
```kusto
let FirewallId=tolower("<firewall-resource-id>");
AZFWNetworkRule
| where TimeGenerated>ago(1h) and tolower(_ResourceId)==FirewallId
| where DestinationPort !in (80,443)
| summarize Hosts=dcount(DestinationIp),HostSample=make_set(DestinationIp,100),
 Hits=count() by SourceIp,DestinationPort,Protocol,bin(TimeGenerated,30s)
| where Hosts>=200
| order by Hosts desc
| take 100
```

#### 9. Abnormal deny rate by source
```kusto
let FirewallId=tolower("<firewall-resource-id>");
let D=union AZFWNetworkRule,AZFWApplicationRule
| where tolower(_ResourceId)==FirewallId and Action=~"Deny";
let B=D | where TimeGenerated between (ago(6d)..ago(1h))
| summarize Hits=count() by SourceIp,bin(TimeGenerated,1h)
| summarize Avg=avg(Hits),Std=stdev(Hits),Buckets=count() by SourceIp
| where Buckets>=5;
D | where TimeGenerated>ago(1h)
| summarize CurrentHits=count() by SourceIp
| join kind=leftouter B on SourceIp
| extend Threshold=max_of(coalesce(Avg,0.0)+3.0*coalesce(Std,0.0),5.0)
| where CurrentHits>Threshold
| order by CurrentHits desc
| take 100
```

#### 10. First-seen source/destination/port/protocol tuple
```kusto
let FirewallId=tolower("<firewall-resource-id>");
let T=union
 (AZFWNetworkRule | project TimeGenerated,_ResourceId,SourceIp,
  Destination=DestinationIp,DestinationPort,Protocol),
 (AZFWApplicationRule | project TimeGenerated,_ResourceId,SourceIp,
  Destination=coalesce(TargetUrl,Fqdn),DestinationPort,Protocol)
| where tolower(_ResourceId)==FirewallId;
let H=T | where TimeGenerated between (ago(7d)..ago(1h))
| distinct SourceIp,Destination,DestinationPort,Protocol;
T | where TimeGenerated>ago(1h)
| distinct SourceIp,Destination,DestinationPort,Protocol
| join kind=leftanti H on SourceIp,Destination,DestinationPort,Protocol
| take 200
```

#### 11. Distributed fan-in heuristic
```kusto
let FirewallId=tolower("<firewall-resource-id>");
AZFWNetworkRule
| where TimeGenerated>ago(5m) and tolower(_ResourceId)==FirewallId
| where isnotempty(SourceIp) and isnotempty(DestinationIp)
| summarize Events=count(),Sources=dcount(SourceIp),Protocols=dcount(Protocol),
 Allowed=countif(Action=~"Allow"),Denied=countif(Action=~"Deny")
 by DestinationIp
| where Events>=500 and Sources>=50 and Protocols>=2
| order by Events desc
| take 100
```

#### 12. DNAT matches and translated targets
```kusto
let FirewallId=tolower("<firewall-resource-id>");
AZFWNatRule
| where TimeGenerated>ago(24h) and tolower(_ResourceId)==FirewallId
| summarize Matches=count(),Sources=dcount(SourceIp),LastSeen=max(TimeGenerated)
 by DestinationIp,DestinationPort,TranslatedIp,TranslatedPort,Protocol,
    RuleCollectionGroup,RuleCollection,Rule
| order by Matches desc
| take 100
```

#### 13. Threat intelligence affecting multiple sources
```kusto
let FirewallId=tolower("<firewall-resource-id>");
AZFWThreatIntel
| where TimeGenerated>ago(24h) and tolower(_ResourceId)==FirewallId
| extend Indicator=coalesce(TargetUrl,Fqdn,DestinationIp)
| summarize Hits=count(),AffectedSources=dcount(SourceIp),
 Actions=make_set(Action,10),Descriptions=make_set(ThreatDescription,10) by Indicator
| where AffectedSources>=2
| order by AffectedSources desc,Hits desc
| take 100
```

#### 14. High-severity IDPS events
```kusto
let FirewallId=tolower("<firewall-resource-id>");
AZFWIdpsSignature
| where TimeGenerated>ago(24h) and tolower(_ResourceId)==FirewallId and Severity==1
| summarize Hits=count(),FirstSeen=min(TimeGenerated),LastSeen=max(TimeGenerated),
 Sources=dcount(SourceIp),Destinations=dcount(DestinationIp),Actions=make_set(Action,10)
 by SignatureId,Category,Description
| order by Hits desc
| take 100
```

#### 15. IDPS action/severity/signature distribution
```kusto
let FirewallId=tolower("<firewall-resource-id>");
AZFWIdpsSignature
| where TimeGenerated>ago(24h) and tolower(_ResourceId)==FirewallId
| summarize Hits=count(),Sources=dcount(SourceIp),Destinations=dcount(DestinationIp)
 by Severity,Action,Category,SignatureId,Description
| order by Severity asc,Hits desc
| take 200
```

#### 16. TLS inspection coverage
```kusto
let FirewallId=tolower("<firewall-resource-id>");
AZFWApplicationRule
| where TimeGenerated>ago(24h) and tolower(_ResourceId)==FirewallId and Protocol=~"HTTPS"
| summarize Hits=count(),Sources=dcount(SourceIp)
 by IsTlsInspected,Action,RuleCollectionGroup,RuleCollection,Rule
| order by Hits desc
| take 100
```

#### 17. DNS errors and latency
```kusto
let FirewallId=tolower("<firewall-resource-id>");
AZFWDnsQuery
| where TimeGenerated>ago(24h) and tolower(_ResourceId)==FirewallId
| extend DurationMs=1000.0*RequestDurationSecs
| summarize Queries=count(),
 Failures=countif(ErrorNumber!=0 or ResponseCode !in~ ("","NOERROR")),
 P50Ms=percentile(DurationMs,50),P95Ms=percentile(DurationMs,95),MaxMs=max(DurationMs)
 by QueryName,QueryType,ResponseCode,ErrorNumber,ErrorMessage
| where Failures>0 or P95Ms>1000
| order by Failures desc,P95Ms desc
| take 100
```

#### 18. Internal FQDN resolution failures
```kusto
let FirewallId=tolower("<firewall-resource-id>");
AZFWInternalFqdnResolutionFailure
| where TimeGenerated>ago(24h) and tolower(_ResourceId)==FirewallId
| summarize Failures=count(),FirstSeen=min(TimeGenerated),LastSeen=max(TimeGenerated)
 by Fqdn,Error,ServerIp,ServerPort,Policy,RuleCollectionGroup,RuleCollection,Rule
| order by Failures desc
| take 100
```

#### 19. DNS flow stage distribution
```kusto
let FirewallId=tolower("<firewall-resource-id>");
AZFWDnsFlowTrace
| where TimeGenerated>ago(1h) and tolower(_ResourceId)==FirewallId
| summarize Events=count(),Sources=dcount(SourceIp),
 UpstreamServers=make_set(ServerIp,10)
 by MsgType,Protocol,bin(TimeGenerated,5m)
| order by TimeGenerated desc,Events desc
| take 200
```

#### 20. TCP resets and invalid flows
```kusto
let FirewallId=tolower("<firewall-resource-id>");
AZFWFlowTrace
| where TimeGenerated>ago(1h) and tolower(_ResourceId)==FirewallId
| where Flag in~ ("RST","INVALID")
| summarize Events=count(),Reasons=make_set(ActionReason,20),Actions=make_set(Action,10)
 by Flag,SourceIp,SourcePort,DestinationIp,DestinationPort,Protocol
| order by Events desc
| take 200
```

#### 21. Top throughput flows
```kusto
let FirewallId=tolower("<firewall-resource-id>");
AZFWFatFlow
| where TimeGenerated>ago(1h) and tolower(_ResourceId)==FirewallId and FlowRate>=5.0
| summarize MaxMbps=max(FlowRate),AvgMbps=avg(FlowRate),Samples=count()
 by SourceIp,SourcePort,DestinationIp,DestinationPort,Protocol
| top 50 by MaxMbps desc
```

#### 22. Policy Analytics low-use rules
```kusto
let FirewallId=tolower("<firewall-resource-id>");
let A=AZFWApplicationRuleAggregation
| where TimeGenerated>ago(30d) and tolower(_ResourceId)==FirewallId
| summarize Hits=sum(ApplicationRuleCount),LastHit=max(TimeGenerated)
 by Kind="Application",Policy,RuleCollectionGroup,RuleCollection,Rule,Action;
let N=AZFWNetworkRuleAggregation
| where TimeGenerated>ago(30d) and tolower(_ResourceId)==FirewallId
| summarize Hits=sum(NetworkRuleCount),LastHit=max(TimeGenerated)
 by Kind="Network",Policy,RuleCollectionGroup,RuleCollection,Rule,Action;
let D=AZFWNatRuleAggregation
| where TimeGenerated>ago(30d) and tolower(_ResourceId)==FirewallId
| summarize Hits=sum(NatRuleCount),LastHit=max(TimeGenerated)
 by Kind="NAT",Policy,RuleCollectionGroup,RuleCollection,Rule | extend Action="DNAT";
union A,N,D | where Hits<=10 | order by Hits asc
| take 200
```

#### 23. Critical platform metrics
```kusto
let FirewallId=tolower("<firewall-resource-id>");
AzureMetrics
| where TimeGenerated>ago(6h) and tolower(ResourceId)==FirewallId
| where MetricName in ("FirewallHealth","SNATPortUtilization","FirewallLatencyPng",
 "ObservedCapacity","DataProcessed","NetworkRuleHit","ApplicationRuleHit")
| summarize Avg=avg(Average),Max=max(Maximum),Total=sum(Total)
 by MetricName,UnitName,bin(TimeGenerated,5m)
| order by TimeGenerated desc
```

#### 24. Missing health metric publication
```kusto
let FirewallId=tolower("<firewall-resource-id>");
AzureMetrics
| where TimeGenerated>ago(1h) and tolower(ResourceId)==FirewallId
| where MetricName=="FirewallHealth"
| summarize LastMetric=max(TimeGenerated)
| extend MinutesSinceMetric=datetime_diff("minute",now(),LastMetric)
| where isnull(LastMetric) or MinutesSinceMetric>15
```

#### 25. Control-plane activity
```kusto
let FirewallId=tolower("<firewall-resource-id>");
let PolicyId=tolower("<firewall-policy-resource-id>");
let ParentPolicyId=tolower("<parent-policy-resource-id-or-empty>");
AzureActivity
| where TimeGenerated>ago(7d)
| where tolower(ResourceId)==FirewallId
    or tolower(ResourceId) startswith PolicyId
    or (isnotempty(ParentPolicyId) and tolower(ResourceId) startswith ParentPolicyId)
| where ActivityStatusValue !~ "Started"
| project TimeGenerated,OperationNameValue,ActivityStatusValue,
 CallerHash=hash_sha256(tostring(Caller)),ResourceId,CorrelationId
| order by TimeGenerated desc
| take 200
```

#### 26. Resource Graph configuration summary
```kusto
Resources
| where type=~"microsoft.network/azurefirewalls"
| where id=~"<firewall-resource-id>"
| extend Tier=tostring(properties.sku.tier),
 ProvisioningState=tostring(properties.provisioningState),
 FirewallPolicy=tostring(properties.firewallPolicy.id),
 ManagementNicEnabled=isnotempty(tostring(properties.managementIpConfiguration.id)),
 IpConfigurationCount=array_length(properties.ipConfigurations)
| project id,name,resourceGroup,subscriptionId,location,zones,Tier,
 ProvisioningState,FirewallPolicy,ManagementNicEnabled,IpConfigurationCount
```

## Interpretation and report
- `Severity=1` is IDPS **High**; preserve `Action` because Alert and Deny differ.
- `AZFWNatRule` contains successful DNAT matches, not every attempted inbound flow.
- Empty `TargetUrl` on uninspected HTTPS is expected.
- DNS cache hits can have only client query/response stages.
- Flow trace excludes application-rule traffic; `INVALID` can have benign causes.
- `FlowRate` is sampled Mbps, not bytes. Enable fat/flow traces only temporarily.
- Policy Analytics begins after enablement and cannot prove a rule is safe to delete.
- Forced tunneling/asymmetry can resemble rule denial or firewall failure.

Use **Critical** for confirmed compromise/outage or SNAT exhaustion with failed
connections; **High** for repeated Severity-1 IDPS, outbound TI tied to a workload,
sustained SNAT >=95%, broad unauthorized allow, or impactful latency/capacity;
**Medium** for anomalous denies/DNS/resets, TLS gaps, or drift; **Low** for isolated
scans, expected denies, low-use rules, or temporary gaps. High confidence needs
two independent sources. Never elevate solely on event count.

Report scope/window/workspace/plans, data coverage and legacy warning, impact,
ranked findings with severity/confidence/evidence/caveats/owner, rule/TI/IDPS/TLS/
DNS analysis, health/SNAT/capacity/latency/flow analysis, topology/change findings,
approval-gated remediation/rollback, verification, gaps, exact queries, and sources.

## References
- Monitor Azure Firewall: https://learn.microsoft.com/azure/firewall/monitor-firewall
- Monitoring reference: https://learn.microsoft.com/azure/firewall/monitor-firewall-reference
- Rule processing: https://learn.microsoft.com/azure/firewall/rule-processing
- Premium features: https://learn.microsoft.com/azure/firewall/premium-features
- DNS: https://learn.microsoft.com/azure/firewall/dns-settings
- Forced tunneling: https://learn.microsoft.com/azure/firewall/forced-tunneling
- Policy Analytics: https://learn.microsoft.com/azure/firewall/policy-analytics
- Azure Network Security repository: https://github.com/Azure/Azure-Network-Security/tree/master/Azure%20Firewall
