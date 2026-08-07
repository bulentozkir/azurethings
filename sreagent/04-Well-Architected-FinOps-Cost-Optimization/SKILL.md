---
name: finops-cost-optimization
description: >
  Assess and prioritize Azure cost optimization opportunities using the FinOps
  Toolkit optimization workbook model and FinOps Hubs FOCUS data. Use for rate
  optimization, usage optimization, Advisor recommendations, daily reservation
  and savings-plan utilization, cost anomalies, Azure Hybrid Benefit, idle
  resources, rightsizing, waste reduction, and evidence-based savings plans.
tools:
  - RunAzCliReadCommands
  - execute_kusto_query
  - AzureMCP/*
  - MicrosoftLearnMCP/*
---

# Azure Cost Optimization with FinOps Hubs

> **Required MCP grounding:** Before conclusions, use `AzureMCP/*` for live Azure evidence and `MicrosoftLearnMCP/*` for current authoritative guidance. If either connector is unavailable, report a blocking evidence gap instead of relying on model memory.

## Purpose
Perform a read-only Azure cost optimization assessment modeled after the
Microsoft FinOps Toolkit optimization workbook. Analyze **Rate optimization**
and **Usage optimization** in that report order, using FinOps Hubs as the
preferred source for normalized FOCUS cost data and recommendations.

Produce a non-overlapping, confidence-rated savings plan that protects
reliability, security, performance, and business commitments. Savings are
estimates until validated against negotiated prices, actual usage, workload
requirements, and implementation results.

## When to use this skill
- The user asks how to reduce or optimize Azure cost
- The user asks for FinOps Hubs or optimization workbook analysis
- The user wants Advisor, reservation, savings plan, or Hybrid Benefit review
- The user wants last-day commitment utilization or cost spike/dip detection
- The user wants idle resource, rightsizing, or waste identification
- The user wants a monthly cost optimization review or backlog
- The user needs validated savings estimates and implementation priorities

## Operating model
Use this source priority:

1. FinOps Hubs `Costs()`, `Recommendations()`, and
   `CommitmentDiscountUsage()` functions in the Hub database
2. Azure Advisor and Azure Resource Graph for current recommendations/state
3. Azure Cost Management query for cost when FinOps Hubs is unavailable
4. Azure Monitor metrics for utilization validation

Do not deploy or modify FinOps Hubs from this skill. If a hub is unavailable,
continue with supported Azure sources and state which FOCUS analyses are
unavailable.

## Guardrails
- Run read-only Azure CLI, Resource Graph, KQL, and metrics queries.
- Do not apply workbook Quick Fix actions automatically.
- Do not delete, stop, deallocate, resize, migrate, retier, change redundancy,
  buy commitments, enable Hybrid Benefit, or change licenses without approval.
- Never expose billing account details, negotiated rates, invoice identifiers,
  sensitive tags, or recommendation metadata outside the approved report scope.
- Analyze each billing currency separately; never sum unlike currencies.
- State whether each figure uses `BilledCost`, `EffectiveCost`, `ContractedCost`,
  or `ListCost`. Do not mix cost bases in one comparison.
- Treat current-month data as partial and distinguish forecast from actual cost.
- Do not promise savings. Label estimates, assumptions, confidence, and overlap.
- Reject optimizations that violate workload SLOs, resilience, security,
  compliance, licensing, support, or data-retention requirements.

## Pre-check
Collect or infer:

| Field | Required value |
|-------|----------------|
| Scope | Billing scope, management group, subscriptions, resource groups, or tags |
| Period | Default: last 3 complete months plus month-to-date |
| Cost basis | `EffectiveCost` for economics; `BilledCost` for invoice views |
| Currency | One billing currency per result set |
| Hub source | ADX/Fabric Hub database and dataset freshness |
| Exclusions | Sandboxes, planned capacity, disaster recovery, legal retention |
| Commitments | Existing reservations, savings plans, terms, and renewal dates |
| Licensing | Software Assurance and Hybrid Benefit eligibility |
| Ownership | Workload owner, finance owner, and approver |

Use the latest fully ingested completed UTC day for daily controls and the prior
60 complete days for anomaly context. Use complete billing periods for trends
and 7, 30, and 60-day lookbacks for commitment purchase recommendations.

## Assessment procedure

### Step 1: Validate FinOps Hubs data readiness
Query the Hub database functions, not raw ingestion tables. The stable functions
provide schema compatibility across hub versions.

**Cost freshness and coverage**

```kusto
Costs()
| summarize
    FirstCharge=min(ChargePeriodStart),
    LastCharge=max(ChargePeriodEnd),
    LastIngestion=max(x_IngestionTime),
    Rows=count(),
    Subscriptions=dcount(SubAccountId),
    Currencies=dcount(BillingCurrency)
```

**Recommendation freshness and sources**

```kusto
Recommendations()
| summarize
    Recommendations=count(),
    LastRecommendation=max(x_RecommendationDate),
    LastIngestion=max(x_IngestionTime)
  by x_SourceProvider, x_SourceType, x_SourceName
| order by LastIngestion desc
```

**Commitment usage coverage**

```kusto
CommitmentDiscountUsage()
| summarize
    FirstUsage=min(ChargePeriodStart),
    LastUsage=max(ChargePeriodEnd),
    LastIngestion=max(x_IngestionTime),
    Rows=count()
  by CommitmentDiscountCategory, CommitmentDiscountType
```

Check for:
- Missing scopes or exports
- Stale ingestion or gaps between charge dates
- Multiple billing currencies
- Missing recommendation sources
- Incomplete current-month data
- Hub functions or columns that differ from the current data model

If data is stale or incomplete, reduce confidence and do not extrapolate the
missing period as zero cost.

### Step 2: Establish the FOCUS cost baseline
Use `EffectiveCost` for amortized economic analysis and `BilledCost` for invoice
reconciliation. Retain `ListCost` and `ContractedCost` only for rate comparisons.

```kusto
Costs()
| where ChargePeriodStart >= startofmonth(now(), -3)
| where ProviderName =~ "Microsoft"
| summarize
    EffectiveCost=sum(EffectiveCost),
    BilledCost=sum(BilledCost),
    ContractedCost=sum(ContractedCost),
    ListCost=sum(ListCost)
  by Month=startofmonth(ChargePeriodStart), BillingCurrency
| order by Month asc
```

Identify the largest current cost drivers.

```kusto
Costs()
| where ChargePeriodStart >= startofmonth(ago(90d))
| where ProviderName =~ "Microsoft"
| summarize EffectiveCost=sum(EffectiveCost)
  by BillingCurrency, ServiceName, ResourceType, SubAccountName
| top 25 by EffectiveCost desc
```

Break down cost by workload tags only when tag quality is sufficient. Track
untagged cost separately; do not infer ownership from a resource name unless
the user confirms the naming convention.

### Step 2.1: Run last-day critical controls
Use the latest fully ingested completed UTC usage date (`D`), never a partial
current day. Report source freshness and scope coverage. Missing or pending data
is **Unknown**, not zero utilization, zero cost, or a healthy result.

#### Reservation utilization gate
Query daily Reservation Summaries and Reservation Details for `D`.
- If `AvgUtilizationPercentage < 100.0` or `UsedHours < ReservedHours`, classify
  **Critical - unutilized reservation**. Do not average it away or downgrade it.
- Report reservation/order IDs, display name, SKU, scope, region, quantity,
  used/reserved hours, utilization, unused quantity, and affected resources.
- Show 7-day and 30-day context and recheck after refresh because last-day data
  can change. Evaluate prepurchase plans against their term balance separately.

#### Savings plan utilization gate
Query Benefit Utilization Summaries at daily grain for `D`.
- If daily `AvgUtilizationPercentage < 100.0`, classify
  **Critical - unutilized savings plan**. Do not average it away or downgrade it.
- Report benefit/order IDs, display name, scope, hourly commitment and currency,
  average/minimum/maximum utilization, unused commitment, and covered resources.
- Treat a new plan with no data for up to 48 hours, or a normal 2-24 hour refresh
  delay, as **Data pending** and recheck; never infer 0% utilization.

#### Resource-group cost spike and dip detection
Run native Cost Management subscription anomaly insights first; they compare a
day with a forecast based on the prior 60 days and can take 36 hours after UTC
day-end. Also calculate daily `EffectiveCost` by resource group and currency.
- Flag as **Critical** when native detection identifies a positive/negative anomaly, or
  when a 60-day robust z-score is at least 3.5, absolute change is at least 50%,
  and the change exceeds the approved currency-specific materiality floor.
- Treat material new cost from zero and removed cost to zero as candidates.
- For each flagged group, compare `D` with each resource's 60-day median. Report
  resource ID/name/type, service, meter, latest cost, baseline, delta, delta
  percentage, and share of the resource-group delta, ranked by absolute impact.
- Correlate Resource Graph and Activity Log changes. A cost dip can indicate an
  outage, deletion, missing ingestion, or benefit reassignment, not savings.

### Step 3: Build the current recommendation inventory
FinOps Hubs combines Cost Management reservation recommendations, Azure Advisor
cost recommendations, and custom Resource Graph recommendations.

```kusto
Recommendations()
| extend RecommendationKey=coalesce(
    x_RecommendationId,
    strcat(x_SourceType, "|", ResourceId, "|", x_RecommendationDescription))
| summarize arg_max(x_IngestionTime, *) by RecommendationKey
| project
    x_RecommendationDate,
    x_SourceProvider,
    x_SourceType,
    x_SourceName,
    x_RecommendationCategory,
    x_RecommendationDescription,
    ResourceId,
    ResourceName,
    ResourceType,
    SubAccountId,
    SubAccountName,
    x_ResourceGroupName,
    x_EffectiveCostBefore,
    x_EffectiveCostAfter,
    x_EffectiveCostSavings,
    x_RecommendationDetails
| order by x_EffectiveCostSavings desc
```

For every recommendation:
1. Confirm the resource still exists and the recommendation is current.
2. Confirm the finding is not an accepted exception.
3. Validate configuration and utilization with read-only resource/metric data.
4. Normalize savings to the same currency and monthly or annual period.
5. Identify overlap with other recommendations for the same usage.
6. Assign confidence and implementation risk.

Null or zero `x_EffectiveCostSavings` means the source did not provide a
monetary estimate; it does not mean the opportunity has no value.

### Step 4: Rate optimization
Present this section first to match the FinOps optimization workbook.

#### 4.1 Review current realized rates
Use FOCUS values to show realized discount context, not actionable savings.

```kusto
Costs()
| where ChargePeriodStart >= startofmonth(ago(90d))
| where ProviderName =~ "Microsoft"
| summarize
    EffectiveCost=sum(EffectiveCost),
    ContractedCost=sum(ContractedCost),
    ListCost=sum(ListCost)
  by BillingCurrency, PricingCategory, CommitmentDiscountType, ServiceName
| extend DiscountVsList=max_of(0.0, ListCost-EffectiveCost)
| order by EffectiveCost desc
```

Do not attribute `ListCost - EffectiveCost` entirely to reservations or savings
plans; it can include negotiated and commitment discounts.

#### 4.2 Azure Hybrid Benefit
Review potential Windows VM/VMSS, Linux VM/VMSS, SQL VM, Azure SQL Database,
SQL Managed Instance, and Azure Stack HCI eligibility.

Require confirmation of Software Assurance, subscription type, license
assignment rights, workload OS/database edition, and compliance ownership.
Recommendations do not apply when equivalent license discounts are already
included, such as eligible Dev/Test scenarios.

#### 4.3 Reservations
Review Cost Management reservation recommendations by 7, 30, and 60-day
lookback and 1-year or 3-year term. Validate stable baseline usage, SKU, region,
scope, instance-size flexibility, architecture plans, and existing coverage.

Start small with high-confidence usage. Do not buy based only on a short spike,
seasonal peak, migration, or workload scheduled for retirement.

#### 4.4 Azure savings plan for compute
Evaluate savings plan recommendations for stable compute spend that needs more
flexibility across eligible resource types, SKUs, and regions. Compare with
reservation economics; do not count the same usage in both opportunities.

#### 4.5 Existing commitment utilization
Use the Step 2.1 daily gates as the source of record, then use
`CommitmentDiscountUsage()` and the FinOps Hubs report for cost attribution.
Keep quantities and units separate and validate refreshed utilization before
proposing scope, exchange, return, or renewal actions.

### Step 5: Usage optimization
Validate workload need and utilization before recommending any change.

| Area | Workbook and FinOps Hubs checks |
|------|---------------------------------|
| Virtual machines | Stopped but allocated VMs; deallocated VMs with billable disks/networking; Advisor rightsizing; managed disk migration |
| VM scale sets | Spot eligibility, Spot Priority Mix, autoscale, and right SKU |
| AKS | Cluster autoscaler, HPA, Spot node pools, start/stop, node SKU and commitment coverage |
| App Service | Stopped apps, empty plans, autoscale, V2-to-V3 economics, reservation eligibility |
| Databases | Unused Azure SQL elastic pools, Advisor recommendations, stable reserved-capacity candidates |
| Managed disks | Unattached disks excluding Azure Site Recovery; premium snapshots; snapshots with deleted sources |
| Storage | GPv1 upgrade, lifecycle management, access tiers, reserved capacity, stale snapshots |
| Backup | Idle protection, failed/stale backups, and redundancy aligned to approved recovery requirements |
| Networking | Idle gateways, empty backend pools, unattached public IPs/NICs, orphan NAT gateways, empty NSGs, unassociated DDoS plans |
| Azure Firewall | Premium features in use, regional consolidation, and cross-region traffic risk |
| ExpressRoute | Unprovisioned circuits and business-approved connectivity requirements |
| Azure Monitor | Ingestion trends, table plans, commitment tiers, restored tables, and dedicated cluster economics |
| Other services | Synapse workspaces without pools and current Advisor cost recommendations |

For rightsizing:
- Use at least 14 days of metrics and prefer 30 days for variable workloads.
- Review p50, p95, peak, seasonality, autoscale, failover, and deployment events.
- Include memory when available; CPU alone is insufficient.
- Verify target SKU capability, quotas, disks, networking, zones, and SLA impact.
- Calculate savings with actual negotiated cost where available.

For idle-resource findings:
- Verify attachments, dependencies, locks, backup/DR use, retention, and owner.
- A deallocated VM stops compute cost but attached disks and networking can bill.
- Do not treat missing metrics as proof of idleness.

### Step 6: Deduplicate and sequence savings
Recommendations can overlap because rightsizing, reservations, and savings plans
may analyze the same on-demand usage.

Create one recommendation group per resource or usage pool and mark alternatives
as mutually exclusive. Report:

- **Gross source savings**: sum before overlap removal
- **Validated non-overlapping savings**: implementation planning estimate
- **Realized savings**: measured after the change

Use this implementation sequence:

1. Remove or shut down validated waste and rightsize usage.
2. Wait for Advisor and Cost Management recommendations to refresh; Microsoft
   notes updated commitment recommendations can take about three days.
3. Re-evaluate and purchase high-confidence reservations.
4. Cover eligible residual compute spend with savings plans.
5. Monitor commitment utilization, coverage, and realized savings.

This execution order supersedes the workbook's display order.

### Step 7: Prioritize the backlog
Score each opportunity:

| Factor | Weight |
|--------|--------|
| Validated non-overlapping annual savings | 30% |
| Evidence confidence | 20% |
| Implementation effort | 15% |
| Reversibility | 10% |
| Reliability/security/performance risk | 15% |
| Owner and approval readiness | 10% |

Classify:
- **Quick win**: high confidence, low risk, reversible, owner identified
- **Plan next**: material savings with testing or architecture work required
- **Investigate**: plausible opportunity with missing utilization or ownership
- **Do not pursue**: invalid, duplicate, exception, or unacceptable risk

## Scoring
Calculate an Azure Cost Optimization maturity score:

| Dimension | Points |
|-----------|--------|
| FinOps Hubs coverage, freshness, and FOCUS data quality | 0-20 |
| Rate optimization coverage and commitment utilization | 0-20 |
| Usage optimization and rightsizing discipline | 0-25 |
| Recommendation deduplication and savings validation | 0-20 |
| Ownership, exceptions, implementation, and realization tracking | 0-15 |
| **Total** | **0-100** |

| Score | Maturity |
|-------|----------|
| 90-100 | Optimized |
| 70-89 | Managed |
| 40-69 | Developing |
| 0-39 | Initial |

Missing data earns zero points; it is not evidence of optimization.
Any confirmed reservation or savings-plan utilization below 100% must appear as
**Critical** in the executive summary regardless of the maturity score.

## Accepted exceptions
If the user provides approved exceptions, exclude them from actionable savings
and scoring. List the resource, reason, owner, approval date, and review date.

Examples:

| Finding | Accepted reason |
|---------|-----------------|
| Low-utilization standby VM | Required for documented disaster recovery |
| Unattached disk | Retained under legal hold until a specified date |
| Premium firewall without current premium traffic | Feature rollout approved next month |
| No commitment purchase | Workload retirement is scheduled within six months |

Expired or out-of-scope exceptions must be investigated normally.

## Expected output

## Azure FinOps Cost Optimization Report

| Field | Value |
|-------|-------|
| Scope | Billing scope and subscriptions |
| Analysis period | Complete months plus MTD |
| Billing currency | Currency |
| Cost basis | Effective / Billed |
| FinOps Hubs freshness | Last cost and recommendation ingestion |
| Latest daily control date | Latest complete utilization and cost date |
| Baseline monthly cost | Amount |
| Gross source savings | Amount/year |
| Validated non-overlapping savings | Amount/year and percentage |
| Maturity score | XX/100 and level |

Required sections:
1. **Executive summary**
2. **Data quality and assumptions**
3. **Last-day critical controls** - reservations, savings plans, cost anomalies
4. **Cost baseline and top drivers**
5. **Rate optimization** - Hybrid Benefit, reservations, savings plans
6. **Usage optimization** - compute, storage, networking, and services
7. **Deduplicated savings summary**
8. **Prioritized backlog** - quick wins, plan next, investigate
9. **Implementation sequence and verification**
10. **Accepted exceptions**
11. **Commands and queries used**
12. **References**

Every recommendation row must include source, resource/scope, current cost,
savings period, estimated savings, confidence, overlap group, risk, owner,
next action, and verification method.
Daily-control rows must also include source date, utilization or baseline,
absolute/percentage delta, severity, freshness, and contributing resources.

## Remediation guidance
- Suggest changes only; never execute them from this skill.
- Validate Azure CLI write syntax with `GetAzCliHelp` when available.
- Require owner approval and a rollback plan before resource changes.
- Require procurement/licensing approval before commitments or Hybrid Benefit.
- Recalculate commitments after usage optimization.
- Measure realized savings against a normalized baseline after implementation.
- Link each action to official Microsoft Learn guidance.

## References
- FinOps Toolkit optimization workbook: https://learn.microsoft.com/cloud-computing/finops/toolkit/workbooks/optimization
- Cost Optimization workbook details: https://learn.microsoft.com/azure/advisor/advisor-workbook-cost-optimization
- FinOps Hubs overview: https://learn.microsoft.com/cloud-computing/finops/toolkit/hubs/finops-hubs-overview
- FinOps Hubs data model: https://learn.microsoft.com/cloud-computing/finops/toolkit/hubs/data-model
- Configure Hubs recommendations: https://learn.microsoft.com/cloud-computing/finops/toolkit/hubs/configure-recommendations
- Optimize usage and cost: https://learn.microsoft.com/cloud-computing/finops/framework/optimize/optimize-cloud-usage-cost
- Rate optimization: https://learn.microsoft.com/cloud-computing/finops/framework/optimize/rates
- Calculate Advisor savings: https://learn.microsoft.com/azure/advisor/advisor-how-to-calculate-total-cost-savings
- Advisor cost recommendations: https://learn.microsoft.com/azure/advisor/advisor-reference-cost-recommendations
- FOCUS overview: https://learn.microsoft.com/cloud-computing/finops/focus/what-is-focus
- Reservation utilization: https://learn.microsoft.com/azure/cost-management-billing/reservations/reservation-utilization
- Savings plan utilization: https://learn.microsoft.com/azure/cost-management-billing/savings-plan/view-utilization
- Cost anomaly investigation: https://learn.microsoft.com/azure/cost-management-billing/understand/analyze-unexpected-charges
- Cost Management automation APIs: https://learn.microsoft.com/azure/cost-management-billing/manage/cost-management-automation-scenarios

## Sample output

> Redacted example with illustrative values.

## Azure FinOps Cost Optimization Report

| Field | Value |
|-------|-------|
| Scope | Contoso production subscriptions |
| Analysis period | 2026-05-01 to 2026-07-31 plus August MTD |
| Billing currency | USD |
| Cost basis | EffectiveCost |
| FinOps Hubs freshness | Costs: 2026-08-03; recommendations: 2026-08-04 |
| Baseline monthly cost | $420,000 |
| Gross source savings | $690,000/year |
| Validated non-overlapping savings | $438,000/year (8.7%) |
| Maturity score | 74/100 - Managed |

### Last-day critical controls

| Control | Latest complete day | Finding | Severity |
|---------|---------------------|---------|----------|
| VM reservation | 2026-08-04 | 92.4%; 1.8 of 24 reserved hours unused | Critical |
| Compute savings plan | 2026-08-04 | 97.1%; $14.50 commitment unused | Critical |
| `rg-orders-prod` anomaly | 2026-08-04 | +68%; VM scale set and egress drove 91% of delta | Critical |

**Next action:** Investigate these critical controls before resource changes or
new commitment purchases; keep overlapping savings estimates excluded.
