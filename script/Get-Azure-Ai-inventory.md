# Get-Azure-Ai-inventory.ps1 - Azure AI Inventory

[Get-Azure-Ai-inventory.ps1](./Get-Azure-Ai-inventory.ps1) is a read-only PowerShell 7 script that builds an
**Azure AI Inventory** Excel workbook (`.xlsx`). The workbook covers the 16 AI services and 7 classic AI services
listed in the Azure portal (Microsoft Foundry > AI services). It also covers model deployments, usage, cost,
Azure Advisor, service retirements, Azure Service Health, Microsoft Defender for Cloud, security hygiene, content
filters, capacity and quota, the total AI spend, and Machine Learning computes.

This document explains how to run the script, how it collects and interprets the data, and what every sheet, table,
column and visual of the workbook contains.

- [1. Quick start](#1-quick-start)
- [2. Requirements](#2-requirements)
- [3. Parameters](#3-parameters)
- [4. Execution flow](#4-execution-flow)
- [5. Logic and rules](#5-logic-and-rules)
- [6. Workbook reference](#6-workbook-reference)
- [7. Conditional highlights](#7-conditional-highlights)
- [8. Assumptions and limitations](#8-assumptions-and-limitations)
- [9. Troubleshooting](#9-troubleshooting)

---

## 1. Quick start

```powershell
Install-Module Az.Accounts, ImportExcel -Scope CurrentUser        # once
Connect-AzAccount                                                   # sign in (any tenant you can access)

# Every subscription the signed-in identity can read in the current tenant
./Get-Azure-Ai-inventory.ps1

# Another tenant, a list of subscriptions, custom output path
./Get-Azure-Ai-inventory.ps1 -TenantId '<tenant-id>' -Subscriptions @('<sub-id-1>', '<sub-id-2>') `
    -OutputPath "$HOME\Downloads\AzureAIInventory_Contoso.xlsx"

# Management group scope, 60-day window, open the workbook when done
./Get-Azure-Ai-inventory.ps1 -ManagementGroupId contoso-platform -UsageDays 60 -Show
```

The console prints one line per step (`[ 1/11] ... [11/11]`) and then a summary: resources, deployments, cost, total
AI spend, Advisor, retirements, Service Health, Defender, security hygiene, content filters, capacity and quota, ML
computes, and the run duration. A count read from a source that failed is marked *(incomplete)*, and *n/a* means the
check was skipped (e.g. `-SkipMetrics`) or had no data. A typical run takes 3-6 minutes for a few dozen AI resources.
Cost Management throttling is the main variable.

Every call is **read-only**. The script only issues GET requests, plus the POST query APIs of Resource Graph and
Cost Management. It never changes a resource, a setting or the saved Az context.

## 2. Requirements

| Item | Requirement |
|---|---|
| PowerShell | 7.2 or later (`#Requires -Version 7.2`; uses `ForEach-Object -Parallel`) |
| Modules | `Az.Accounts` (token acquisition) and `ImportExcel` (EPPlus, workbook creation). No other Az modules are used. |
| Sign-in | `Connect-AzAccount` before the run. For another tenant, `-TenantId` reuses the signed-in account. If no token can be obtained silently, run `Connect-AzAccount -TenantId <tenant>` first. |
| Excel | Excel desktop is recommended to view the pivot tables and charts. They are calculated when the workbook opens. |

**Permissions (RBAC)** - missing permissions never stop the run. They blank the affected columns or sections, and
each gap is listed under **Data collection notes** at the bottom of the Summary sheet.

| Role on the scope | Data it unlocks |
|---|---|
| Reader | Inventory (Resource Graph), model deployments, Foundry projects, content filter policies, model quota, model catalog, Azure Monitor metrics, activity log, diagnostic settings, resource locks, ML computes, Advisor, Service Health |
| Security Reader | Defender for Cloud plans, recommendations (assessments) and security alerts |
| Cost Management Reader (or Billing Reader) | Actual and amortized cost, reservation names, AI cost reconciliation and subscription totals |

## 3. Parameters

| Parameter | Default | Description |
|---|---|---|
| `-OutputPath` | `.\AzureAIInventory_<yyyyMMdd-HHmm>.xlsx` | Workbook path. `.xlsx` is appended if missing, the folder is created, and an existing file is overwritten (it must not be open in Excel). |
| `-TenantId` | Tenant of the current Az context | Tenant (ID or domain) to inventory. The signed-in account is reused and the saved context is not changed. |
| `-SubscriptionId` (alias `-Subscriptions`) | All readable subscriptions of the tenant | One or more subscription IDs (array) that scope the inventory. These subscriptions are also included in the AI cost reconciliation. |
| `-ManagementGroupId` | - | Management group scope. Ignored when `-SubscriptionId` is used. |
| `-UsageDays` | 30 (1-90) | Look-back window for token usage metrics, right-sizing, content filter request counts and cost. The window is a rolling one, ending at the start of the run. |
| `-CostType` | `AmortizedCost` | Measure used by the *Token cost per deployed model* and *ML workspace cost* charts (`AmortizedCost` or `ActualCost`). Tables always show both. |
| `-EventDays` | 90 (1-365) | Look-back for resolved Service Health events, Defender alerts and the activity log (the activity log is capped at 90 days). Active Service Health events are always included. |
| `-CriticalDays` | 60 | A retirement within this many days is `CRITICAL`. |
| `-WarningDays` | 180 | A retirement within this many days is `WARNING` (raised to `-CriticalDays` if lower). |
| `-ThrottleLimit` | 8 (1-32) | Parallel ARM calls in the per-resource collection phases. |
| `-SkipCost` | off | Skips Cost Management. Cost columns, cost pivots and the AI Cost Reconciliation sheet are empty. |
| `-SkipMetrics` | off | Skips Azure Monitor metrics. Tokens, requests, right-sizing and filter counts are empty. |
| `-SkipModelLifecycle` | off | Skips the model catalog: no lifecycle, retirement dates or suggested upgrades for deployments. Model quota is still read and mapped by naming convention. |
| `-SkipActivityLog` | off | Skips the activity log. The key retrieval and rotation columns of Security Hygiene are empty. |
| `-AllServiceHealthEvents` | off | Includes every Service Health event of the AI subscriptions, not only AI-related events. |
| `-ShowDataSheets` | off | Keeps the four `Data_*` pivot source sheets visible. |
| `-Show` | off | Opens the workbook when done. |

## 4. Execution flow

The script runs 11 steps. Each ARM call goes through one self-contained REST helper. It uses an ARM token for
`-TenantId` (refreshed per batch), retries HTTP 429 and 5xx up to 6 times honouring `Retry-After`, and follows
`nextLink` paging.

| Step | What happens | APIs |
|---|---|---|
| 0. Preflight | Checks modules and sign-in, resolves the tenant, output path and time windows. | `Get-AzContext`, `Get-AzAccessToken` |
| 1. Subscriptions and regions | Gets an ARM token for the tenant (fails fast with a `Connect-AzAccount -TenantId` hint), then lists the subscriptions in scope and the region display names. | Resource Graph `resourcecontainers`, ARM `locations` |
| 2. AI resources | Queries Cognitive Services accounts, ML workspaces (hubs, hub projects, workspaces), AI Search services, Bot services and ML endpoints, and maps them to the 23 services. The script **stops** if a core inventory query fails, so that it never under-reports. It also finds Power Platform accounts (for Copilot Studio cost). | Azure Resource Graph `resources` |
| 3. Deployments, projects and metrics | For each Foundry / Azure OpenAI account (in parallel): model deployments, Foundry projects, content filter (RAI) policies, and Azure Monitor metrics (tokens, requests, busiest hour, HTTP 429 per day, last request, PTU utilization, content filter counts, API calls). | ARM `accounts/deployments`, `accounts/projects`, `accounts/raiPolicies`, `Microsoft.Insights/metrics` |
| 4. Hygiene and ML data | Diagnostic settings of every AI resource, management locks per subscription, activity-log key operations, ML computes (paged), and workspace dependencies (storage, key vault, registry, App Insights). | ARM `diagnosticSettings`, `Microsoft.Authorization/locks`, `eventtypes/management/values`, `workspaces/computes`; Resource Graph |
| 5. Model lifecycle and quota | Model catalog and model quota (usages) for each subscription and region that hosts model accounts. Retirement risk, suggested upgrade, quota and right-sizing are resolved per deployment. | ARM `locations/{region}/models`, `locations/{region}/usages` |
| 6. Cost | Actual and amortized cost per resource x meter x reservation, AI cost outside the AI resources, and subscription totals. | Cost Management `query` (API 2023-11-01) |
| 7. Advisor | Active recommendations for AI resources, plus subscription-level AI recommendations (e.g. PTU reservations). | Resource Graph `advisorresources` |
| 8. Service Health | Active events and events from the last `-EventDays` days that concern AI services or impact AI resources. | Resource Graph `servicehealthresources` |
| 9. Defender for Cloud | Plans (Defender for AI services, Defender CSPM), assessments and alerts for the AI resources. | Resource Graph `securityresources` |
| 10. Shape datasets | Builds every table: service rows, deployments, token cost per model, deployment cost estimates, retirements, security hygiene, content filters, right-sizing, quota, ML computes and dependencies, reconciliation. | - |
| 11. Build workbook | Writes the sheets, tables, formulas, conditional highlights, pivot tables and pivot charts (EPPlus), then saves. | - |

## 5. Logic and rules

### 5.1 Service mapping

| Group | Service (sheet) | Resource type / kind |
|---|---|---|
| Use with Foundry | Foundry | `Microsoft.CognitiveServices/accounts` kind `AIServices` + model deployments + Foundry projects |
| | AI Hubs | `Microsoft.MachineLearningServices/workspaces` kind `Hub` + hub-based projects (kind `Project`) + endpoints |
| | Azure OpenAI | Cognitive Services kind `OpenAI` + model deployments |
| | AI Search | `Microsoft.Search/searchServices` |
| More services | Bot services | `Microsoft.BotService/botServices` |
| | Computer vision / Custom vision / Content safety / Document intelligence / Face API / Health Insights / Immersive reader / Language service / Speech service / Translator | Cognitive Services kinds `ComputerVision`, `CustomVision.Training` + `CustomVision.Prediction`, `ContentSafety`, `FormRecognizer`, `Face`, `HealthInsights`, `ImmersiveReader`, `TextAnalytics` + `ConversationalLanguageUnderstanding` + `LanguageAuthoring`, `SpeechServices`, `TextTranslation` |
| | Machine Learning | ML workspaces kind `Default` / `FeatureStore` + endpoints |
| Classic AI services | Anomaly detector (classic), Multi-service account (classic), Content moderator (classic), Lang. understanding (classic), Metrics advisor (classic), Personalizer (classic), QnA maker (classic) | Cognitive Services kinds `AnomalyDetector`, `CognitiveServices`, `ContentModerator`, `LUIS` + `LUIS.Authoring`, `MetricsAdvisor`, `Personalizer`, `QnAMaker` + `QnAMaker.v2` |

The classic services carry their retirement date and migration guidance (Microsoft Learn): Anomaly detector
2026-10-01, Content moderator 2027-03-15, LUIS 2025-10-01, Metrics advisor 2026-10-01, Personalizer 2026-10-01,
QnA maker 2025-03-31. The multi-service account has no announced date.

### 5.2 Usage metrics (Foundry and Azure OpenAI deployments)

| Measure | Rule |
|---|---|
| Input / output / total tokens, requests | Sum over `-UsageDays` of `InputTokens` / `OutputTokens` / `TotalTokens` / `ModelRequests`. Falls back to the classic Azure OpenAI metrics (`ProcessedPromptTokens`, `GeneratedTokens`, `TokenTransaction`, `AzureOpenAIRequests`). |
| Peak TPM (busiest hour) | Tokens of the busiest hour / 60. Azure Monitor has no per-minute totals over 30 days, so this is the average rate within the busiest hour. |
| Peak % of TPM limit | Peak TPM / the deployment's token rate limit (`rateLimits` key `token`). Blank for PTU, image, audio and video deployments, which have no token limit. |
| Throttled requests (429) | Requests with `StatusCode = 429` within the usage window, counted from daily buckets. |
| Last request date / Idle days | Last day with at least one request in the last **90 days**. Idle days = today minus the last request. With no request in 90 days: days since creation (capped at 90). |
| PTU utilization avg / peak | Hourly average of `AzureOpenAIProvisionedManagedUtilizationV2` (fallback `ProvisionedUtilization`). Avg = sum of the hourly averages / hours in the window (or hours since creation). Peak = the busiest hour. |
| Requests screened / harmful / blocked | `RAITotalRequests`, `RAIHarmfulRequests`, `RAIRejectedRequests` over the usage window. |
| API calls (all Cognitive accounts) | `TotalCalls` over the usage window. |

### 5.3 Cost

- Cost Management is queried per subscription for **ActualCost** and **AmortizedCost** over the usage window. It is
  filtered to the AI resource types (Cognitive Services, ML workspaces + endpoints + computes, AI Search, Bot
  Service) and grouped by resource, meter, meter sub-category, meter category and reservation name. Back ends that
  allow only two groupings are handled with extra two-dimension queries.
- Each cost is shown as three columns:
  - **Actual cost**: what was billed. PTU reservation usage shows 0 here; the purchase is a separate charge.
  - **Amortized cost**: reservation and savings plan purchases spread over the resources that use them.
  - **Reservation name**: the reservation that covers the usage.
- Sub-resource cost rolls up to the top-level resource. A **hub includes its projects**, shown as *Projects actual /
  amortized cost* on the AI Hubs sheet and added to the hub on the Summary and in the pivots. Hub projects whose hub is
  outside the scope are listed on the AI Hubs sheet too, and their cost counts toward AI Hubs.
- Resources that were billed in the window but are not on a service sheet (deleted, or kinds outside the 23
  services) still count in the cost KPIs. The Summary shows them on their own *Not on a service sheet* line (see
  [6.1](#61-summary)).
- Costs are summed only within one currency. With several billing currencies, totals are shown per currency.
- **Token cost per model** (`Data_ModelCost`): meters with *token*, *provisioned*, *PTU* or *hosting* in the name are
  parsed for model, token type (Input, Cached input, Cache write, Output, Provisioned (PTU), Fine-tuning, Tokens,
  Other) and deployment scope (Global, DataZone, Regional). Each meter is matched to a model deployed on the
  account by normalized-name similarity. PTU meters are model-agnostic, so they are split across the account's
  provisioned deployments by capacity. Meters that cannot be matched keep the meter name.
- **Estimated deployment cost** (`Est. actual cost`, `Est. amortized cost`): the billed cost of a model on an account
  is split across the deployments of that model:
  - Token meters are split by token share across the pay-as-you-go deployments of the same scope.
  - PTU meters are split by provisioned capacity.
  - Usage of deleted deployments stays in the denominator, so their share remains unallocated.
  - A blank value means the cost cannot be attributed (e.g. fine-tuning hosting).

### 5.4 AI cost reconciliation (total AI spend)

A second Cost Management query per subscription catches the AI spend that is not billed on the AI resources. It
filters on resource types `microsoft.powerplatform/accounts` and `microsoft.saas/resources`, charge types Purchase,
Refund, UnusedReservation and UnusedSavingsPlan, publisher type Marketplace, and the AI meter categories. A third
query reads the **subscription total** (all charges). The scanned subscriptions are:

- the subscriptions with AI resources,
- the subscriptions with Power Platform accounts (Copilot Studio billing policies), and
- the `-SubscriptionId` list.

Every charge is classified into one cost line (first match wins):

| Cost line | Rule | Measures |
|---|---|---|
| AI resources (service sheets) | Per-resource cost of the resources on the service sheets (hub + projects) | Actual, amortized |
| AI resources not on the service sheets | AI resource types billed in the window but not on the sheets: deleted, or kinds outside the 23 services | Actual, amortized |
| Copilot Studio and Copilot meters | Meter category or sub-category contains *copilot* | Actual, amortized |
| AI reservation purchases | Charge type Purchase or Refund with an AI meter category (e.g. PTU reservations) | **Actual only**. In amortized cost the purchase is spread into line 1. |
| Unused AI reservations | Charge type UnusedReservation with an AI meter category, or a reservation that covers AI meters | **Amortized only**. In actual cost it is part of the purchase. |
| Marketplace AI models | SaaS / Marketplace charges whose meter or resource name matches a partner model (Claude, Mistral, Llama, Cohere, Grok, DeepSeek, ...), or whose SaaS name carries a Foundry account's internal ID | Actual, amortized |
| Other AI meters | AI meter categories billed on other resource types | Actual, amortized |

AI meter categories match `^(foundry|azure openai|cognitive services|azure cognitive search|azure ai|azure bot
service|machine learning|azure machine learning)`. Marketplace SaaS resources named
`<offer>-<15 hex of the account internal ID>-<32 hex>` are linked to their Foundry resource (*Linked AI resource*).

**Excel formulas** on the AI Cost Reconciliation sheet:
- *Total AI spend* = `SUM` of the seven lines.
- *Non-AI spend* = subscription total - total AI spend.
- *Share* = `IF(AND(ISNUMBER(x),ISNUMBER(total),total<>0),x/total,"")`.
- Per subscription: *Total AI* = AI resources + other AI.

The formulas are pre-calculated, so viewers that do not recalculate still show values. The *AI share* KPI is
computed only when all amounts are in a single currency.

A partial read never shows as a smaller number:
- *Total AI spend* (KPI tiles, total line and AI share) is computed separately for each measure. It needs both
  parts of that measure: the per-resource cost of the AI subscriptions, and the reconciliation query. If either
  part could not be read, the KPI shows *n/a* and the sheet shows an INCOMPLETE note.
- In `tblReconSubscriptions`, the *AI resources* and *Other AI* amounts of a subscription are blank, not 0, when
  their query failed for that subscription.

### 5.5 Right-sizing (Foundry and Azure OpenAI deployments)

The rules are evaluated in order, and the first match sets the status. They require metrics, i.e. not `-SkipMetrics`.

| Status | Rule | Advice |
|---|---|---|
| New | Created less than 7 days ago | Too early to assess |
| Idle | No request for 30+ days (90-day look-back) | Delete the deployment: frees quota, or stops paying for PTUs |
| PTU saturated | Provisioned: busiest hour >= 95% utilization and no spillover deployment | Add PTUs or configure spillover |
| PTU under-used | Provisioned: average utilization < 30% | Reduce PTUs (or the reservation at renewal), or move to pay-as-you-go |
| Throttled | Pay-as-you-go: >= 100 HTTP 429, or 429s >= 1% of requests | Raise the TPM limit, spread the load, add a spillover / fallback deployment. The advice states the free quota. |
| Over-allocated | Pay-as-you-go: busiest hour < 10% of the TPM limit, limit >= 10,000 TPM, and 3x the busiest hour needs fewer units than allocated | Lower the capacity to the suggested units to release quota |
| OK | None of the above | - |

*Right-sizing candidates* (KPI) = Idle + Throttled + PTU saturated + PTU under-used + Over-allocated. When the model
quota is at least 90% used, the advice adds that the change frees quota for other deployments.

### 5.6 Model quota

Model quota comes from the Cognitive Services **usages** API per subscription and region, for example
`OpenAI.GlobalStandard.gpt-4o` = used / limit in capacity units (1 unit = 1,000 TPM for most models). A deployment
is mapped to its quota entry in this order:

1. the `usageName` that the model catalog publishes for the deployment type,
2. the `<format>.<deployment type>.<model>` convention,
3. a punctuation-insensitive match (e.g. `gpt-4.1` -> `gpt4.1`).

Provisioned quota is shared by all models of a deployment type. The Capacity and Quota sheet lists the quota
entries that are used or consumed by a deployment:
- **Full** = 100%+ used.
- **High** = 80%+ used.
- The KPI counts quotas that are **90%+** used.

### 5.7 Content filters

Every content filter (RAI) policy of a Foundry / Azure OpenAI account is compared with the **Microsoft.DefaultV2**
baseline:

| Setting | Baseline | Weaker (Relaxed) | Stronger (Stricter) |
|---|---|---|---|
| Hate, Sexual, Violence, Self-harm (prompt and completion) | Block Medium+ | Off, annotate only, or block High only | Block Low+ |
| Prompt shields (jailbreak) | Block | Annotate or off | - |
| Protected material (text) | Block | Annotate or off | - |
| Protected material (code) | Annotate | Off | Block |
| Indirect attacks, spotlighting, profanity | Off | - | On |
| Custom blocklists | none | - | any |
| Mode | Default (synchronous) | Asynchronous / deferred (streamed content is filtered after it is returned) | - |

The assessment is **Relaxed** if any setting is weaker, otherwise **Stricter** if any setting is stronger,
otherwise **Default**. Deployment-level assessments:
- **Not set**: the deployment names no policy. The service default applies where the model supports filtering.
- **Policy not found**: the named policy does not exist on the account.

System policies (`Microsoft.*`) are listed only where a deployment uses them. The legacy `Microsoft.Default` is
*Relaxed*, because it has no prompt shields and no protected material filters.

### 5.8 Security hygiene checks (one row per AI resource)

| Finding | Rule |
|---|---|
| Local (key) authentication enabled | `disableLocalAuth` is false. For ML workspaces and hubs, which have no such switch: *Datastores use storage account keys* when `systemDatastoresAuthMode` is not `identity`. |
| Keys not rotated in the last N days | Keys are enabled and there was no successful key regeneration in the activity log window. |
| No diagnostic logs | No diagnostic setting, or settings that export metrics only. |
| No resource lock | No CanNotDelete / ReadOnly lock on the resource, its resource group or its subscription. |
| Reachable from all networks | Public network access is enabled and not narrowed by a rule. Cognitive accounts: network default action Allow. AI Search: no IP rule. ML workspaces and Bot services: public network access enabled. Private only (disabled) and network security perimeter are not flagged. |
| No managed identity | No system- or user-assigned identity (not applicable to Bot services). |
| Defender for AI services off | The subscription's Defender for AI services plan is Free. Checked only for Azure OpenAI and Foundry accounts. |

**Key retrievals** are successful activity-log operations matching `/(list*keys|listsecrets|listchannelwithkeys)/action`.
**Key regenerations** match `/(regenerate*|resynckeys)/action`. Only *Succeeded* events count, because the activity
log also records *Started* events. A hub includes the operations on its projects. Callers are classified as:
- *User*: a UPN containing `@`.
- *App*: a GUID, i.e. a service principal or managed identity.
- *Other*.

The raw events and caller claims are aggregated in memory and not written to the workbook, apart from the counts.

### 5.9 ML compute and dependency checks

- **Computes** (ML workspaces, hubs and hub projects, all pages). The findings are:
  - *No idle shutdown or stop schedule*: compute instances only.
  - *N node(s) always on*: AmlCompute clusters with minimum nodes > 0.
  - *Public IP address*.
  - *SSH / remote login open to the internet*.
  - *Local authentication enabled*.
- **Dependencies** (storage account, key vault, container registry, Application Insights referenced by the
  workspaces), read from Resource Graph. The findings are:
  - Storage account:
    - *Shared key access enabled*
    - *Anonymous blob access allowed*
    - *Minimum TLS 1.0 / 1.1*
  - Key vault:
    - *Purge protection off*
    - *Soft delete off*
    - *Vault access policies instead of Azure RBAC*
  - Container registry: *Admin user enabled*.
  - Application Insights:
    - *Local (instrumentation key) authentication enabled*
    - *Classic Application Insights (not workspace-based)*
  - All types except Application Insights: *Reachable from all networks* (public access enabled, default action
    Allow, no private endpoint).
  - *Not found*: the dependency was deleted or is not readable.

### 5.10 Service retirements

Retirement rows come from four sources:

1. **Model lifecycle (model catalog)**: the effective retirement of a deployment is the earliest of the model's
   inference deprecation and the deployment type's SKU deprecation. Placeholder dates in 2099+ are ignored.
   Deployments that are *Deprecating* or *Deprecated* but have no date are listed as `REVIEW`.
2. **Azure Advisor**: sub-category *ServiceUpgradeAndRetirement*, or recommendations that carry a retirement date.
3. **Azure Service Health**: events of sub-type *Retirement*. The date is parsed from the title and summary.
   Service Health's own service names are mapped to the service names of this workbook, e.g. *Azure OpenAI
   Service* to Azure OpenAI, *Foundry Agent Service* to Foundry, and *Azure Machine Learning* to Machine Learning.
   The *Service* column also lists the services of the impacted resources, so a row can name several services.
4. **Service lifecycle (Microsoft Learn)**: the classic AI services that are in use.

Risk values:
- `RETIRED`: the date has passed.
- `CRITICAL`: within `-CriticalDays`.
- `WARNING`: within `-WarningDays`.
- `OK`: later.
- `REVIEW`: no parseable date.

On the deployments table, `Retirement risk` can also be:
- `NO DATE PUBLISHED`
- `NOT IN CATALOG`
- `CATALOG UNAVAILABLE`
- `NOT CHECKED` (`-SkipModelLifecycle`)
- `UNKNOWN` (no model name)

*Suggested upgrade* is the newer version of the same model that offers the same deployment type. The script prefers
GA over preview, then the default version, then the latest retirement date.

### 5.11 Service Health and Defender for Cloud

- An **event** is kept if it is **Active**, or was updated within `-EventDays`. It must also match at least one of:
  - an AI service name in the impacted services or the title (`OpenAI`, `Cognitive`, `AI services`, `Foundry`,
    `Machine Learning`, `Search`, `Speech`, `Vision`, ...), or
  - an impact on an AI resource.

  `-AllServiceHealthEvents` removes the AI filter. Events are grouped by tracking ID across subscriptions.
- **Defender for Cloud**:
  - Plans: the `AI` plan (Defender for AI services) and `CloudPosture` plan (Defender CSPM) of each subscription
    with AI resources.
  - Assessments: those whose resource is an AI resource or one of its child resources.
  - Alerts: from the last `-EventDays` days on AI resources.

## 6. Workbook reference

The workbook has **34 visible sheets** and **4 hidden** pivot source sheets. Every detail sheet starts with a title
(row 1), a subtitle with the scope, source and window (row 2), an optional note in red when data is incomplete
(row 3), and a *<< Back to Summary* link. Tables are Excel tables with filter buttons, number formats and
hyperlinks. *Portal* and *... link* cells show *Open*.

| # | Sheet | Tables |
|---|---|---|
| 1 | Summary | `tblSummary` + KPI tiles, sheet guide, data collection notes |
| 2 | Visuals | 13 pivot tables + 13 pivot charts |
| 3 | Recommendations | `tblAdvisor` |
| 4 | Service Retirements | `tblRetirements` |
| 5 | Service Health | `tblServiceHealth` |
| 6 | Security Best Practices | `tblDefenderPlans`, `tblDefenderAssessments`, `tblDefenderAlerts` |
| 7 | Security Hygiene | `tblSecurityHygiene` |
| 8 | Content Filters | `tblContentFilterPolicies`, `tblContentFilterDeployments` |
| 9 | Capacity and Quota | `tblRightSizing`, `tblQuota` |
| 10 | AI Cost Reconciliation | `tblReconLines`, `tblReconSubscriptions`, `tblReconDetail` |
| 11 | ML Compute and Dependencies | `tblMlComputes`, `tblMlDependencies`, `tblMlCost` |
| 12-34 | One sheet per AI service | `tbl<Service>` + deployments / projects / endpoints tables |
| hidden | Data_Resources, Data_Deployments, Data_ModelCost, Data_AISpend | Pivot sources (`-ShowDataSheets` to show) |

> Sheet names avoid `&`: EPPlus writes the pivot cache source without XML escaping, which would corrupt the file.

### 6.1 Summary

**Header**: row 2 lists the tenant, the signed-in account, the scope (with the number of subscriptions that have AI
resources) and the generation time (local and UTC). Row 3 lists the cost and usage window with the currency, the
Service Health / alert window and the retirement thresholds, and flags incomplete cost data.

**KPI tiles** (3 rows of 8; the labels link to the detail sheet):

| KPI | Meaning |
|---|---|
| AI resources | Resources on the 23 service sheets (hub projects are counted on the AI Hubs sheet, not here) |
| AI services in use | Services with at least one resource / 23 |
| Subscriptions with AI | Subscriptions hosting AI resources |
| Regions | Distinct regions of the AI resources |
| Model deployments | Foundry + Azure OpenAI deployments + ML online deployments and serverless endpoints |
| Distinct models | Distinct model names across the deployments |
| Tokens - last N days | Total tokens of the Foundry / Azure OpenAI deployments |
| Actual cost / Amortized cost - last N days | Cost of the AI resources (with currency; per currency when mixed; *(partial)* when some subscriptions were unreadable) |
| Total AI spend - actual / amortized | Sum of all reconciliation cost lines (see [5.4](#54-ai-cost-reconciliation-total-ai-spend)) |
| AI share of subscription spend (amortized) | Total AI spend / subscription total (single currency only) |
| Advisor recommendations | Active Advisor recommendations (Recommendations sheet) |
| Retired or retiring within N days | Retirement rows with at most `-WarningDays` days remaining, including past dates |
| Active Service Health events | Events with status Active |
| Defender unhealthy findings | Unhealthy Defender assessments |
| Security alerts - last N days | Defender alerts on AI resources |
| Resources with local auth (keys) enabled | Security Hygiene: *Local auth (keys)* = Enabled |
| Resources without diagnostic logs | Security Hygiene: *Diagnostic logs* = None or Metrics only |
| Relaxed content filter policies | Content Filters: policies assessed Relaxed |
| Deployments without content filter | Content Filters: deployments assessed Not set |
| Right-sizing candidates | Capacity and Quota: Idle + Throttled + PTU saturated + PTU under-used + Over-allocated |
| Model quotas 90%+ used | Capacity and Quota: quota entries with Used % >= 90% |
| ML computes with findings | ML Compute and Dependencies: computes with at least one finding |

**`tblSummary` - AI services summary** (one row per service, an optional *Not on a service sheet* line, and a Total
row):

| Column | Description |
|---|---|
| Service | Service name as in the Azure portal |
| Group | Use with Foundry / More services / Classic AI services |
| Resources | Number of resources of the service |
| Regions / Subscriptions | Distinct regions / subscriptions of those resources |
| Model deployments | Foundry and Azure OpenAI deployments; online deployments + serverless endpoints for AI Hubs and Machine Learning; blank for other services |
| Actual cost / Amortized cost | Cost of the service's resources, hubs including their projects (blank when the service mixes currencies) |
| Reservation name | Reservations that cover the service's usage |
| Currency | Billing currency, or *mixed - see sheet* |
| Advisor recommendations | Active Advisor recommendations on the service's resources (AI Hubs includes the hub projects) |
| Defender unhealthy | Unhealthy Defender assessments on the service's resources (AI Hubs includes the hub projects) |
| Retirement items | Rows of the service on the Service Retirements sheet. A row that names several services counts for each of them. |
| Sheet | Hyperlink to the service sheet |

**Not on a service sheet** (italic, only when needed) holds what the KPI tiles count but no service row holds:
- the cost of resources that are no longer in scope or are of other kinds,
- subscription-level Advisor recommendations, and
- retirement items of other services, e.g. a Service Health event for *Azure AI Services* in general.

**Total** adds the service rows and that line, so it always matches the KPI tiles. *Regions* and *Subscriptions*
are distinct counts. A total stays blank when its source could not be read. With several currencies, the cost cells
refer to the KPI tiles. The column widths are sized to the KPI values and the table, so large numbers never show as
`#####`.

**Report sheets**: a guide with one line per sheet (link and description with the key counts). **Data collection
notes**: every gap, failure or informational note of the run, e.g. a permission missing, a throttled API, a skipped
phase, or the cost of resources that are not on the service sheets. *All data sources were collected successfully*
means the data is complete.

### 6.2 Visuals

Each block holds a pivot table (left) and its pivot chart (right). The pivots are sorted by value and refresh when
the workbook opens in Excel desktop. Otherwise use *Data > Refresh All*. With several billing currencies, the cost
pivots group by currency and have no grand total. Blocks without data are omitted, or replaced by a short note that
explains why (e.g. *Cost collection was skipped*). The pivots are stacked in shared columns, so *Autofit column
widths on update* is turned off. Otherwise each refresh would fit the columns to one pivot and show `#####` in the
others. Instead, the columns have fixed widths: 46 for the row labels and 22 for the values.

| # | Pivot (chart) | Chart type | Source | Rows | Columns | Values |
|---|---|---|---|---|---|---|
| 1 | `ptModels` - Most common models | Clustered column | Data_Deployments | Model | - | Count of Deployment (*Deployments*) |
| 2 | `ptResourcesRegion` - AI resources per service and region | Stacked column | Data_Resources | Service | Region | Count of Resource (*Resources*) |
| 3 | `ptTokenCost` - Token cost per deployed model | Stacked column | Data_ModelCost | Model | Token type | Sum of `-CostType` measure (*Token cost*) |
| 4 | `ptDeploymentTypes` - Model deployments by deployment type | Pie | Data_Deployments | Deployment type | - | Count of Deployment |
| 5 | `ptTokenUsage` - Token usage per model | Stacked column | Data_Deployments | Model | - | Sum of Input tokens, Sum of Output tokens |
| 6 | `ptCostService` - AI cost per service | Clustered column | Data_Resources | Service | - | Sum of Actual cost, Sum of Amortized cost |
| 7 | `ptAISpend` - Total AI spend by cost line | Clustered bar | Data_AISpend | Cost line | - | Sum of Actual cost, Sum of Amortized cost |
| 8 | `ptMlCost` - Machine Learning and Foundry hub cost per workspace | Stacked column | tblMlCost | Workspace | Meter category | Sum of `-CostType` measure (*Workspace cost*) |
| 9 | `ptRetirement` - Model retirement outlook | Pie | Data_Deployments | Retirement risk | - | Count of Deployment |
| 10 | `ptRightSizing` - Model deployment right-sizing | Pie | tblRightSizing | Right-sizing | - | Count of Deployment |
| 11 | `ptContentFilter` - Content filter posture of model deployments | Pie | tblContentFilterDeployments | Content filter assessment | - | Count of Deployment |
| 12 | `ptDefender` - Defender for Cloud recommendations by severity and status | Stacked column | tblDefenderAssessments | Severity | Status | Count of Recommendation (*Findings*) |
| 13 | `ptAdvisor` - Azure Advisor recommendations by category and impact | Stacked column | tblAdvisor | Category | Impact | Count of Recommendation (*Recommendations*) |

### 6.3 Recommendations - `tblAdvisor`

Active Advisor recommendations (not Completed, Dismissed or Resolved) on AI resources, plus subscription-level
recommendations that mention AI (e.g. Azure OpenAI PTU reservations).

| Column | Description |
|---|---|
| Category | Cost, Security, Reliability, Operational excellence, Performance |
| Impact | High / Medium / Low |
| Service / Resource / Resource group / Subscription | Affected AI resource (*(subscription)* for subscription-level items) |
| Recommendation / Solution | Problem and solution text |
| Sub-category | Advisor sub-category (e.g. ServiceUpgradeAndRetirement) |
| Potential benefits / Potential savings | Stated benefit and annual savings (with currency) |
| Status / Last updated (UTC) | Recommendation status and last update |
| Learn more link / Resource ID / Recommendation type ID | References |

### 6.4 Service Retirements - `tblRetirements`

| Column | Description |
|---|---|
| Source | Model lifecycle (model catalog) / Azure Advisor / Azure Service Health / Service lifecycle (Microsoft Learn) |
| Service / Subscription / Resource group / Resource | Affected service and resource |
| Item | What retires (e.g. `Model gpt-4o 2024-05-13 (GlobalStandard), deployment 'chat'`) |
| Retirement date / Days remaining | Effective retirement date and days from today (negative = already retired) |
| Risk | RETIRED / CRITICAL / WARNING / OK / REVIEW (see [5.10](#510-service-retirements)) |
| Impact | E.g. *Breaks at retirement - version pinned (NoAutoUpgrade)*, *Auto-upgrade enabled (OnceNewDefaultVersionAvailable)*, lifecycle state |
| Recommended action | Upgrade target or migration guidance |
| Link / Resource ID | Microsoft Learn or Service Health link and the affected resource |

### 6.5 Service Health - `tblServiceHealth`

| Column | Description |
|---|---|
| Event type | Service issue, Planned maintenance, Health advisory, Security advisory, Billing update, Emerging issue, Post-incident review |
| Status / Level | Active or Resolved; event level (Critical, Error, Warning, Informational) |
| Tracking ID / Title | Service Health tracking ID and title |
| Impacted services / Impacted regions | Services and regions named by the event |
| Subscriptions | Subscriptions that received the event |
| Impacted AI resources | AI resources listed as impacted |
| Impact start (UTC) / Impact mitigation (UTC) / Last update (UTC) | Event times |
| Sub-type | E.g. Retirement |
| Summary / Link | Event text and the Service Health deep link |

### 6.6 Security Best Practices

**`tblDefenderPlans`** - Defender plan coverage per subscription with AI resources:

| Column | Description |
|---|---|
| Subscription / Subscription ID | Subscription |
| AI resources | AI resources and hub projects in the subscription |
| Defender for AI services / AI plan extensions / AI plan enabled (UTC) | Plan state (On (Standard) / Off (Free) / Unknown), its extensions (e.g. AIPromptEvidence: On) and the enablement time |
| Defender CSPM / CSPM extensions | Defender CSPM state and extensions (AI posture: AI-BOM, attack paths) |
| Recommended action | What to enable, or *Coverage OK* |

**`tblDefenderAssessments`** - recommendations for AI resources (unhealthy first, then by severity):

| Column | Description |
|---|---|
| Status / Severity | Unhealthy, Healthy, NotApplicable; High / Medium / Low |
| Recommendation | Assessment display name |
| Service / Resource / Resource group / Subscription | Affected resource (*resource / child* for sub-resources) |
| Risk level / Risk factors / Attack paths | Defender CSPM risk prioritization (when CSPM is on) |
| Categories / Threats / User impact / Implementation effort | Assessment metadata |
| Cause / Description / Remediation | Why it fails and how to fix it |
| First evaluated (UTC) / Status changed (UTC) | Evaluation dates |
| Assessment key / Portal link / Resource ID | References |

**`tblDefenderAlerts`** - security alerts in the last `-EventDays` days:
- Start time (UTC)
- Severity
- Status
- Alert
- Alert type
- Service
- Resource
- Subscription
- Intent (MITRE tactic)
- Description
- Remediation
- Alert link
- Resource ID

### 6.7 Security Hygiene - `tblSecurityHygiene`

One row per AI resource, with the most findings first. See [5.8](#58-security-hygiene-checks-one-row-per-ai-resource) for the rules.

| Column | Description |
|---|---|
| Issues / Findings | Number and list of findings |
| Service / Resource / Subscription / Resource group / Region | The AI resource |
| Local auth (keys) | Enabled / Disabled (ML: datastore credential mode) |
| Key retrievals | Successful list-keys / list-secrets operations in the activity log window (hub includes projects) |
| Key retrieval callers / Caller types | Distinct callers and their split (e.g. `App 3; User 2`) |
| Last key retrieval (UTC) | Most recent key retrieval |
| Key regenerations / Last key regeneration (UTC) | Successful key regenerations and the most recent one |
| Key rotation | Rotated / Not rotated (last N days) / n/a (keys disabled). Blank when the activity log was not read. |
| Diagnostic settings | Number of diagnostic settings |
| Diagnostic logs | All logs / Partial / Metrics only / None |
| Log categories enabled | Enabled categories or category groups (e.g. `allLogs`, `Audit`, `RequestResponse`) |
| Diagnostic destinations | Log Analytics, Storage account, Event Hub, Partner solution |
| Resource lock / Lock scope | Strongest lock (ReadOnly > CanNotDelete > None) and where it is set (Resource / Resource group / Subscription) |
| Network exposure | Private only / Network security perimeter / Selected networks / All networks |
| Private endpoints | Number of private endpoint connections |
| Managed identity | None / SystemAssigned / UserAssigned / both (n/a for Bot services) |
| Encryption | Customer-managed key / Microsoft-managed key |
| Defender for AI services | Plan state of the subscription (n/a for services it does not protect) |
| Resource ID / Portal | References |

### 6.8 Content Filters

**`tblContentFilterPolicies`** - custom policies, and system policies that are in use (Relaxed first):

| Column | Description |
|---|---|
| Assessment | Relaxed / Stricter / Default versus Microsoft.DefaultV2 |
| Account / Subscription | Foundry or Azure OpenAI resource |
| Policy / Policy type / Base policy / Mode | Policy name, System or Custom, base policy, and mode (Default, Asynchronous_filter, Blocking, Deferred) |
| Hate / Sexual / Violence / Self-harm | `prompt / completion` setting: Low+, Medium+, High, Annotate, Off |
| Prompt shields (jailbreak) / Indirect attacks | Block / Annotate / Off |
| Protected material (text) / Protected material (code) | Block / Annotate / Off |
| Profanity / Custom blocklists | Profanity filter state and blocklist names |
| Relaxed vs DefaultV2 / Stricter vs DefaultV2 | Every weaker and stronger setting |
| Deployments using the policy / Deployment names | Usage of the policy |

**`tblContentFilterDeployments`** - every Foundry / Azure OpenAI deployment:

| Column | Description |
|---|---|
| Content filter assessment | Relaxed / Not set / Policy not found / Stricter / Default |
| Account / Subscription / Region / Deployment / Model / Model version / Deployment type | The deployment |
| Content filter / Policy type | Policy name (*(not set)*) and System / Custom |
| Requests screened / Harmful requests detected / Blocked requests / Blocked % | Content filter metrics over the usage window |
| Defender for AI services | Plan state of the subscription (prompt-level threat protection) |
| Deployment ID | Resource ID of the deployment |

### 6.9 Capacity and Quota

**`tblRightSizing`** - every Foundry / Azure OpenAI deployment. Candidates come first, ordered Idle > Throttled >
PTU saturated > PTU under-used > Over-allocated > New > OK, then by estimated amortized cost.

| Column | Description |
|---|---|
| Right-sizing / Right-sizing advice | Status and concrete advice (see [5.5](#55-right-sizing-foundry-and-azure-openai-deployments)); *Not assessed* without metrics |
| Account / Deployment / Model / Model version / Deployment type | The deployment |
| Capacity / Tokens per minute | Allocated units (PTUs for provisioned) and the TPM rate limit |
| Peak TPM (busiest hour) / Peak % of TPM limit | Busiest-hour rate and its share of the limit |
| Requests / Throttled requests (429) | Requests and HTTP 429s in the usage window |
| PTU utilization avg / PTU utilization peak | Provisioned deployments only |
| Last request date / Idle days | Last day with requests (90-day look-back) and days since |
| Quota / Quota used % | Quota entry consumed by the deployment and its current use |
| Spillover deployment | Standard deployment that receives PTU overflow |
| Est. actual cost / Est. amortized cost / Currency | Estimated cost of the deployment (see [5.3](#53-cost)) |
| Subscription / Region / Deployment ID | Location and resource ID |

**`tblQuota`** - quota entries in use (most used first):

| Column | Description |
|---|---|
| Quota status | Full (100%+) / High (80%+) / OK |
| Subscription / Region | Quota scope |
| Quota / Deployment type / Model | Usage name (e.g. `OpenAI.GlobalStandard.gpt-4o`) and its parts (*(all models)* for provisioned) |
| Used / Limit / Available / Used % | Capacity units |
| Deployments / Idle deployments | Deployments consuming the quota, and how many of them are idle |
| Capacity held by idle deployments | Units that deleting the idle deployments would free |
| Deployment names | `account/deployment` list |

### 6.10 AI Cost Reconciliation

**`tblReconLines`** - one block per currency: the 7 cost lines + *Total AI spend* + *Subscription total (all
charges)* + *Non-AI spend* (see [5.4](#54-ai-cost-reconciliation-total-ai-spend)).

| Column | Description |
|---|---|
| Cost line | Cost line name |
| Actual cost / Amortized cost | Amount of the line. The formula rows are bold. Blank = the line does not exist in that measure (by design), or the data was not readable. |
| Currency | Billing currency |
| Share of actual / Share of amortized | Line / subscription total (formula) |
| What it covers | Definition of the line |

**`tblReconSubscriptions`** - per scanned subscription:

| Column | Description |
|---|---|
| Subscription / Subscription ID | Scanned subscription |
| AI resources actual cost / AI resources amortized cost | The two AI resource lines of the subscription |
| Other AI actual cost / Other AI amortized cost | The other cost lines of the subscription |
| Total AI actual cost / Total AI amortized cost | AI resources + other AI (formula) |
| Subscription actual cost / Subscription amortized cost | All charges of the subscription |
| AI share (actual) / AI share (amortized) | Total AI / subscription total (formula) |
| Currency | Billing currency |

**`tblReconDetail`** - every charge outside the service sheets:

| Column | Description |
|---|---|
| Cost line | Classification |
| Subscription / Resource / Resource type | Where it is billed (*(no resource)* for purchases) |
| Linked AI resource | Foundry resource of a Marketplace model, when resolvable |
| Meter category / Meter sub-category / Charge type / Publisher type / Reservation name | Cost Management dimensions |
| Actual cost / Amortized cost / Currency / Resource ID | Amounts and reference |

### 6.11 ML Compute and Dependencies

**`tblMlComputes`** - computes of ML workspaces, hubs and hub projects (with findings first):

| Column | Description |
|---|---|
| Issues / Findings | See [5.9](#59-ml-compute-and-dependency-checks) |
| Workspace / Workspace kind | Owning workspace (Default, Hub, Project, FeatureStore) |
| Compute / Type / VM size / Priority | ComputeInstance, AmlCompute, Kubernetes, SynapseSpark, ...; Dedicated / LowPriority |
| State | Instance state (Running, Stopped, ...), cluster allocation state (Steady, Resizing) or provisioning state |
| Current nodes / Min nodes / Max nodes | AmlCompute clusters |
| Idle shutdown (min) / Stop schedules / Auto-shutdown | Compute instances: idle shutdown, enabled stop schedules, and the resulting auto-shutdown mode (None is flagged) |
| Public IP / SSH public access / Local auth disabled | Network and authentication settings |
| Subnet / Region / Subscription / Resource group / Created (UTC) / Resource ID | Placement and reference |

**`tblMlDependencies`** - one row per dependency, with the workspaces that use it:

| Column | Description |
|---|---|
| Issues / Findings | See [5.9](#59-ml-compute-and-dependency-checks) |
| Dependency / Name / Used by workspaces / Found | Storage account, Key vault, Container registry, Application Insights; Yes / Missing |
| SKU / Public network access / Network default action / Private endpoints | Network posture |
| Key-based access | Storage shared key, registry admin user, or App Insights local auth |
| Purge protection / Soft delete / Permission model | Key vault settings (Azure RBAC or Access policies) |
| Blob anonymous access / Minimum TLS | Storage settings |
| Subscription / Resource group / Resource ID | Reference |

**`tblMlCost`** - workspace cost by meter category:
- Workspace
- Workspace kind
- Hub (for hub projects)
- Meter category (e.g. Virtual Machines, Storage, Foundry Models)
- Actual cost
- Amortized cost
- Reservation name
- Currency
- Subscription
- Resource group

### 6.12 Service sheets (12-34)

Every service sheet has:
- a subtitle with the group, the resource type / kinds, the resource count and the cost window;
- for classic services, a red **RETIREMENT** or **LIFECYCLE** note with the date, guidance and a Microsoft Learn link;
- the primary table `tbl<ServiceKey>` (e.g. `tblFoundry`, `tblComputerVision`); an empty service shows *No ...
  resources found in scope*;
- extra tables for Foundry, Azure OpenAI, AI Hubs and Machine Learning.

**Common columns** (end of every primary table):

| Column | Description |
|---|---|
| Actual cost / Amortized cost / Reservation name / Currency | Cost of the resource in the usage window (see [5.3](#53-cost)) |
| Advisor recommendations / Defender unhealthy | Active Advisor recommendations / unhealthy Defender assessments of the resource |
| Tags | `key=value; ...` |
| Resource ID / Portal | Resource ID and Azure portal link |

**Cognitive Services accounts** (Foundry, Azure OpenAI, the "More services" Cognitive kinds and all classic services):

| Column | Description |
|---|---|
| Subscription / Resource group / Name / Region / Kind / SKU / Provisioning state | Identity of the account |
| Endpoint / Custom subdomain | Endpoint URL and custom subdomain (required for Entra ID auth and private endpoints) |
| Public network access / Network default action / IP rules / VNet rules / Private endpoints | Network posture |
| Local auth disabled | True = keys disabled (Entra ID only) |
| Managed identity / Encryption / Outbound restricted | Identity, key source, and outbound network restriction |
| Model deployments / Models / Input tokens / Output tokens / Requests | Foundry and Azure OpenAI only |
| Project management / Projects / Default project / Agent network injection | Foundry only: project management enabled, number of Foundry projects, default project, and agent subnet injection |
| API calls | `TotalCalls` in the usage window |
| Retirement date / Days to retirement | Classic services only |
| Created (UTC) | Creation date |

**Model deployments** (`tblFoundryDeployments`, `tblAzureOpenAIDeployments`; also `Data_Deployments`):

| Column | Description |
|---|---|
| Subscription / Resource group / Account / Region / Deployment | Where the deployment lives |
| Model / Model version / Model format | Deployed model (format: OpenAI, Microsoft, Meta, xAI, DeepSeek, ...) |
| Deployment type / Capacity / Tokens per minute | SKU (GlobalStandard, DataZoneStandard, Standard, GlobalProvisionedManaged, GlobalBatch, ...), units and TPM limit |
| Version upgrade | OnceNewDefaultVersionAvailable / OnceCurrentVersionExpired / NoAutoUpgrade |
| Content filter / Content filter assessment | RAI policy and its assessment (see [5.7](#57-content-filters)) |
| Provisioning state | Deployment state |
| Lifecycle / Retirement date / Days to retirement / Retirement risk / Retirement impact / Suggested upgrade | From the model catalog (see [5.10](#510-service-retirements)) |
| Input tokens / Output tokens / Total tokens / Requests | Usage in the window |
| Peak TPM (busiest hour) / Peak % of TPM limit / Throttled requests (429) / PTU utilization avg / PTU utilization peak / Last request date / Idle days | Capacity metrics (see [5.2](#52-usage-metrics-foundry-and-azure-openai-deployments)) |
| Quota / Quota used % / Spillover deployment | Quota entry and spillover target |
| Right-sizing / Right-sizing advice | See [5.5](#55-right-sizing-foundry-and-azure-openai-deployments) |
| Est. actual cost / Est. amortized cost / Reservation name / Currency | Estimated deployment cost (see [5.3](#53-cost)) |
| Created (UTC) / Created by / Deployment ID | Creation metadata and resource ID |

**Foundry projects** (`tblFoundryProjects`):
- Foundry resource
- Subscription
- Resource group
- Project
- Display name
- Description
- Region
- Default project
- Managed identity
- Project endpoint
- Provisioning state
- Created (UTC)
- Created by
- Resource ID
- Portal

**ML workspaces** (`tblAIHubs`, `tblMachineLearning`):

| Column | Description |
|---|---|
| Subscription / Resource group / Name / Friendly name / Region / Kind / SKU / Provisioning state | Identity |
| Public network access / Managed network / Private endpoints | Network posture (managed network isolation mode) |
| Managed identity / Storage account / Key vault / Application Insights / Container registry | Identity and dependencies |
| Encryption / High business impact / Datastore auth mode | CMK, HBI flag, datastore credential mode (identity or access key) |
| Projects / Endpoints / Projects actual cost / Projects amortized cost | AI Hubs: hub projects, endpoints of the hub and its projects, and project cost |
| v1 legacy mode / Endpoints | Machine Learning: v1 legacy mode flag and endpoint count |
| Created (UTC) | Creation date |

**Hub projects** (`tblAIHubsProjects`):
- Hub
- Subscription
- Resource group
- Project
- Friendly name
- Region
- Provisioning state
- Public network access
- Managed identity
- Endpoints
- Created (UTC)
- The common columns

**Endpoints** (`tblAIHubsEndpoints`, `tblMachineLearningEndpoints`):

| Column | Description |
|---|---|
| Workspace / Workspace kind / Type | Serverless API endpoint, Managed online endpoint, Managed online deployment, Batch endpoint |
| Endpoint / Deployment | Endpoint name and online deployment name |
| Model / Model version / Model source | Model and where it comes from (registry, workspace, Azure Marketplace). Name and version are parsed from the model asset ID: a registry path (`azureml://registries/<registry>/models/<name>/versions/<version>`), a workspace model path, or `azureml:<name>:<version>`. |
| SKU / instance type / Capacity | Serverless SKU or VM instance type, and instance count (the scale settings of a managed online deployment) |
| Auth mode / Public network access / Provisioning state / Endpoint URI | Access settings |
| Region / Subscription / Resource group | Placement |
| Actual cost / Amortized cost / Reservation name | Cost billed on the endpoint |
| Resource ID / Portal | References |

**AI Search** (`tblAISearch`):
- Subscription, Resource group, Name, Region, SKU, Status, Provisioning state
- Replicas, Partitions, Search units, Hosting mode
- Public network access, IP rules, Network bypass, Private endpoints, Shared private links
- Local auth disabled, Authentication (*Microsoft Entra ID only*, API keys, or the `aadOrApiKey` options)
- Semantic ranker, CMK enforcement, Managed identity, Endpoint
- The common columns

**Bot services** (`tblBotServices`):
- Subscription, Resource group, Name, Display name, Kind, Region, SKU
- Messaging endpoint
- App type (SingleTenant / MultiTenant / UserAssignedMSI), App ID, App tenant ID
- Public network access, Local auth disabled, CMK encryption
- Channels, App Insights configured, Streaming endpoint, Private endpoints
- Provisioning state
- The common columns

### 6.13 Hidden data sheets

| Sheet | Table | Content |
|---|---|---|
| Data_Resources | `tblDataResources` | One row per AI resource: Group, Service, Subscription, Resource group, Resource, Region, Kind, SKU, Public network access, Private endpoints, Actual cost, Amortized cost (hub + projects), Reservation name, Currency, Advisor recommendations and Defender unhealthy (hub + projects), Resource ID |
| Data_Deployments | `tblDataDeployments` | All model deployments (Foundry, Azure OpenAI, AI Hubs, Machine Learning): *Platform* + the model deployment columns |
| Data_ModelCost | `tblDataModelCost` | Token meters matched to models: Service, Subscription, Resource group, Account, Region, Model, Matched to deployment, Token type, Deployment scope, Meter, Meter sub-category, Meter category, Quantity, Actual cost, Amortized cost, Reservation name, Currency, Resource ID |
| Data_AISpend | `tblDataAISpend` | AI spend by cost line and item: Cost line, Item (service, reservation, Marketplace offer, resource), Subscription, Actual cost, Amortized cost, Currency |

## 7. Conditional highlights

Highlights apply to every table column with one of these headers:

| Column | Red | Amber / yellow | Green / blue |
|---|---|---|---|
| Retirement risk, Risk | RETIRED (dark red), CRITICAL | WARNING | REVIEW (blue) |
| Status | Unhealthy, Active (light) | - | Healthy |
| Severity, Impact | High | Medium | Low (blue) |
| Level | Critical, Error | Warning | - |
| Public network access / Local auth disabled | - | Enabled / FALSE (light) | - |
| Defender for AI services, Defender CSPM | Off (Free) | - | On (Standard) |
| Right-sizing | Idle, Throttled, PTU saturated | Over-allocated, PTU under-used | OK |
| Assessment | Relaxed | - | Stricter |
| Content filter assessment | Relaxed | Not set, Policy not found | Stricter |
| Quota status | Full | High | - |
| Local auth (keys), Key rotation, Network exposure | - | Enabled, Not rotated, All networks | - |
| Diagnostic logs | None, Metrics only | Partial (light) | All logs |
| Resource lock, Managed identity, Key-based access | - | None / None / Enabled (light) | - |
| Found, Auto-shutdown, SSH public access, Soft delete | Missing, None, Enabled, Off | - | - |
| Public IP, Purge protection | - | TRUE, Off | - |

## 8. Assumptions and limitations

- **Busiest-hour TPM** is an hourly average. Minute-level bursts inside that hour can be higher, which is why
  *Over-allocated* suggests 3x the busiest hour.
- **Idle** looks back 90 days, the Azure Monitor metric retention. Deployments created less than 7 days ago are
  *New* and are not assessed.
- **Over-allocated** pay-as-you-go deployments cost nothing while unused. The benefit of right-sizing is the quota
  freed for other deployments. PTU findings (under-used, idle) have a direct cost impact.
- The **activity log** keeps 90 days. Key retrievals include every successful list-keys call: portal views, apps and
  automation. A high count on a keys-enabled resource indicates key-based apps to move to Entra ID.
- **Estimated deployment cost** is an allocation, not a billed figure. The account-level cost is authoritative.
- **Total AI spend** only covers the scanned subscriptions. Copilot Studio billed in a subscription that is outside
  the tenant scope is not included. Reservations bought for non-AI meters (e.g. VM reservations used by ML
  computes) are shared and are not counted as AI reservations.
- **Currencies**: totals, the AI share and the cost pivots never add different currencies.
- **Pivot tables** are built by EPPlus and calculated by Excel. Web viewers may show them empty until refreshed in
  Excel desktop.
- Hub projects are not counted as separate resources in *AI resources*. They appear on the AI Hubs sheet, and their
  cost, Advisor recommendations and Defender findings roll up to the hub.

## 9. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `Not signed in. Run Connect-AzAccount first.` | Sign in with `Connect-AzAccount`, then re-run. |
| Token error for `-TenantId` | Run `Connect-AzAccount -TenantId <tenant>` once (MFA / consent for that tenant), then re-run. |
| Warnings `Unable to acquire token for tenant ...` | Az.Accounts reports other tenants of the account. They are harmless and can be ignored. |
| `Cannot overwrite '<path>'` | The workbook is open in Excel. Close it or use another `-OutputPath`. |
| `Core inventory query failed` | Resource Graph was unreachable or throttled for a core query. The run stops rather than under-reporting. Re-run. |
| Blank cost columns / *n/a* KPIs | Missing Cost Management Reader, an unsupported offer type, or throttling. See the Data collection notes. |
| Blank Defender tables | Missing Security Reader, or Defender for Cloud not enabled. |
| Empty key retrieval columns | `-SkipActivityLog`, or the activity log was unreadable (see notes). |
| Pivot tables empty | Open the workbook in Excel desktop, or use *Data > Refresh All*. |
| Slow run | Cost Management throttles per tenant. The script waits and retries automatically. Raise `-ThrottleLimit` for many accounts, or use `-SkipCost` / `-SkipMetrics` for a quick inventory. |
