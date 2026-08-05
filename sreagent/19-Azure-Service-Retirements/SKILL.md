---
name: azure-service-retirements
description: >
  Discover, correlate, assess, and track Azure service and feature retirements.
  Use for Service Health retirement advisories, Advisor Service Upgrade and
  Retirement recommendations, impacted-resource inventory, retirement deadlines,
  migration planning, owner assignment, alert coverage, cutover readiness,
  post-migration verification, and portfolio retirement governance.
tools:
  - RunAzCliReadCommands
  - execute_kusto_query
  - AzureMCP/*
  - MicrosoftLearnMCP/*
---

# Azure Service Retirements

> **Required MCP grounding:** Before conclusions, use `AzureMCP/*` for live Azure evidence and `MicrosoftLearnMCP/*` for current authoritative guidance. If either connector is unavailable, report a blocking evidence gap instead of relying on model memory.

## Purpose
Provide a read-only operating process for Azure service retirements from initial
announcement through verified migration and closure.

Use the Microsoft signal-to-action model:

| Layer | Azure service | Responsibility |
|-------|---------------|----------------|
| Signal | Azure Service Health | Announces the retirement and supplies a tracking ID and timeline |
| Join | Azure Resource Graph | Correlates the signal with recommendation and resource data |
| Action | Azure Advisor | Supplies resource-level impact and migration guidance where available |

Produce a deadline-driven action register that includes resources, application
dependencies, owners, migration plans, test evidence, risk, and verification.

## When to use this skill
- The user asks which Azure services or features are retiring
- A Service Health retirement advisory is received
- The user needs impacted resources for a tracking ID
- The user wants Advisor Service Upgrade and Retirement recommendations reviewed
- The user needs a migration plan before a retirement deadline
- The user wants retirement alerting or governance assessed
- A periodic Azure lifecycle and retirement review is requested

## Coverage model and limitations
- Service Health is the awareness signal; Advisor is the preferred action source.
- Advisor recommendations use category `HighAvailability` and subcategory
  `ServiceUpgradeAndRetirement`.
- Recommendations can include upgrades not tied to a retirement. Those entries
  can have null retirement date and retiring feature; report them separately.
- Advisor and Service Retirement workbook impacted-resource coverage is not
  comprehensive.
- Service Health impacted resources are available for only a subset of active
  advisory events, can take up to two weeks to appear, and can change.
- The workbook's **All Services** view covers retirements without resource-level
  mapping. Azure Updates is an additional portfolio source.
- Current documented retirement recommendation channels apply to Azure public
  cloud. Validate sovereign-cloud support and use Microsoft's retirement impact
  analyzer when applicable.
- A missing recommendation or resource row is not proof of no impact.

## Guardrails
- Use read-only Azure CLI, Resource Graph, KQL, and inventory queries.
- Do not migrate, upgrade, deploy, delete, restart, fail over, or change alerts.
- Do not run metadata-provided Resource Graph query text without reviewing it.
- Do not expose private resource IDs, architecture, owners, support details, or
  migration plans outside the authorized report.
- Do not mark a retirement complete when the resource no longer appears in
  Advisor alone; verify application, data plane, code, and operational behavior.
- Do not postpone a mandatory retirement solely through an accepted exception;
  exceptions document risk but do not change Microsoft's deadline.
- Use UTC and record query time, source, tracking ID, and last update.

## Pre-check
Collect or infer:

| Field | Required value |
|-------|----------------|
| Cloud | Public, Government, China, or other supported environment |
| Scope | Tenant, subscriptions, resource groups, workloads, and regions |
| Workload inventory | Resources, APIs, SDKs, runtimes, images, libraries, and dependencies |
| Criticality | Production tier, SLO, data classification, and business impact |
| Ownership | Service owner, application owner, platform owner, and approver |
| Change constraints | Freeze periods, procurement, compliance, and release cadence |
| Alerting | Service Health and Advisor alert rules, action groups, and ITSM routing |
| Existing plans | Migration epics, tickets, tests, exceptions, and target architecture |

If the scope is workload-specific, include shared services and cross-subscription
dependencies. If no owner exists, create an ownership finding before planning.

## Investigation procedure

### Step 1: Verify retirement signal coverage
Use one primary alert path per scenario:

| Scenario | Primary path |
|----------|--------------|
| Awareness of a new retirement | Service Health alert |
| Resource-level remediation workflow | Advisor alert or scheduled Advisor pull |

Push and pull can coexist, but avoid duplicate alerts for the same retirement.
Tenant-level Service Health alerts don't include every subscription-level event,
so inspect both levels where supported.

Inventory Service Health activity-log alerts:

```bash
az graph query -q "resources | where type =~ 'microsoft.insights/activitylogalerts' | where tostring(properties.condition) has 'ServiceHealth' | project id, name, location, enabled=tobool(properties.enabled), scopes=properties.scopes, condition=properties.condition, actions=properties.actions" -o json
```

Check:
- Health Advisory event type is covered
- All intended subscriptions are covered
- All relevant services and regions are covered
- Global action groups route to owned channels or ITSM
- Alert delivery is tested
- Awareness and remediation paths don't create unowned duplicate tickets

### Step 2: Discover upcoming Service Health retirements
Query all upcoming retirement events:

```kusto
ServiceHealthResources
| where type =~ "Microsoft.ResourceHealth/events"
| extend
    EventType=tostring(properties.EventType),
    EventSubType=tostring(properties.EventSubType),
    Status=tostring(properties.Status),
    Title=tostring(properties.Title),
    TrackingId=tostring(properties.TrackingId),
    Summary=tostring(properties.Summary),
    Priority=tostring(properties.Priority),
    ImpactStartTime=todatetime(tolong(properties.ImpactStartTime)),
    RetirementDate=todatetime(tolong(properties.ImpactMitigationTime))
| where EventType == "HealthAdvisory"
  and EventSubType == "Retirement"
  and RetirementDate > now()
| project TrackingId, subscriptionId, Status, Title, Summary, Priority,
          ImpactStartTime, RetirementDate
| order by RetirementDate asc
```

Deduplicate subscription copies by tracking ID for the portfolio view, but retain
subscription scope for impact analysis. The tracking ID links Service Health
updates and Advisor metadata.

### Step 3: Pull Advisor retirement recommendations
Query current resource-level recommendations:

```kusto
advisorresources
| where type =~ "microsoft.advisor/recommendations"
| extend Props=parse_json(properties)
| where tostring(Props.category) == "HighAvailability"
| where tostring(Props.extendedProperties.recommendationSubCategory)
    == "ServiceUpgradeAndRetirement"
| extend
    RetiringFeature=tostring(Props.extendedProperties.retirementFeatureName),
    RetirementDate=todatetime(Props.extendedProperties.retirementDate),
    ResourceId=tolower(tostring(Props.resourceMetadata.resourceId)),
    RecommendationTypeId=tostring(Props.recommendationTypeId),
    Problem=tostring(Props.shortDescription.problem),
    Solution=tostring(Props.shortDescription.solution),
    Impact=tostring(Props.impact),
    LastUpdated=todatetime(Props.lastUpdated)
| where isnotempty(RetiringFeature)
| project subscriptionId, ResourceId, RecommendationTypeId, RetiringFeature,
          RetirementDate, Problem, Solution, Impact, LastUpdated
| order by RetirementDate asc
```

Report upgrade-only recommendations separately when `RetiringFeature` or
`RetirementDate` is empty.

#### Use the Service Retirement workbook Impacted Services view
Use **Advisor > Workbooks > Gallery > Service Retirement** when an interactive
or exportable resource-level view is required.

1. Set the **Subscription**, **Resource group**, and **Location** filters.
2. In **Retiring Azure services**, capture:
   - Service Name
   - Retiring Feature
   - Retirement Date
   - Actions
   - Number of impacted resources
3. Sort by retirement date and resource count to expose urgent, broad-impact
   retirements.
4. Select one or more service rows.
5. In the affected-resources table, capture:
   - Subscription and Subscription ID
   - Resource type and Resource Name
   - Retiring Feature and Retirement Date
   - Resource Group and Location
   - Tags
   - Recommended Action
6. Record filters and extraction time with the evidence.

Workbook exports are `.xlsx` and contain only the currently filtered data.
Never treat an export as a complete tenant inventory unless all intended scopes
and filters were explicitly selected.

Use the workbook views together:

| View | Purpose |
|------|---------|
| Impacted Services | Resource-level impact for supported retirements |
| All Services | Portfolio list and whether resource impact is available |
| Retired Services | Features past their published retirement date |

`Is available under Impacted Services = No` means resource-level analysis is
unavailable in the workbook, not that the workload is unaffected.

### Step 4: Correlate Service Health signals to impacted resources
When the workflow begins with a tracking ID:

1. Query Advisor metadata where subcategory is
   `ServiceUpgradeAndRetirement`.
2. Expand `sourceProperties.serviceRetirement.serviceHealth.trackingIds`.
3. Map tracking ID to `recommendationTypeId`.
4. Join active Advisor recommendations by recommendation type.
5. Join Service Health event data for title, status, and retirement date.

Use the current Microsoft unified-impact query from:
`service-retirement-unified-impact-queries`.

The join result should contain:

| Field | Purpose |
|-------|---------|
| Tracking ID | Stable retirement-event correlation key |
| Recommendation type ID | Maps metadata to resource recommendations |
| Retiring feature | Exact feature or service capability |
| Retirement date | Mandatory deadline |
| Resource ID | Resource-level impacted item |
| Subscription/resource group/region | Ownership and migration scope |
| Recommendation action/link | Migration guidance |
| Last refreshed | Data freshness |

Do not rely on legacy `recommendationControl` filtering. Microsoft documents
`recommendationSubCategory` as the current filter.

### Step 5: Fill resource-level coverage gaps
When Advisor or Service Health does not list impacted resources:

1. Review the Advisor Service Retirement workbook **All Services** view.
2. Review Azure Updates retirement announcements.
3. Read the retirement's supported metadata and linked documentation.
4. Inspect `recommendationDataSourceQuery` before running it.
5. Inventory matching ARM resource types and configurations.
6. Search application code, IaC, pipelines, SDK/runtime manifests, images,
   API versions, endpoints, certificates, and protocol dependencies.
7. Check data-plane features that aren't represented by an ARM resource.
8. Ask workload owners to confirm use or non-use.

Classify missing mapping as `Impact discovery required`, not `No impact`.

### Step 6: Validate workload impact
For every candidate resource or dependency:

| Check | Required evidence |
|-------|-------------------|
| Feature use | Exact retiring SKU, API, runtime, protocol, endpoint, or capability |
| Runtime activity | Current calls, traffic, jobs, data, or dependency telemetry |
| Workload relationship | Critical flow, environment, and owner |
| Replacement | Supported target and feature parity |
| Compatibility | API, SDK, data, identity, network, security, and compliance |
| Migration complexity | Code, infrastructure, data, downtime, and procurement |
| Reliability | SLO, capacity, DR, rollback, and coexistence |
| Deadline | Engineering completion date with safety buffer |

Resource existence alone doesn't prove feature use. Conversely, no matching ARM
resource doesn't rule out SDK, API, protocol, or shared-service dependency.

### Step 7: Build the retirement action register
Use these states:

| State | Meaning |
|-------|---------|
| Announced | Retirement signal received |
| Impact discovery | Scope and dependencies being identified |
| Validated impacted | Feature use confirmed |
| Not impacted | Non-use confirmed with evidence and review date |
| Plan approved | Target, owner, schedule, funding, and rollback approved |
| Build | Migration implementation in progress |
| Test | Functional, security, performance, DR, and operational validation |
| Cutover ready | Go/no-go criteria and rollback are approved |
| Migrated | Production cutover completed |
| Verified | Legacy use stopped and success criteria met |
| Closed | Evidence archived and tracking completed |
| Exception | Risk documented; deadline still applies |

Each register row must include tracking ID, recommendation type, service,
feature, deadline, days remaining, resources/dependencies, criticality, owner,
state, target, milestone dates, risk, blocker, evidence link, and next action.

### Step 8: Prioritize deadlines and migration risk
Start with time-to-retirement:

| Days remaining | Base urgency |
|----------------|--------------|
| Retired or <=30 days | Critical |
| 31-90 days | High |
| 91-180 days | Medium |
| >180 days | Planned |

Escalate for:
- Business-critical production flows
- Data migration or irreversible transformation
- Cross-tenant, cross-region, or shared-platform dependencies
- Large fleets or many application teams
- Replacement capacity, quota, procurement, or licensing requirements
- Security/compliance review or external certification
- No supported replacement or feature gap
- Long release freezes or limited test windows
- Unknown ownership or unvalidated impact

A distant deadline can still be critical when migration lead time is longer.

### Step 9: Create and validate the migration plan
For each validated impact:

1. Confirm Microsoft's recommended replacement and support dates.
2. Document current/target architecture and feature-parity gaps.
3. Define migration waves and a representative pilot.
4. Include data migration, identity, networking, security, monitoring, cost,
   capacity, quota, backup, DR, and support changes.
5. Define coexistence, rollback, and point-of-no-return.
6. Test functional behavior, performance, reliability, security, and operations.
7. Set cutover criteria and a deadline buffer.
8. Update IaC, code, pipelines, runbooks, diagrams, inventory, and ownership.
9. Verify no legacy traffic, configuration, resources, or dependencies remain.
10. Monitor Advisor and Service Health until closure.

Do not close solely because a recommendation disappears; it might be suppressed,
stale, or outside current coverage.

### Step 10: Run a recurring governance cycle
Recommended cadence:

- Immediate processing for new Service Health retirement signals
- Weekly review for items within 180 days
- Monthly portfolio pull for all active retirements and upgrades
- Quarterly alert delivery and ownership test
- Post-migration verification until Advisor and internal evidence agree

Track notification-to-owner time, discovery completion, plan approval, test
completion, deadline buffer, overdue actions, and migration verification.

## Scoring
Calculate a Retirement Readiness score:

| Dimension | Points |
|-----------|--------|
| Service Health and Advisor signal coverage | 0-20 |
| Complete impacted-resource and dependency inventory | 0-25 |
| Ownership, funding, target, and approved plan | 0-20 |
| Build, test, cutover, rollback, and operational readiness | 0-20 |
| Post-migration verification and governance evidence | 0-15 |
| **Total** | **0-100** |

| Score | Readiness |
|-------|-----------|
| 90-100 | Ready |
| 70-89 | On track |
| 40-69 | At risk |
| 0-39 | Critical |

Calculate per retirement and portfolio-wide. Missing impact data earns zero
inventory points; it doesn't count as no impact.

## Accepted exceptions
An exception must include:

| Field | Requirement |
|-------|-------------|
| Tracking ID / feature | Exact retirement signal |
| Scope | Resources, code, workload, and environment |
| Reason | Why migration is delayed or impact is disputed |
| Evidence | Current use/non-use and dependency evidence |
| Consequence | Support, availability, security, and compliance impact |
| Compensating control | Temporary containment or continuity measure |
| Owner and approver | Accountable decision makers |
| Expiry/review date | Before the retirement deadline |

An exception doesn't extend Microsoft's deadline or guarantee continued service.

## Expected output

## Azure Service Retirements Report

| Field | Value |
|-------|-------|
| Scope and cloud | Tenant/subscriptions and environment |
| Report date | YYYY-MM-DD UTC |
| Active retirements | Count |
| Validated impacted resources | Count |
| Impact discovery gaps | Count |
| Deadlines | <=30 / 31-90 / 91-180 / >180 days |
| Overdue items | Count |
| Portfolio readiness | XX/100 and status |
| Alert coverage | Service Health and Advisor status |

Required sections:
1. **Executive summary**
2. **Source coverage, workbook filters, freshness, and limitations**
3. **Retirement timeline**
4. **Impacted service/resource/dependency register**
5. **Items requiring impact discovery**
6. **Migration plans and milestone status**
7. **Critical blockers and decisions**
8. **Alerting and governance gaps**
9. **Accepted exceptions**
10. **Commands, queries, tracking IDs, and references**

Each retirement must show tracking ID, feature, deadline, source, resources,
critical flows, owner, state, target, risk, blocker, next milestone, and evidence.

## Remediation guidance
- Suggest only; never execute migrations or alert changes from this skill.
- Validate write commands with `GetAzCliHelp` when available.
- Use IaC preview/what-if before infrastructure migration.
- Pilot and test before production cutover.
- Preserve rollback until target success criteria and monitoring are satisfied.
- Escalate unsupported or ambiguous guidance through Microsoft support.
- Use official migration documentation linked from Advisor metadata.

## References
- Retirement alerting guidance: https://learn.microsoft.com/azure/service-health/service-retirement-alerting-guidance
- Service Upgrade and Retirement recommendations: https://learn.microsoft.com/azure/advisor/advisor-how-to-use-service-upgrade-retirement-recommendations
- Service Retirement workbook - Impacted Services: https://learn.microsoft.com/azure/advisor/advisor-workbook-service-retirement?tabs=impacted-services
- Unified impact queries: https://learn.microsoft.com/azure/service-health/service-retirement-unified-impact-queries
- Impacted resources: https://learn.microsoft.com/azure/service-health/impacted-resources-retirements
- Service Health Resource Graph samples: https://learn.microsoft.com/azure/service-health/resource-graph-samples
- Create Service Health alerts: https://learn.microsoft.com/azure/service-health/alerts-activity-log-service-notifications-portal
- Azure Updates retirements: https://azure.microsoft.com/updates/?updateType=retirements
- Sovereign-cloud analyzer: https://github.com/microsoft/azure-retirement-impact-analyzer

## Sample output

> Redacted example with illustrative values.

## Azure Service Retirements Report

| Field | Value |
|-------|-------|
| Scope and cloud | Contoso tenant, 12 subscriptions, Azure public cloud |
| Report date | 2026-08-04 UTC |
| Active retirements | 14 |
| Validated impacted resources | 37 |
| Impact discovery gaps | 5 retirements |
| Deadlines | 1 / 3 / 4 / 6 |
| Overdue items | 0 |
| Portfolio readiness | 66/100 - At risk |
| Alert coverage | Service Health partial; Advisor pull enabled |

### Priority retirements

| Urgency | Tracking ID | Feature | Deadline | Impact | State | Next action |
|---------|-------------|---------|----------|--------|-------|-------------|
| Critical | ABCD-123 | Legacy availability test | 2026-09-30 | 18 production tests | Test | Complete alert and dashboard validation |
| High | EFGH-456 | Legacy storage account type | 2026-10-13 | 7 accounts | Build | Finish GPv2 pilot and rollback test |
| Medium | IJKL-789 | Retiring SDK version | 2027-01-31 | Resource mapping unavailable | Impact discovery | Scan application dependency manifests |

### Coverage warning
Five retirements have no resource-level Advisor mapping. They remain open for
code, IaC, API, SDK, and owner validation; they are not classified as no impact.

No migration, upgrade, or alert change was executed by this assessment.
