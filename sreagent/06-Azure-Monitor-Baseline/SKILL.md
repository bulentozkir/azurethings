---
name: azure-monitor-baseline
description: >
  Assess Azure Monitor alert coverage against Azure Monitor Baseline Alerts
  (AMBA). Use for metric, log, activity log, Service Health, Resource Health,
  action group, alert processing rule, Azure Policy, threshold, notification,
  testing, alert-noise, telemetry prerequisite, and monitoring governance reviews
  across Azure services and landing zones.
tools:
  - RunAzCliReadCommands
  - execute_kusto_query
  - AzureMCP/*
  - MicrosoftLearnMCP/*
---

# Azure Monitor Baseline

> **Required MCP grounding:** Before conclusions, use `AzureMCP/*` for live Azure evidence and `MicrosoftLearnMCP/*` for current authoritative guidance. If either connector is unavailable, report a blocking evidence gap instead of relying on model memory.

## Purpose
Perform a read-only assessment of Azure Monitor alerting against the current
Azure Monitor Baseline Alerts (AMBA) service catalog.

Separate five controls that must all work:

1. **Catalog applicability** - AMBA defines a relevant signal for the resource.
2. **Rule equivalence** - an enabled rule monitors the intended signal and scope.
3. **Telemetry readiness** - the metric, log, table, identity, and data path exist.
4. **Notification delivery** - an owned action path receives fired and resolved alerts.
5. **Operational actionability** - severity, threshold, runbook, and response are useful.

An alert resource existing in Azure proves only part of the monitoring control.

## When to use this skill
- The user requests an Azure Monitor or AMBA baseline review
- Alert coverage across subscriptions or landing zones must be assessed
- The user wants missing, disabled, drifted, duplicate, or noisy alerts identified
- AMBA Azure Policy initiatives or brownfield deployment must be planned
- Action groups, processing rules, Service Health, or Resource Health need review
- Alert thresholds and delivery need validation before production
- A recurring monitoring governance review is requested

## AMBA source model
Use the live service catalog:

`https://azure.github.io/azure-monitor-baseline-alerts/services/index.html`

For each in-scope resource type, read its current `alerts.yaml` and references
from the AMBA repository. Record the repository commit/date used for assessment.

AMBA catalog entries can include:

| Field | Meaning |
|-------|---------|
| `guid` | Stable catalog identity |
| `name`, `description`, `type` | Signal intent and alert type |
| `verified` | Whether the recommendation has been validated by maintainers |
| `visible` | Whether it appears in the published service view |
| `tags` | Scenario applicability such as `alz`, `hpc`, or `rag` |
| `properties` | Namespace, signal, severity, threshold, aggregation, window, frequency, dimensions, resolution |
| `references` | Supporting Microsoft documentation |
| `deployments` | Available policy/template implementation and scope |

On service pages:
- **Enabled** by default means AMBA treats the alert as **Must Have**.
- **Disabled** by default means **Nice to Have** and requires an explicit decision.

`verified`, `visible`, and default `enabled` describe different things. Don't
conflate them.

## Service coverage
The catalog spans many Azure resource types, including:

- Compute, VM scale sets, Arc, AKS, Container Apps, Container Instances, and ACR
- Application Gateway, Firewall, ExpressRoute, load balancers, VPN, Virtual WAN,
  VNets, public IPs, NAT, NSGs, DNS, Front Door, and Traffic Manager
- Storage, Azure Files, NetApp, Storage Sync, Recovery Services, and Key Vault
- SQL, Cosmos DB, MySQL, PostgreSQL, Redis, Data Factory, Synapse, and Event Hubs
- App Service, API Management, Logic Apps, Service Bus, Event Grid, and SignalR
- Log Analytics, Automation, Kusto, Search, IoT, Machine Learning, and AI services
- Subscription-level administrative, Service Health, and Resource Health signals

Catalog coverage is not complete observability. Add workload-specific SLIs,
application/dependency alerts, business signals, security detections, and data
quality checks outside AMBA when required.

## Guardrails
- Use read-only Azure CLI, Resource Graph, Azure Monitor, Policy, metrics, and KQL.
- Do not create, modify, enable, disable, suppress, or delete alerts or action groups.
- Do not deploy or remediate AMBA policies without explicit approval.
- Do not copy AMBA thresholds blindly into production.
- Do not expose webhook URIs, email/phone recipients, ITSM credentials, private
  endpoints, query payloads, or sensitive custom properties in the report.
- Treat alert queries and notification routing as security-sensitive configuration.
- Do not infer coverage from alert names alone.
- Use UTC and record catalog version, scope, query time, and evidence freshness.

## Pre-check
Collect or infer:

| Field | Required value |
|-------|----------------|
| Scope | Management groups, subscriptions, resource groups, workloads, environments |
| Criticality | SLO, critical flows, owners, support hours, and response targets |
| Resource inventory | Resource IDs, types, regions, tags, and lifecycle |
| Monitoring architecture | Workspaces, DCRs, AMA, diagnostic settings, managed identities |
| Routing | Action groups, ITSM/on-call targets, escalation, and common schema |
| Governance | Policy initiatives, assignments, exemptions, disable/override tags |
| Operations | Runbooks, maintenance windows, MTTA/MTTR, noise, and incident history |
| Cost | Alert-rule counts, query frequency, data ingestion, and retention |

If the user doesn't provide an AMBA deployment pattern, assess existing rules
without assuming the Azure Landing Zone pattern is required.

## Assessment procedure

### Step 1: Inventory in-scope resources by type

```kusto
resources
| summarize Resources=count(), Subscriptions=dcount(subscriptionId),
            Regions=dcount(location)
  by type
| order by Resources desc
```

Map each resource type to the corresponding AMBA service page and `alerts.yaml`.
Mark resource types without an AMBA page as `Custom baseline required`, not
compliant.

Exclude decommissioned resources and approved non-production scopes only when an
explicit rule or exception exists.

### Step 2: Build the expected alert catalog
For every applicable catalog entry capture:

- AMBA GUID and source commit/date
- Resource type, kind, tier, and unsupported SKU conditions
- Metric, log, activity, Service Health, or Resource Health signal
- Metric namespace/name or normalized log query/operation
- Dimensions and target resource types
- Severity, threshold/dynamic sensitivity, operator, aggregation
- Window size, evaluation frequency, failing periods, and auto-resolution
- Default state, verified status, deployment scope, and references

Use default AMBA values as a starting hypothesis. Adjust them to workload SLOs,
traffic, seasonality, redundancy, and support model.

### Step 3: Inventory deployed alerting resources

```kusto
resources
| where type in~ (
    "microsoft.insights/metricalerts",
    "microsoft.insights/scheduledqueryrules",
    "microsoft.insights/activitylogalerts",
    "microsoft.insights/actiongroups",
    "microsoft.alertsmanagement/actionrules")
| extend
    Enabled=tobool(properties.enabled),
    Severity=toint(properties.severity),
    Scopes=properties.scopes,
    IsAmba=tobool(tags["_deployed_by_amba"])
| project id, name, type, subscriptionId, resourceGroup, location,
          Enabled, Severity, Scopes, IsAmba, tags, properties
```

Also inventory:
- Policy definitions with metadata `_deployed_by_amba`
- AMBA initiatives, assignments, parameters, exemptions, and remediation state
- User-assigned managed identities used by scheduled query rules
- Workspaces, DCRs, diagnostic settings, and required tables

Never output complete action group receivers or secure endpoints.

### Step 4: Match catalog entries to deployed rules
Match by a normalized signal identity, not display name:

| Alert type | Match key |
|------------|-----------|
| Metric | Target resource type + namespace + metric + dimensions |
| Log | Target type/scope + normalized query intent + resource ID column |
| Activity log | Scope + category/operation/status conditions |
| Service Health | Subscription/tenant scope + event types + service/region filters |
| Resource Health | Scope + current/previous health states |

Then compare severity, state, threshold, aggregation, frequency, window,
dimensions, scopes, actions, auto-mitigation, and resolution behavior.

Classification:

| State | Meaning |
|-------|---------|
| Equivalent | Signal and operational behavior meet the approved baseline |
| Drifted | Rule exists but material properties differ |
| Disabled | Applicable rule exists but cannot fire |
| Missing | No equivalent rule exists |
| Duplicate | Multiple rules create overlapping incidents |
| Not applicable | Supported exception with evidence |
| Custom | Organization rule intentionally replaces AMBA |

AMBA tags such as `_deployed_by_amba` help identify origin but don't prove that
the deployed version or properties match the current catalog.

### Step 5: Validate telemetry prerequisites
For every log or guest metric rule, verify:

- Azure Monitor Agent and required extension state
- DCR association and data source configuration
- Correct Log Analytics workspace and table
- Recent data for representative resources
- Diagnostic settings and required log categories
- Query permissions for the rule's managed identity
- Resource ID normalization and target resource types
- Query time range compatible with window/evaluation frequency

Example freshness checks:

```kusto
Heartbeat
| summarize LastHeartbeat=max(TimeGenerated) by _ResourceId, Computer
| extend MinutesOld=datetime_diff("minute", now(), LastHeartbeat)
| order by MinutesOld desc
```

```kusto
InsightsMetrics
| summarize LastMetric=max(TimeGenerated), Rows=count()
  by _ResourceId, Namespace, Name
| order by LastMetric asc
```

A scheduled query rule with no source data is `Telemetry blocked`, not covered.

### Step 6: Assess platform and health alerts
Confirm:

- Administrative activity alerts for high-risk changes
- Resource Health alerts for supported critical resources
- Service Health alerts for service issues, planned maintenance, health
  advisories, and security advisories
- Subscription-level and tenant-level Service Health coverage where supported
- Direct action groups on Service Health alerts

Alert processing rules don't apply to Service Health alerts. Don't rely on them
to add routing or suppress Service Health notifications.

### Step 7: Assess action groups and delivery
For each production subscription, confirm at least one owned notification path.
Evaluate:

- Email/on-call/ITSM/programmatic channels aligned to severity
- Global region when required for Service Health
- Secure webhook instead of unauthenticated webhook where possible
- Common alert schema compatibility
- Receiver enablement, ownership, escalation, and service limits
- Fired and resolved notification behavior
- Delivery tests and downstream ticket creation
- Break-glass routing if the primary integration fails

An action group attached to a rule isn't evidence that a person or system
received and acted on the alert.

### Step 8: Assess alert processing rules
Inventory `Microsoft.AlertsManagement/actionRules` and validate:

- Scope stays within the same subscription as the processing rule
- Filters match intended resources, types, severities, and monitor services
- Suppression schedules match approved maintenance windows and time zones
- No indefinite or broad suppression hides production incidents
- Apply-action-group rules don't duplicate direct rule routing
- Rules have owner, reason, expiry/review date, and test evidence

Suppressed alerts still fire and remain visible; only their action groups are
removed. Propagation after changes can take time.

### Step 9: Tune threshold and signal quality
For every alert, review at least 30 days and preferably 90 days of:

- Fired and resolved count
- Duration, recurrence, flapping, and duplicate incidents
- True positive, false positive, and missed-incident evidence
- MTTA, MTTR, escalation, and after-hours response
- Resource criticality, redundancy, seasonality, and deployment windows

Use dynamic thresholds where workload behavior is stable enough and static
thresholds where explicit limits or SLOs are known. Validate all dimensions to
avoid cardinality explosion or masking individual failures.

Azure Monitor severity meaning:

| Severity | Intent |
|----------|--------|
| Sev0 | Critical |
| Sev1 | Error |
| Sev2 | Warning |
| Sev3 | Informational |
| Sev4 | Verbose |

Severity must reflect operational impact, not only the AMBA default.

### Step 10: Assess policy-at-scale deployment
AMBA's Azure Landing Zone pattern uses DeployIfNotExists policies and initiatives
for connectivity, identity, management, VM/VMSS, Arc, key management, load
balancing, network changes, recovery, storage, web, Service Health, and
notification assets.

Validate initiative placement against the actual management-group hierarchy.
Don't assign initiatives to scopes that don't contain relevant resources.

For brownfield:

1. Import pinned and reviewed AMBA definitions.
2. Assign to a pilot management group or subscription.
3. Review parameters, identities, permissions, and exclusions.
4. Run what-if and evaluate Policy compliance.
5. Remediate a controlled cohort.
6. Test alert creation, firing, routing, resolution, and cleanup.
7. Expand in waves.

Separate production and non-production management groups to avoid unnecessary
noise. Review the current policy's monitor-disable and threshold-override tag
parameters rather than hardcoding historical tag names.

### Step 11: Assess cost and maintainability
Consider:

- Activity Log, Service Health, and Resource Health alerts are free
- Log alert evaluation frequency and query complexity affect cost
- Metric alert cost scales with monitored time series/resources
- Multi-resource rules can reduce management overhead when supported
- Data ingestion, retention, transformations, and workspace architecture
- Alert-rule, notification, and API service limits
- Version drift between imported AMBA artifacts and the current catalog

Never reduce monitoring solely for cost without documenting detection and SLO
tradeoffs.

### Step 12: Prioritize remediation
Priority combines:

| Factor | Weight |
|--------|--------|
| Critical-flow impact and missing detection | 30% |
| Telemetry or delivery failure | 25% |
| Security/reliability significance | 20% |
| Frequency of real incidents or near misses | 15% |
| Ease and safety of remediation | 10% |

Fix in this order:
1. Broken telemetry and delivery for existing critical alerts
2. Missing Service Health, Resource Health, and critical-flow alerts
3. Disabled or drifted Must Have rules
4. Dangerous suppression and routing gaps
5. Noise, duplicates, threshold tuning, and cost
6. Nice to Have and custom coverage

## Scoring
Calculate an Azure Monitor Baseline score:

| Domain | Points |
|--------|--------|
| Resource-to-catalog coverage | 0-20 |
| Rule equivalence and enabled state | 0-20 |
| Telemetry and query readiness | 0-15 |
| Action groups and delivery validation | 0-15 |
| Health alerts and processing governance | 0-10 |
| Threshold quality, runbooks, and response | 0-10 |
| Policy lifecycle, testing, cost, and versioning | 0-10 |
| **Total** | **0-100** |

| Score | Maturity |
|-------|----------|
| 90-100 | Optimized |
| 70-89 | Managed |
| 40-69 | Developing |
| 0-39 | Initial |

Missing evidence earns zero points. Disabled Nice to Have rules don't reduce the
score when an approved decision exists.

## Accepted exceptions
Each exception must include:

| Field | Requirement |
|-------|-------------|
| AMBA GUID/signal | Exact catalog item or custom replacement |
| Scope | Resource type, workload, and environment |
| Reason | Why the alert is disabled, replaced, or tuned |
| Detection impact | Failure modes no longer or differently detected |
| Compensating control | Replacement alert, dashboard, SLO, or manual process |
| Owner | Accountable approver |
| Expiry/review date | Mandatory |
| Test evidence | Proof the replacement control works |

## Expected output

## Azure Monitor Baseline Assessment Report

| Field | Value |
|-------|-------|
| Scope | Management groups/subscriptions/workloads |
| Assessment date | YYYY-MM-DD UTC |
| AMBA source | Commit/date |
| Applicable Must Have alerts | Count |
| Equivalent / drifted / missing | Counts |
| Telemetry blocked | Count |
| Delivery unverified | Count |
| Baseline score | XX/100 and maturity |

Required sections:
1. **Executive summary**
2. **Scope, AMBA version, assumptions, and limitations**
3. **Resource and catalog coverage**
4. **Alert equivalence and drift**
5. **Telemetry prerequisites**
6. **Health alerts, action groups, and processing rules**
7. **Noise, thresholds, response, and cost**
8. **Policy deployment and version lifecycle**
9. **Prioritized remediation roadmap**
10. **Accepted exceptions**
11. **Commands, queries, and references**

Every finding must include AMBA GUID, signal, resource scope, expected/deployed
properties, gap, impact, owner, priority, recommendation, and validation.

## Remediation guidance
- Suggest only; never deploy or change alerts from this skill.
- Validate write syntax with `GetAzCliHelp` when available.
- Use policy/deployment what-if and a pilot scope before remediation.
- Test fired and resolved delivery before production rollout.
- Add runbook and ownership before enabling high-volume rules.
- Pin AMBA versions and periodically review upstream changes.
- Link each action to AMBA and official Microsoft documentation.

## References
- AMBA service catalog: https://azure.github.io/azure-monitor-baseline-alerts/services/index.html
- AMBA welcome: https://azure.github.io/azure-monitor-baseline-alerts/welcome/
- AMBA repository: https://github.com/Azure/azure-monitor-baseline-alerts
- ALZ deployment guidance: https://azure.github.io/azure-monitor-baseline-alerts/patterns/alz/HowTo/deploy/Introduction-to-deploying-the-ALZ-Pattern/
- Azure Monitor alert best practices: https://learn.microsoft.com/azure/azure-monitor/alerts/best-practices-alerts
- Alert processing rules: https://learn.microsoft.com/azure/azure-monitor/alerts/alerts-processing-rules
- Azure Monitor alerts: https://learn.microsoft.com/azure/azure-monitor/alerts/alerts-overview
- Landing zone monitoring: https://learn.microsoft.com/azure/cloud-adoption-framework/ready/landing-zone/design-area/management-monitor

## Sample output

> Redacted example with illustrative values.

## Azure Monitor Baseline Assessment Report

| Field | Value |
|-------|-------|
| Scope | 3 management groups, 16 subscriptions |
| Assessment date | 2026-08-05 UTC |
| AMBA source | Pinned commit `abc1234` |
| Applicable Must Have alerts | 284 |
| Equivalent / drifted / missing | 211 / 28 / 45 |
| Telemetry blocked | 17 |
| Delivery unverified | 6 subscriptions |
| Baseline score | 69/100 - Developing |

### Top findings

| Priority | Signal | Gap | Next action |
|----------|--------|-----|-------------|
| Critical | VM heartbeat | Rule exists but no Heartbeat data for 23 VMs | Repair AMA/DCR path before tuning alert |
| Critical | Service Health | Four production subscriptions have no direct action group | Add and test owned global routing |
| High | Key Vault availability | AMBA Must Have signal missing | Pilot current AMBA policy definition |
| High | Maintenance suppression | Subscription-wide recurring rule has no owner or expiry | Narrow scope and validate schedule |
| Medium | VM CPU | Duplicate metric and log rules create two incidents | Select one approved operational signal |

An alert was counted as covered only when its signal, telemetry, routing, and
operational behavior were validated. No alert or policy change was executed.
