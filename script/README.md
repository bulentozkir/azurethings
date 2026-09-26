# azurethings
Automation code to improve Azure WAF CAF maturity

## Get-Azure-Ai-inventory.ps1

PowerShell 7 script that builds a comprehensive **Azure AI Inventory** Excel workbook (`.xlsx`) for the
16 AI services and 7 classic AI services listed in the Azure portal (Microsoft Foundry > AI services).

| Sheet | Content |
|---|---|
| 1. Summary | Key figures (linked to the detail sheets), AI services summary with links to every service sheet, report sheet guide and data collection notes |
| 2. Visuals | Pivot tables + charts: most common models, AI resources per service and region, token cost per deployed model, deployment types, token usage per model, actual vs. amortized cost per service, model retirement outlook, Defender findings, Advisor recommendations |
| 3. Recommendations | Azure Advisor recommendations for the AI resources |
| 4. Service Retirements | Retirements from the model lifecycle (model catalog), Azure Advisor, Azure Service Health and the classic AI services, with risk (RETIRED / CRITICAL / WARNING / REVIEW) and recommended action |
| 5. Service Health | Azure Service Health events: service issues, planned maintenance, health advisories, security advisories, billing updates |
| 6. Security Best Practices | Microsoft Defender for Cloud plan coverage (Defender for AI services, Defender CSPM), recommendations and security alerts for the AI resources |
| 7-29 | One inventory sheet per AI service: Foundry, AI Hubs, Azure OpenAI, AI Search, Bot services, Computer vision, Custom vision, Content safety, Document intelligence, Face API, Health Insights, Machine Learning, Immersive reader, Language service, Speech service, Translator, and the classic Anomaly detector, AI services multi-service account, Content moderator, Language understanding, Metrics advisor, Personalizer, QnA maker |

Every cost is reported as three columns: **Actual cost**, **Amortized cost** and **Reservation name** (the
reservation that covers the usage, e.g. a provisioned throughput (PTU) reservation - its usage shows 0 actual cost
and the reservation spread as amortized cost). `-CostType` only selects the measure of the token cost chart.
Model deployments show an estimated share of the billed model cost: token meters are split by token usage across
the pay-as-you-go deployments of the model in the same Global / DataZone / Regional scope, PTU meters by provisioned
capacity. A blank estimate means the cost could not be attributed (e.g. fine-tuned hosting fees).

Hidden `Data_*` sheets hold the flat datasets behind the pivot tables (`-ShowDataSheets` keeps them visible).

```powershell
Install-Module Az.Accounts, ImportExcel -Scope CurrentUser   # once
Connect-AzAccount
./Get-Azure-Ai-inventory.ps1                                   # all readable subscriptions of the tenant
./Get-Azure-Ai-inventory.ps1 -SubscriptionId $subA, $subB -UsageDays 60 -Show
./Get-Azure-Ai-inventory.ps1 -TenantId $tenantId -Subscriptions @($subA, $subB)   # another tenant, same sign-in
./Get-Azure-Ai-inventory.ps1 -ManagementGroupId contoso -SkipCost -OutputPath C:\reports\ai.xlsx
```

All calls are read-only (Resource Graph, ARM, Azure Monitor metrics, Cost Management). Reader is enough for the
inventory; Security Reader and Cost Management Reader add the Defender and cost data. Missing permissions only
blank the affected sections and are listed under "Data collection notes" on the Summary sheet. Pivot tables are
calculated when the workbook is opened in Excel desktop (otherwise use Data > Refresh All).
