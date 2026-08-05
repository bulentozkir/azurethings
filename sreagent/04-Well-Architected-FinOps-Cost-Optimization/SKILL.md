---
name: finops-cost-optimization
description: >
  Assess and prioritize Azure cost optimization opportunities using the FinOps
  Toolkit optimization workbook model and FinOps Hubs FOCUS data. Use for rate
  optimization, usage optimization, Advisor recommendations, commitments,
  Azure Hybrid Benefit, idle resources, rightsizing, waste reduction, and
  evidence-based savings plans across Azure scopes.
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

Use complete billing periods for trends and commitment decisions. Use 7, 30,
and 60-day lookback windows when comparing reservation and savings plan
recommendations, as supported by the optimization workbook.

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
| where ChargePeriodStart >= startofmonth(ago(120d))
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
Use `CommitmentDiscountUsage()` and the FinOps Hubs rate optimization report to
identify underutilized commitments. Keep quantities and units separate and
validate portal utilization before proposing scope or renewal changes.

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
| Baseline monthly cost | Amount |
| Gross source savings | Amount/year |
| Validated non-overlapping savings | Amount/year and percentage |
| Maturity score | XX/100 and level |

Required sections:
1. **Executive summary**
2. **Data quality and assumptions**
3. **Cost baseline and top drivers**
4. **Rate optimization** - Hybrid Benefit, reservations, savings plans
5. **Usage optimization** - compute, storage, networking, and services
6. **Deduplicated savings summary**
7. **Prioritized backlog** - quick wins, plan next, investigate
8. **Implementation sequence**
9. **Verification and realized-savings plan**
10. **Accepted exceptions**
11. **Commands and queries used**
12. **References**

Every recommendation row must include source, resource/scope, current cost,
savings period, estimated savings, confidence, overlap group, risk, owner,
next action, and verification method.

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

### Rate optimization

| Opportunity | Savings/year | Confidence | Decision |
|-------------|--------------|------------|----------|
| SQL Hybrid Benefit | $96,000 | Medium | Confirm Software Assurance |
| VM reservations | $180,000 | Medium | Recalculate after rightsizing |
| Savings plan residual | $72,000 | Low | Mutually exclusive with part of VM RI |

### Usage optimization

| Opportunity | Savings/year | Confidence | Decision |
|-------------|--------------|------------|----------|
| Deallocate 14 stopped VMs | $84,000 | High | Quick win after owner approval |
| Remove 31 unattached disks | $18,000 | High | Excludes ASR and legal-hold disks |
| Rightsize 9 VMs | $60,000 | Medium | Validate memory and seasonal peaks |

### Implementation sequence
1. Apply approved waste removal and rightsizing.
2. Wait for refreshed commitment recommendations.
3. Purchase validated reservations.
4. Apply savings plan only to uncovered eligible spend.

**Excluded overlap:** $252,000/year of reservation and savings plan estimates
targeted the same pre-rightsizing usage and was removed from validated savings.
