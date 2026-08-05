---
name: well-architected-reliability
description: >
  Run an Azure Well-Architected Reliability review using the Azure Proactive
  Resiliency Library (APRL) and Microsoft reliability guidance. Use for WARA,
  resiliency assessments, high availability, failure mode analysis, SLO/RTO/RPO,
  disaster recovery, scaling, self-healing, reliability testing, monitoring,
  service retirement, and prioritized reliability remediation.
tools:
  - RunAzCliReadCommands
  - execute_kusto_query
  - AzureMCP/*
  - MicrosoftLearnMCP/*
---

# Azure Well-Architected Reliability Review

> **Required MCP grounding:** Before conclusions, use `AzureMCP/*` for live Azure evidence and `MicrosoftLearnMCP/*` for current authoritative guidance. If either connector is unavailable, report a blocking evidence gap instead of relying on model memory.

## Purpose
Assess whether an Azure workload is designed, configured, tested, and operated
to meet its availability and recoverability targets. Combine:

- Workload-level Azure Well-Architected Reliability checks `RE:01` through `RE:10`
- APRL resource-specific recommendations and Azure Resource Graph automation
- Azure Advisor Reliability workbook and reliability recommendations
- Service Health, resource health, retirement, and support evidence
- Manual architecture, failure-mode, recovery, and testing validation

Produce an evidence-based reliability score and action plan. APRL automation
finds configuration candidates; it does not replace workload-owner review or
prove end-to-end reliability.

## When to use this skill
- The user requests a Well-Architected Reliability review or WARA
- The user asks whether an Azure workload is resilient or highly available
- The user wants APRL recommendations evaluated against deployed resources
- The user needs SLO, RTO, RPO, redundancy, scaling, or DR assessment
- The user wants reliability risks prioritized before production launch
- The user requests a recurring reliability health review

## Source and coverage model
Use current sources in this order:

1. Microsoft Azure Well-Architected Framework Reliability guidance
2. Azure Advisor Reliability workbook and current Advisor recommendations
3. Current APRL active recommendations and their linked Microsoft documentation
4. Workload requirements, architecture, runbooks, tests, and accepted risks
5. Azure control-plane, telemetry, Service Health, and incident evidence

For APRL recommendations retain:
- `aprlGuid` as the stable recommendation identifier
- `recommendationControl`
- `recommendationImpact`
- `recommendationResourceType`
- `recommendationMetadataState`
- `pgVerified`
- `automationAvailable`
- `learnMoreLink`

Evaluate only active APRL recommendations. `automationAvailable: true` means a
query exists; it does not authorize automated remediation. Product-group
verification and automated validation do not eliminate contextual review.

The Advisor workbook is guidance, not a service-level guarantee. It complements
APRL: the workbook provides an application-filtered service view, while APRL
adds a broader recommendation catalog and automated configuration checks.

## Guardrails
- Use read-only Azure CLI, Resource Graph, metrics, and log queries.
- Do not install modules, run collection software, change resources, fail over,
  restore, scale, restart, or execute chaos tests without explicit approval.
- APRL Resource Graph checks read ARM configuration and don't access secrets,
  but collected files can still contain sensitive inventory and support data.
- Do not publish resource IDs, support tickets, outage details, architecture, or
  recovery information outside the authorized assessment.
- Do not mark a recommendation compliant only because its automated query
  returns no rows. Confirm scope, query applicability, permissions, and freshness.
- Reliability targets must come from business requirements, not inferred SLAs.
- Evaluate cost, security, performance, and operational tradeoffs explicitly.
- Use UTC and record collection time, source version, scope, and limitations.

## Pre-check
Collect or infer:

| Field | Required value |
|-------|----------------|
| Workload | Name, owner, business purpose, lifecycle stage |
| Environment | Production plus required DR and shared-service dependencies |
| Scope | Tenant, subscriptions, resource groups, resources, and tag filters |
| Critical flows | User and system flows with criticality ratings |
| Targets | SLO/SLI, SLA dependencies, RTO, RPO, MTD, error budget |
| Architecture | Components, dependencies, regions, zones, and data flows |
| Recovery | Backup, restore, failover, failback, and continuity plans |
| Operations | Monitoring, alerts, on-call, runbooks, incidents, and support cases |
| Testing | Load, fault, zone, region, dependency, restore, and DR evidence |
| Exceptions | Accepted risks with owner, compensating control, and expiry |

If business targets or critical flows are missing, continue with configuration
discovery but classify target-dependent conclusions as `Not assessed`.

Do not scope only the primary production resource group when the workload
depends on DR, shared identity, networking, DNS, monitoring, data, or platform
subscriptions.

## Assessment procedure

### Step 1: Define workload boundaries and critical flows
Document:

1. Entry points and user/system flows
2. Business impact and criticality per flow
3. Components and dependencies on each critical path
4. Healthy, degraded, and unhealthy states
5. Availability and recovery target per flow
6. Planned degraded modes and business continuity alternatives

Challenge generic targets such as "always available." Targets must be
measurable, achievable, and tied to business outcomes.

### Step 2: Choose the APRL collection path

#### Path A: Existing WARA/APRL artifacts
If the user provides collector JSON or Expert Analysis Excel output:

- Confirm collection date, APRL/WARA version, tenant, subscription, resource
  group, tag filters, and specialized workload switches
- Confirm production, DR, and shared dependencies are included
- Treat stale inventory as evidence requiring refresh
- Never publish reports before expert review is complete

#### Path B: Official WARA module
The optional Microsoft workflow is sequential:

1. `Start-WARACollector` evaluates scope with Resource Graph and gathers Advisor,
   Service Health, retirement, support, and alert information into JSON.
2. `Start-WARAAnalyzer` converts JSON and current APRL metadata into the Expert
   Analysis Excel workbook.
3. A reviewer validates every category and customizes recommendations.
4. `Start-WARAReport` creates PowerPoint and Excel/CSV outputs after review.

Do not run or install the module automatically. Collector and analyzer require
PowerShell 7.4 and Reader access; reports require a local Windows environment
with Excel and PowerPoint and don't support Cloud Shell.

Collector scope precedence matters: a full subscription selection includes the
entire subscription even when narrower resource-group filters are also supplied.
Tag filters further refine explicitly selected scopes.

#### Path C: Agent-native read-only review
When WARA artifacts or modules are unavailable, execute current APRL Resource
Graph checks through `az graph query`, then perform all manual workload checks.
Record that official APRL report artifacts were not generated.

### Step 3: Build the workload inventory
Summarize in-scope Azure resource types and regions:

```bash
az graph query -q "resources | summarize ResourceCount=count() by type, location | order by ResourceCount desc" --subscriptions <subscription-id> -o table
```

Use workload-specific scope filters in the actual query. Check for:
- Components outside the declared inventory
- Single-region, single-zone, or single-instance critical components
- Hidden cross-subscription and shared-service dependencies
- Unsupported, preview, retiring, or deprecated SKUs and API versions
- Capacity, quota, and regional feature constraints
- Stateful data paths and replication boundaries

Inventory alone doesn't establish workload membership. Confirm ownership and
flow dependencies.

### Step 4: Collect external reliability evidence

**Azure Advisor high-availability recommendations**

```bash
az advisor recommendation list --category HighAvailability -o json
```

**Resource health**

```bash
az graph query -q "healthresources | where type =~ 'microsoft.resourcehealth/availabilitystatuses' | extend AvailabilityState=tostring(properties.availabilityState), Summary=tostring(properties.summary) | project id, AvailabilityState, Summary, properties" --subscriptions <subscription-id> -o json
```

**Service Health alert coverage**

```bash
az graph query -q "resources | where type =~ 'microsoft.insights/activitylogalerts' | where tostring(properties.condition) has 'ServiceHealth' | project id, name, location, properties.enabled, properties.scopes, properties.actions" --subscriptions <subscription-id> -o json
```

Also review:
- Relevant Service Health outages, planned maintenance, and retirements
- Support-request resolutions and Microsoft recommendations
- Recent incidents, postmortems, recurring failure patterns, and error budgets
- Alert action groups, ownership, routing, and test evidence

Minimize sensitive output. Do not copy full support or incident contents into
the report.

### Step 5: Use the Advisor Reliability workbook
Open **Advisor > Workbooks > Reliability** and record the workbook access time.

Apply and preserve these filters with exported evidence:

- Subscription
- Resource group
- Environment
- Tags

The environment filter infers values from tags named `Environment`,
`environment`, `Env`, or `env`, and from common resource-name keywords such as
prod, dev, qa, uat, sit, and test. `undefined` is a workbook-only classification.
Verify every inferred environment and workload boundary before scoring.

Use **Show SLA** for the documented service SLA and **Show Help** for
configuration guidance. Never treat an individual service SLA, or a sum of SLAs,
as the end-to-end workload availability target.

Review all applicable workbook areas:

| Area | Services |
|------|----------|
| Compute/containers | VM, VMSS, AKS |
| Data | SQL Database, Synapse SQL, Cosmos DB, MySQL, PostgreSQL, Redis |
| Integration/network | API Management, Firewall, Front Door/CDN, Application Gateway, Load Balancer, Public IP, VPN/ExpressRoute |
| Storage/web | Storage, App Service Plan/App, Functions |
| Recovery/operations | Site Recovery and Service Alerts |

Export each applicable service view or preserve its filtered workbook link.
Record services not covered by the workbook as manual/APRL coverage gaps.
Correlate rows to critical flows, then deduplicate them with APRL, Advisor,
Service Health, incidents, and custom findings.

### Step 6: Evaluate APRL resource recommendations
For every in-scope resource type:

1. Load current active APRL recommendations for the matching ARM resource type.
2. Run the associated Resource Graph query when automation is available.
3. Confirm query permissions, scope, API shape, and exclusions.
4. Manually validate recommendations without automation.
5. Check APRL linked documentation for current service behavior.
6. Personalize the recommendation for the workload and critical flow.
7. Record APRL GUID, control, impact, evidence, and affected resources.

Use APRL controls:

| Control | Review focus |
|---------|--------------|
| HighAvailability | Instance, zone, region, and service redundancy |
| BusinessContinuity | Continuity process and degraded operation |
| DisasterRecovery | Backup, replication, failover, restore, and failback |
| Scalability | Capacity, quotas, autoscale, partitioning, and load handling |
| MonitoringAndAlerting | Health model, SLIs, alerts, diagnostics, and ownership |
| ServiceUpgradeAndRetirement | Supported versions, migrations, and retirement plans |
| OtherBestPractices | Service-specific reliability configuration |
| Governance/Security | Reliability dependencies on policy and protection |
| Personalized | Workload-specific findings not represented by APRL |

Automated results require expert review. A missing APRL recommendation or query
is a coverage gap, not proof that the resource is reliable.

### Step 7: Complete the WAF RE:01-RE:10 review

| Code | Required evidence |
|------|-------------------|
| RE:01 Simplicity | Lean critical path, justified components, documented tradeoffs |
| RE:02 Critical flows | Rated user/system flows and dependency maps |
| RE:03 Failure modes | FMA with likelihood, impact, blast radius, detection, mitigation |
| RE:04 Targets | SLOs, SLIs, RTO, RPO, health model, and error budget |
| RE:05 Redundancy | Layered instance/zone/region redundancy aligned to targets |
| RE:06 Scaling | Tested autoscale/capacity strategy, quota and regional headroom |
| RE:07 Self-preservation | Timeouts, retries, backoff, circuit breakers, isolation, graceful degradation, self-healing |
| RE:08 Testing | Load, fault, chaos, deployment, restore, and recovery evidence |
| RE:09 DR | Documented and tested component plus end-to-end recovery plans |
| RE:10 Monitoring | Flow-level health, actionable alerts, retention, response, learning |

APRL resource checks supplement these controls but cannot fully automate
business requirements, application design, operations, or testing evidence.

### Step 8: Perform failure mode analysis
For each critical flow produce:

| Field | Required content |
|-------|------------------|
| Component/dependency | Exact dependency on the flow |
| Failure mode | Zone, region, capacity, data, network, identity, dependency, deployment, human, or platform |
| Trigger | Conditions that cause or expose failure |
| Impact and blast radius | User, data, flow, region, and duration |
| Detection | SLI, alert, health signal, and detection target |
| Prevention/mitigation | Redundancy, isolation, retry, buffering, scaling, recovery |
| Recovery | Automated/manual steps, RTO, RPO, and owner |
| Test evidence | Date, environment, result, and observed recovery |
| Residual risk | Accepted, pending, or requires remediation |

Include failures in shared dependencies and control planes. Evaluate correlated
failure and dependency exhaustion, not only isolated component failure.

### Step 9: Validate redundancy, capacity, and recovery
Check:
- Availability-zone and regional support for each chosen SKU
- Quota and capacity headroom during one-instance, one-zone, or one-region loss
- Load distribution, health probes, failover criteria, and split-brain prevention
- Data replication mode, consistency, lag, backup immutability, and restore tests
- Active-active or active-passive routing and failback behavior
- Autoscale minimums, maximums, cooldown, signals, and dependency limits
- Deployment rings, health gates, rollback, configuration, and secret dependencies
- Recovery sequence and dependency order

Redundancy counts only when failure domains are independent and the remaining
capacity can meet critical-flow targets.

### Step 10: Validate operations and testing
Require dated evidence for:
- End-to-end SLI and SLO monitoring
- Alert delivery and on-call response
- Backup restoration and data integrity
- Zone and regional failover/failback
- Dependency outage and throttling
- Load, scale, and capacity exhaustion
- Deployment rollback and configuration recovery
- Chaos or controlled fault injection where appropriate
- Runbook execution and incident learning

A documented plan without a successful drill is `Partial`, not `Pass`.

### Step 11: Correlate and prioritize findings
Do not report duplicate findings from APRL, Advisor, WAF, incidents, and service
retirements separately. Create one finding with all source references.

Priority combines:

| Factor | Weight |
|--------|--------|
| Critical-flow impact | 30% |
| Gap against SLO/RTO/RPO | 25% |
| Likelihood and observed incident evidence | 20% |
| Blast radius | 15% |
| Detection and recovery weakness | 10% |

APRL `recommendationImpact` is an input, not the final workload priority.

## Scoring
Score the ten WAF Reliability controls equally:

| Status | Points |
|--------|--------|
| Pass with current evidence | 10 |
| Partial or pending validation | 5 |
| Fail | 0 |
| Not applicable / accepted exception | Excluded from denominator |
| Not assessed because evidence is missing | 0 |

Overall score:

`earned points / available applicable points * 100`

| Score | Maturity |
|-------|----------|
| 90-100 | Optimized |
| 70-89 | Managed |
| 40-69 | Developing |
| 0-39 | Initial |

Report APRL automation coverage separately:
- Active recommendations applicable
- Automated checks executed
- Manual checks completed
- Pending validations
- False positives

Do not increase the reliability score because a check lacks automation.

## Accepted exceptions
An accepted reliability exception must include:

| Field | Requirement |
|-------|-------------|
| Recommendation | WAF code and/or APRL GUID |
| Scope | Flow, resource, and environment |
| Reason | Business and technical justification |
| Target impact | Availability, RTO, RPO, and error-budget effect |
| Compensating control | Detection, recovery, continuity, or insurance |
| Risk owner | Accountable approver |
| Review/expiry date | Mandatory |
| Test evidence | Evidence that residual risk is understood |

List exceptions separately. Reopen expired, ownerless, or materially changed
exceptions.

## Expected output

## Azure Well-Architected Reliability Review Report

| Field | Value |
|-------|-------|
| Workload and environment | Name and production/DR scope |
| Subscriptions/resource groups | Assessed scope |
| Assessment date | YYYY-MM-DD UTC |
| Reliability targets | SLO, RTO, RPO by critical flow |
| Overall score | XX/100 and maturity |
| Advisor workbook context | Filters, timestamp, covered/undefined resources |
| APRL coverage | Automated / manual / pending counts |
| Findings | Critical / High / Medium / Low |
| Accepted exceptions | Count and nearest review date |

Required sections:
1. **Executive summary**
2. **Scope, architecture, targets, evidence, and limitations**
3. **Critical-flow reliability matrix**
4. **RE:01-RE:10 scorecard**
5. **Advisor workbook, APRL, and Advisor findings**
6. **Failure-mode analysis**
7. **Redundancy, capacity, and dependency analysis**
8. **BCDR and recovery-test evidence**
9. **Monitoring, operations, and retirement risks**
10. **Prioritized action plan**
11. **Accepted exceptions**
12. **Commands, queries, APRL version/date, and references**

Each finding must include WAF code, APRL GUID when applicable, affected flow and
resource, evidence, target gap, priority, recommendation, tradeoffs, owner,
effort, validation, and official documentation.

## Remediation guidance
- Suggest only; never execute reliability changes or tests from this skill.
- Validate Azure CLI write syntax with `GetAzCliHelp` when available.
- Use deployment preview/what-if for infrastructure changes.
- Test redundancy, failover, and recovery in a safe environment before production.
- Define rollback and observability before every change.
- Prefer platform-native features and simple designs that meet agreed targets.
- Recalculate the score only after evidence confirms remediation.

## References
- APRL: https://azure.github.io/Azure-Proactive-Resiliency-Library-v2/
- APRL tools: https://azure.github.io/Azure-Proactive-Resiliency-Library-v2/tools/
- APRL collector: https://azure.github.io/Azure-Proactive-Resiliency-Library-v2/tools/collector/
- APRL analyzer: https://azure.github.io/Azure-Proactive-Resiliency-Library-v2/tools/analyzer/
- APRL reports: https://azure.github.io/Azure-Proactive-Resiliency-Library-v2/tools/reports/
- APRL WAF Reliability recommendations: https://azure.github.io/Azure-Proactive-Resiliency-Library-v2/azure-waf/reliability/
- Advisor Reliability workbook: https://learn.microsoft.com/azure/advisor/advisor-workbook-reliability
- Reliability principles: https://learn.microsoft.com/azure/well-architected/reliability/principles
- Reliability checklist: https://learn.microsoft.com/azure/well-architected/reliability/checklist
- Reliability targets: https://learn.microsoft.com/azure/well-architected/reliability/metrics
- Failure mode analysis: https://learn.microsoft.com/azure/well-architected/reliability/failure-mode-analysis
- Reliability testing: https://learn.microsoft.com/azure/well-architected/reliability/reliability-test
- Reliability monitoring: https://learn.microsoft.com/azure/well-architected/reliability/monitoring

## Sample output

> Redacted example with illustrative values.

## Azure Well-Architected Reliability Review Report

| Field | Value |
|-------|-------|
| Workload and environment | Orders API - Production and DR |
| Subscriptions/resource groups | 2 subscriptions, 7 resource groups |
| Assessment date | 2026-08-04 UTC |
| Reliability targets | Checkout SLO 99.95%; RTO 30m; RPO 5m |
| Overall score | 68/100 - Developing |
| APRL coverage | 42 automated / 18 manual / 7 pending |
| Findings | 2 Critical / 5 High / 8 Medium / 3 Low |
| Accepted exceptions | 2; nearest review 2026-09-01 |

### Top findings

| Priority | WAF/APRL | Evidence | Recommendation |
|----------|----------|----------|----------------|
| Critical | RE:09 | Regional failover has never completed within RTO | Run an end-to-end failover/failback drill and remediate dependency order |
| Critical | RE:05 | Critical data tier is single-region | Add target-aligned regional recovery and validate data consistency |
| High | RE:06 | Remaining zone capacity cannot handle peak load | Reserve quota and test one-zone-loss capacity |
| High | RE:10 | Health model reports component uptime, not checkout flow | Add flow-level SLIs and actionable alerts |

### APRL review summary

| State | Count |
|-------|-------|
| Confirmed gap | 31 |
| Pending manual validation | 7 |
| Already compliant | 19 |
| Not applicable | 3 |

Automated APRL results were manually correlated to critical flows and targets.
No remediation or reliability test was executed by this assessment.
