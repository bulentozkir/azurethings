# azurethings
Automation code to improve Azure WAF CAF maturity

## Get-Azure-Ai-inventory.ps1

PowerShell 7 script that builds a comprehensive **Azure AI Inventory** Excel workbook (`.xlsx`) for the
16 AI services and 7 classic AI services listed in the Azure portal (Microsoft Foundry > AI services).

| Sheet | Content |
|---|---|
| 1. Summary | Key figures (linked to the detail sheets), AI services summary with links to every service sheet (items that belong to no service sheet are on a separate line, so the total matches the key figures), report sheet guide and data collection notes |
| 2. Visuals | Pivot tables + charts: most common models, AI resources per service and region, token cost per deployed model, deployment types, token usage per model, actual vs. amortized cost per service, total AI spend by cost line, ML workspace cost, model retirement outlook, right-sizing, content filter posture, Defender findings, Advisor recommendations |
| 3. Recommendations | Azure Advisor recommendations for the AI resources |
| 4. Service Retirements | Retirements from the model lifecycle (model catalog), Azure Advisor, Azure Service Health and the classic AI services, with risk (RETIRED / CRITICAL / WARNING / REVIEW) and recommended action |
| 5. Service Health | Azure Service Health events: service issues, planned maintenance, health advisories, security advisories, billing updates |
| 6. Security Best Practices | Microsoft Defender for Cloud plan coverage (Defender for AI services, Defender CSPM), recommendations and security alerts for the AI resources |
| 7. Security Hygiene | Per AI resource: local (key) authentication, key retrievals and key rotation (activity log), diagnostic logs, resource locks, network exposure, managed identity, encryption, Defender for AI services |
| 8. Content Filters | Content filter (RAI) policies compared with the Microsoft.DefaultV2 baseline (Relaxed / Stricter / Default), and the policy and blocked / harmful request counts of every model deployment |
| 9. Capacity and Quota | Right-sizing of every Foundry / Azure OpenAI deployment (idle, throttled HTTP 429, PTU saturated or under-used, over-allocated) and model quota use per subscription and region |
| 10. AI Cost Reconciliation | Total AI spend: AI resources plus PTU reservation purchases, unused reservations, Marketplace models (e.g. Claude), Copilot Studio and other AI meters, against the subscription total (Excel formulas) |
| 11. ML Compute and Dependencies | Machine Learning / Foundry hub computes (auto-shutdown, always-on nodes, public IP, SSH), workspace dependencies (storage, key vault, registry, Application Insights) and workspace cost by meter category |
| 12-34 | One inventory sheet per AI service: Foundry, AI Hubs, Azure OpenAI, AI Search, Bot services, Computer vision, Custom vision, Content safety, Document intelligence, Face API, Health Insights, Machine Learning, Immersive reader, Language service, Speech service, Translator, and the classic Anomaly detector, AI services multi-service account, Content moderator, Language understanding, Metrics advisor, Personalizer, QnA maker |

Every cost is reported as three columns: **Actual cost**, **Amortized cost** and **Reservation name** (the
reservation that covers the usage, e.g. a provisioned throughput (PTU) reservation - its usage shows 0 actual cost
and the reservation spread as amortized cost). `-CostType` only selects the measure of the token cost chart.
Model deployments show an estimated share of the billed model cost: token meters are split by token usage across
the pay-as-you-go deployments of the model in the same Global / DataZone / Regional scope, PTU meters by provisioned
capacity. A blank estimate means the cost could not be attributed (e.g. fine-tuned hosting fees).

Four hidden `Data_*` sheets hold the flat datasets behind the pivot tables (`-ShowDataSheets` keeps them visible).
See [Get-Azure-Ai-inventory.md](./Get-Azure-Ai-inventory.md) for the full reference: execution flow, the rules
behind every assessment, and every sheet, table, column and visual.

```powershell
Install-Module Az.Accounts, ImportExcel -Scope CurrentUser   # once
Connect-AzAccount
./Get-Azure-Ai-inventory.ps1                                   # all readable subscriptions of the tenant
./Get-Azure-Ai-inventory.ps1 -SubscriptionId $subA, $subB -UsageDays 60 -Show
./Get-Azure-Ai-inventory.ps1 -TenantId $tenantId -Subscriptions @($subA, $subB)   # another tenant, same sign-in
./Get-Azure-Ai-inventory.ps1 -ManagementGroupId contoso -SkipCost -OutputPath C:\reports\ai.xlsx
./Get-Azure-Ai-inventory.ps1 -SkipActivityLog -SkipMetrics   # quick inventory
```

All calls are read-only (Resource Graph, ARM, Azure Monitor metrics, activity log, Cost Management). Reader is enough
for the inventory, metrics, activity log, diagnostic settings, locks, quota and content filters. Security Reader and
Cost Management Reader add the Defender and cost data. Missing permissions only blank the affected sections and are
listed under "Data collection notes" on the Summary sheet. Pivot tables are calculated when the workbook is opened in
Excel desktop (otherwise use Data > Refresh All).
