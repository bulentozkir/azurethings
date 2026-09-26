<#
.SYNOPSIS
    Generates a comprehensive "Azure AI Inventory" Excel workbook (.xlsx) for the 16 AI services
    and the 7 classic AI services listed in the Azure portal (Microsoft Foundry > AI services).

.DESCRIPTION
    Read-only collector and report builder. The workbook contains 34 visible sheets:

      1     Summary                  Key figures (with links to the detail sheets), AI services
                                     summary (links to every service sheet), report sheet guide and
                                     data collection notes.
      2     Visuals                  Pivot tables + pivot charts: most common models, AI resources
                                     per service per region, token cost per deployed model,
                                     deployment types, token usage, cost per service, total AI
                                     spend by cost line, ML workspace cost, model retirement
                                     outlook, right-sizing status, content filter assessment,
                                     Defender findings, Advisor recommendations.
      3     Recommendations          Azure Advisor recommendations for the AI resources.
      4     Service Retirements      Retirements from the model lifecycle (model catalog), Azure
                                     Advisor, Azure Service Health and the classic AI services.
      5     Service Health           Azure Service Health events: service issues, planned
                                     maintenance, health advisories, security advisories and
                                     billing updates.
      6     Security Best Practices  Microsoft Defender for Cloud plan coverage (Defender for AI
                                     services, Defender CSPM), recommendations (assessments) and
                                     security alerts for the AI resources.
      7     Security Hygiene         Per AI resource: key (local) authentication, key retrievals and
                                     key rotation from the activity log, diagnostic logs, resource
                                     locks, network exposure, managed identity and Defender for AI.
      8     Content Filters          Content filter (RAI) policies compared with the Microsoft
                                     DefaultV2 baseline, and the policy, blocked and harmful request
                                     counts of every model deployment.
      9     Capacity and Quota       Model quota use per subscription and region, and right-sizing
                                     candidates: idle, over-allocated, throttled (HTTP 429) and
                                     under-used or saturated provisioned (PTU) deployments.
      10    AI Cost Reconciliation   Total AI spend: the AI resources plus AI reservation (PTU)
                                     purchases, unused reservations, Marketplace partner models
                                     (e.g. Claude), Copilot Studio and other AI meters, compared
                                     with the total spend of the subscriptions.
      11    ML Compute and Dependencies
                                     Azure Machine Learning / Foundry hub workspace cost by meter,
                                     compute instances and clusters (auto-shutdown, public IP, SSH,
                                     idle nodes) and the workspace dependencies (storage, key vault,
                                     container registry, Application Insights) with their security
                                     settings.
      12-34 One inventory sheet per AI service:
              Use with Foundry  Foundry, AI Hubs, Azure OpenAI, AI Search
              More services     Bot services, Computer vision, Custom vision, Content safety,
                                Document intelligence, Face API, Health Insights, Machine Learning,
                                Immersive reader, Language service, Speech service, Translator
              Classic services  Anomaly detector, AI services multi-service account, Content
                                moderator, Language understanding (LUIS), Metrics advisor,
                                Personalizer, QnA maker

    Every cost is reported as three columns: Actual cost, Amortized cost and Reservation name
    (the reservation, e.g. a provisioned throughput (PTU) reservation, that covers the usage).

    Four hidden Data_* sheets hold the flat datasets that feed the pivot tables
    (use -ShowDataSheets to keep them visible).

    Data sources (all read-only):
      * Azure Resource Graph ... resources, advisorresources, servicehealthresources, securityresources
      * Azure Resource Manager . Cognitive Services model deployments, Foundry projects, content
                                 filter (RAI) policies, model quota usage, the model catalog
                                 (lifecycle / retirement dates), diagnostic settings, resource locks
                                 and Azure Machine Learning computes
      * Azure Monitor metrics .. token usage, busiest-hour tokens, requests per HTTP status (429),
                                 last request, PTU utilization and content filter (RAI) request
                                 counts per model deployment, API calls per account
      * Azure activity log ..... key retrievals (listKeys) and key regenerations
      * Cost Management ........ actual and amortized cost per resource and per model token meter,
                                 with the covering reservation; AI reservation purchases, unused
                                 reservations, Marketplace models, Copilot and subscription totals

.PARAMETER OutputPath
    Path of the .xlsx file to create. Default: .\AzureAIInventory_<yyyyMMdd-HHmm>.xlsx

.PARAMETER TenantId
    Optional. Tenant (ID or domain) to inventory. Default: the tenant of the current Az context.
    The signed-in account is reused; the saved Az context is not changed. If no token can be
    obtained silently for the tenant, run Connect-AzAccount -TenantId <tenant> first.

.PARAMETER SubscriptionId
    Optional. One or more subscription IDs (array) to scope the inventory to; alias -Subscriptions.
    Default: every subscription the signed-in identity can read in the tenant.

.PARAMETER ManagementGroupId
    Optional. Management group to scope the inventory to (ignored when -SubscriptionId is used).

.PARAMETER UsageDays
    Look-back window in days for token usage metrics and cost. Default 30 (max 90).

.PARAMETER CostType
    Cost measure used by the "Token cost per deployed model" chart: AmortizedCost (default -
    spreads reservations such as PTU reservations over the resources that use them) or ActualCost.
    Tables always list Actual cost, Amortized cost and Reservation name.

.PARAMETER EventDays
    Look-back window in days for resolved Service Health events, Defender security alerts and the
    activity log (key retrievals and key regenerations; the activity log keeps at most 90 days).
    Active Service Health events are always included. Default 90.

.PARAMETER CriticalDays
    A retirement within this many days is flagged CRITICAL. Default 60.

.PARAMETER WarningDays
    A retirement within this many days is flagged WARNING. Default 180.

.PARAMETER ThrottleLimit
    Number of parallel ARM calls for the per-resource collection. Default 8.

.PARAMETER SkipCost
    Do not query Cost Management.

.PARAMETER SkipMetrics
    Do not query Azure Monitor metrics (token usage / API calls).

.PARAMETER SkipModelLifecycle
    Do not query the model catalog for model lifecycle and retirement dates.

.PARAMETER SkipActivityLog
    Do not read the activity log (key retrievals and key regenerations on the Security Hygiene
    sheet).

.PARAMETER AllServiceHealthEvents
    Include every Service Health event of the subscriptions that host AI resources, not only the
    events that concern AI services or AI resources.

.PARAMETER ShowDataSheets
    Keep the Data_* pivot source sheets visible (they are hidden by default).

.PARAMETER Show
    Open the workbook when done.

.EXAMPLE
    ./Get-Azure-Ai-inventory.ps1

.EXAMPLE
    ./Get-Azure-Ai-inventory.ps1 -SubscriptionId $subA, $subB -UsageDays 60 -Show

.EXAMPLE
    ./Get-Azure-Ai-inventory.ps1 -TenantId 00000000-0000-0000-0000-000000000000 -Subscriptions @('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222')

.EXAMPLE
    ./Get-Azure-Ai-inventory.ps1 -ManagementGroupId contoso-platform -SkipCost -OutputPath C:\reports\ai.xlsx

.NOTES
    Requires  PowerShell 7.2+, modules Az.Accounts and ImportExcel. Run Connect-AzAccount first.
    RBAC      Reader on the scope (inventory, Advisor, Service Health, model catalog, quota,
              content filters, metrics, activity log, diagnostic settings, locks, ML computes),
              Security Reader for Defender for Cloud data and Cost Management Reader for cost.
              Missing permissions only blank the affected columns or sections; see the
              "Data collection notes" at the bottom of the Summary sheet.
    Pivots    Pivot tables and charts are calculated by Excel when the workbook is opened in
              Excel desktop. If a viewer shows them empty, use Data > Refresh All.
#>
#Requires -Version 7.2
[CmdletBinding()]
param(
    [string]   $OutputPath = (Join-Path -Path (Get-Location) -ChildPath ('AzureAIInventory_{0}.xlsx' -f (Get-Date -Format 'yyyyMMdd-HHmm'))),
    [string]   $TenantId,
    [Alias('Subscriptions')]
    [string[]] $SubscriptionId,
    [string]   $ManagementGroupId,
    [ValidateRange(1, 90)]   [int] $UsageDays = 30,
    [ValidateSet('AmortizedCost', 'ActualCost')] [string] $CostType = 'AmortizedCost',
    [ValidateRange(1, 365)]  [int] $EventDays = 90,
    [ValidateRange(0, 3650)] [int] $CriticalDays = 60,
    [ValidateRange(0, 3650)] [int] $WarningDays = 180,
    [ValidateRange(1, 32)]   [int] $ThrottleLimit = 8,
    [switch] $SkipCost,
    [switch] $SkipMetrics,
    [switch] $SkipModelLifecycle,
    [switch] $SkipActivityLog,
    [switch] $AllServiceHealthEvents,
    [switch] $ShowDataSheets,
    [switch] $Show
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
$RunStartedUtc         = [datetime]::UtcNow
$TodayUtc              = $RunStartedUtc.Date

#region Preflight ----------------------------------------------------------------

foreach ($moduleName in 'Az.Accounts', 'ImportExcel') {
    if (-not (Get-Module -ListAvailable -Name $moduleName)) {
        throw "Module '$moduleName' is not installed. Run: Install-Module $moduleName -Scope CurrentUser"
    }
    Import-Module $moduleName -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null
}

$AzContext = Get-AzContext
if (-not $AzContext -or -not $AzContext.Account) { throw 'Not signed in. Run Connect-AzAccount first.' }

$UseContextTenant = -not $TenantId -or $TenantId -eq [string]$AzContext.Tenant.Id
if (-not $TenantId) { $TenantId = [string]$AzContext.Tenant.Id }
$ArmUrl    = ([string]$AzContext.Environment.ResourceManagerUrl).TrimEnd('/')
$PortalUrl = if ($AzContext.Environment.ManagementPortalUrl) { ([string]$AzContext.Environment.ManagementPortalUrl).TrimEnd('/') } else { 'https://portal.azure.com' }
$IsPublicCloud = $AzContext.Environment.Name -eq 'AzureCloud'
if ($WarningDays -lt $CriticalDays) { $WarningDays = $CriticalDays }

$OutputPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
if ([System.IO.Path]::GetExtension($OutputPath) -ne '.xlsx') { $OutputPath = "$OutputPath.xlsx" }
$outDir = Split-Path -Parent $OutputPath
if ($outDir -and -not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
if (Test-Path -LiteralPath $OutputPath) {
    try { Remove-Item -LiteralPath $OutputPath -Force }
    catch { throw "Cannot overwrite '$OutputPath'. Close it in Excel or choose another -OutputPath." }
}

$DoCost        = -not $SkipCost.IsPresent
$DoMetrics     = -not $SkipMetrics.IsPresent
$DoLifecycle   = -not $SkipModelLifecycle.IsPresent
$DoActivityLog = -not $SkipActivityLog.IsPresent

$UsageToUtc      = $RunStartedUtc
$UsageFromUtc    = $RunStartedUtc.AddDays(-$UsageDays)   # rolling window of exactly UsageDays days
$MetricsTimespan = '{0}/{1}' -f $UsageFromUtc.ToString('yyyy-MM-ddTHH:mm:ssZ'), $UsageToUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')
$UsageHours      = [Math]::Max(1.0, ($UsageToUtc - $UsageFromUtc).TotalHours)

# Look-back for the last request of a model deployment (Azure Monitor keeps metrics for 93 days)
$IdleLookbackDays = 90
$IdleTimespan     = '{0}/{1}' -f $RunStartedUtc.AddDays(-$IdleLookbackDays).ToString('yyyy-MM-ddTHH:mm:ssZ'), $UsageToUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')

# The activity log keeps 90 days of events
$ActivityDays    = [Math]::Min(90, $EventDays)
$ActivityFromUtc = $RunStartedUtc.AddDays(-$ActivityDays)

$Notes = [System.Collections.Generic.List[string]]::new()
function Add-Note {
    param([string]$Message, [switch]$Quiet)
    $script:Notes.Add($Message)
    if (-not $Quiet) { Write-Warning $Message }
}

$script:StepNo    = 0
$script:StepTotal = 11
function Write-Step {
    param([string]$Text)
    $script:StepNo++
    Write-Host ('[{0,2}/{1}] {2}' -f $script:StepNo, $script:StepTotal, $Text) -ForegroundColor Cyan
}

#endregion

#region Service catalog: 16 AI services + 7 classic AI services (Azure portal naming) ---

function New-ServiceDef {
    param(
        [string]$Key, [string]$Name, [string]$Sheet, [string]$Group, [string]$Family,
        [string[]]$Kinds = @(), [string]$Scope, [string]$RetireDate, [string]$Guidance, [string]$Link
    )
    [pscustomobject]@{
        Key        = $Key
        Name       = $Name
        Sheet      = if ($Sheet) { $Sheet } else { $Name }
        Group      = $Group
        Family     = $Family
        Kinds      = $Kinds
        Scope      = $Scope
        RetireDate = if ($RetireDate) { [datetime]::SpecifyKind([datetime]::ParseExact($RetireDate, 'yyyy-MM-dd', [cultureinfo]::InvariantCulture), 'Utc') } else { $null }
        Guidance   = $Guidance
        Link       = $Link
    }
}

$G1 = 'Use with Foundry'; $G2 = 'More services'; $G3 = 'Classic AI services'
$CogType = 'Microsoft.CognitiveServices/accounts'

$ServiceCatalog = @(
    New-ServiceDef -Key 'Foundry'              -Name 'Foundry'               -Group $G1 -Family 'Cognitive' -Kinds 'AIServices' -Scope "$CogType (kind AIServices), model deployments and Foundry projects"
    New-ServiceDef -Key 'AIHubs'               -Name 'AI Hubs'               -Group $G1 -Family 'MLHub'  -Scope 'Microsoft.MachineLearningServices/workspaces (kind Hub), hub-based projects and their endpoints'
    New-ServiceDef -Key 'AzureOpenAI'          -Name 'Azure OpenAI'          -Group $G1 -Family 'Cognitive' -Kinds 'OpenAI' -Scope "$CogType (kind OpenAI) and model deployments"
    New-ServiceDef -Key 'AISearch'             -Name 'AI Search'             -Group $G1 -Family 'Search' -Scope 'Microsoft.Search/searchServices'
    New-ServiceDef -Key 'BotServices'          -Name 'Bot services'          -Group $G2 -Family 'Bot'    -Scope 'Microsoft.BotService/botServices'
    New-ServiceDef -Key 'ComputerVision'       -Name 'Computer vision'       -Group $G2 -Family 'Cognitive' -Kinds 'ComputerVision' -Scope "$CogType (kind ComputerVision)"
    New-ServiceDef -Key 'CustomVision'         -Name 'Custom vision'         -Group $G2 -Family 'Cognitive' -Kinds 'CustomVision.Training', 'CustomVision.Prediction' -Scope "$CogType (kind CustomVision.Training / CustomVision.Prediction)"
    New-ServiceDef -Key 'ContentSafety'        -Name 'Content safety'        -Group $G2 -Family 'Cognitive' -Kinds 'ContentSafety' -Scope "$CogType (kind ContentSafety)"
    New-ServiceDef -Key 'DocumentIntelligence' -Name 'Document intelligence' -Group $G2 -Family 'Cognitive' -Kinds 'FormRecognizer' -Scope "$CogType (kind FormRecognizer)"
    New-ServiceDef -Key 'FaceAPI'              -Name 'Face API'              -Group $G2 -Family 'Cognitive' -Kinds 'Face' -Scope "$CogType (kind Face)"
    New-ServiceDef -Key 'HealthInsights'       -Name 'Health Insights'       -Group $G2 -Family 'Cognitive' -Kinds 'HealthInsights' -Scope "$CogType (kind HealthInsights)"
    New-ServiceDef -Key 'MachineLearning'      -Name 'Machine Learning'      -Group $G2 -Family 'ML'     -Scope 'Microsoft.MachineLearningServices/workspaces (kind Default / FeatureStore) and their endpoints'
    New-ServiceDef -Key 'ImmersiveReader'      -Name 'Immersive reader'      -Group $G2 -Family 'Cognitive' -Kinds 'ImmersiveReader' -Scope "$CogType (kind ImmersiveReader)"
    New-ServiceDef -Key 'LanguageService'      -Name 'Language service'      -Group $G2 -Family 'Cognitive' -Kinds 'TextAnalytics', 'ConversationalLanguageUnderstanding', 'LanguageAuthoring' -Scope "$CogType (kind TextAnalytics / ConversationalLanguageUnderstanding / LanguageAuthoring)"
    New-ServiceDef -Key 'SpeechService'        -Name 'Speech service'        -Group $G2 -Family 'Cognitive' -Kinds 'SpeechServices' -Scope "$CogType (kind SpeechServices)"
    New-ServiceDef -Key 'Translator'           -Name 'Translator'            -Group $G2 -Family 'Cognitive' -Kinds 'TextTranslation' -Scope "$CogType (kind TextTranslation)"
    New-ServiceDef -Key 'AnomalyDetector'      -Name 'Anomaly detector (classic)' -Group $G3 -Family 'Cognitive' -Kinds 'AnomalyDetector' -Scope "$CogType (kind AnomalyDetector)" `
        -RetireDate '2026-10-01' -Link 'https://learn.microsoft.com/azure/ai-services/anomaly-detector/overview' `
        -Guidance 'No new resources since 20 Sep 2023. Migrate to anomaly detection in Microsoft Fabric Real-Time Intelligence (or the open-source microsoft/anomaly-detector package).'
    New-ServiceDef -Key 'MultiService'         -Name 'Azure AI services multi-service account (classic)' -Sheet 'Multi-service account (classic)' -Group $G3 -Family 'Cognitive' -Kinds 'CognitiveServices' -Scope "$CogType (kind CognitiveServices)" `
        -Link 'https://learn.microsoft.com/azure/ai-services/multi-service-resource' `
        -Guidance 'No retirement date announced. Microsoft recommends Foundry resources (kind AIServices) for new workloads - plan the move.'
    New-ServiceDef -Key 'ContentModerator'     -Name 'Content moderator (classic)' -Group $G3 -Family 'Cognitive' -Kinds 'ContentModerator' -Scope "$CogType (kind ContentModerator)" `
        -RetireDate '2027-03-15' -Link 'https://learn.microsoft.com/azure/ai-services/content-moderator/overview' `
        -Guidance 'Deprecated since February 2024. Migrate to Azure AI Content Safety.'
    New-ServiceDef -Key 'LUIS'                 -Name 'Language understanding (classic)' -Sheet 'Lang. understanding (classic)' -Group $G3 -Family 'Cognitive' -Kinds 'LUIS', 'LUIS.Authoring' -Scope "$CogType (kind LUIS / LUIS.Authoring)" `
        -RetireDate '2025-10-01' -Link 'https://learn.microsoft.com/azure/ai-services/luis/what-is-luis' `
        -Guidance 'Retired 1 Oct 2025; since 31 Mar 2026 all LUIS runtime and authoring requests fail. Migrate to Microsoft Foundry (conversational language understanding itself retires 31 Mar 2029).'
    New-ServiceDef -Key 'MetricsAdvisor'       -Name 'Metrics advisor (classic)' -Group $G3 -Family 'Cognitive' -Kinds 'MetricsAdvisor' -Scope "$CogType (kind MetricsAdvisor)" `
        -RetireDate '2026-10-01' -Link 'https://learn.microsoft.com/azure/ai-services/metrics-advisor/overview' `
        -Guidance 'Service retires on 1 Oct 2026. Plan the migration of data feeds and alerting before the retirement date.'
    New-ServiceDef -Key 'Personalizer'         -Name 'Personalizer (classic)' -Group $G3 -Family 'Cognitive' -Kinds 'Personalizer' -Scope "$CogType (kind Personalizer)" `
        -RetireDate '2026-10-01' -Link 'https://learn.microsoft.com/azure/ai-services/personalizer/what-is-personalizer' `
        -Guidance 'Service retires on 1 Oct 2026. Plan the migration of ranking / reward workloads before the retirement date.'
    New-ServiceDef -Key 'QnAMaker'             -Name 'QnA maker (classic)' -Group $G3 -Family 'Cognitive' -Kinds 'QnAMaker', 'QnAMaker.v2' -Scope "$CogType (kind QnAMaker / QnAMaker.v2)" `
        -RetireDate '2025-03-31' -Link 'https://learn.microsoft.com/azure/ai-services/qnamaker/overview/overview' `
        -Guidance 'Retired 31 Mar 2025. Migrate the knowledge bases to Microsoft Foundry (agents with knowledge retrieval).'
)

$ServiceByKey     = @{}
$KindToServiceKey = @{}
foreach ($svc in $ServiceCatalog) {
    $ServiceByKey[$svc.Key] = $svc
    foreach ($k in $svc.Kinds) { $KindToServiceKey[$k] = $svc.Key }
}

# Regex used to decide whether a Service Health event / Advisor item concerns AI services.
$AiServiceRegex  = '(?i)open ?ai|cognitive|\bai services\b|\bazure ai\b|foundry|machine learning|bot service|\bsearch\b|speech|translator|\bvision\b|\bface\b|form recognizer|document intelligence|\blanguage\b|content safety|content moderator|health insights|immersive reader|anomaly detector|metrics advisor|personalizer|qna maker|\bluis\b'
# Service Health names services its own way (e.g. 'Azure OpenAI Service'); map them to the service names of this
# workbook. The first match wins, so the specific patterns come before the generic ones.
$HealthServiceMap = @(
    @('(?i)open ?ai', 'Azure OpenAI'),
    @('(?i)foundry|\bai studio\b', 'Foundry'),
    @('(?i)machine learning', 'Machine Learning'),
    @('(?i)\bai search\b|cognitive search', 'AI Search'),
    @('(?i)bot service', 'Bot services'),
    @('(?i)custom vision', 'Custom vision'),
    @('(?i)\bvision\b', 'Computer vision'),
    @('(?i)content safety', 'Content safety'),
    @('(?i)document intelligence|form recognizer', 'Document intelligence'),
    @('(?i)\bface\b', 'Face API'),
    @('(?i)health insights', 'Health Insights'),
    @('(?i)immersive reader', 'Immersive reader'),
    @('(?i)language understanding|\bluis\b', 'Language understanding (classic)'),
    @('(?i)\blanguage\b|text analytics', 'Language service'),
    @('(?i)speech', 'Speech service'),
    @('(?i)translator', 'Translator'),
    @('(?i)anomaly detector', 'Anomaly detector (classic)'),
    @('(?i)content moderator', 'Content moderator (classic)'),
    @('(?i)metrics advisor', 'Metrics advisor (classic)'),
    @('(?i)personalizer', 'Personalizer (classic)'),
    @('(?i)qna maker', 'QnA maker (classic)')
)
function Get-CatalogServiceName {
    param([string]$Name)
    foreach ($m in $HealthServiceMap) { if ($Name -match $m[0]) { return $m[1] } }
    return $null
}
$AiAdvisorRegex  = '(?i)open ?ai|cognitive ?services|\bai services\b|foundry|machine ?learning|\bai search\b|cognitive search|bot service|\bptu\b|provisioned throughput unit'
$MeterStopWords  = @('inp', 'input', 'inputs', 'opt', 'outp', 'output', 'outputs', 'cached', 'cchd', 'cache', 'cch', 'cd', 'wr', 'write', 'gl', 'glbl', 'global',
    'dz', 'datazone', 'dzone', 'data', 'zone', 'regnl', 'regional', 'rgnl', 'reg', 'rg', 'tokens', 'token', 'tkns', 'tok', '1m', '1k', 'priority',
    'batch', 'paygo', 'inference', 'prompt', 'completion', 'completions', 'generated', 'units', 'unit', 'hosting', 'provisioned', 'managed',
    'ptu', 'hour', 'hours', 'hr', 'in', 'out', 'std', 'standard', 'shortco', 'longco')

# Cost reconciliation: meter categories of AI services and partner models sold through Azure Marketplace.
$AiMeterRegex       = '(?i)^(foundry|azure openai|cognitive services|azure cognitive search|azure ai|azure bot service|machine learning|azure machine learning)'
$AiMarketplaceRegex = '(?i)claude|anthropic|mistral|codestral|ministral|llama|\bmeta\b|cohere|grok|\bxai\b|deepseek|\bjais\b|ai21|jamba|nixtla|timegen|\bphi-?\d|\bgpt|openai|gemini|black ?forest|\bflux|stability ai|stable diffusion|\bbria\b|nemotron|nvidia nim|core42|palmyra|\bwriter\b|paige|virchow|sakana|voyage ai|nomic|jina ai|qwen|kimi|moonshot'

# Activity log operations that read or renew keys / secrets of AI resources.
$KeyRetrievalRegex    = '(?i)/(list\w*keys|listsecrets|listchannelwithkeys)/action$'
$KeyRegenerationRegex = '(?i)/(regenerate\w*|resynckeys)/action$'

# Microsoft.DefaultV2 content filter baseline (what a deployment gets when no custom policy is assigned).
$ContentHarmCategories = 'Hate', 'Sexual', 'Violence', 'Selfharm'

#endregion

#region Helpers: REST / Resource Graph ---------------------------------------------

function Get-ArmToken {
    if ($script:ArmTokenCache -and $script:ArmTokenCache.ExpiresOn -gt [DateTimeOffset]::UtcNow.AddMinutes(10)) {
        return $script:ArmTokenCache.Token
    }
    $t = Get-AzAccessToken -ResourceUrl "$ArmUrl/" -TenantId $TenantId -WarningAction SilentlyContinue -ErrorAction Stop
    # Az.Accounts 5+ returns the token as SecureString, older versions as plain text.
    $plain = if ($t.Token -is [securestring]) { [System.Net.NetworkCredential]::new('', $t.Token).Password } else { [string]$t.Token }
    $script:ArmTokenCache = [pscustomobject]@{ Token = $plain; ExpiresOn = [DateTimeOffset]$t.ExpiresOn }
    return $plain
}

# Self-contained REST core, also used inside ForEach-Object -Parallel runspaces.
# Retries 429/5xx honouring Retry-After style headers and optionally follows nextLink paging.
$RestCoreText = @'
param([string]$Uri, [string]$Token, [string]$Method = 'GET', [string]$Body, [switch]$AllPages, [int]$MaxRetries = 6)
$ProgressPreference = 'SilentlyContinue'
$items = [System.Collections.Generic.List[object]]::new()
$next  = $Uri
while ($next) {
    $attempt = 0
    $resp = $null
    while ($true) {
        $attempt++
        try {
            $p = @{ Uri = $next; Method = $Method; Headers = @{ Authorization = "Bearer $Token" }; SkipHttpErrorCheck = $true; TimeoutSec = 180; ErrorAction = 'Stop' }
            if ($Body) { $p.Body = $Body; $p.ContentType = 'application/json' }
            $resp = Invoke-WebRequest @p
        }
        catch {
            if ($attempt -le $MaxRetries) { Start-Sleep -Seconds ([Math]::Min(30, [Math]::Pow(2, $attempt))); continue }
            return [pscustomobject]@{ Ok = $false; Status = 0; Data = $null; Error = $_.Exception.Message }
        }
        $code = [int]$resp.StatusCode
        if (($code -eq 429 -or $code -ge 500) -and $attempt -le $MaxRetries) {
            $wait = [Math]::Min(60, [Math]::Pow(2, $attempt))
            foreach ($h in $resp.Headers.GetEnumerator()) {
                if ($h.Key -match '(?i)retry-after$|quota-resets-after$') {
                    $v  = [string]($h.Value | Select-Object -First 1)
                    $n  = 0
                    $ts = [timespan]::Zero
                    if ([int]::TryParse($v, [ref]$n)) { $wait = [Math]::Max(1, $n) }
                    elseif ([timespan]::TryParse($v, [ref]$ts)) { $wait = [Math]::Max(1, [int][Math]::Ceiling($ts.TotalSeconds)) }
                    break
                }
            }
            Start-Sleep -Seconds ([Math]::Min(120, $wait))
            continue
        }
        break
    }
    $code    = [int]$resp.StatusCode
    $content = [string]$resp.Content
    if ($code -lt 200 -or $code -ge 300) {
        $msg = $content
        try { $e = $content | ConvertFrom-Json -Depth 20; if ($e.error) { $msg = "$($e.error.code): $($e.error.message)" } } catch { }
        if ($msg.Length -gt 400) { $msg = $msg.Substring(0, 400) }
        return [pscustomobject]@{ Ok = $false; Status = $code; Data = $null; Error = "HTTP $code $msg" }
    }
    $data = if ($content) { $content | ConvertFrom-Json -Depth 100 } else { $null }
    if (-not $AllPages) { return [pscustomobject]@{ Ok = $true; Status = $code; Data = $data; Error = $null } }
    if ($null -ne $data -and $data.PSObject.Properties['value']) { foreach ($v in @($data.value)) { if ($null -ne $v) { $items.Add($v) } } }
    $next = $null
    if ($null -ne $data) {
        foreach ($pn in 'nextLink', '@odata.nextLink') {
            if ($data.PSObject.Properties[$pn] -and $data.$pn) { $next = [string]$data.$pn; break }
        }
    }
}
return [pscustomobject]@{ Ok = $true; Status = 200; Data = $items.ToArray(); Error = $null }
'@
$RestCore = [scriptblock]::Create($RestCoreText)

function Invoke-Arm {
    param([Parameter(Mandatory)][string]$Uri, [string]$Method = 'GET', $Body, [switch]$AllPages)
    if ($Uri -notmatch '^https?://') { $Uri = $ArmUrl + $Uri }
    $bodyText = if ($null -eq $Body) { $null } elseif ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 30 -Compress }
    $r = & $RestCore -Uri $Uri -Token (Get-ArmToken) -Method $Method -Body $bodyText -AllPages:$AllPages
    if (-not $r.Ok -and $r.Status -eq 401) {
        $script:ArmTokenCache = $null
        $r = & $RestCore -Uri $Uri -Token (Get-ArmToken) -Method $Method -Body $bodyText -AllPages:$AllPages
    }
    return $r
}

$script:ArgFailures = @{}   # query label -> error of a failed (thus incomplete) Resource Graph query

function Invoke-Arg {
    param([Parameter(Mandatory)][string]$Query, [string]$Label = 'query', [string[]]$Subscriptions)
    $rows    = [System.Collections.Generic.List[object]]::new()
    # One entry per request scope: batches of max. 1000 subscriptions (Resource Graph limit) or
    # $null for the tenant / management group scope (no subscription limit).
    $targets = @(if ($Subscriptions) { $Subscriptions } elseif ($SubscriptionId) { $SubscriptionId })
    $scopes  = [System.Collections.Generic.List[object]]::new()
    if ($targets.Count) {
        for ($i = 0; $i -lt $targets.Count; $i += 1000) { $scopes.Add(@($targets[$i..([Math]::Min($i + 999, $targets.Count - 1))])) }
    }
    else { $scopes.Add($null) }
    foreach ($scope in $scopes) {
        $skip = $null
        do {
            $body = [ordered]@{ query = $Query; options = [ordered]@{ resultFormat = 'objectArray'; '$top' = 1000 } }
            if ($skip) { $body.options['$skipToken'] = $skip }
            if ($scope) { $body.subscriptions = @($scope) }
            elseif ($ManagementGroupId) { $body.managementGroups = @($ManagementGroupId) }
            $r = Invoke-Arm -Method POST -Uri '/providers/Microsoft.ResourceGraph/resources?api-version=2022-10-01' -Body $body
            if (-not $r.Ok) {
                $script:ArgFailures[$Label] = $r.Error
                Add-Note "Resource Graph ($Label) failed: $($r.Error)"
                break
            }
            foreach ($d in @($r.Data.data)) { if ($null -ne $d) { $rows.Add($d) } }
            $skip = if ($r.Data.PSObject.Properties['$skipToken']) { [string]$r.Data.'$skipToken' } else { $null }
        } while ($skip)
    }
    return $rows
}

function Test-ArgComplete {
    param([string[]]$Labels)
    foreach ($l in $Labels) { if ($script:ArgFailures.ContainsKey($l)) { return $false } }
    return $true
}

#endregion

#region Helpers: data shaping -------------------------------------------------------

function ConvertTo-UtcDateTime {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [datetime]) {
        if ($Value.Kind -eq [DateTimeKind]::Unspecified) { return [datetime]::SpecifyKind($Value, 'Utc') }
        return $Value.ToUniversalTime()
    }
    if ($Value -is [datetimeoffset]) { return $Value.UtcDateTime }
    if ($Value -is [long] -or $Value -is [int] -or $Value -is [double] -or $Value -is [decimal]) {
        # Service Health timestamps in Resource Graph are .NET ticks.
        $l = [long]$Value
        if ($l -gt 100000000000000000 -and $l -lt [datetime]::MaxValue.Ticks) { return [datetime]::new($l, [DateTimeKind]::Utc) }
        return $null
    }
    $s = [string]$Value
    if ([string]::IsNullOrWhiteSpace($s)) { return $null }
    $dto = [datetimeoffset]::MinValue
    if ([datetimeoffset]::TryParse($s, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$dto)) { return $dto.UtcDateTime }
    return $null
}

function ConvertTo-PlainText {
    param($Text, [int]$MaxLength = 1000)
    if ($null -eq $Text) { return '' }
    $s = [string]$Text
    if ([string]::IsNullOrWhiteSpace($s)) { return '' }
    $s = $s -replace '(?i)<br\s*/?>|</p>|</div>|</h\d>|</tr>', ' ' -replace '(?i)<li[^>]*>', ' - ' -replace '<[^>]+>', ''
    $s = [System.Net.WebUtility]::HtmlDecode($s)
    $s = ($s -replace '\s+', ' ').Trim()
    if ($s.Length -gt $MaxLength) { $s = $s.Substring(0, $MaxLength - 3) + '...' }
    if ($s.StartsWith('=')) { $s = ' ' + $s }   # never let text be written as an Excel formula
    return $s
}

function Get-TopLevelId {
    param([string]$Id)
    if ([string]::IsNullOrWhiteSpace($Id)) { return '' }
    $parts = $Id.Trim().Trim('/').Split('/')
    if ($parts.Count -ge 8 -and $parts[0] -eq 'subscriptions' -and $parts[2] -eq 'resourceGroups' -and $parts[4] -eq 'providers') {
        return ('/' + ($parts[0..7] -join '/')).ToLowerInvariant()
    }
    return ('/' + ($parts -join '/')).ToLowerInvariant()
}

function Get-LastSegment {
    param([string]$Id)
    if ([string]::IsNullOrWhiteSpace($Id)) { return '' }
    return ($Id.Trim().TrimEnd('/') -split '/')[-1]
}

function Get-RegionName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return '(none)' }
    $k = $Name.ToLowerInvariant()
    if ($script:RegionNames.ContainsKey($k)) { return $script:RegionNames[$k] }
    return $Name
}

function Get-SubscriptionName {
    param([string]$Id)
    if ([string]::IsNullOrWhiteSpace($Id)) { return '' }
    if ($script:SubscriptionNames.ContainsKey($Id)) { return $script:SubscriptionNames[$Id] }
    return $Id
}

function Format-Tags {
    param($Tags)
    if ($null -eq $Tags) { return '' }
    $pairs = foreach ($p in $Tags.PSObject.Properties) { '{0}={1}' -f $p.Name, $p.Value }
    return (@($pairs) -join '; ')
}

function Join-Unique {
    param([object[]]$Values, [string]$Separator = ', ')
    return ((@($Values) | Where-Object { $null -ne $_ -and "$_" -ne '' } | ForEach-Object { [string]$_ } | Sort-Object -Unique) -join $Separator)
}

function Get-DaysUntil {
    param($Date)
    if ($null -eq $Date) { return $null }
    return [int][Math]::Floor(($Date.Date - $TodayUtc).TotalDays)
}

function Get-RetirementRisk {
    param($Date)
    if ($null -eq $Date) { return 'NO DATE' }
    $d = Get-DaysUntil $Date
    if ($d -lt 0) { return 'RETIRED' }
    if ($d -le $CriticalDays) { return 'CRITICAL' }
    if ($d -le $WarningDays) { return 'WARNING' }
    return 'OK'
}

function Get-DateFromText {
    # Structured dates are preferred by the callers; this only mines free text. With several dates in
    # the text, the one right after a retirement keyword wins; otherwise the date stays unknown.
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $months = 'January|February|March|April|May|June|July|August|September|October|November|December'
    $inv = [cultureinfo]::InvariantCulture
    $found = [System.Collections.Generic.List[object]]::new()
    $patterns = @(
        @{ Rx = "\b(\d{1,2})(?:st|nd|rd|th)?\s+(?:of\s+)?($months)\s*,?\s+(\d{4})\b"; Fmt = { param($g) '{0} {1} {2}' -f $g[1].Value, $g[2].Value, $g[3].Value } }
        @{ Rx = "\b($months)\s+(\d{1,2})(?:st|nd|rd|th)?\s*,?\s+(\d{4})\b"; Fmt = { param($g) '{0} {1} {2}' -f $g[2].Value, $g[1].Value, $g[3].Value } }
        @{ Rx = '\b(20\d{2})-(\d{2})-(\d{2})\b'; Fmt = $null }
    )
    foreach ($p in $patterns) {
        foreach ($mm in [regex]::Matches($Text, $p.Rx, 'IgnoreCase')) {
            try {
                $d = if ($p.Fmt) { [datetime]::ParseExact((& $p.Fmt $mm.Groups), 'd MMMM yyyy', $inv) } else { [datetime]::ParseExact($mm.Value, 'yyyy-MM-dd', $inv) }
                $found.Add([pscustomobject]@{ Index = $mm.Index; Date = [datetime]::SpecifyKind($d, 'Utc') })
            }
            catch { }
        }
    }
    if ($found.Count -eq 0) { return $null }
    if (@($found | Select-Object -ExpandProperty Date -Unique).Count -eq 1) { return $found[0].Date }
    $best = $null
    $bestDistance = [int]::MaxValue
    foreach ($k in [regex]::Matches($Text, '(?i)retir|end of support|end-of-life|deprecat|shut ?down|discontinu|sunset')) {
        foreach ($f in $found) {
            $distance = $f.Index - $k.Index
            if ($distance -ge 0 -and $distance -lt 120 -and $distance -lt $bestDistance) { $bestDistance = $distance; $best = $f }
        }
    }
    if ($best) { return $best.Date }
    return $null
}

function Get-PortalLink {
    param([string]$Id)
    if ([string]::IsNullOrWhiteSpace($Id)) { return '' }
    return "$PortalUrl/#@$TenantId/resource$Id"
}

function Get-ServiceHealthLink {
    param([string]$TrackingId, [string]$Subscription)
    if (-not $IsPublicCloud -or -not $TrackingId -or -not $Subscription -or $Subscription.Length -lt 6) { return '' }
    # Documented deep link format: https://app.azure.com/h/<trackingId>/<first 3 + last 3 chars of the subscription id>
    return 'https://app.azure.com/h/{0}/{1}{2}' -f $TrackingId, $Subscription.Substring(0, 3), $Subscription.Substring($Subscription.Length - 3)
}

function Get-NormalizedName {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    return ($Text.ToLowerInvariant() -replace '[^a-z0-9]', '')
}

function Get-IdentityLabel {
    param([string]$Type)
    if ([string]::IsNullOrWhiteSpace($Type) -or $Type -eq 'None') { return 'None' }
    return $Type
}

function Get-PublicAccess {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return 'Enabled' }   # ARM default when the property is not set
    return $Value.Substring(0, 1).ToUpperInvariant() + $Value.Substring(1)   # AI Search reports 'enabled' / 'disabled'
}

function Get-SkuScope {
    param([string]$Sku)
    if ($Sku -match '^(?i)global') { return 'Global' }
    if ($Sku -match '^(?i)datazone') { return 'DataZone' }
    if ($Sku) { return 'Regional' }
    return ''
}

function Get-AdvisorCategory {
    param([string]$Category)
    switch ($Category) {
        'HighAvailability'      { 'Reliability' }
        'OperationalExcellence' { 'Operational excellence' }
        ''                      { 'Other' }
        default                 { $Category }
    }
}

function Get-EventTypeLabel {
    param([string]$Type)
    switch ($Type) {
        'ServiceIssue'       { 'Service issue' }
        'PlannedMaintenance' { 'Planned maintenance' }
        'HealthAdvisory'     { 'Health advisory' }
        'SecurityAdvisory'   { 'Security advisory' }
        'Billing'            { 'Billing update' }
        'EmergingIssues'     { 'Emerging issue' }
        'RCA'                { 'Post-incident review' }
        ''                   { 'Other' }
        default              { $Type }
    }
}

function Format-NetworkInjection {
    param($Value)
    if ($null -eq $Value) { return '' }
    $parts = foreach ($n in @($Value)) {
        if ($null -eq $n) { continue }
        $scenario = if ($n.scenario) { [string]$n.scenario } else { 'agent' }
        if ($n.subnetArmId) { '{0}: subnet {1}' -f $scenario, (Get-LastSegment $n.subnetArmId) }
        elseif ($n.useMicrosoftManagedNetwork) { '{0}: Microsoft-managed network' -f $scenario }
    }
    return (@($parts) -join '; ')
}

function Get-MlModelInfo {
    param([string]$ModelId)
    $r = [pscustomobject]@{ Name = ''; Version = ''; Source = '' }
    if ([string]::IsNullOrWhiteSpace($ModelId)) { return $r }
    if ($ModelId -match '(?i)/registries/(?<reg>[^/]+)/models/(?<n>[^/]+)(/versions/(?<v>[^/]+))?') {
        $r.Name = $Matches['n']; $r.Version = [string]$Matches['v']; $r.Source = $Matches['reg']
    }
    elseif ($ModelId -match '(?i)/models/(?<n>[^/]+)(/versions/(?<v>[^/]+))?') {
        $r.Name = $Matches['n']; $r.Version = [string]$Matches['v']; $r.Source = 'workspace'
    }
    elseif ($ModelId -match '(?i)^azureml:(?<n>[^:@]+)(:(?<v>[^@]+))?') {
        $r.Name = $Matches['n']; $r.Version = [string]$Matches['v']; $r.Source = 'workspace'
    }
    else { $r.Name = $ModelId }
    return $r
}

function Get-MeterInfo {
    # Parses Cost Management meter names such as "gpt-4o-0806-Inp-glbl Tokens", "5.4 mini Opt Gl 1M Tokens",
    # "V4 Flash cached DZ Tokens", "5.4 mini cd Inp Gl 1M Tokens" (cd = cached), "GPT 5.1 inp Rg 1M Tokens" (Rg = regional)
    # or "5.6 sol ShortCo Cd Wr Std Gl 1M Tokens".
    param([string]$Meter)
    $m = ([string]$Meter).ToLowerInvariant()
    $tokens = @($m -split '[\s\-_/]+' | Where-Object { $_ })
    $cached = $m -match 'cach|cchd|\bcd\b'
    $type = if ($cached -and $m -match '\bwr\b|write') { 'Cache write' }
            elseif ($cached) { 'Cached input' }
            elseif ($tokens -contains 'inp' -or $m -match 'input|prompt|\bin\b') { 'Input' }
            elseif ($tokens -contains 'opt' -or $tokens -contains 'outp' -or $m -match 'output|completion|generated|\bout\b') { 'Output' }
            elseif ($m -match 'provisioned|\bptu\b|hosting') { 'Provisioned (PTU)' }
            elseif ($m -match 'fine.?tun|training|\bft\b') { 'Fine-tuning' }
            elseif ($m -match 'token') { 'Tokens' }   # e.g. embeddings: a single token meter without direction
            else { 'Other' }
    $scope = if (@($tokens | Where-Object { $_ -in 'gl', 'glbl', 'global' }).Count) { 'Global' }
             elseif (@($tokens | Where-Object { $_ -in 'dz', 'datazone', 'dzone' }).Count -or $m -match 'data ?zone') { 'DataZone' }
             elseif (@($tokens | Where-Object { $_ -in 'rg', 'reg', 'regnl', 'regional', 'rgnl' }).Count) { 'Regional' }
             else { '' }
    $core = (@($tokens | Where-Object { $_ -notin $MeterStopWords }) -join ' ').Trim()
    # 4-digit tokens such as 0513 / 0806 / 1120 are model version hints (MMDD of the model version).
    $versionHint = @($tokens | Where-Object { $_ -match '^\d{4}$' } | Select-Object -First 1)[0]
    return [pscustomobject]@{ TokenType = $type; Scope = $scope; Core = $core; CoreNormalized = (Get-NormalizedName $core); VersionHint = [string]$versionHint }
}

function Resolve-MeterModel {
    # Picks the deployed model whose normalized name best matches the model part of a meter name.
    param([string]$Core, [string[]]$Candidates)
    if ([string]::IsNullOrEmpty($Core) -or $Core.Length -lt 2 -or -not $Candidates) { return $null }
    $best = $null
    $bestScore = 0.0
    foreach ($c in $Candidates) {
        $n = Get-NormalizedName $c
        if (-not $n) { continue }
        $score = 0.0
        if ($n -eq $Core) { $score = 100 }
        elseif ($n.EndsWith($Core)) { $score = 90 - ($n.Length - $Core.Length) * 0.1 }
        elseif ($Core.StartsWith($n)) { $score = 80 + $n.Length * 0.1 }
        elseif ($n.Contains($Core)) { $score = 70 - ($n.Length - $Core.Length) * 0.1 }
        elseif ($Core.Contains($n)) { $score = 60 + $n.Length * 0.1 }
        if ($score -gt $bestScore) { $bestScore = $score; $best = $c }
    }
    return $best
}

function Get-CatalogRetireDate {
    # Effective retirement of a catalog model for a deployment type: earliest of the inference
    # deprecation and the SKU-level deprecation (placeholder dates in 2099+ mean "no date").
    param($Model, [string]$SkuName)
    $dates = [System.Collections.Generic.List[datetime]]::new()
    $inf = ConvertTo-UtcDateTime $Model.deprecation.inference
    if ($inf -and $inf.Year -lt 2099) { $dates.Add($inf) }
    foreach ($s in @($Model.skus)) {
        if ($null -eq $s -or $s.name -ne $SkuName -or ([string]$s.usageName) -match '(?i)finetune') { continue }
        $sd = ConvertTo-UtcDateTime $s.deprecationDate
        if ($sd -and $sd.Year -lt 2099) { $dates.Add($sd) }
    }
    if ($dates.Count -eq 0) { return $null }
    return ($dates | Sort-Object | Select-Object -First 1).Date
}

function Get-DeploymentLifecycle {
    param($Account, [string]$ModelName, [string]$ModelVersion, [string]$SkuName, [string]$UpgradeOption)
    $r = [pscustomobject]@{ Lifecycle = ''; RetirementDate = $null; Days = $null; Risk = 'NOT CHECKED'; Impact = ''; Suggested = '' }
    if (-not $DoLifecycle) { return $r }
    if (-not $ModelName) { $r.Risk = 'UNKNOWN'; return $r }
    $k1 = '{0}|{1}|{2}' -f $Account.SubscriptionId, $Account.Location, $ModelName.ToLowerInvariant()
    $list = $script:CatalogIndex["$k1|$ModelVersion"]
    if (-not $list) {
        $catalogRead = $script:CatalogStatus['{0}|{1}' -f $Account.SubscriptionId, $Account.Location]
        $r.Risk = if ($catalogRead -eq $false) { 'CATALOG UNAVAILABLE' } else { 'NOT IN CATALOG' }
        return $r
    }
    $entry = @($list | Where-Object { $_.kind -eq $Account.Kind })[0]
    if (-not $entry) { $entry = $list[0] }
    $r.Lifecycle = [string]$entry.model.lifecycleStatus
    $retire = Get-CatalogRetireDate -Model $entry.model -SkuName $SkuName
    if ($retire) {
        $r.RetirementDate = $retire
        $r.Days = Get-DaysUntil $retire
        $r.Risk = Get-RetirementRisk $retire
    }
    else { $r.Risk = 'NO DATE PUBLISHED' }
    if ($r.Risk -in 'RETIRED', 'CRITICAL', 'WARNING') {
        $r.Impact = if ($UpgradeOption -eq 'NoAutoUpgrade') { 'Breaks at retirement - version pinned (NoAutoUpgrade)' } else { "Auto-upgrade enabled ($UpgradeOption)" }
    }
    if ($r.Risk -in 'RETIRED', 'CRITICAL', 'WARNING' -or $r.Lifecycle -in 'Deprecating', 'Deprecated') {
        # Newer version of the same model offering the same (non fine-tuning) deployment type; GA versions first.
        $alts = foreach ($e in @($script:CatalogByModel[$k1])) {
            if ($null -eq $e -or $e.kind -ne $entry.kind -or [string]$e.model.version -eq $ModelVersion) { continue }
            if ([string]$e.model.format -and [string]$entry.model.format -and [string]$e.model.format -ne [string]$entry.model.format) { continue }
            $life = [string]$e.model.lifecycleStatus
            if ($life -in 'Deprecated', 'Deprecating', 'Retired') { continue }
            if (-not @($e.model.skus | Where-Object { $_ -and $_.name -eq $SkuName -and ([string]$_.usageName) -notmatch '(?i)finetune' }).Count) { continue }
            $rd = Get-CatalogRetireDate -Model $e.model -SkuName $SkuName
            if ($retire -and $rd -and $rd -le $retire) { continue }
            [pscustomobject]@{
                Version   = [string]$e.model.version
                IsGA      = $life -match '(?i)^(GenerallyAvailable|Stable|GA)$'
                IsPreview = $life -match '(?i)preview'
                IsDefault = [bool]$e.model.isDefaultVersion
                Retire    = $(if ($rd) { $rd } else { [datetime]::MaxValue })
            }
        }
        $best = @($alts | Sort-Object -Property @{ Expression = 'IsGA'; Descending = $true }, @{ Expression = 'IsDefault'; Descending = $true }, @{ Expression = 'Retire'; Descending = $true })[0]
        if ($best) { $r.Suggested = "$ModelName $($best.Version)$(if ($best.IsPreview) { ' (preview)' })" }
    }
    return $r
}

function Select-Export {
    # Drops internal ("_" prefixed) properties so only report columns reach Excel.
    param([object[]]$Rows, [string[]]$Exclude = @())
    $list = @($Rows | Where-Object { $null -ne $_ })
    if ($list.Count -eq 0) { return @() }
    $cols = @($list[0].PSObject.Properties.Name | Where-Object { $_ -notlike '_*' -and $_ -notin $Exclude })
    return @($list | Select-Object -Property $cols)
}

#endregion

#region 1. Subscriptions and regions -------------------------------------------------

Write-Step 'Resolving subscriptions and region names'

try { $null = Get-ArmToken }
catch { throw "Cannot get an Azure Resource Manager token for tenant '$TenantId' ($($_.Exception.Message)). Run: Connect-AzAccount -TenantId $TenantId" }
Write-Host "        Tenant $TenantId, signed in as $($AzContext.Account.Id)"

$kqlSubscriptions = @'
resourcecontainers
| where type =~ 'microsoft.resources/subscriptions'
| project subscriptionId, name
'@
$SubscriptionNames = @{}
foreach ($s in @(Invoke-Arg -Label 'subscriptions' -Query $kqlSubscriptions)) { $SubscriptionNames[[string]$s.subscriptionId] = [string]$s.name }

$RegionNames = @{ 'global' = 'Global' }
$locationSub = if ($SubscriptionId) { $SubscriptionId[0] }
               elseif ($UseContextTenant -and $AzContext.Subscription -and $AzContext.Subscription.Id) { [string]$AzContext.Subscription.Id }
               else { @($SubscriptionNames.Keys)[0] }
if ($locationSub) {
    $r = Invoke-Arm -Uri "/subscriptions/$locationSub/locations?api-version=2022-12-01"
    if ($r.Ok) { foreach ($l in @($r.Data.value)) { $RegionNames[[string]$l.name] = [string]$l.displayName } }
    else { Add-Note "Region display names unavailable: $($r.Error)" }
}
Write-Host "        $($SubscriptionNames.Count) subscription(s) visible in scope"

#endregion

#region 2. AI resources (Azure Resource Graph) ----------------------------------------

Write-Step 'Collecting AI resources (Azure Resource Graph)'

$kqlCognitive = @'
resources
| where type =~ 'microsoft.cognitiveservices/accounts'
| extend p = properties
| project id, name, type, kind, location, resourceGroup, subscriptionId, tags,
    skuName = tostring(sku.name),
    identityType = tostring(identity.type),
    provisioningState = tostring(p.provisioningState),
    endpoint = tostring(p.endpoint),
    customSubDomainName = tostring(p.customSubDomainName),
    publicNetworkAccess = tostring(p.publicNetworkAccess),
    networkDefaultAction = tostring(p.networkAcls.defaultAction),
    ipRules = coalesce(array_length(p.networkAcls.ipRules), 0),
    vnetRules = coalesce(array_length(p.networkAcls.virtualNetworkRules), 0),
    privateEndpoints = coalesce(array_length(p.privateEndpointConnections), 0),
    disableLocalAuth = tobool(p.disableLocalAuth),
    restrictOutbound = tobool(p.restrictOutboundNetworkAccess),
    encryptionKeySource = tostring(p.encryption.keySource),
    allowProjectManagement = tobool(p.allowProjectManagement),
    defaultProject = tostring(p.defaultProject),
    networkInjections = p.networkInjections,
    internalId = tostring(p.internalId),
    dateCreated = tostring(p.dateCreated)
'@

$kqlWorkspaces = @'
resources
| where type =~ 'microsoft.machinelearningservices/workspaces'
| extend p = properties
| project id, name, type, kind, location, resourceGroup, subscriptionId, tags,
    skuName = tostring(sku.name),
    identityType = tostring(identity.type),
    provisioningState = tostring(p.provisioningState),
    friendlyName = tostring(p.friendlyName),
    hubResourceId = tolower(tostring(p.hubResourceId)),
    storageAccount = tostring(p.storageAccount),
    keyVault = tostring(p.keyVault),
    applicationInsights = tostring(p.applicationInsights),
    containerRegistry = tostring(p.containerRegistry),
    publicNetworkAccess = tostring(p.publicNetworkAccess),
    isolationMode = tostring(p.managedNetwork.isolationMode),
    privateEndpoints = coalesce(array_length(p.privateEndpointConnections), 0),
    hbiWorkspace = tobool(p.hbiWorkspace),
    v1LegacyMode = tobool(p.v1LegacyMode),
    encryptionStatus = tostring(p.encryption.status),
    systemDatastoresAuthMode = tostring(p.systemDatastoresAuthMode),
    creationTime = tostring(p.creationTime)
'@

$kqlMlEndpoints = @'
resources
| where type in~ ('microsoft.machinelearningservices/workspaces/onlineendpoints',
                  'microsoft.machinelearningservices/workspaces/onlineendpoints/deployments',
                  'microsoft.machinelearningservices/workspaces/serverlessendpoints',
                  'microsoft.machinelearningservices/workspaces/batchendpoints')
| extend p = properties
| project id, name, type, location, resourceGroup, subscriptionId,
    skuName = tostring(sku.name),
    skuCapacity = coalesce(toint(sku.capacity), toint(p.scaleSettings.instanceCount)),
    provisioningState = tostring(p.provisioningState),
    modelId = coalesce(tostring(p.modelSettings.modelId), tostring(p.model.assetId), iff(gettype(p.model) == 'string', tostring(p.model), '')),
    authMode = tostring(p.authMode),
    endpointUri = coalesce(tostring(p.inferenceEndpoint.uri), tostring(p.scoringUri)),
    instanceType = tostring(p.instanceType),
    publicNetworkAccess = tostring(p.publicNetworkAccess)
'@

$kqlSearch = @'
resources
| where type =~ 'microsoft.search/searchservices'
| extend p = properties
| project id, name, type, kind, location, resourceGroup, subscriptionId, tags,
    skuName = tostring(sku.name),
    identityType = tostring(identity.type),
    status = tostring(p.status),
    provisioningState = tostring(p.provisioningState),
    replicaCount = toint(p.replicaCount),
    partitionCount = toint(p.partitionCount),
    hostingMode = tostring(p.hostingMode),
    publicNetworkAccess = tostring(p.publicNetworkAccess),
    ipRules = coalesce(array_length(p.networkRuleSet.ipRules), 0),
    networkBypass = tostring(p.networkRuleSet.bypass),
    privateEndpoints = coalesce(array_length(p.privateEndpointConnections), 0),
    sharedPrivateLinks = coalesce(array_length(p.sharedPrivateLinkResources), 0),
    disableLocalAuth = tobool(p.disableLocalAuth),
    authOptions = p.authOptions,
    semanticSearch = tostring(p.semanticSearch),
    cmkEnforcement = tostring(p.encryptionWithCmk.enforcement)
'@

$kqlBots = @'
resources
| where type =~ 'microsoft.botservice/botservices'
| extend p = properties
| project id, name, type, kind, location, resourceGroup, subscriptionId, tags,
    skuName = tostring(sku.name),
    displayName = tostring(p.displayName),
    endpoint = tostring(p.endpoint),
    msaAppType = tostring(p.msaAppType),
    msaAppId = tostring(p.msaAppId),
    msaAppTenantId = tostring(p.msaAppTenantId),
    publicNetworkAccess = tostring(p.publicNetworkAccess),
    disableLocalAuth = tobool(p.disableLocalAuth),
    isCmekEnabled = tobool(p.isCmekEnabled),
    configuredChannels = p.configuredChannels,
    appInsightsConfigured = isnotempty(tostring(p.developerAppInsightKey)),
    isStreamingSupported = tobool(p.isStreamingSupported),
    privateEndpoints = coalesce(array_length(p.privateEndpointConnections), 0),
    provisioningState = tostring(p.provisioningState)
'@

function New-InventoryItem {
    param($Raw, [string]$ServiceKey, [bool]$IsPrimary = $true)
    $id = [string]$Raw.id
    [pscustomobject]@{
        Id                = $id
        IdLower           = $id.ToLowerInvariant()
        Name              = [string]$Raw.name
        Type              = ([string]$Raw.type).ToLowerInvariant()
        Kind              = [string]$Raw.kind
        Location          = ([string]$Raw.location).ToLowerInvariant()
        Region            = (Get-RegionName ([string]$Raw.location))
        ResourceGroup     = [string]$Raw.resourceGroup
        SubscriptionId    = [string]$Raw.subscriptionId
        Subscription      = (Get-SubscriptionName ([string]$Raw.subscriptionId))
        ServiceKey        = $ServiceKey
        Service           = $ServiceByKey[$ServiceKey]
        IsPrimary         = $IsPrimary
        Raw               = $Raw
        ActualCost        = $null
        AmortizedCost     = $null
        Reservation       = ''
        Currency          = ''
        ProjectsActualCost    = $null
        ProjectsAmortizedCost = $null
        AdvisorCount      = 0
        DefenderUnhealthy = 0
        Calls             = $null
        InputTokens       = $null
        OutputTokens      = $null
        TotalTokens       = $null
        Requests          = $null
        Deployments       = @()
        DeploymentsError  = $null
        Projects          = @()
        ProjectsError     = $null
        Endpoints         = @()
        Hub               = $null
    }
}

$Resources   = [System.Collections.Generic.List[object]]::new()   # primary resources = rows of the service sheets
$HubProjects = [System.Collections.Generic.List[object]]::new()   # hub-based projects (ML workspaces of kind Project)
$ResIndex    = @{}                                                # lower-case resource id -> inventory item

$unmappedKinds = @{}
foreach ($r in @(Invoke-Arg -Label 'Cognitive Services accounts' -Query $kqlCognitive)) {
    $key = $KindToServiceKey[[string]$r.kind]
    if (-not $key) { $unmappedKinds[[string]$r.kind] = 1 + [int]$unmappedKinds[[string]$r.kind]; continue }
    $item = New-InventoryItem -Raw $r -ServiceKey $key
    $Resources.Add($item)
    $ResIndex[$item.IdLower] = $item
}
if ($unmappedKinds.Count) {
    Add-Note ('{0} Cognitive Services account(s) of kind {1} are not one of the 23 portal AI services and were not inventoried.' -f `
        ($unmappedKinds.Values | Measure-Object -Sum).Sum, (($unmappedKinds.Keys | Sort-Object) -join ', '))
}

foreach ($r in @(Invoke-Arg -Label 'Machine Learning workspaces' -Query $kqlWorkspaces)) {
    switch ([string]$r.kind) {
        'Hub'     { $item = New-InventoryItem -Raw $r -ServiceKey 'AIHubs'; $Resources.Add($item) }
        'Project' { $item = New-InventoryItem -Raw $r -ServiceKey 'AIHubs' -IsPrimary $false; $HubProjects.Add($item) }
        default   { $item = New-InventoryItem -Raw $r -ServiceKey 'MachineLearning'; $Resources.Add($item) }
    }
    $ResIndex[$item.IdLower] = $item
}
foreach ($r in @(Invoke-Arg -Label 'AI Search services' -Query $kqlSearch)) {
    $item = New-InventoryItem -Raw $r -ServiceKey 'AISearch'
    $Resources.Add($item)
    $ResIndex[$item.IdLower] = $item
}
foreach ($r in @(Invoke-Arg -Label 'Bot services' -Query $kqlBots)) {
    $item = New-InventoryItem -Raw $r -ServiceKey 'BotServices'
    $Resources.Add($item)
    $ResIndex[$item.IdLower] = $item
}

foreach ($p in $HubProjects) {
    $hub = $ResIndex[[string]$p.Raw.hubResourceId]
    if ($hub -and $hub.IsPrimary) {
        $p.Hub = $hub
        $hub.Projects = @($hub.Projects) + $p
    }
}

# An incomplete core inventory would make every count in the workbook wrong: stop instead of under-reporting.
$coreQueries = 'Cognitive Services accounts', 'Machine Learning workspaces', 'AI Search services', 'Bot services'
if (-not (Test-ArgComplete $coreQueries)) {
    $failed = @($coreQueries | Where-Object { $script:ArgFailures.ContainsKey($_) })
    throw ("Core inventory query failed ({0}): {1}. Re-run when Azure Resource Graph is reachable." -f ($failed -join ', '), $script:ArgFailures[$failed[0]])
}

$MlEndpoints = [System.Collections.Generic.List[object]]::new()
$mlKindLabels = @{ serverless = 'Serverless API endpoint'; onlinedeployment = 'Managed online deployment'; onlineendpoint = 'Managed online endpoint'; batchendpoint = 'Batch endpoint' }
foreach ($e in @(Invoke-Arg -Label 'Machine Learning endpoints' -Query $kqlMlEndpoints)) {
    $id    = [string]$e.id
    $parts = $id.Trim('/').Split('/')
    $type  = ([string]$e.type).ToLowerInvariant()
    $kind  = if ($type -like '*/serverlessendpoints') { 'serverless' }
             elseif ($type -like '*/onlineendpoints/deployments') { 'onlinedeployment' }
             elseif ($type -like '*/onlineendpoints') { 'onlineendpoint' }
             elseif ($type -like '*/batchendpoints') { 'batchendpoint' }
             else { 'other' }
    $wsId  = Get-TopLevelId $id
    $ws    = $ResIndex[$wsId]
    $mi    = Get-MlModelInfo ([string]$e.modelId)
    $ep = [pscustomobject]@{
        Id                  = $id
        IdLower             = $id.ToLowerInvariant()
        Kind                = $kind
        TypeLabel           = $(if ($mlKindLabels.ContainsKey($kind)) { $mlKindLabels[$kind] } else { $type })
        WorkspaceId         = $wsId
        WorkspaceItem       = $ws
        WorkspaceName       = $(if ($ws) { $ws.Name } elseif ($parts.Count -ge 8) { $parts[7] } else { '' })
        EndpointName        = $(if ($parts.Count -ge 10) { $parts[9] } else { [string]$e.name })
        DeploymentName      = $(if ($kind -eq 'onlinedeployment' -and $parts.Count -ge 12) { $parts[11] } else { '' })
        Model               = $mi.Name
        ModelVersion        = $mi.Version
        ModelSource         = $mi.Source
        Sku                 = $(if ($e.instanceType) { [string]$e.instanceType } else { [string]$e.skuName })
        Capacity            = $e.skuCapacity
        AuthMode            = [string]$e.authMode
        ProvisioningState   = [string]$e.provisioningState
        PublicNetworkAccess = [string]$e.publicNetworkAccess
        EndpointUri         = [string]$e.endpointUri
        Region              = (Get-RegionName ([string]$e.location))
        SubscriptionId      = [string]$e.subscriptionId
        Subscription        = (Get-SubscriptionName ([string]$e.subscriptionId))
        ResourceGroup       = [string]$e.resourceGroup
        ActualCost          = $null
        AmortizedCost       = $null
        Reservation         = ''
    }
    $MlEndpoints.Add($ep)
    if ($ws) { $ws.Endpoints = @($ws.Endpoints) + $ep }
}

$AiSubscriptions = @(@($Resources) + @($HubProjects) | ForEach-Object { $_.SubscriptionId } | Where-Object { $_ } | Sort-Object -Unique)
Write-Host ("        {0} AI resource(s), {1} hub-based project(s), {2} ML endpoint(s) in {3} subscription(s)" -f $Resources.Count, $HubProjects.Count, $MlEndpoints.Count, $AiSubscriptions.Count)

# Copilot Studio pay-as-you-go is billed on Power Platform accounts: their subscriptions are included in the
# AI cost reconciliation even when they host no AI resource.
$PowerPlatformSubs = @()
if ($DoCost) {
    $kqlPowerPlatform = @'
resources
| where type =~ 'microsoft.powerplatform/accounts'
| project id, subscriptionId
'@
    $PowerPlatformSubs = @(Invoke-Arg -Label 'Power Platform accounts' -Query $kqlPowerPlatform | ForEach-Object { [string]$_.subscriptionId } | Where-Object { $_ } | Sort-Object -Unique)
}

#endregion

#region 3. Model deployments, Foundry projects and usage metrics (ARM, parallel) -------

Write-Step 'Collecting model deployments, Foundry projects and usage metrics'

$cogItems    = @($Resources | Where-Object { $_.Type -eq 'microsoft.cognitiveservices/accounts' })
$modelHosts  = @($cogItems | Where-Object { $_.Kind -in 'OpenAI', 'AIServices' })
$AcctResults = @{}
$BatchSize   = 100   # a fresh ARM token per batch keeps long parallel phases inside the token lifetime
if ($cogItems.Count -gt 0) {
    $work = @($cogItems | ForEach-Object { [pscustomobject]@{ Id = $_.Id; IdLower = $_.IdLower; Kind = $_.Kind } })
    for ($b = 0; $b -lt $work.Count; $b += $BatchSize) {
        $batch = @($work[$b..([Math]::Min($b + $BatchSize, $work.Count) - 1)])
        $tok   = Get-ArmToken
        $results = $batch | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
            $rest      = [scriptblock]::Create($using:RestCoreText)
            $arm       = $using:ArmUrl
            $token     = $using:tok
            $ts        = $using:MetricsTimespan
            $idleTs    = $using:IdleTimespan
            $usageFrom = $using:UsageFromUtc
            $doMetrics = $using:DoMetrics
            $a         = $_
            $o = [ordered]@{
                IdLower = $a.IdLower; Deployments = @(); DeploymentsError = $null; Projects = @(); ProjectsError = $null
                Usage = @{}; UsageSlots = @(); UsageError = $null; Calls = $null; CallsError = $null
                RaiPolicies = @(); RaiError = $null
                Peak = @{}; PeakError = $null; Daily = @{}; DailyError = $null; Ptu = @{}; PtuError = $null
                Rai = @{}; RaiSlots = @(); RaiMetricsError = $null
            }
            # Parses a metrics timestamp (DateTime from ConvertFrom-Json or ISO text) as UTC.
            $toUtc = {
                param($v)
                if ($v -is [datetime]) { if ($v.Kind -eq [DateTimeKind]::Local) { return $v.ToUniversalTime() } return [datetime]::SpecifyKind($v, 'Utc') }
                return ([datetimeoffset]::Parse([string]$v, [cultureinfo]::InvariantCulture)).UtcDateTime
            }
            $deploymentOf = { param($t) [string](@($t.metadatavalues) | Where-Object { $_.name.value -eq 'modeldeploymentname' } | Select-Object -First 1).value }
            if ($a.Kind -in 'OpenAI', 'AIServices') {
                # 2025-06-01 adds spilloverDeploymentName; older API versions as fallback.
                $r = & $rest -Uri "$arm$($a.Id)/deployments?api-version=2025-06-01" -Token $token -AllPages
                if (-not $r.Ok -and $r.Status -in 400, 404) { $r = & $rest -Uri "$arm$($a.Id)/deployments?api-version=2024-10-01" -Token $token -AllPages }
                if ($r.Ok) { $o.Deployments = @($r.Data) } else { $o.DeploymentsError = $r.Error }
                if ($a.Kind -eq 'AIServices') {
                    $r = & $rest -Uri "$arm$($a.Id)/projects?api-version=2025-06-01" -Token $token -AllPages
                    if ($r.Ok) { $o.Projects = @($r.Data) } else { $o.ProjectsError = $r.Error }
                }
                $r = & $rest -Uri "$arm$($a.Id)/raiPolicies?api-version=2024-10-01" -Token $token -AllPages
                if ($r.Ok) { $o.RaiPolicies = @($r.Data) } else { $o.RaiError = $r.Error }
                if ($doMetrics) {
                    # Foundry "Models - Usage" metrics first (split by model name too, so usage of deleted
                    # deployments can still be attributed), classic Azure OpenAI metric names as fallback.
                    # HTTP 200 responses may carry per-metric errors, so each metric's errorCode is checked.
                    $sets = @(
                        @{ Map = [ordered]@{ InputTokens = 'In'; OutputTokens = 'Out'; TotalTokens = 'Total'; ModelRequests = 'Req' }; Filter = "ModelDeploymentName eq '*' and ModelName eq '*'" },
                        @{ Map = [ordered]@{ ProcessedPromptTokens = 'In'; GeneratedTokens = 'Out'; TokenTransaction = 'Total'; AzureOpenAIRequests = 'Req' }; Filter = "ModelDeploymentName eq '*'" }
                    )
                    $best   = $null
                    $errors = [System.Collections.Generic.List[string]]::new()
                    for ($si = 0; $si -lt $sets.Count; $si++) {
                        $set   = $sets[$si]
                        $names = @($set.Map.Keys) -join ','
                        $u = "$arm$($a.Id)/providers/Microsoft.Insights/metrics?api-version=2023-10-01&metricnames=$names&timespan=$ts&interval=FULL&aggregation=Total&top=1000&`$filter=$([uri]::EscapeDataString($set.Filter))"
                        $r = & $rest -Uri $u -Token $token
                        if (-not $r.Ok) { $errors.Add($r.Error); continue }
                        $usage = @{}
                        $slots = @{}
                        foreach ($m in @($r.Data.value)) {
                            $slot = $set.Map[[string]$m.name.value]
                            if (-not $slot) { continue }
                            if ($m.errorCode -and $m.errorCode -ne 'Success') { $errors.Add("$($m.name.value): $($m.errorCode) $($m.errorMessage)"); continue }
                            $slots[$slot] = $true
                            foreach ($t in @($m.timeseries)) {
                                $meta = @($t.metadatavalues)
                                $dn = [string]($meta | Where-Object { $_.name.value -eq 'modeldeploymentname' } | Select-Object -First 1).value
                                if (-not $dn) { continue }
                                $mn  = [string]($meta | Where-Object { $_.name.value -eq 'modelname' } | Select-Object -First 1).value
                                $sum = 0.0
                                foreach ($pt in @($t.data)) { if ($null -ne $pt.total) { $sum += [double]$pt.total } }
                                $k = $dn.ToLowerInvariant()
                                if (-not $usage.ContainsKey($k)) { $usage[$k] = @{ Name = $dn; Model = $mn; In = 0.0; Out = 0.0; Total = 0.0; Req = 0.0 } }
                                if ($mn -and -not $usage[$k].Model) { $usage[$k].Model = $mn }
                                $usage[$k][$slot] += $sum
                            }
                        }
                        if (-not $best -or $slots.Count -gt $best.Slots.Count) { $best = @{ Usage = $usage; Slots = $slots; Index = $si } }
                        if ($slots.ContainsKey('In') -and $slots.ContainsKey('Out')) { break }
                    }
                    if ($best -and $best.Slots.Count) { $o.Usage = $best.Usage; $o.UsageSlots = @($best.Slots.Keys) }
                    else { $o.UsageError = if ($errors.Count) { $errors[0] } else { 'no token usage metrics returned' } }

                    if (@($o.Deployments).Count -gt 0) {
                        $classic   = $best -and $best.Index -eq 1
                        $depFilter = [uri]::EscapeDataString("ModelDeploymentName eq '*'")

                        # Busiest hour per deployment (Azure Monitor has no per-minute totals over 30 days):
                        # peak tokens per minute = tokens of the busiest hour / 60.
                        $tn = if ($classic) { 'TokenTransaction' } else { 'TotalTokens' }
                        $u = "$arm$($a.Id)/providers/Microsoft.Insights/metrics?api-version=2023-10-01&metricnames=$tn&timespan=$ts&interval=PT1H&aggregation=Total&top=1000&`$filter=$depFilter"
                        $r = & $rest -Uri $u -Token $token
                        if ($r.Ok) {
                            foreach ($m in @($r.Data.value)) {
                                if ($m.errorCode -and $m.errorCode -ne 'Success') { $o.PeakError = "$($m.name.value): $($m.errorCode) $($m.errorMessage)"; continue }
                                foreach ($t in @($m.timeseries)) {
                                    $dn = & $deploymentOf $t
                                    if (-not $dn) { continue }
                                    $k   = $dn.ToLowerInvariant()
                                    $max = 0.0
                                    foreach ($pt in @($t.data)) { if ($null -ne $pt.total -and [double]$pt.total -gt $max) { $max = [double]$pt.total } }
                                    if (-not $o.Peak.ContainsKey($k) -or $max -gt $o.Peak[$k]) { $o.Peak[$k] = $max }
                                }
                            }
                        }
                        else { $o.PeakError = $r.Error }

                        # Requests per day and HTTP status code over 90 days: last request and throttling (429).
                        $rn = if ($classic) { 'AzureOpenAIRequests' } else { 'ModelRequests' }
                        $u = "$arm$($a.Id)/providers/Microsoft.Insights/metrics?api-version=2023-10-01&metricnames=$rn&timespan=$idleTs&interval=P1D&aggregation=Total&top=1000&`$filter=$([uri]::EscapeDataString("ModelDeploymentName eq '*' and StatusCode eq '*'"))"
                        $r = & $rest -Uri $u -Token $token
                        if ($r.Ok) {
                            foreach ($m in @($r.Data.value)) {
                                if ($m.errorCode -and $m.errorCode -ne 'Success') { $o.DailyError = "$($m.name.value): $($m.errorCode) $($m.errorMessage)"; continue }
                                foreach ($t in @($m.timeseries)) {
                                    $dn = & $deploymentOf $t
                                    if (-not $dn) { continue }
                                    $sc = [string](@($t.metadatavalues) | Where-Object { $_.name.value -eq 'statuscode' } | Select-Object -First 1).value
                                    $k  = $dn.ToLowerInvariant()
                                    if (-not $o.Daily.ContainsKey($k)) { $o.Daily[$k] = @{ Last = $null; Throttled = 0.0 } }
                                    $d = $o.Daily[$k]
                                    foreach ($pt in @($t.data)) {
                                        if ($null -eq $pt.total -or [double]$pt.total -le 0) { continue }
                                        $day = & $toUtc $pt.timeStamp
                                        if ($null -eq $d.Last -or $day -gt $d.Last) { $d.Last = $day }
                                        if ($sc -eq '429' -and $day -ge $usageFrom.Date) { $d.Throttled += [double]$pt.total }
                                    }
                                }
                            }
                        }
                        else { $o.DailyError = $r.Error }

                        # Provisioned throughput (PTU) utilization, hourly average per deployment.
                        if (@($o.Deployments | Where-Object { [string]$_.sku.name -match '(?i)provisioned' }).Count) {
                            foreach ($pn in 'AzureOpenAIProvisionedManagedUtilizationV2', 'ProvisionedUtilization') {
                                $u = "$arm$($a.Id)/providers/Microsoft.Insights/metrics?api-version=2023-10-01&metricnames=$pn&timespan=$ts&interval=PT1H&aggregation=Average&top=1000&`$filter=$depFilter"
                                $r = & $rest -Uri $u -Token $token
                                if (-not $r.Ok) { $o.PtuError = $r.Error; continue }
                                $got = $false
                                foreach ($m in @($r.Data.value)) {
                                    if ($m.errorCode -and $m.errorCode -ne 'Success') { $o.PtuError = "$($m.name.value): $($m.errorCode) $($m.errorMessage)"; continue }
                                    $got = $true
                                    foreach ($t in @($m.timeseries)) {
                                        $dn = & $deploymentOf $t
                                        if (-not $dn) { continue }
                                        $sum = 0.0; $peak = 0.0
                                        foreach ($pt in @($t.data)) { if ($null -ne $pt.average) { $v = [double]$pt.average; $sum += $v; if ($v -gt $peak) { $peak = $v } } }
                                        $o.Ptu[$dn.ToLowerInvariant()] = @{ Sum = $sum; Peak = $peak }
                                    }
                                }
                                if ($got) { $o.PtuError = $null; break }
                            }
                        }

                        # Content filter (RAI) request counts per deployment; one metric at a time if the
                        # combined request is rejected (a metric missing on the account fails the request).
                        $raiMap   = [ordered]@{ RAITotalRequests = 'Total'; RAIHarmfulRequests = 'Harmful'; RAIRejectedRequests = 'Rejected' }
                        $raiSlots = @{}
                        $batches  = @(, @($raiMap.Keys))
                        for ($bi = 0; $bi -lt $batches.Count; $bi++) {
                            $u = "$arm$($a.Id)/providers/Microsoft.Insights/metrics?api-version=2023-10-01&metricnames=$(@($batches[$bi]) -join ',')&timespan=$ts&interval=FULL&aggregation=Total&top=1000&`$filter=$depFilter"
                            $r = & $rest -Uri $u -Token $token
                            if (-not $r.Ok) {
                                if ($bi -eq 0 -and $r.Status -eq 400) { foreach ($mn in $raiMap.Keys) { $batches += , @($mn) } }
                                $o.RaiMetricsError = $r.Error
                                continue
                            }
                            foreach ($m in @($r.Data.value)) {
                                $slot = $raiMap[[string]$m.name.value]
                                if (-not $slot) { continue }
                                if ($m.errorCode -and $m.errorCode -ne 'Success') { $o.RaiMetricsError = "$($m.name.value): $($m.errorCode) $($m.errorMessage)"; continue }
                                $raiSlots[$slot] = $true
                                foreach ($t in @($m.timeseries)) {
                                    $dn = & $deploymentOf $t
                                    if (-not $dn) { continue }
                                    $sum = 0.0
                                    foreach ($pt in @($t.data)) { if ($null -ne $pt.total) { $sum += [double]$pt.total } }
                                    $k = $dn.ToLowerInvariant()
                                    if (-not $o.Rai.ContainsKey($k)) { $o.Rai[$k] = @{ Total = 0.0; Harmful = 0.0; Rejected = 0.0 } }
                                    $o.Rai[$k][$slot] += $sum
                                }
                            }
                        }
                        $o.RaiSlots = @($raiSlots.Keys)
                        if ($raiSlots.Count) { $o.RaiMetricsError = $null }
                    }
                }
            }
            if ($doMetrics) {
                $u = "$arm$($a.Id)/providers/Microsoft.Insights/metrics?api-version=2023-10-01&metricnames=TotalCalls&timespan=$ts&interval=FULL&aggregation=Total"
                $r = & $rest -Uri $u -Token $token
                if ($r.Ok) {
                    $sum = 0.0
                    $metricOk = $false
                    foreach ($m in @($r.Data.value)) {
                        if ($m.errorCode -and $m.errorCode -ne 'Success') { $o.CallsError = "$($m.errorCode) $($m.errorMessage)"; continue }
                        $metricOk = $true
                        foreach ($t in @($m.timeseries)) { foreach ($pt in @($t.data)) { if ($null -ne $pt.total) { $sum += [double]$pt.total } } }
                    }
                    if ($metricOk) { $o.Calls = $sum } elseif (-not $o.CallsError) { $o.CallsError = 'TotalCalls metric not returned' }
                }
                else { $o.CallsError = $r.Error }
            }
            [pscustomobject]$o
        }
        foreach ($x in @($results)) { if ($x) { $AcctResults[$x.IdLower] = $x } }
    }

    $errorLabels = [ordered]@{
        DeploymentsError = 'Model deployments'; ProjectsError = 'Foundry projects'; UsageError = 'Token usage metrics'; CallsError = 'API call metrics'
        RaiError = 'Content filter (RAI) policies'; PeakError = 'Busiest-hour token metrics (peak TPM)'; DailyError = 'Daily request metrics (last request / HTTP 429)'
        PtuError = 'PTU utilization metrics'; RaiMetricsError = 'Content filter request metrics'
    }
    foreach ($prop in $errorLabels.Keys) {
        $failed = @($AcctResults.Values | Where-Object { $_.$prop })
        if ($failed.Count) {
            Add-Note ('{0} unavailable for {1} account(s), e.g. {2}: {3}' -f $errorLabels[$prop], $failed.Count, (Get-LastSegment $failed[0].IdLower), $failed[0].$prop)
        }
    }
}

foreach ($c in $cogItems) {
    $res = $AcctResults[$c.IdLower]
    if (-not $res) { continue }
    $c.Calls            = $res.Calls
    $c.DeploymentsError = $res.DeploymentsError
    $c.ProjectsError    = $res.ProjectsError
    if ($c.Kind -in 'OpenAI', 'AIServices' -and $DoMetrics -and -not $res.UsageError) {
        $slots = @($res.UsageSlots)
        $in = 0.0; $out = 0.0; $tot = 0.0; $req = 0.0
        foreach ($u in $res.Usage.Values) {
            $in += $u.In; $out += $u.Out; $req += $u.Req
            $tot += $(if ($slots -contains 'Total' -and $u.Total) { $u.Total } else { $u.In + $u.Out })
        }
        # Only metrics that were actually returned become numbers; the others stay unknown (blank).
        $c.InputTokens  = if ($slots -contains 'In') { $in } else { $null }
        $c.OutputTokens = if ($slots -contains 'Out') { $out } else { $null }
        $c.TotalTokens  = if ($slots -contains 'Total' -or ($slots -contains 'In' -and $slots -contains 'Out')) { $tot } else { $null }
        $c.Requests     = if ($slots -contains 'Req') { $req } else { $null }
    }
}

#endregion

#region 3b. Security hygiene and ML compute data (ARM + Resource Graph, parallel) -------------

Write-Step 'Collecting diagnostic settings, resource locks, key activity (activity log), ML computes and dependencies'

$ProviderNames = @{
    'microsoft.cognitiveservices'       = 'Microsoft.CognitiveServices'
    'microsoft.machinelearningservices' = 'Microsoft.MachineLearningServices'
    'microsoft.search'                  = 'Microsoft.Search'
    'microsoft.botservice'              = 'Microsoft.BotService'
}
$MlWorkspaces = @(@($Resources) + @($HubProjects) | Where-Object { $_.Type -eq 'microsoft.machinelearningservices/workspaces' })

$hygieneWork = [System.Collections.Generic.List[object]]::new()
foreach ($i in $Resources) {
    $hygieneWork.Add([pscustomobject]@{ Kind = 'diag'; Key = $i.IdLower; Uri = "$ArmUrl$($i.Id)/providers/Microsoft.Insights/diagnosticSettings?api-version=2021-05-01-preview" })
}
foreach ($w in $MlWorkspaces) {
    $hygieneWork.Add([pscustomobject]@{ Kind = 'computes'; Key = $w.IdLower; Uri = "$ArmUrl$($w.Id)/computes?api-version=2024-10-01" })
}
foreach ($s in $AiSubscriptions) {
    $hygieneWork.Add([pscustomobject]@{ Kind = 'locks'; Key = $s; Uri = "$ArmUrl/subscriptions/$s/providers/Microsoft.Authorization/locks?api-version=2020-05-01" })
    if ($DoActivityLog) {
        $providers = @(@($Resources) + @($HubProjects) | Where-Object { $_.SubscriptionId -eq $s } | ForEach-Object { ($_.Type -split '/')[0] } | Sort-Object -Unique)
        foreach ($pv in $providers) {
            $pvName = if ($ProviderNames.ContainsKey($pv)) { $ProviderNames[$pv] } else { $pv }
            $filter = "eventTimestamp ge '{0}' and eventTimestamp le '{1}' and resourceProvider eq '{2}'" -f `
                $ActivityFromUtc.ToString('yyyy-MM-ddTHH:mm:ssZ'), $RunStartedUtc.ToString('yyyy-MM-ddTHH:mm:ssZ'), $pvName
            $select = 'operationName,caller,resourceId,status,eventTimestamp'
            $hygieneWork.Add([pscustomobject]@{ Kind = 'activity'; Key = "$s|$pv"; Uri = "$ArmUrl/subscriptions/$s/providers/Microsoft.Insights/eventtypes/management/values?api-version=2015-04-01&`$filter=$([uri]::EscapeDataString($filter))&`$select=$([uri]::EscapeDataString($select))" })
        }
    }
}

$DiagByRes     = @{}   # lower-case resource id -> diagnostic settings
$ComputesByWs  = @{}   # lower-case workspace id -> computes
$LocksBySub    = @{}   # subscription id -> management locks (all scopes)
$KeyActivity   = @{}   # lower-case top-level resource id -> key retrieval / regeneration statistics
$ActivityOk    = @{}   # "subscription|provider" -> activity log read
$hygieneErrors = @{}
if ($hygieneWork.Count) {
    $retrievalRx = $KeyRetrievalRegex
    $regenRx     = $KeyRegenerationRegex
    for ($b = 0; $b -lt $hygieneWork.Count; $b += $BatchSize) {
        $batch = @($hygieneWork[$b..([Math]::Min($b + $BatchSize, $hygieneWork.Count) - 1)])
        $tok   = Get-ArmToken
        $results = $batch | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
            $rest  = [scriptblock]::Create($using:RestCoreText)
            $w     = $_
            $r     = & $rest -Uri $w.Uri -Token $using:tok -AllPages
            $out   = [ordered]@{ Kind = $w.Kind; Key = $w.Key; Ok = $r.Ok; Error = $r.Error; Data = $null }
            if ($r.Ok -and $w.Kind -eq 'activity') {
                # Aggregated here, the raw events (with caller claims) are not kept.
                $retrievalRx = $using:retrievalRx
                $regenRx     = $using:regenRx
                $agg = @{}
                foreach ($e in @($r.Data)) {
                    if ([string]$e.status.value -ne 'Succeeded') { continue }
                    $op    = [string]$e.operationName.value
                    $isGet = $op -match $retrievalRx
                    $isNew = -not $isGet -and $op -match $regenRx
                    if (-not $isGet -and -not $isNew) { continue }
                    $parts = ([string]$e.resourceId).Trim('/').Split('/')
                    if ($parts.Count -lt 8) { continue }
                    $top = ('/' + ($parts[0..7] -join '/')).ToLowerInvariant()
                    if (-not $agg.ContainsKey($top)) { $agg[$top] = @{ Retrievals = 0; Callers = @{}; LastRetrieval = $null; Regenerations = 0; LastRegeneration = $null } }
                    $st   = $agg[$top]
                    $when = $e.eventTimestamp
                    $when = if ($when -is [datetime]) { if ($when.Kind -eq [DateTimeKind]::Local) { $when.ToUniversalTime() } else { [datetime]::SpecifyKind($when, 'Utc') } }
                            else { ([datetimeoffset]::Parse([string]$when, [cultureinfo]::InvariantCulture)).UtcDateTime }
                    if ($isGet) {
                        $st.Retrievals++
                        $st.Callers[[string]$e.caller] = $true
                        if ($null -eq $st.LastRetrieval -or $when -gt $st.LastRetrieval) { $st.LastRetrieval = $when }
                    }
                    else {
                        $st.Regenerations++
                        if ($null -eq $st.LastRegeneration -or $when -gt $st.LastRegeneration) { $st.LastRegeneration = $when }
                    }
                }
                $out.Data = $agg
            }
            elseif ($r.Ok) { $out.Data = @($r.Data) }
            [pscustomobject]$out
        }
        foreach ($x in @($results)) {
            if (-not $x) { continue }
            if (-not $x.Ok) {
                if (-not $hygieneErrors.ContainsKey($x.Kind)) { $hygieneErrors[$x.Kind] = [System.Collections.Generic.List[object]]::new() }
                $hygieneErrors[$x.Kind].Add($x)
                continue
            }
            switch ($x.Kind) {
                'diag'     { $DiagByRes[$x.Key] = @($x.Data) }
                'computes' { $ComputesByWs[$x.Key] = @($x.Data) }
                'locks'    { $LocksBySub[$x.Key] = @($x.Data) }
                'activity' {
                    $ActivityOk[$x.Key] = $true
                    foreach ($k in $x.Data.Keys) { $KeyActivity[$k] = $x.Data[$k] }
                }
            }
        }
    }
    $hygieneLabels = @{ diag = 'Diagnostic settings'; computes = 'Machine Learning computes'; locks = 'Resource locks'; activity = 'Activity log (key retrievals and regenerations)' }
    foreach ($k in $hygieneErrors.Keys) {
        $f = $hygieneErrors[$k]
        $example = if ($k -in 'diag', 'computes') { Get-LastSegment $f[0].Key } else { $f[0].Key }
        Add-Note ('{0} unavailable for {1} item(s), e.g. {2}: {3}' -f $hygieneLabels[$k], $f.Count, $example, $f[0].Error)
    }
}
if (-not $DoActivityLog) { Add-Note 'Activity log skipped (-SkipActivityLog): key retrieval and key rotation columns of the Security Hygiene sheet are blank.' -Quiet }

# Workspace dependencies (storage account, key vault, container registry, Application Insights).
$DependencyInfo = @{}   # lower-case dependency id -> Resource Graph row
$depIds = @($MlWorkspaces | ForEach-Object { $_.Raw.storageAccount, $_.Raw.keyVault, $_.Raw.applicationInsights, $_.Raw.containerRegistry } |
    Where-Object { $_ } | ForEach-Object { ([string]$_).ToLowerInvariant() } | Sort-Object -Unique)
for ($i = 0; $i -lt $depIds.Count; $i += 100) {
    $chunk = @($depIds[$i..([Math]::Min($i + 99, $depIds.Count - 1))])
    $list  = ($chunk | ForEach-Object { "'" + ($_ -replace "'", '') + "'" }) -join ', '
    $kqlDependencies = @"
resources
| where tolower(id) in ($list)
| extend p = properties
| project id = tolower(id), name, type = tolower(type), resourceGroup, subscriptionId, location,
    skuName = tostring(sku.name),
    publicNetworkAccess = tostring(p.publicNetworkAccess),
    networkDefaultAction = coalesce(tostring(p.networkAcls.defaultAction), tostring(p.networkRuleSet.defaultAction)),
    privateEndpoints = coalesce(array_length(p.privateEndpointConnections), 0),
    allowSharedKeyAccess = tostring(p.allowSharedKeyAccess),
    allowBlobPublicAccess = tostring(p.allowBlobPublicAccess),
    minimumTlsVersion = tostring(p.minimumTlsVersion),
    enablePurgeProtection = tostring(p.enablePurgeProtection),
    enableSoftDelete = tostring(p.enableSoftDelete),
    enableRbacAuthorization = tostring(p.enableRbacAuthorization),
    adminUserEnabled = tostring(p.adminUserEnabled),
    disableLocalAuth = coalesce(tostring(p.DisableLocalAuth), tostring(p.disableLocalAuth)),
    workspaceResourceId = coalesce(tostring(p.WorkspaceResourceId), tostring(p.workspaceResourceId)),
    ingestionAccess = tostring(p.publicNetworkAccessForIngestion),
    queryAccess = tostring(p.publicNetworkAccessForQuery)
"@
    foreach ($d in @(Invoke-Arg -Label 'ML workspace dependencies' -Query $kqlDependencies)) { $DependencyInfo[[string]$d.id] = $d }
}
$computeCount = @($ComputesByWs.Values | ForEach-Object { $_ } | ForEach-Object { ([string]$_.id).ToLowerInvariant() } | Sort-Object -Unique).Count
Write-Host ("        {0} diagnostic setting list(s), {1} lock list(s), {2}, {3} ML compute(s), {4} of {5} dependencies found" -f `
    $DiagByRes.Count, $LocksBySub.Count, $(if ($DoActivityLog) { "$($KeyActivity.Count) resource(s) with key activity" } else { 'activity log skipped' }), $computeCount, $DependencyInfo.Count, $depIds.Count)

#endregion

#region 4. Model lifecycle / retirement dates (model catalog, parallel) -----------------

Write-Step 'Checking model lifecycle, retirement dates (model catalog) and model quota'

$CatalogIndex   = @{}   # sub|region|model|version -> catalog entries (one per account kind)
$CatalogByModel = @{}   # sub|region|model         -> catalog entries (all versions)
$CatalogStatus  = @{}   # sub|region               -> $true (read) / $false (failed)
$QuotaByPair    = @{}   # sub|region               -> model quota usages (Cognitive Services usages API)
$QuotaIndex     = @{}   # sub|region|usage name    -> usage
$QuotaFailures  = 0     # sub|region pairs whose quota could not be read
if ($modelHosts.Count -gt 0) {
    $pairs = @($modelHosts | Group-Object -Property { '{0}|{1}' -f $_.SubscriptionId, $_.Location } | ForEach-Object {
            [pscustomobject]@{ Sub = $_.Group[0].SubscriptionId; Loc = $_.Group[0].Location } })
    $catalogResults = [System.Collections.Generic.List[object]]::new()
    for ($b = 0; $b -lt $pairs.Count; $b += $BatchSize) {
        $batch = @($pairs[$b..([Math]::Min($b + $BatchSize, $pairs.Count) - 1)])
        $tok = Get-ArmToken
        $batchResults = $batch | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
            $rest = [scriptblock]::Create($using:RestCoreText)
            $base = "$($using:ArmUrl)/subscriptions/$($_.Sub)/providers/Microsoft.CognitiveServices/locations/$($_.Loc)"
            $o = [ordered]@{ Sub = $_.Sub; Loc = $_.Loc; Ok = $false; Models = @(); Error = $null; QuotaOk = $false; Usages = @(); QuotaError = $null }
            if ($using:DoLifecycle) {
                $r = & $rest -Uri "$base/models?api-version=2024-10-01" -Token $using:tok -AllPages
                $o.Ok = $r.Ok; $o.Models = @($r.Data); $o.Error = $r.Error
            }
            $r = & $rest -Uri "$base/usages?api-version=2023-05-01" -Token $using:tok -AllPages
            $o.QuotaOk = $r.Ok; $o.Usages = @($r.Data); $o.QuotaError = $r.Error
            [pscustomobject]$o
        }
        foreach ($x in @($batchResults)) { if ($x) { $catalogResults.Add($x) } }
    }
    foreach ($c in $catalogResults) {
        $pairKey = '{0}|{1}' -f $c.Sub, $c.Loc
        if ($c.QuotaOk) {
            $QuotaByPair[$pairKey] = @($c.Usages | Where-Object { $_ -and $_.name.value })
            foreach ($u in $QuotaByPair[$pairKey]) { $QuotaIndex['{0}|{1}' -f $pairKey, ([string]$u.name.value).ToLowerInvariant()] = $u }
        }
        else { $QuotaFailures++; Add-Note "Model quota unavailable for $(Get-SubscriptionName $c.Sub) / $($c.Loc): $($c.QuotaError)" }
        if (-not $DoLifecycle) { continue }
        $CatalogStatus[$pairKey] = [bool]$c.Ok
        if (-not $c.Ok) { Add-Note "Model catalog unavailable for $(Get-SubscriptionName $c.Sub) / $($c.Loc): $($c.Error)"; continue }
        foreach ($e in $c.Models) {
            $m = $e.model
            if ($null -eq $m -or -not $m.name) { continue }
            $k1 = '{0}|{1}|{2}' -f $c.Sub, $c.Loc, ([string]$m.name).ToLowerInvariant()
            $k2 = '{0}|{1}' -f $k1, [string]$m.version
            if (-not $CatalogIndex.ContainsKey($k2)) { $CatalogIndex[$k2] = [System.Collections.Generic.List[object]]::new() }
            $CatalogIndex[$k2].Add($e)
            if (-not $CatalogByModel.ContainsKey($k1)) { $CatalogByModel[$k1] = [System.Collections.Generic.List[object]]::new() }
            $CatalogByModel[$k1].Add($e)
        }
    }
}

function Get-DeploymentQuota {
    # Quota (usages API entry) consumed by a deployment: the usage name published by the model catalog for
    # the deployment type, then the <format>.<type>.<model> convention, then a punctuation-insensitive match
    # (e.g. gpt-4.1 -> OpenAI.GlobalStandard.gpt4.1). Provisioned (PTU) quota is per deployment type.
    param($Account, [string]$ModelName, [string]$ModelVersion, [string]$ModelFormat, [string]$SkuName)
    $pair = '{0}|{1}' -f $Account.SubscriptionId, $Account.Location
    if (-not $script:QuotaByPair.ContainsKey($pair) -or -not $SkuName) { return $null }
    $names = [System.Collections.Generic.List[string]]::new()
    $catalog = if ($ModelName) { $script:CatalogIndex['{0}|{1}|{2}' -f $pair, $ModelName.ToLowerInvariant(), $ModelVersion] }
    foreach ($e in @($catalog)) {
        foreach ($s in @($e.model.skus)) {
            if ($s -and [string]$s.name -eq $SkuName -and $s.usageName -and [string]$s.usageName -notmatch '(?i)finetune') { $names.Add([string]$s.usageName) }
        }
    }
    foreach ($prefix in @($ModelFormat, 'OpenAI', 'AIServices') | Where-Object { $_ } | Select-Object -Unique) {
        if ($SkuName -match '(?i)provisioned') { $names.Add("$prefix.$SkuName") }
        if ($ModelName) { $names.Add("$prefix.$SkuName.$ModelName") }
    }
    foreach ($n in $names) {
        $u = $script:QuotaIndex['{0}|{1}' -f $pair, $n.ToLowerInvariant()]
        if ($u) { return $u }
    }
    if (-not $ModelName) { return $null }
    $want = Get-NormalizedName "$SkuName.$ModelName"
    foreach ($u in $script:QuotaByPair[$pair]) {
        $parts = ([string]$u.name.value).Split('.', 2)
        if ($parts.Count -eq 2 -and (Get-NormalizedName $parts[1]) -eq $want) { return $u }
    }
    return $null
}

function Get-RightSizing {
    # Right-sizing status and advice of one model deployment from its metrics, rate limit and quota.
    param($Rec, [bool]$IsPtu, [double]$PerUnit, $QuotaUsage)
    $r = [pscustomobject]@{ Status = ''; Advice = '' }
    if (-not $script:DoMetrics -or $null -eq $Rec.'Idle days') { return $r }
    $cap     = [double]$(if ($null -ne $Rec.Capacity) { $Rec.Capacity } else { 0 })
    $quotaFull = $QuotaUsage -and [double]$QuotaUsage.limit -gt 0 -and [double]$QuotaUsage.currentValue -ge 0.9 * [double]$QuotaUsage.limit
    $freed   = if ($quotaFull) { ' (the quota is {0:P0} used, so this frees quota for other deployments)' -f ([double]$QuotaUsage.currentValue / [double]$QuotaUsage.limit) } else { '' }
    $created = $Rec.'Created (UTC)'
    if ($created -and ($RunStartedUtc - $created).TotalDays -lt 7) {
        $r.Status = 'New'; $r.Advice = 'Created less than 7 days ago - too early to assess.'
        return $r
    }
    if ([int]$Rec.'Idle days' -ge 30) {
        $last = if ($Rec.'Last request date') { 'last request on {0:yyyy-MM-dd}' -f $Rec.'Last request date' } else { "no request in the last $($script:IdleLookbackDays) days" }
        $what = if ($IsPtu) { "stop paying for $cap provisioned throughput unit(s)" } else { "release $cap unit(s) of quota" }
        $r.Status = 'Idle'; $r.Advice = "Idle for $($Rec.'Idle days') days ($last). Delete the deployment to $what$freed."
        return $r
    }
    $throttled = [double]$(if ($null -ne $Rec.'Throttled requests (429)') { $Rec.'Throttled requests (429)' } else { 0 })
    $requests  = [double]$(if ($null -ne $Rec.Requests) { $Rec.Requests } else { 0 })
    if ($IsPtu) {
        $avg  = $Rec.'PTU utilization avg'
        $peak = $Rec.'PTU utilization peak'
        if ($null -eq $avg) { return $r }
        if ($null -ne $peak -and [double]$peak -ge 0.95 -and -not $Rec.'Spillover deployment') {
            $r.Status = 'PTU saturated'
            $r.Advice = 'The busiest hour averaged {0:P0} utilization and no spillover deployment is set. Add PTUs or configure spillover to a standard deployment to avoid HTTP 429.' -f [double]$peak
            return $r
        }
        if ([double]$avg -lt 0.3) {
            $r.Status = 'PTU under-used'
            $r.Advice = 'Average utilization {0:P0} (busiest hour {1:P0}) of {2} PTU. Reduce the PTUs (or the reservation at renewal) or move the traffic to a pay-as-you-go deployment.' -f [double]$avg, [double]$(if ($null -ne $peak) { $peak } else { 0 }), $cap
            return $r
        }
        $r.Status = 'OK'
        return $r
    }
    if ($throttled -ge 100 -or ($requests -gt 0 -and $throttled / $requests -ge 0.01)) {
        $share = if ($requests -gt 0) { ' ({0:P1} of the requests)' -f ($throttled / $requests) } else { '' }
        $room  = if ($QuotaUsage -and [double]$QuotaUsage.limit -gt 0) {
                     $free = [double]$QuotaUsage.limit - [double]$QuotaUsage.currentValue
                     if ($free -gt 0) { ' {0:N0} unit(s) of quota are still available.' -f $free } else { ' The quota is full: request a quota increase or use a Global / Data zone deployment type.' }
                 } else { '' }
        $r.Status = 'Throttled'
        $r.Advice = ('{0:N0} requests were throttled (HTTP 429){1}. Raise the tokens-per-minute limit, spread the load or add a spillover / fallback deployment.{2}' -f $throttled, $share, $room)
        return $r
    }
    $pct = $Rec.'Peak % of TPM limit'
    if ($null -ne $pct -and [double]$pct -lt 0.10 -and $Rec.'Tokens per minute' -ge 10000 -and $PerUnit -gt 0) {
        $suggest = [Math]::Max(1, [Math]::Ceiling(3 * [double]$Rec.'Peak TPM (busiest hour)' / $PerUnit))
        if ($suggest -lt $cap) {
            $r.Status = 'Over-allocated'
            $r.Advice = ('The busiest hour used {0:P1} of the {1:N0} tokens-per-minute limit. Lower the capacity from {2} to about {3} (3x the busiest-hour average) to release quota{4}.' -f [double]$pct, [double]$Rec.'Tokens per minute', $cap, $suggest, $freed)
            return $r
        }
    }
    $r.Status = 'OK'
    return $r
}

function Get-ContentFilterProfile {
    # Compares one content filter (RAI) policy with the Microsoft.DefaultV2 baseline: the four harm categories
    # block Medium+ on prompts and completions, prompt shields (jailbreak) and protected material (text) block,
    # protected material (code) annotates, indirect attacks and profanity are off.
    param($Policy)
    $pp       = $Policy.properties
    $filters  = @($pp.contentFilters | Where-Object { $_ })
    $relaxed  = [System.Collections.Generic.List[string]]::new()
    $stricter = [System.Collections.Generic.List[string]]::new()
    $find = { param([string]$Name, [string]$Source) @($filters | Where-Object { [string]$_.name -eq $Name -and (-not $Source -or [string]$_.source -eq $Source) }) | Select-Object -First 1 }
    $state = { param($f) if (-not $f -or -not $f.enabled) { 'Off' } elseif (-not $f.blocking) { 'Annotate' } else { 'Block' } }
    $harm = [ordered]@{}
    foreach ($cat in $script:ContentHarmCategories) {
        $cells = foreach ($src in 'Prompt', 'Completion') {
            $f     = & $find $cat $src
            $label = '{0} ({1})' -f $(if ($cat -eq 'Selfharm') { 'Self-harm' } else { $cat }), $src.ToLowerInvariant()
            switch (& $state $f) {
                'Off'      { $relaxed.Add("$label off"); 'Off' }
                'Annotate' { $relaxed.Add("$label annotate only"); 'Annotate' }
                default {
                    switch ([string]$f.severityThreshold) {
                        'Low'    { $stricter.Add("$label blocks Low+"); 'Low+' }
                        'Medium' { 'Medium+' }
                        'High'   { $relaxed.Add("$label blocks High only"); 'High' }
                        default  { [string]$f.severityThreshold }
                    }
                }
            }
        }
        $harm[$cat] = @($cells) -join ' / '
    }
    $jailbreak = & $state (& $find 'Jailbreak' 'Prompt')
    if ($jailbreak -ne 'Block') { $relaxed.Add("Prompt shields (jailbreak) $($jailbreak.ToLowerInvariant())") }
    $indirect = & $state (& $find 'Indirect Attack' '')
    if ($indirect -ne 'Off') { $stricter.Add("Indirect attacks $($indirect.ToLowerInvariant())") }
    if ((& $state (& $find 'Indirect Attack Spotlighting' '')) -ne 'Off') { $stricter.Add('Spotlighting on') }
    $pmText = & $state (& $find 'Protected Material Text' '')
    if ($pmText -ne 'Block') { $relaxed.Add("Protected material (text) $($pmText.ToLowerInvariant())") }
    $pmCode = & $state (& $find 'Protected Material Code' '')
    if ($pmCode -eq 'Off') { $relaxed.Add('Protected material (code) off') } elseif ($pmCode -eq 'Block') { $stricter.Add('Protected material (code) blocks') }
    $profanity = & $state (& $find 'Profanity' '')
    if ($profanity -ne 'Off') { $stricter.Add("Profanity $($profanity.ToLowerInvariant())") }
    $blocklists = @($pp.customBlocklists | Where-Object { $_ -and $_.blocklistName } | ForEach-Object { [string]$_.blocklistName } | Sort-Object -Unique)
    if ($blocklists.Count) { $stricter.Add("$($blocklists.Count) custom blocklist(s)") }
    $mode = [string]$pp.mode
    if ($mode -match '(?i)async|deferred') { $relaxed.Add("Mode $mode (streamed content is filtered after it is returned)") }
    [pscustomobject]@{
        Name           = [string]$Policy.name
        Type           = $(if ([string]$pp.type -eq 'SystemManaged' -or ([string]$Policy.name).StartsWith('Microsoft.')) { 'System' } else { 'Custom' })
        BasePolicy     = [string]$pp.basePolicyName
        Mode           = $mode
        Hate           = $harm['Hate']
        Sexual         = $harm['Sexual']
        Violence       = $harm['Violence']
        SelfHarm       = $harm['Selfharm']
        Jailbreak      = $jailbreak
        IndirectAttack = $indirect
        ProtectedText  = $pmText
        ProtectedCode  = $pmCode
        Profanity      = $profanity
        Blocklists     = ($blocklists -join ', ')
        Assessment     = $(if ($relaxed.Count) { 'Relaxed' } elseif ($stricter.Count) { 'Stricter' } else { 'Default' })
        Relaxed        = ($relaxed -join '; ')
        Stricter       = ($stricter -join '; ')
    }
}

# Content filter (RAI) policies per account, compared with the DefaultV2 baseline.
$RaiProfiles = @{}   # account id|policy name (lower-case) -> profile
foreach ($acct in $modelHosts) {
    $res = $AcctResults[$acct.IdLower]
    if (-not $res) { continue }
    foreach ($p in @($res.RaiPolicies)) {
        if (-not $p -or -not $p.name) { continue }
        $RaiProfiles['{0}|{1}' -f $acct.IdLower, ([string]$p.name).ToLowerInvariant()] = Get-ContentFilterProfile $p
    }
}

# Model deployment records (Foundry + Azure OpenAI) enriched with lifecycle, usage, right-sizing and quota.
$ModelHostDeployments = [System.Collections.Generic.List[object]]::new()
foreach ($acct in $modelHosts) {
    $res = $AcctResults[$acct.IdLower]
    if (-not $res) { continue }
    $usageOk  = $DoMetrics -and -not $res.UsageError
    $slots    = @($res.UsageSlots)
    $hasIn    = $usageOk -and $slots -contains 'In'
    $hasOut   = $usageOk -and $slots -contains 'Out'
    $hasTotal = $usageOk -and ($slots -contains 'Total' -or ($hasIn -and $hasOut))
    $hasReq   = $usageOk -and $slots -contains 'Req'
    $peakOk   = $DoMetrics -and -not $res.PeakError
    $dailyOk  = $DoMetrics -and -not $res.DailyError
    $ptuOk    = $DoMetrics -and -not $res.PtuError
    $raiOk    = $DoMetrics -and @($res.RaiSlots).Count -gt 0
    $acctDeps = [System.Collections.Generic.List[object]]::new()
    foreach ($d in @($res.Deployments)) {
        $m         = $d.properties.model
        $modelName = [string]$m.name
        $skuName   = [string]$d.sku.name
        $upgrade   = [string]$d.properties.versionUpgradeOption
        $life      = Get-DeploymentLifecycle -Account $acct -ModelName $modelName -ModelVersion ([string]$m.version) -SkuName $skuName -UpgradeOption $upgrade
        $dk        = ([string]$d.name).ToLowerInvariant()
        $u         = if ($usageOk) { $res.Usage[$dk] } else { $null }
        # Provisioned (PTU) deployments and image / audio / video models carry no token rate limit: leave the cell blank.
        $tokenLimit = @($d.properties.rateLimits) | Where-Object { $_ -and $_.key -eq 'token' } | Select-Object -First 1
        $tpm       = if ($tokenLimit) { $tokenLimit.count } else { $null }
        $isPtu     = $skuName -match '(?i)provisioned'
        $created   = ConvertTo-UtcDateTime $d.systemData.createdAt
        $peakTpm   = if ($peakOk) { [Math]::Round([double]$(if ($res.Peak.ContainsKey($dk)) { $res.Peak[$dk] } else { 0 }) / 60.0) } else { $null }
        $daily     = if ($dailyOk) { $res.Daily[$dk] } else { $null }
        $lastReq   = if ($daily) { $daily.Last } else { $null }
        $idleDays  = if (-not $dailyOk) { $null }
                     elseif ($lastReq) { [int][Math]::Max(0, [Math]::Floor(($TodayUtc - $lastReq.Date).TotalDays)) }
                     elseif ($created) { [int][Math]::Max(0, [Math]::Min($IdleLookbackDays, [Math]::Floor(($RunStartedUtc - $created).TotalDays))) }
                     else { $IdleLookbackDays }
        $ptuAvg = $null; $ptuPeak = $null
        if ($isPtu -and $ptuOk) {
            $pt    = $res.Ptu[$dk]
            $hours = if ($created -and $created -gt $UsageFromUtc) { [Math]::Max(1.0, ($UsageToUtc - $created).TotalHours) } else { $UsageHours }
            $ptuAvg  = if ($pt) { [Math]::Min(1.0, $pt.Sum / $hours / 100.0) } else { 0.0 }
            $ptuPeak = if ($pt) { [Math]::Min(1.0, $pt.Peak / 100.0) } else { 0.0 }
        }
        $quota    = Get-DeploymentQuota -Account $acct -ModelName $modelName -ModelVersion ([string]$m.version) -ModelFormat ([string]$m.format) -SkuName $skuName
        $policy     = [string]$d.properties.raiPolicyName
        $raiProfile = if ($policy) { $RaiProfiles['{0}|{1}' -f $acct.IdLower, $policy.ToLowerInvariant()] } else { $null }
        $rai        = if ($raiOk) { $res.Rai[$dk] } else { $null }
        $rec = [pscustomobject]@{
            'Platform'           = $acct.Service.Name
            'Subscription'       = $acct.Subscription
            'Resource group'     = $acct.ResourceGroup
            'Account'            = $acct.Name
            'Region'             = $acct.Region
            'Deployment'         = [string]$d.name
            'Model'              = $(if ($modelName) { $modelName } else { '(unknown)' })
            'Model version'      = [string]$m.version
            'Model format'       = [string]$m.format
            'Deployment type'    = $(if ($skuName) { $skuName } else { '(none)' })
            'Capacity'           = $d.sku.capacity
            'Tokens per minute'  = $tpm
            'Version upgrade'    = $upgrade
            'Content filter'     = $(if ($policy) { $policy } else { '(not set)' })
            'Content filter assessment' = $(if (-not $policy) { 'Not set' } elseif ($raiProfile) { $raiProfile.Assessment } elseif ($res.RaiError) { '' } else { 'Policy not found' })
            'Provisioning state' = [string]$d.properties.provisioningState
            'Lifecycle'          = $life.Lifecycle
            'Retirement date'    = $life.RetirementDate
            'Days to retirement' = $life.Days
            'Retirement risk'    = $life.Risk
            'Retirement impact'  = $life.Impact
            'Suggested upgrade'  = $life.Suggested
            'Input tokens'       = $(if ($hasIn) { if ($u) { $u.In } else { 0 } } else { $null })
            'Output tokens'      = $(if ($hasOut) { if ($u) { $u.Out } else { 0 } } else { $null })
            'Total tokens'       = $(if ($hasTotal) { if ($u) { if ($slots -contains 'Total' -and $u.Total) { $u.Total } else { $u.In + $u.Out } } else { 0 } } else { $null })
            'Requests'           = $(if ($hasReq) { if ($u) { $u.Req } else { 0 } } else { $null })
            'Peak TPM (busiest hour)'  = $peakTpm
            'Peak % of TPM limit'      = $(if ($null -ne $peakTpm -and $tpm) { $peakTpm / [double]$tpm } else { $null })
            'Throttled requests (429)' = $(if ($dailyOk) { if ($daily) { $daily.Throttled } else { 0 } } else { $null })
            'PTU utilization avg'      = $ptuAvg
            'PTU utilization peak'     = $ptuPeak
            'Last request date'        = $(if ($lastReq) { $lastReq.Date } else { $null })
            'Idle days'                = $idleDays
            'Quota'                    = $(if ($quota) { [string]$quota.name.value } else { '' })
            'Quota used %'             = $(if ($quota -and [double]$quota.limit -gt 0) { [double]$quota.currentValue / [double]$quota.limit } else { $null })
            'Spillover deployment'     = [string]$d.properties.spilloverDeploymentName
            'Right-sizing'             = ''
            'Right-sizing advice'      = ''
            'Est. actual cost'    = $null
            'Est. amortized cost' = $null
            'Reservation name'   = ''
            'Currency'           = ''
            'Created (UTC)'      = $created
            'Created by'         = [string]$d.systemData.createdBy
            'Deployment ID'      = [string]$d.id
            '_AccountId'         = $acct.IdLower
            '_ModelKey'          = $modelName.ToLowerInvariant()
            '_Scope'             = (Get-SkuScope $skuName)
            '_Account'           = $acct
            '_Quota'             = $quota
            '_IsPtu'             = $isPtu
            '_RaiProfile'        = $raiProfile
            '_RaiTotal'          = $(if ($raiOk -and @($res.RaiSlots) -contains 'Total') { if ($rai) { $rai.Total } else { 0 } } else { $null })
            '_RaiHarmful'        = $(if ($raiOk -and @($res.RaiSlots) -contains 'Harmful') { if ($rai) { $rai.Harmful } else { 0 } } else { $null })
            '_RaiRejected'       = $(if ($raiOk -and @($res.RaiSlots) -contains 'Rejected') { if ($rai) { $rai.Rejected } else { 0 } } else { $null })
        }
        $perUnit = if ($tpm -and $d.sku.capacity) { [double]$tpm / [double]$d.sku.capacity } else { 0 }
        $rs = Get-RightSizing -Rec $rec -IsPtu $isPtu -PerUnit $perUnit -QuotaUsage $quota
        $rec.'Right-sizing'        = $rs.Status
        $rec.'Right-sizing advice' = $rs.Advice
        $acctDeps.Add($rec)
        $ModelHostDeployments.Add($rec)
    }
    $acct.Deployments = $acctDeps.ToArray()
}

# Foundry projects (child resources of Foundry accounts, not indexed by Resource Graph).
$FoundryProjects = [System.Collections.Generic.List[object]]::new()
foreach ($acct in @($modelHosts | Where-Object { $_.Kind -eq 'AIServices' })) {
    $res = $AcctResults[$acct.IdLower]
    if (-not $res) { continue }
    $list = foreach ($p in @($res.Projects)) {
        $pp = $p.properties
        $projectEndpoint = ''
        if ($pp -and $pp.endpoints) {
            $firstEndpoint = @($pp.endpoints.PSObject.Properties)[0]
            if ($firstEndpoint) { $projectEndpoint = [string]$firstEndpoint.Value }
        }
        [pscustomobject]@{
            'Foundry resource'   = $acct.Name
            'Subscription'       = $acct.Subscription
            'Resource group'     = $acct.ResourceGroup
            'Project'            = (Get-LastSegment ([string]$p.name))
            'Display name'       = [string]$pp.displayName
            'Description'        = (ConvertTo-PlainText $pp.description 300)
            'Region'             = (Get-RegionName ([string]$p.location))
            'Default project'    = [bool]$pp.isDefault
            'Managed identity'   = (Get-IdentityLabel ([string]$p.identity.type))
            'Project endpoint'   = $projectEndpoint
            'Provisioning state' = [string]$pp.provisioningState
            'Created (UTC)'      = (ConvertTo-UtcDateTime $p.systemData.createdAt)
            'Created by'         = [string]$p.systemData.createdBy
            'Resource ID'        = [string]$p.id
            'Portal'             = (Get-PortalLink ([string]$p.id))
        }
    }
    $acct.Projects = @($list)
    foreach ($x in @($list)) { if ($x) { $FoundryProjects.Add($x) } }
}
Write-Host ("        {0} model deployment(s), {1} Foundry project(s)" -f $ModelHostDeployments.Count, $FoundryProjects.Count)

#endregion

#region 5. Cost (Cost Management) --------------------------------------------------------

Write-Step "Collecting actual and amortized cost (last $UsageDays days)"

$CostRows        = [System.Collections.Generic.List[object]]::new()
$CostOkSubs      = @{}   # subscriptions with at least one readable cost dataset
$ActualOkSubs    = @{}
$AmortizedOkSubs = @{}
$costResourceTypes = @(
    'microsoft.cognitiveservices/accounts',
    'microsoft.machinelearningservices/workspaces',
    'microsoft.machinelearningservices/workspaces/onlineendpoints',
    'microsoft.machinelearningservices/workspaces/serverlessendpoints',
    'microsoft.machinelearningservices/workspaces/batchendpoints',
    'microsoft.machinelearningservices/workspaces/computes',
    'microsoft.search/searchservices',
    'microsoft.botservice/botservices'
)

function Invoke-CostQuery {
    # One Cost Management query (all pages); rows are returned as hashtables keyed by column name.
    # Default filter: the AI resource types. -Filter replaces it, -AllTypes removes it.
    param([string]$Subscription, [string]$Type, [string[]]$Grouping, [string]$CostColumn, $Filter, [switch]$AllTypes)
    $dataset = [ordered]@{
        granularity = 'None'
        aggregation = [ordered]@{
            totalCost     = @{ name = $CostColumn; function = 'Sum' }
            totalQuantity = @{ name = 'UsageQuantity'; function = 'Sum' }
        }
        grouping    = @($Grouping | ForEach-Object { @{ type = 'Dimension'; name = $_ } })
    }
    if ($Filter) { $dataset.filter = $Filter }
    elseif (-not $AllTypes) { $dataset.filter = @{ dimensions = @{ name = 'ResourceType'; operator = 'In'; values = $costResourceTypes } } }
    $body = [ordered]@{
        type       = $Type
        timeframe  = 'Custom'
        timePeriod = [ordered]@{ from = $UsageFromUtc.ToString('yyyy-MM-ddTHH:mm:ssZ'); to = $UsageToUtc.ToString('yyyy-MM-ddTHH:mm:ssZ') }
        dataset    = $dataset
    } | ConvertTo-Json -Depth 10 -Compress
    $uri  = "/subscriptions/$Subscription/providers/Microsoft.CostManagement/query?api-version=2023-11-01"
    $rows = [System.Collections.Generic.List[object]]::new()
    while ($uri) {
        $r = Invoke-Arm -Method POST -Uri $uri -Body $body
        if (-not $r.Ok) { return [pscustomobject]@{ Ok = $false; Status = $r.Status; Error = $r.Error; Rows = $null } }
        $cols = @($r.Data.properties.columns | ForEach-Object { [string]$_.name })
        foreach ($row in @($r.Data.properties.rows)) {
            $h = @{}
            for ($i = 0; $i -lt $cols.Count; $i++) { $h[$cols[$i]] = $row[$i] }
            $rows.Add($h)
        }
        $uri = [string]$r.Data.properties.nextLink
    }
    return [pscustomobject]@{ Ok = $true; Status = 200; Error = $null; Rows = $rows }
}

function Get-SubscriptionCost {
    # Normalised cost rows (resource x meter x covering reservation) of one subscription for one
    # dataset: ActualCost or AmortizedCost.
    param([string]$Subscription, [string]$Type)
    # 'Cost' works for EA/MCA/most offers; very old offer types only expose 'PreTaxCost'.
    $costColumn = 'Cost'
    $fullGrouping = @('ResourceId', 'Meter', 'MeterSubCategory', 'MeterCategory', 'ReservationName')
    $q = Invoke-CostQuery -Subscription $Subscription -Type $Type -Grouping $fullGrouping -CostColumn $costColumn
    if (-not $q.Ok -and $q.Status -eq 400 -and $q.Error -match '(?i)aggregat|column|pretaxcost') {
        $costColumn = 'PreTaxCost'
        $q = Invoke-CostQuery -Subscription $Subscription -Type $Type -Grouping $fullGrouping -CostColumn $costColumn
    }
    $maps = $null
    if (-not $q.Ok -and $q.Status -eq 400 -and $q.Error -match '(?i)group') {
        # Back ends enforcing the documented limit of two groupings: query resource x meter, then
        # resolve (sub)category and reservation with further two-dimension queries.
        $q = Invoke-CostQuery -Subscription $Subscription -Type $Type -Grouping 'ResourceId', 'Meter' -CostColumn $costColumn
        if ($q.Ok) {
            $maps = @{ Category = @{}; SubCategory = @{}; Reservation = @{}; MeterReservation = $null }
            $qc = Invoke-CostQuery -Subscription $Subscription -Type $Type -Grouping 'Meter', 'MeterCategory' -CostColumn $costColumn
            if ($qc.Ok) { foreach ($x in $qc.Rows) { $maps.Category[[string]$x['Meter']] = [string]$x['MeterCategory'] } }
            $qs = Invoke-CostQuery -Subscription $Subscription -Type $Type -Grouping 'Meter', 'MeterSubCategory' -CostColumn $costColumn
            if ($qs.Ok) { foreach ($x in $qs.Rows) { $maps.SubCategory[[string]$x['Meter']] = [string]$x['MeterSubCategory'] } }
            $qr = Invoke-CostQuery -Subscription $Subscription -Type $Type -Grouping 'ResourceId', 'ReservationName' -CostColumn $costColumn
            if ($qr.Ok) {
                foreach ($x in $qr.Rows) {
                    $rn = [string]$x['ReservationName']
                    if (-not $rn) { continue }
                    $rid = ([string]$x['ResourceId']).ToLowerInvariant()
                    if (-not $maps.Reservation.ContainsKey($rid)) { $maps.Reservation[$rid] = [System.Collections.Generic.SortedSet[string]]::new() }
                    [void]$maps.Reservation[$rid].Add($rn)
                }
            }
            # Reservations per meter narrow the per-resource reservations down to the covered meters.
            $qm = Invoke-CostQuery -Subscription $Subscription -Type $Type -Grouping 'Meter', 'ReservationName' -CostColumn $costColumn
            if ($qm.Ok) {
                $maps.MeterReservation = @{}
                foreach ($x in $qm.Rows) {
                    $rn = [string]$x['ReservationName']
                    if (-not $rn) { continue }
                    $mn = [string]$x['Meter']
                    if (-not $maps.MeterReservation.ContainsKey($mn)) { $maps.MeterReservation[$mn] = [System.Collections.Generic.SortedSet[string]]::new() }
                    [void]$maps.MeterReservation[$mn].Add($rn)
                }
            }
        }
    }
    if (-not $q.Ok) { return [pscustomobject]@{ Ok = $false; Error = $q.Error; Rows = @() } }
    $rows = foreach ($x in $q.Rows) {
        $meter = [string]$x['Meter']
        $rid   = ([string]$x['ResourceId']).ToLowerInvariant()
        $reservation = if (-not $maps) { [string]$x['ReservationName'] }
                       elseif (-not $maps.Reservation.ContainsKey($rid)) { '' }
                       elseif ($null -eq $maps.MeterReservation) { @($maps.Reservation[$rid]) -join '; ' }
                       else { @($maps.Reservation[$rid] | Where-Object { $maps.MeterReservation.ContainsKey($meter) -and $maps.MeterReservation[$meter].Contains($_) }) -join '; ' }
        [pscustomobject]@{
            ResourceId       = $rid
            Meter            = $meter
            MeterSubCategory = $(if ($maps) { [string]$maps.SubCategory[$meter] } else { [string]$x['MeterSubCategory'] })
            MeterCategory    = $(if ($maps) { [string]$maps.Category[$meter] } else { [string]$x['MeterCategory'] })
            Reservation      = $reservation
            Quantity         = [double]$x['UsageQuantity']
            Cost             = [double]$x[$costColumn]
            Currency         = [string]$x['Currency']
        }
    }
    return [pscustomobject]@{ Ok = $true; Error = $null; Rows = @($rows) }
}

if ($DoCost -and $AiSubscriptions.Count -gt 0) {
    foreach ($sub in $AiSubscriptions) {
        $measures = [ordered]@{
            Actual    = Get-SubscriptionCost -Subscription $sub -Type 'ActualCost'
            Amortized = Get-SubscriptionCost -Subscription $sub -Type 'AmortizedCost'
        }
        foreach ($m in @($measures.Keys)) {
            if (-not $measures[$m].Ok) { Add-Note ("{0} cost unavailable for subscription '{1}': {2}" -f $m, (Get-SubscriptionName $sub), $measures[$m].Error) }
        }
        if (-not ($measures.Actual.Ok -or $measures.Amortized.Ok)) { continue }
        $CostOkSubs[$sub] = $true
        if ($measures.Actual.Ok) { $ActualOkSubs[$sub] = $true }
        if ($measures.Amortized.Ok) { $AmortizedOkSubs[$sub] = $true }
        # Merge both datasets per resource x meter; the per-reservation split of a meter becomes one row.
        $merged = [ordered]@{}
        foreach ($m in 'Actual', 'Amortized') {
            if (-not $measures[$m].Ok) { continue }
            foreach ($x in $measures[$m].Rows) {
                $k = '{0}|{1}|{2}|{3}' -f $x.ResourceId, $x.Meter, $x.MeterSubCategory, $x.MeterCategory
                if (-not $merged.Contains($k)) {
                    $merged[$k] = [pscustomobject]@{
                        ResourceId = $x.ResourceId; Meter = $x.Meter; MeterSubCategory = $x.MeterSubCategory; MeterCategory = $x.MeterCategory
                        Actual = 0.0; Amortized = 0.0; QtyActual = 0.0; QtyAmortized = 0.0; Currency = $x.Currency
                        Reservations = [System.Collections.Generic.SortedSet[string]]::new()
                    }
                }
                $e = $merged[$k]
                if ($m -eq 'Actual') { $e.Actual += $x.Cost; $e.QtyActual += $x.Quantity } else { $e.Amortized += $x.Cost; $e.QtyAmortized += $x.Quantity }
                foreach ($n in ([string]$x.Reservation -split ';\s*')) { if ($n) { [void]$e.Reservations.Add($n) } }
                if (-not $e.Currency -and $x.Currency) { $e.Currency = $x.Currency }
            }
        }
        foreach ($e in $merged.Values) {
            $CostRows.Add([pscustomobject]@{
                    SubscriptionId   = $sub
                    ResourceId       = $e.ResourceId
                    Meter            = $e.Meter
                    MeterSubCategory = $e.MeterSubCategory
                    MeterCategory    = $e.MeterCategory
                    Quantity         = $(if ($measures.Amortized.Ok) { $e.QtyAmortized } else { $e.QtyActual })
                    ActualCost       = $(if ($measures.Actual.Ok) { $e.Actual } else { $null })
                    AmortizedCost    = $(if ($measures.Amortized.Ok) { $e.Amortized } else { $null })
                    Reservation      = (@($e.Reservations) -join '; ')
                    Currency         = $e.Currency
                })
        }
    }
}

function Add-CostAggregate {
    param([hashtable]$Map, [string]$Key, $Row)
    if (-not $Map.ContainsKey($Key)) { $Map[$Key] = [pscustomobject]@{ Actual = 0.0; Amortized = 0.0; Reservations = [System.Collections.Generic.SortedSet[string]]::new() } }
    $e = $Map[$Key]
    $e.Actual    += [double]$Row.ActualCost
    $e.Amortized += [double]$Row.AmortizedCost
    foreach ($n in ([string]$Row.Reservation -split ';\s*')) { if ($n) { [void]$e.Reservations.Add($n) } }
}

function Set-ItemCost {
    # Known zero when the dataset was read for the subscription, blank (unknown) otherwise.
    param($Target, [string]$Subscription, $Aggregate)
    if ($ActualOkSubs.ContainsKey($Subscription)) { $Target.ActualCost = $(if ($Aggregate) { $Aggregate.Actual } else { 0.0 }) }
    if ($AmortizedOkSubs.ContainsKey($Subscription)) { $Target.AmortizedCost = $(if ($Aggregate) { $Aggregate.Amortized } else { 0.0 }) }
    if ($Aggregate) { $Target.Reservation = @($Aggregate.Reservations) -join '; ' }
}

$CostByTop     = @{}   # top-level resource id -> actual / amortized cost + reservations (includes child resources)
$CostByExact   = @{}   # exact resource id     -> actual / amortized cost + reservations
$CurrencyBySub = @{}
foreach ($c in $CostRows) {
    Add-CostAggregate -Map $CostByTop -Key (Get-TopLevelId $c.ResourceId) -Row $c
    Add-CostAggregate -Map $CostByExact -Key $c.ResourceId -Row $c
    if ($c.Currency) { $CurrencyBySub[$c.SubscriptionId] = $c.Currency }
}
$Currencies    = @($CostRows | ForEach-Object { $_.Currency } | Where-Object { $_ } | Sort-Object -Unique)
$MultiCurrency = $Currencies.Count -gt 1
$CurrencyLabel = if ($Currencies.Count -eq 1) { $Currencies[0] } elseif ($MultiCurrency) { 'mixed currencies' } else { '' }
if ($MultiCurrency) { Add-Note "Cost data spans several billing currencies ($($Currencies -join ', ')); cost pivots are grouped by currency and totals are shown per currency." }
if ($DoCost -and $AiSubscriptions.Count -and ($ActualOkSubs.Count -lt $AiSubscriptions.Count -or $AmortizedOkSubs.Count -lt $AiSubscriptions.Count)) {
    Add-Note ("Cost is partial: actual cost covers {0}, amortized cost {1} of {2} subscription(s) with AI resources." -f $ActualOkSubs.Count, $AmortizedOkSubs.Count, $AiSubscriptions.Count)
}

foreach ($item in @(@($Resources) + @($HubProjects))) {
    Set-ItemCost -Target $item -Subscription $item.SubscriptionId -Aggregate $CostByTop[$item.IdLower]
    if ($CostOkSubs.ContainsKey($item.SubscriptionId)) { $item.Currency = [string]$CurrencyBySub[$item.SubscriptionId] }
}
foreach ($hub in @($Resources | Where-Object { $_.ServiceKey -eq 'AIHubs' })) {
    if ($ActualOkSubs.ContainsKey($hub.SubscriptionId)) { $hub.ProjectsActualCost = [double](@($hub.Projects | ForEach-Object { [double]$_.ActualCost }) | Measure-Object -Sum).Sum }
    if ($AmortizedOkSubs.ContainsKey($hub.SubscriptionId)) { $hub.ProjectsAmortizedCost = [double](@($hub.Projects | ForEach-Object { [double]$_.AmortizedCost }) | Measure-Object -Sum).Sum }
}
foreach ($ep in $MlEndpoints) { Set-ItemCost -Target $ep -Subscription $ep.SubscriptionId -Aggregate $CostByExact[$ep.IdLower] }

# Totals per currency - amounts of different currencies are never added together.
function Get-CostByCurrency {
    # A currency seen only in the other dataset is unknown for this measure, not zero.
    param([object[]]$Rows, [string]$Measure)
    $map = [ordered]@{}
    foreach ($g in @($Rows | Where-Object { $_.Currency -and $null -ne $_.$Measure } | Group-Object -Property Currency | Sort-Object -Property Name)) {
        $map[$g.Name] = [double](($g.Group | ForEach-Object { [double]$_.$Measure } | Measure-Object -Sum).Sum)
    }
    return $map
}
function Format-CurrencyTotal {
    param($Map, [bool]$Available)
    if (-not $Available) { return 'n/a' }
    $text = (@($Map.Keys | ForEach-Object { '{0:N2} {1}' -f $Map[$_], $_ }) -join ' | ')
    if ($text) { return $text }
    return '0.00'
}
$ActualByCurrency    = Get-CostByCurrency -Rows $CostRows -Measure 'ActualCost'
$AmortizedByCurrency = Get-CostByCurrency -Rows $CostRows -Measure 'AmortizedCost'
$TotalActual        = [double](($ActualByCurrency.Values | Measure-Object -Sum).Sum)
$TotalAmortized     = [double](($AmortizedByCurrency.Values | Measure-Object -Sum).Sum)
$ActualTotalText    = Format-CurrencyTotal -Map $ActualByCurrency -Available ([bool]$ActualOkSubs.Count)
$AmortizedTotalText = Format-CurrencyTotal -Map $AmortizedByCurrency -Available ([bool]$AmortizedOkSubs.Count)
if ($DoCost) { Write-Host ("        {0} cost row(s) - actual {1}, amortized {2}" -f $CostRows.Count, $ActualTotalText, $AmortizedTotalText) }

# Cost of resources that are not in the service tables (deleted during the window, or account kinds
# outside the 23 services) is part of the totals only - say so, so that the table totals reconcile.
# Every hub-based project is listed on the AI Hubs sheet, including projects whose hub is out of scope.
$tableIds = [System.Collections.Generic.HashSet[string]]::new()
foreach ($item in @(@($Resources) + @($HubProjects))) { [void]$tableIds.Add($item.IdLower) }
$outsideRows = @($CostRows | Where-Object { -not $tableIds.Contains((Get-TopLevelId $_.ResourceId)) })
$outsideSum  = [double](($outsideRows | ForEach-Object { [Math]::Abs([double]$_.ActualCost) + [Math]::Abs([double]$_.AmortizedCost) } | Measure-Object -Sum).Sum)
$OutsideActualByCurrency    = Get-CostByCurrency -Rows $outsideRows -Measure 'ActualCost'
$OutsideAmortizedByCurrency = Get-CostByCurrency -Rows $outsideRows -Measure 'AmortizedCost'
$OutsideCount = 0
if ($outsideSum -ge 0.005) {
    $OutsideCount = @($outsideRows | ForEach-Object { Get-TopLevelId $_.ResourceId } | Sort-Object -Unique).Count
    $outsideText  = 'Cost totals include {0} resource(s) that are not in the service tables (deleted during the window, or account kinds outside the 23 services): actual {1}, amortized {2}. The AI services summary shows them on a separate line above the total.' -f `
        $OutsideCount, (Format-CurrencyTotal -Map $OutsideActualByCurrency -Available ([bool]$ActualOkSubs.Count)),
        (Format-CurrencyTotal -Map $OutsideAmortizedByCurrency -Available ([bool]$AmortizedOkSubs.Count))
    Add-Note $outsideText -Quiet
    Write-Host "        $outsideText"
}

# --- AI cost reconciliation: AI spend outside the AI resource types, and the subscription totals ---
# Foundry account internal id (first 15 characters, no dashes) -> account. Partner models sold through
# Azure Marketplace (e.g. Claude) are billed on SaaS resources named <offer>-<internal id prefix>-<32 hex>.
$InternalIdIndex = @{}
foreach ($c in $cogItems) {
    $iid = ([string]$c.Raw.internalId -replace '-', '').ToLowerInvariant()
    if ($iid.Length -ge 15) { $InternalIdIndex[$iid.Substring(0, 15)] = $c }
}
function Get-SaasAccount {
    param([string]$Name)
    if ($Name -match '-(?<iid>[0-9a-f]{15})-[0-9a-f]{32}$' -and $script:InternalIdIndex.ContainsKey($Matches['iid'])) { return $script:InternalIdIndex[$Matches['iid']] }
    return $null
}

$ReconLines = [ordered]@{
    'AI resources (service sheets)'          = 'Usage of the AI resources on the service sheets (a hub includes its projects). Amortized cost includes the share of the reservations (e.g. PTU) and savings plans the resources use.'
    'AI resources not on the service sheets' = 'AI resource types (Cognitive Services, Machine Learning, AI Search, Bot Service) billed in the window but not on the service sheets: deleted during the window, or account kinds outside the 23 services.'
    'AI reservation purchases'               = 'Purchases and refunds of AI reservations, e.g. provisioned throughput (PTU). Actual cost only - amortized cost spreads the purchase over the resources that use it (first line).'
    'Unused AI reservations'                 = 'Unused hours of AI reservations. Amortized cost only - in actual cost they are part of the purchase.'
    'Marketplace AI models'                  = 'Partner models sold through Azure Marketplace (e.g. Claude, Mistral), billed on Marketplace (SaaS) resources; linked to the Foundry resource when the resource name allows it.'
    'Copilot Studio and Copilot meters'      = 'Copilot Studio pay-as-you-go billed on Power Platform billing policies, and other Copilot meters.'
    'Other AI meters'                        = 'AI service meters (Foundry, Azure OpenAI, Cognitive Services, AI Search, Machine Learning, Bot Service) billed on other resource types.'
}
$ReconScanSubs = @(@($AiSubscriptions) + @($PowerPlatformSubs) + @($SubscriptionId) | Where-Object { $_ } | ForEach-Object { ([string]$_).ToLowerInvariant() } | Sort-Object -Unique)
$ReconOk       = @{ Actual = @{}; Amortized = @{} }   # measure -> subscription -> AI cost outside the AI resources read
$TotalsOk      = @{ Actual = @{}; Amortized = @{} }   # measure -> subscription -> subscription total read
$SubTotals     = @{}                                  # subscription|measure|currency -> total of all charges
$reconRaw      = [System.Collections.Generic.List[object]]::new()
if ($DoCost -and $ReconScanSubs.Count) {
    $reconFilter = @{ or = @(
            @{ dimensions = @{ name = 'ResourceType'; operator = 'In'; values = @('microsoft.powerplatform/accounts', 'microsoft.saas/resources') } },
            @{ dimensions = @{ name = 'ChargeType'; operator = 'In'; values = @('Purchase', 'Refund', 'UnusedReservation', 'UnusedSavingsPlan') } },
            @{ dimensions = @{ name = 'PublisherType'; operator = 'In'; values = @('Marketplace') } },
            @{ dimensions = @{ name = 'MeterCategory'; operator = 'In'; values = @('Foundry Models', 'Foundry Tools', 'Azure OpenAI', 'Cognitive Services', 'Azure AI Services',
                        'Azure Cognitive Search', 'Azure AI Search', 'Azure Bot Service', 'Machine Learning', 'Azure Machine Learning', 'Microsoft Copilot Studio', 'Copilot Studio') } }
        ) }
    $reconGrouping = 'ResourceId', 'ResourceType', 'MeterCategory', 'MeterSubCategory', 'ChargeType', 'PublisherType', 'ReservationName'
    foreach ($sub in $ReconScanSubs) {
        foreach ($m in 'Actual', 'Amortized') {
            $col = 'Cost'
            $q = Invoke-CostQuery -Subscription $sub -Type "${m}Cost" -Grouping $reconGrouping -CostColumn $col -Filter $reconFilter
            if (-not $q.Ok -and $q.Status -eq 400 -and $q.Error -match '(?i)aggregat|column|pretaxcost') {
                $col = 'PreTaxCost'
                $q = Invoke-CostQuery -Subscription $sub -Type "${m}Cost" -Grouping $reconGrouping -CostColumn $col -Filter $reconFilter
            }
            if ($q.Ok) {
                $ReconOk[$m][$sub] = $true
                foreach ($x in $q.Rows) {
                    $reconRaw.Add([pscustomobject]@{
                            Measure = $m; SubscriptionId = $sub; ResourceId = ([string]$x['ResourceId']).ToLowerInvariant(); ResourceType = ([string]$x['ResourceType']).ToLowerInvariant()
                            MeterCategory = [string]$x['MeterCategory']; MeterSubCategory = [string]$x['MeterSubCategory']; ChargeType = [string]$x['ChargeType']
                            PublisherType = [string]$x['PublisherType']; ReservationName = [string]$x['ReservationName']; Cost = [double]$x[$col]; Currency = [string]$x['Currency']
                        })
                }
            }
            else { Add-Note ("AI cost outside the AI resources ({0} cost) unavailable for subscription '{1}': {2}" -f $m.ToLowerInvariant(), (Get-SubscriptionName $sub), $q.Error) }
            $t = Invoke-CostQuery -Subscription $sub -Type "${m}Cost" -Grouping 'ChargeType' -CostColumn $col -AllTypes
            if ($t.Ok) {
                $TotalsOk[$m][$sub] = $true
                foreach ($x in $t.Rows) {
                    $tk = '{0}|{1}|{2}' -f $sub, $m, [string]$x['Currency']
                    $SubTotals[$tk] = [double]$SubTotals[$tk] + [double]$x[$col]
                }
            }
            else { Add-Note ("Subscription total ({0} cost) unavailable for subscription '{1}': {2}" -f $m.ToLowerInvariant(), (Get-SubscriptionName $sub), $t.Error) }
        }
    }
}

# Reservations bought for AI meters (e.g. PTU) or covering AI meters: their unused hours are AI spend too.
# Reservations covering other meters of AI resources (e.g. VM reservations used by ML computes) are shared: not counted.
$AiReservationNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($c in @($CostRows | Where-Object { $_.MeterCategory -match $AiMeterRegex })) { foreach ($n in ([string]$c.Reservation -split ';\s*')) { if ($n) { [void]$AiReservationNames.Add($n) } } }
foreach ($x in $reconRaw) { if ($x.ChargeType -eq 'Purchase' -and $x.ReservationName -and $x.MeterCategory -match $AiMeterRegex) { [void]$AiReservationNames.Add($x.ReservationName) } }

function Get-ReconLine {
    param($Row)
    if ("$($Row.MeterCategory) $($Row.MeterSubCategory)" -match '(?i)copilot') { return 'Copilot Studio and Copilot meters' }
    if ($Row.ChargeType -in 'Purchase', 'Refund' -and $Row.MeterCategory -match $AiMeterRegex) { return 'AI reservation purchases' }
    if ($Row.ChargeType -eq 'UnusedReservation' -and ($Row.MeterCategory -match $AiMeterRegex -or ($Row.ReservationName -and $AiReservationNames.Contains($Row.ReservationName)))) { return 'Unused AI reservations' }
    if ($Row.ResourceType -eq 'microsoft.saas/resources' -or $Row.PublisherType -eq 'Marketplace') {
        $name = Get-LastSegment $Row.ResourceId
        if ("$($Row.MeterSubCategory) $($Row.MeterCategory) $name" -match $AiMarketplaceRegex -or (Get-SaasAccount $name)) { return 'Marketplace AI models' }
        return $null
    }
    if ($Row.ChargeType -notlike 'Unused*' -and $Row.ChargeType -ne 'Purchase' -and $Row.MeterCategory -match $AiMeterRegex) { return 'Other AI meters' }
    return $null
}

$ReconRows  = [System.Collections.Generic.List[object]]::new()   # classified AI cost outside the per-resource query
$reconIndex = @{}
foreach ($x in $reconRaw) {
    # AI resource types are already in the per-resource cost (service sheets / not on the sheets).
    if ($x.ResourceType -and $costResourceTypes -contains $x.ResourceType -and $CostOkSubs.ContainsKey($x.SubscriptionId)) { continue }
    $line = if ($x.ResourceType -and $costResourceTypes -contains $x.ResourceType) { 'AI resources not on the service sheets' } else { Get-ReconLine $x }
    if (-not $line) { continue }
    $k = '{0}|{1}|{2}|{3}|{4}|{5}|{6}|{7}|{8}|{9}' -f $line, $x.SubscriptionId, $x.ResourceId, $x.ResourceType, $x.MeterCategory, $x.MeterSubCategory, $x.ChargeType, $x.PublisherType, $x.ReservationName, $x.Currency
    if (-not $reconIndex.ContainsKey($k)) {
        $linked = if ($line -eq 'Marketplace AI models') { Get-SaasAccount (Get-LastSegment $x.ResourceId) } else { $null }
        $e = [pscustomobject]@{
            Line = $line; SubscriptionId = $x.SubscriptionId; ResourceId = $x.ResourceId; ResourceType = $x.ResourceType
            MeterCategory = $x.MeterCategory; MeterSubCategory = $x.MeterSubCategory; ChargeType = $x.ChargeType; PublisherType = $x.PublisherType
            ReservationName = $x.ReservationName; Currency = $x.Currency; LinkedAccount = $linked
            ActualCost    = $(if ($line -ne 'Unused AI reservations' -and $ReconOk.Actual.ContainsKey($x.SubscriptionId)) { 0.0 } else { $null })
            AmortizedCost = $(if ($line -ne 'AI reservation purchases' -and $ReconOk.Amortized.ContainsKey($x.SubscriptionId)) { 0.0 } else { $null })
        }
        $reconIndex[$k] = $e
        $ReconRows.Add($e)
    }
    $e = $reconIndex[$k]
    if ($x.Measure -eq 'Actual' -and $null -ne $e.ActualCost) { $e.ActualCost += $x.Cost }
    if ($x.Measure -eq 'Amortized' -and $null -ne $e.AmortizedCost) { $e.AmortizedCost += $x.Cost }
}
# Rows that net to zero in both datasets (e.g. free Marketplace plan purchases) carry no information.
$ReconRows = [System.Collections.Generic.List[object]]@($ReconRows | Where-Object { [Math]::Abs([double]$_.ActualCost) -ge 0.005 -or [Math]::Abs([double]$_.AmortizedCost) -ge 0.005 })

# Total AI spend by cost line (the source of the reconciliation tables and the Data_AISpend pivot sheet).
$SpendIndex = [ordered]@{}
function Add-SpendRow {
    param([string]$Line, [string]$Item, [string]$Subscription, $Actual, $Amortized, [string]$Currency)
    $k = '{0}|{1}|{2}|{3}' -f $Line, $Item, $Subscription, $Currency
    if (-not $script:SpendIndex.Contains($k)) {
        $script:SpendIndex[$k] = [pscustomobject]@{ 'Cost line' = $Line; 'Item' = $Item; 'Subscription' = (Get-SubscriptionName $Subscription); 'Actual cost' = $null; 'Amortized cost' = $null; 'Currency' = $Currency; '_Sub' = $Subscription }
    }
    $e = $script:SpendIndex[$k]
    if ($null -ne $Actual) { $e.'Actual cost' = [double]$e.'Actual cost' + [double]$Actual }
    if ($null -ne $Amortized) { $e.'Amortized cost' = [double]$e.'Amortized cost' + [double]$Amortized }
}
foreach ($c in $CostRows) {
    $top = Get-TopLevelId $c.ResourceId
    if ($tableIds.Contains($top)) {
        $item  = $ResIndex[$top]
        $label = if ($item -and $item.Service) { $item.Service.Name } else { 'AI resources' }
        Add-SpendRow -Line 'AI resources (service sheets)' -Item $label -Subscription $c.SubscriptionId -Actual $c.ActualCost -Amortized $c.AmortizedCost -Currency $c.Currency
    }
    else { Add-SpendRow -Line 'AI resources not on the service sheets' -Item (Get-LastSegment $top) -Subscription $c.SubscriptionId -Actual $c.ActualCost -Amortized $c.AmortizedCost -Currency $c.Currency }
}
foreach ($x in $ReconRows) {
    $name  = Get-LastSegment $x.ResourceId
    $label = switch ($x.Line) {
        'AI reservation purchases'          { if ($x.ReservationName) { $x.ReservationName } else { $x.MeterSubCategory } }
        'Unused AI reservations'            { if ($x.ReservationName) { $x.ReservationName } else { $x.MeterSubCategory } }
        'Marketplace AI models'             { if ($x.MeterSubCategory) { $x.MeterSubCategory } else { $name } }
        'Copilot Studio and Copilot meters' { if ($name) { $name } else { $x.MeterSubCategory } }
        default                             { '{0} ({1})' -f $(if ($name) { $name } else { '(no resource)' }), $x.MeterCategory }
    }
    Add-SpendRow -Line $x.Line -Item $label -Subscription $x.SubscriptionId -Actual $x.ActualCost -Amortized $x.AmortizedCost -Currency $x.Currency
}
$SpendRows = @($SpendIndex.Values | Sort-Object -Property @{ Expression = { @($ReconLines.Keys).IndexOf($_.'Cost line') } }, @{ Expression = { [double]$_.'Amortized cost' + [double]$_.'Actual cost' }; Descending = $true })

$ReconAvailable = $DoCost -and ($ReconOk.Actual.Count -or $ReconOk.Amortized.Count)
function Get-SubTotalByCurrency {
    param([string]$Measure, [string[]]$Subscriptions)
    $map = [ordered]@{}
    foreach ($k in @($SubTotals.Keys | Sort-Object)) {
        $p = $k.Split('|')
        if ($p[1] -ne $Measure -or ($Subscriptions -and $Subscriptions -notcontains $p[0])) { continue }
        $map[$p[2]] = [double]$map[$p[2]] + [double]$SubTotals[$k]
    }
    return $map
}
$AiSpendActual       = Get-CostByCurrency -Rows @($SpendRows | Select-Object @{ n = 'Currency'; e = { $_.Currency } }, @{ n = 'Cost'; e = { $_.'Actual cost' } }) -Measure 'Cost'
$AiSpendAmortized    = Get-CostByCurrency -Rows @($SpendRows | Select-Object @{ n = 'Currency'; e = { $_.Currency } }, @{ n = 'Cost'; e = { $_.'Amortized cost' } }) -Measure 'Cost'
$SubTotalActual      = Get-SubTotalByCurrency -Measure 'Actual'
$SubTotalAmortized   = Get-SubTotalByCurrency -Measure 'Amortized'
# Total AI spend of a measure needs both parts: the per-resource cost (when there are AI resources) and the
# AI cost billed elsewhere. When either failed, the total is unknown - not the sum of the part that was read.
$SpendOk = @{
    Actual    = [bool]($ReconAvailable -and $ReconOk.Actual.Count -and (-not $AiSubscriptions.Count -or $ActualOkSubs.Count))
    Amortized = [bool]($ReconAvailable -and $ReconOk.Amortized.Count -and (-not $AiSubscriptions.Count -or $AmortizedOkSubs.Count))
}
$AiSpendActualText    = Format-CurrencyTotal -Map $AiSpendActual -Available $SpendOk.Actual
$AiSpendAmortizedText = Format-CurrencyTotal -Map $AiSpendAmortized -Available $SpendOk.Amortized
function Get-AiShare {
    param($AiMap, $TotalMap)
    if (@($TotalMap.Keys).Count -ne 1 -or @($AiMap.Keys | Where-Object { $_ -notin $TotalMap.Keys }).Count) { return $null }
    $cur = @($TotalMap.Keys)[0]
    if ([double]$TotalMap[$cur] -le 0) { return $null }
    return [double]$AiMap[$cur] / [double]$TotalMap[$cur]
}
$AiShareActual    = if ($SpendOk.Actual) { Get-AiShare $AiSpendActual $SubTotalActual } else { $null }
$AiShareAmortized = if ($SpendOk.Amortized) { Get-AiShare $AiSpendAmortized $SubTotalAmortized } else { $null }
if ($ReconAvailable) {
    Write-Host ("        Total AI spend - actual {0}, amortized {1} ({2} subscription(s) scanned)" -f $AiSpendActualText, $AiSpendAmortizedText, $ReconScanSubs.Count)
}

#endregion

#region 6. Azure Advisor --------------------------------------------------------------------

Write-Step 'Collecting Azure Advisor recommendations'

$kqlAdvisor = @'
advisorresources
| where type =~ 'microsoft.advisor/recommendations'
| extend p = properties
| extend impactedType = tolower(tostring(p.impactedField))
| where impactedType in ('microsoft.cognitiveservices/accounts', 'microsoft.machinelearningservices/workspaces',
                         'microsoft.search/searchservices', 'microsoft.botservice/botservices',
                         'microsoft.subscriptions/subscriptions')
| where tostring(p.recommendationStatus) !in~ ('Completed', 'Dismissed') and tostring(p.platformState) !~ 'Resolved'
| project subscriptionId, impactedType,
    category = tostring(p.category), impact = tostring(p.impact), impactedValue = tostring(p.impactedValue),
    resourceId = tolower(tostring(p.resourceMetadata.resourceId)),
    problem = tostring(p.shortDescription.problem), solution = tostring(p.shortDescription.solution),
    potentialBenefits = tostring(p.potentialBenefits), learnMoreLink = tostring(p.learnMoreLink),
    recommendationTypeId = tostring(p.recommendationTypeId),
    subCategory = tostring(p.extendedProperties.recommendationSubCategory),
    extendedProperties = p.extendedProperties,
    status = tostring(p.recommendationStatus), lastUpdated = tostring(p.lastUpdated)
'@

$AdvisorRows           = [System.Collections.Generic.List[object]]::new()
$AdvisorRetirementRows = [System.Collections.Generic.List[object]]::new()
$AiSubSet = @{}
foreach ($s in $AiSubscriptions) { $AiSubSet[$s] = $true }

if ($AiSubscriptions.Count) {
    foreach ($a in @(Invoke-Arg -Label 'Advisor' -Query $kqlAdvisor -Subscriptions $AiSubscriptions)) {
        $item  = $null
        $ext   = $a.extendedProperties
        if ($a.impactedType -eq 'microsoft.subscriptions/subscriptions') {
            if (-not $AiSubSet.ContainsKey([string]$a.subscriptionId)) { continue }
            $blob = '{0} {1} {2}' -f $a.problem, $a.solution, (ConvertTo-Json -InputObject $ext -Compress -Depth 5)
            if ($blob -notmatch $AiAdvisorRegex) { continue }
        }
        else {
            $item = $ResIndex[(Get-TopLevelId $a.resourceId)]
            if (-not $item) { continue }   # stale recommendation of a resource that no longer exists
            $item.AdvisorCount++
        }
        $savings = ''
        if ($ext -and $ext.PSObject.Properties['annualSavingsAmount'] -and $ext.annualSavingsAmount) {
            $savings = '{0:N2} {1}/year' -f [double]$ext.annualSavingsAmount, $ext.savingsCurrency
        }
        $row = [pscustomobject]@{
            'Category'               = (Get-AdvisorCategory ([string]$a.category))
            'Impact'                 = $(if ($a.impact) { [string]$a.impact } else { 'Unknown' })
            'Service'                = $(if ($item) { $item.Service.Name } else { '(subscription)' })
            'Resource'               = $(if ($item) { $item.Name } else { Get-SubscriptionName ([string]$a.subscriptionId) })
            'Resource group'         = $(if ($item) { $item.ResourceGroup } else { '' })
            'Subscription'           = (Get-SubscriptionName ([string]$a.subscriptionId))
            'Recommendation'         = (ConvertTo-PlainText $a.problem 500)
            'Solution'               = (ConvertTo-PlainText $a.solution 500)
            'Sub-category'           = [string]$a.subCategory
            'Potential benefits'     = (ConvertTo-PlainText $a.potentialBenefits 500)
            'Potential savings'      = $savings
            'Status'                 = [string]$a.status
            'Last updated (UTC)'     = (ConvertTo-UtcDateTime $a.lastUpdated)
            'Learn more link'        = [string]$a.learnMoreLink
            'Resource ID'            = $(if ($item) { $item.Id } else { "/subscriptions/$($a.subscriptionId)" })
            'Recommendation type ID' = [string]$a.recommendationTypeId
        }
        $AdvisorRows.Add($row)

        $retireDate = $null
        if ($ext -and $ext.PSObject.Properties['retirementDate'] -and $ext.retirementDate) { $retireDate = ConvertTo-UtcDateTime $ext.retirementDate }
        if ($a.subCategory -eq 'ServiceUpgradeAndRetirement' -or $retireDate) {
            if (-not $retireDate) { $retireDate = Get-DateFromText ('{0} {1}' -f $a.problem, $a.solution) }
            $feature = if ($ext -and $ext.PSObject.Properties['retirementFeatureName'] -and $ext.retirementFeatureName) { "$($ext.retirementFeatureName): " } else { '' }
            $AdvisorRetirementRows.Add([pscustomobject]@{
                    'Source'             = 'Azure Advisor'
                    'Service'            = $row.Service
                    'Subscription'       = $row.Subscription
                    'Resource group'     = $row.'Resource group'
                    'Resource'           = $row.Resource
                    'Item'               = "$feature$($row.Recommendation)"
                    'Retirement date'    = $retireDate
                    'Days remaining'     = (Get-DaysUntil $retireDate)
                    'Risk'               = $(if ($retireDate) { Get-RetirementRisk $retireDate } else { 'REVIEW' })
                    'Impact'             = "Advisor impact: $($row.Impact)"
                    'Recommended action' = $row.Solution
                    'Link'               = $row.'Learn more link'
                    'Resource ID'        = $row.'Resource ID'
                })
        }
    }
}
$impactRank = @{ High = 0; Medium = 1; Low = 2 }
$AdvisorRows = @($AdvisorRows | Sort-Object -Property @{ Expression = { $x = $impactRank[$_.Impact]; if ($null -eq $x) { 9 } else { $x } } }, 'Category', 'Service', 'Resource')
# A failed query must not look like "no recommendations": per-resource counts become unknown.
$AdvisorOk = Test-ArgComplete 'Advisor'
if (-not $AdvisorOk) { foreach ($i in @(@($Resources) + @($HubProjects))) { $i.AdvisorCount = $null } }
Write-Host "        $($AdvisorRows.Count) active recommendation(s)$(if (-not $AdvisorOk) { ' - INCOMPLETE' })"

#endregion

#region 7. Azure Service Health ----------------------------------------------------------------

Write-Step "Collecting Azure Service Health events (active + last $EventDays days)"

$kqlEvents = @'
servicehealthresources
| where type =~ 'microsoft.resourcehealth/events'
| extend p = properties
| project subscriptionId, trackingId = name,
    eventType = tostring(p.EventType), eventSubType = tostring(p.EventSubType), status = tostring(p.Status),
    level = tostring(p.EventLevel), title = tostring(p.Title), summary = tostring(p.Summary),
    impact = p.Impact, impactStart = p.ImpactStartTime, impactMitigation = p.ImpactMitigationTime, lastUpdate = p.LastUpdateTime
'@
$kqlImpacted = @'
servicehealthresources
| where type =~ 'microsoft.resourcehealth/events/impactedresources'
| extend p = properties
| project id, subscriptionId, targetResourceId = tolower(tostring(p.targetResourceId))
'@

$HealthRows           = [System.Collections.Generic.List[object]]::new()
$HealthRetirementRows = [System.Collections.Generic.List[object]]::new()
if ($AiSubscriptions.Count) {
    $impactedByTracking = @{}
    foreach ($ir in @(Invoke-Arg -Label 'Service Health impacted resources' -Query $kqlImpacted -Subscriptions $AiSubscriptions)) {
        $tid  = ([string]$ir.id -split '/')[6]
        $item = $ResIndex[(Get-TopLevelId $ir.targetResourceId)]
        if (-not $tid -or -not $item) { continue }
        if (-not $impactedByTracking.ContainsKey($tid)) { $impactedByTracking[$tid] = [System.Collections.Generic.List[object]]::new() }
        $impactedByTracking[$tid].Add($item)
    }
    $cutoff = $RunStartedUtc.AddDays(-$EventDays)
    $events = @(Invoke-Arg -Label 'Service Health events' -Query $kqlEvents -Subscriptions $AiSubscriptions)
    foreach ($g in @($events | Group-Object -Property trackingId)) {
        $grp      = @($g.Group)
        $first    = $grp[0]
        $services = Join-Unique @($grp | ForEach-Object { @($_.impact) | Where-Object { $_ } | ForEach-Object { $_.ImpactedService } })
        $regions  = Join-Unique @($grp | ForEach-Object { @($_.impact) | Where-Object { $_ } | ForEach-Object { @($_.ImpactedRegions) | Where-Object { $_ } | ForEach-Object { $_.ImpactedRegion } } })
        $impacted = $impactedByTracking[[string]$g.Name]
        $isAi     = ($services -match $AiServiceRegex) -or ([string]$first.title -match $AiServiceRegex) -or [bool]$impacted
        if (-not $isAi -and -not $AllServiceHealthEvents) { continue }
        $status = if (@($grp | Where-Object { $_.status -eq 'Active' }).Count) { 'Active' } else { [string]$first.status }
        $last   = @($grp | ForEach-Object { ConvertTo-UtcDateTime $_.lastUpdate } | Where-Object { $_ } | Sort-Object -Descending)[0]
        if ($status -ne 'Active' -and $last -and $last -lt $cutoff) { continue }
        $title         = ConvertTo-PlainText $first.title 300
        $summary       = ConvertTo-PlainText $first.summary 1500
        $link          = Get-ServiceHealthLink -TrackingId ([string]$g.Name) -Subscription ([string]$first.subscriptionId)
        $impactedNames = if ($impacted) { Join-Unique @($impacted | ForEach-Object { $_.Name }) } else { '' }
        $subNames      = Join-Unique @($grp | ForEach-Object { Get-SubscriptionName ([string]$_.subscriptionId) })
        $HealthRows.Add([pscustomobject]@{
                'Event type'              = (Get-EventTypeLabel ([string]$first.eventType))
                'Status'                  = $status
                'Level'                   = [string]$first.level
                'Tracking ID'             = [string]$g.Name
                'Title'                   = $title
                'Impacted services'       = $services
                'Impacted regions'        = $regions
                'Subscriptions'           = $subNames
                'Impacted AI resources'   = $impactedNames
                'Impact start (UTC)'      = (ConvertTo-UtcDateTime $first.impactStart)
                'Impact mitigation (UTC)' = (ConvertTo-UtcDateTime $first.impactMitigation)
                'Last update (UTC)'       = $last
                'Sub-type'                = [string]$first.eventSubType
                'Summary'                 = $summary
                'Link'                    = $link
            })
        if ([string]$first.eventSubType -eq 'Retirement') {
            $rd = Get-DateFromText "$title $summary"
            # Name the services the way the rest of the workbook does, so the Summary counts them per service.
            $catalogNames = Join-Unique @(@($grp | ForEach-Object { @($_.impact) | Where-Object { $_ } | ForEach-Object { Get-CatalogServiceName ([string]$_.ImpactedService) } }) +
                @($impacted | Where-Object { $_ } | ForEach-Object { $_.Service.Name }))
            $HealthRetirementRows.Add([pscustomobject]@{
                    'Source'             = 'Azure Service Health'
                    'Service'            = $(if ($catalogNames) { $catalogNames } else { $services })
                    'Subscription'       = $subNames
                    'Resource group'     = ''
                    'Resource'           = $impactedNames
                    'Item'               = $title
                    'Retirement date'    = $rd
                    'Days remaining'     = (Get-DaysUntil $rd)
                    'Risk'               = $(if ($rd) { Get-RetirementRisk $rd } else { 'REVIEW' })
                    'Impact'             = "Health advisory ($status)"
                    'Recommended action' = 'Review the retirement advisory and plan the migration.'
                    'Link'               = $link
                    'Resource ID'        = ''
                })
        }
    }
}
$HealthRows = @($HealthRows | Sort-Object -Property @{ Expression = { if ($_.Status -eq 'Active') { 0 } else { 1 } } }, @{ Expression = 'Last update (UTC)'; Descending = $true })
$HealthOk = Test-ArgComplete 'Service Health events', 'Service Health impacted resources'
Write-Host "        $($HealthRows.Count) AI-related event(s)$(if (-not $HealthOk) { ' - INCOMPLETE' })"

#endregion

#region 8. Microsoft Defender for Cloud --------------------------------------------------------

Write-Step 'Collecting Microsoft Defender for Cloud plans, recommendations and alerts'

$kqlPricings = @'
securityresources
| where type =~ 'microsoft.security/pricings'
| where name in~ ('AI', 'CloudPosture')
| project subscriptionId, plan = tolower(name), tier = tostring(properties.pricingTier), subPlan = tostring(properties.subPlan),
    enablementTime = tostring(properties.enablementTime), extensions = properties.extensions
'@
$kqlAssessments = @'
securityresources
| where type =~ 'microsoft.security/assessments'
| extend p = properties
| extend resId = tolower(coalesce(tostring(p.resourceDetails.Id), tostring(p.resourceDetails.ResourceId), tostring(split(tolower(id), '/providers/microsoft.security/assessments/')[0])))
| where resId contains '/providers/microsoft.cognitiveservices/accounts/'
     or resId contains '/providers/microsoft.machinelearningservices/workspaces/'
     or resId contains '/providers/microsoft.search/searchservices/'
     or resId contains '/providers/microsoft.botservice/botservices/'
| project subscriptionId, resId, assessmentKey = name,
    displayName = tostring(p.displayName), status = tostring(p.status.code), cause = tostring(p.status.cause),
    severity = tostring(p.metadata.severity), categories = p.metadata.categories, threats = p.metadata.threats,
    userImpact = tostring(p.metadata.userImpact), implementationEffort = tostring(p.metadata.implementationEffort),
    remediation = tostring(p.metadata.remediationDescription), description = tostring(p.metadata.description),
    riskLevel = tostring(p.risk.level), riskFactors = p.risk.riskFactors,
    attackPaths = coalesce(array_length(p.risk.attackPathsReferences), 0),
    firstEvaluation = tostring(p.status.firstEvaluationDate), statusChange = tostring(p.status.statusChangeDate),
    portal = tostring(p.links.azurePortal)
'@
$kqlAlerts = @'
securityresources
| where type =~ 'microsoft.security/locations/alerts'
| extend p = properties
| extend ids = tolower(tostring(p.ResourceIdentifiers))
| where tostring(p.AlertType) startswith 'AI.'
     or ids contains 'microsoft.cognitiveservices/accounts'
     or ids contains 'microsoft.machinelearningservices/workspaces'
     or ids contains 'microsoft.search/searchservices'
     or ids contains 'microsoft.botservice/botservices'
| extend startTime = todatetime(p.StartTimeUtc)
| where startTime > ago(__DAYS__d)
| project subscriptionId, startTime, alertName = tostring(p.AlertDisplayName), alertType = tostring(p.AlertType),
    severity = tostring(p.Severity), status = tostring(p.Status), intent = tostring(p.Intent),
    description = tostring(p.Description), remediation = p.RemediationSteps, alertUri = tostring(p.AlertUri),
    resourceIdentifiers = p.ResourceIdentifiers
'@
$kqlAlerts = $kqlAlerts.Replace('__DAYS__', [string]$EventDays)

function Get-PlanState {
    param($Plan)
    if (-not $Plan) { return 'Unknown' }
    if ($Plan.tier -eq 'Standard') { return 'On (Standard)' }
    return 'Off (Free)'
}

function Format-PlanExtensions {
    param($Plan)
    if (-not $Plan -or -not $Plan.extensions) { return '' }
    return ((@($Plan.extensions) | Where-Object { $_ } | ForEach-Object { '{0}: {1}' -f $_.name, $(if ("$($_.isEnabled)" -eq 'True') { 'On' } else { 'Off' }) }) -join '; ')
}

$PlanRows       = [System.Collections.Generic.List[object]]::new()
$DefenderAiBySub = @{}   # subscription -> Defender for AI services plan state
$AssessmentRows = @()
$AlertRows      = @()
if ($AiSubscriptions.Count) {
    $pricing = @{}
    foreach ($p in @(Invoke-Arg -Label 'Defender plans' -Query $kqlPricings -Subscriptions $AiSubscriptions)) {
        $pricing['{0}|{1}' -f $p.subscriptionId, $p.plan] = $p
    }
    foreach ($sub in @($AiSubscriptions | Sort-Object { Get-SubscriptionName $_ })) {
        $ai        = $pricing["$sub|ai"]
        $cspm      = $pricing["$sub|cloudposture"]
        $aiState   = Get-PlanState $ai
        $DefenderAiBySub[$sub] = $aiState
        $cspmState = Get-PlanState $cspm
        $actions   = @()
        if ($aiState -eq 'Off (Free)') { $actions += 'Enable Microsoft Defender for AI services (threat protection for AI workloads).' }
        if ($cspmState -eq 'Off (Free)') { $actions += 'Enable Defender CSPM for AI security posture management (AI-BOM, attack paths).' }
        if ($aiState -eq 'Unknown' -or $cspmState -eq 'Unknown') { $actions += 'Plan status not readable (Security Reader required).' }
        $PlanRows.Add([pscustomobject]@{
                'Subscription'             = (Get-SubscriptionName $sub)
                'AI resources'             = @(@($Resources) + @($HubProjects) | Where-Object { $_.SubscriptionId -eq $sub }).Count
                'Defender for AI services' = $aiState
                'AI plan extensions'       = (Format-PlanExtensions $ai)
                'AI plan enabled (UTC)'    = $(if ($ai) { ConvertTo-UtcDateTime $ai.enablementTime } else { $null })
                'Defender CSPM'            = $cspmState
                'CSPM extensions'          = (Format-PlanExtensions $cspm)
                'Recommended action'       = $(if ($actions) { $actions -join ' ' } else { 'Coverage OK' })
                'Subscription ID'          = $sub
            })
    }

    $statusRank = @{ Unhealthy = 0; Healthy = 1; NotApplicable = 2 }
    $sevRank    = @{ High = 0; Medium = 1; Low = 2 }
    $assessments = foreach ($a in @(Invoke-Arg -Label 'Defender assessments' -Query $kqlAssessments -Subscriptions $AiSubscriptions)) {
        $top  = Get-TopLevelId $a.resId
        $item = $ResIndex[$top]
        if (-not $item) { continue }
        $status = if ($a.status) { [string]$a.status } else { 'Unknown' }
        if ($status -eq 'Unhealthy') { $item.DefenderUnhealthy++ }
        $portal = [string]$a.portal
        if ($portal -and $portal -notmatch '^https?://') { $portal = "https://$portal" }
        [pscustomobject]@{
            'Status'                = $status
            'Severity'              = $(if ($a.severity) { [string]$a.severity } else { 'Unknown' })
            'Recommendation'        = (ConvertTo-PlainText $a.displayName 300)
            'Service'               = $item.Service.Name
            'Resource'              = $(if ($top -ne [string]$a.resId) { '{0} / {1}' -f $item.Name, (Get-LastSegment $a.resId) } else { $item.Name })
            'Resource group'        = $item.ResourceGroup
            'Subscription'          = $item.Subscription
            'Risk level'            = [string]$a.riskLevel
            'Risk factors'          = (Join-Unique @($a.riskFactors))
            'Attack paths'          = [int]$a.attackPaths
            'Categories'            = (Join-Unique @($a.categories))
            'Threats'               = (Join-Unique @($a.threats))
            'User impact'           = [string]$a.userImpact
            'Implementation effort' = [string]$a.implementationEffort
            'Cause'                 = [string]$a.cause
            'Description'           = (ConvertTo-PlainText $a.description 1000)
            'Remediation'           = (ConvertTo-PlainText $a.remediation 1500)
            'First evaluated (UTC)' = (ConvertTo-UtcDateTime $a.firstEvaluation)
            'Status changed (UTC)'  = (ConvertTo-UtcDateTime $a.statusChange)
            'Assessment key'        = [string]$a.assessmentKey
            'Portal link'           = $portal
            'Resource ID'           = [string]$a.resId
        }
    }
    $AssessmentRows = @($assessments | Sort-Object -Property `
        @{ Expression = { $x = $statusRank[$_.Status]; if ($null -eq $x) { 9 } else { $x } } },
        @{ Expression = { $x = $sevRank[$_.Severity]; if ($null -eq $x) { 9 } else { $x } } },
        'Service', 'Resource', 'Recommendation')

    $alerts = foreach ($al in @(Invoke-Arg -Label 'Defender alerts' -Query $kqlAlerts -Subscriptions $AiSubscriptions)) {
        $ids  = @(@($al.resourceIdentifiers) | Where-Object { $_ -and $_.AzureResourceId } | ForEach-Object { [string]$_.AzureResourceId })
        $item = $null
        foreach ($rid in $ids) { $item = $ResIndex[(Get-TopLevelId $rid)]; if ($item) { break } }
        $remediation = (@($al.remediation) | Where-Object { $_ } | ForEach-Object { [string]$_ }) -join ' '
        [pscustomobject]@{
            'Start time (UTC)' = (ConvertTo-UtcDateTime $al.startTime)
            'Severity'         = [string]$al.severity
            'Status'           = [string]$al.status
            'Alert'            = (ConvertTo-PlainText $al.alertName 300)
            'Alert type'       = [string]$al.alertType
            'Service'          = $(if ($item) { $item.Service.Name } else { '' })
            'Resource'         = $(if ($item) { $item.Name } elseif ($ids) { Get-LastSegment $ids[0] } else { '' })
            'Subscription'     = (Get-SubscriptionName ([string]$al.subscriptionId))
            'Intent'           = [string]$al.intent
            'Description'      = (ConvertTo-PlainText $al.description 1000)
            'Remediation'      = (ConvertTo-PlainText $remediation 1000)
            'Alert link'       = [string]$al.alertUri
            'Resource ID'      = $(if ($item) { $item.Id } elseif ($ids) { $ids[0] } else { '' })
        }
    }
    $AlertRows = @($alerts | Sort-Object -Property 'Start time (UTC)' -Descending)
}
$PlansOk       = Test-ArgComplete 'Defender plans'
$AssessmentsOk = Test-ArgComplete 'Defender assessments'
$AlertsOk      = Test-ArgComplete 'Defender alerts'
if (-not $AssessmentsOk) { foreach ($i in @(@($Resources) + @($HubProjects))) { $i.DefenderUnhealthy = $null } }
$UnhealthyCount = @($AssessmentRows | Where-Object { $_.Status -eq 'Unhealthy' }).Count
Write-Host ("        {0} assessment(s) ({1} unhealthy), {2} alert(s){3}" -f $AssessmentRows.Count, $UnhealthyCount, $AlertRows.Count, $(if (-not ($PlansOk -and $AssessmentsOk -and $AlertsOk)) { ' - INCOMPLETE' }))

#endregion

#region 9. Shape report datasets --------------------------------------------------------------

Write-Step 'Shaping report datasets'

# --- Token cost per deployed model: Cost Management meters matched to the deployed models ---
$ModelCostRows   = [System.Collections.Generic.List[object]]::new()
$hostIndex       = @{}
foreach ($h in $modelHosts) { $hostIndex[$h.IdLower] = $h }
$serverlessIndex = @{}
foreach ($e in @($MlEndpoints | Where-Object { $_.Kind -eq 'serverless' })) { $serverlessIndex[$e.IdLower] = $e }

function Add-ModelCostRow {
    param($Owner, $CostRow, $Info, [string]$Model, [bool]$Matched, [double]$Share = 1.0, [bool]$IsModelHost)
    $script:ModelCostRows.Add([pscustomobject]@{
            'Service'               = $Owner.Service.Name
            'Subscription'          = $Owner.Subscription
            'Resource group'        = $Owner.ResourceGroup
            'Account'               = $Owner.Name
            'Region'                = $Owner.Region
            'Model'                 = $Model
            'Matched to deployment' = $Matched
            'Token type'            = $Info.TokenType
            'Deployment scope'      = $(if ($Info.Scope) { $Info.Scope } else { 'Unspecified' })
            'Meter'                 = $CostRow.Meter
            'Meter sub-category'    = $CostRow.MeterSubCategory
            'Meter category'        = $CostRow.MeterCategory
            'Quantity'              = $CostRow.Quantity * $Share
            'Actual cost'           = $(if ($null -ne $CostRow.ActualCost) { $CostRow.ActualCost * $Share } else { $null })
            'Amortized cost'        = $(if ($null -ne $CostRow.AmortizedCost) { $CostRow.AmortizedCost * $Share } else { $null })
            'Reservation name'      = [string]$CostRow.Reservation
            'Currency'              = $CostRow.Currency
            'Resource ID'           = $CostRow.ResourceId
            '_AccountId'            = (Get-TopLevelId $CostRow.ResourceId)
            '_ModelKey'             = $(if ($Matched -and $IsModelHost) { $Model.ToLowerInvariant() } else { $null })
            '_Scope'                = $Info.Scope
            '_VersionHint'          = $Info.VersionHint
        })
}

foreach ($c in $CostRows) {
    if ($c.Meter -notmatch '(?i)token|provisioned|\bptu\b|hosting') { continue }
    if ($c.MeterCategory -match '(?i)defender|security') { continue }   # e.g. Defender for AI services is billed per scanned token
    $top   = Get-TopLevelId $c.ResourceId
    $info  = Get-MeterInfo $c.Meter
    $owner = $null
    $model = $null
    $isModelHost = $hostIndex.ContainsKey($top)
    if ($isModelHost) {
        $owner = $hostIndex[$top]
        $cands = @($owner.Deployments | ForEach-Object { $_.Model } | Where-Object { $_ -and $_ -ne '(unknown)' } | Sort-Object -Unique)
        $model = Resolve-MeterModel -Core $info.CoreNormalized -Candidates $cands
        if (-not $model -and $info.TokenType -eq 'Provisioned (PTU)') {
            # PTU meters are model-agnostic: attribute them to the provisioned deployments of the
            # account (same scope, preferably the model family named by the meter sub-category) by capacity.
            $ptu = @($owner.Deployments | Where-Object { $_.'Deployment type' -match '(?i)provisioned' -and (-not $info.Scope -or $_._Scope -eq $info.Scope) })
            $subCat = Get-NormalizedName $c.MeterSubCategory
            $family = @($ptu | Where-Object { $_.'Model format' -and $subCat.Contains((Get-NormalizedName $_.'Model format')) })
            if ($family.Count) { $ptu = $family }
            $capTotal = [double](($ptu | ForEach-Object { [double]$_.Capacity } | Measure-Object -Sum).Sum)
            if ($ptu.Count -and $capTotal -gt 0) {
                foreach ($mg in @($ptu | Group-Object -Property Model)) {
                    $share = [double](($mg.Group | ForEach-Object { [double]$_.Capacity } | Measure-Object -Sum).Sum) / $capTotal
                    Add-ModelCostRow -Owner $owner -CostRow $c -Info $info -Model $mg.Name -Matched $true -Share $share -IsModelHost $true
                }
                continue
            }
        }
    }
    elseif ($serverlessIndex.ContainsKey($c.ResourceId)) {
        $ep    = $serverlessIndex[$c.ResourceId]
        $owner = $ep.WorkspaceItem
        $model = $ep.Model
    }
    else {
        $owner = $ResIndex[$top]
        if ($owner -and $owner.Type -ne 'microsoft.machinelearningservices/workspaces') { $owner = $null }
    }
    if (-not $owner) { continue }
    $matched = -not [string]::IsNullOrEmpty($model)
    if (-not $matched) {
        $model = if ($info.Core -and $c.MeterSubCategory) { '{0} ({1})' -f $info.Core, $c.MeterSubCategory } elseif ($info.Core) { $info.Core } elseif ($c.MeterSubCategory) { "$($c.Meter) ($($c.MeterSubCategory))" } else { $c.Meter }
    }
    Add-ModelCostRow -Owner $owner -CostRow $c -Info $info -Model $model -Matched $matched -IsModelHost $isModelHost
}

# --- Estimated cost per deployment: billed model cost of an account split across the deployments
#     of that model (same deployment scope when the meter tells it). Token meters are split by
#     token share across the pay-as-you-go deployments only (provisioned deployments are billed per
#     PTU-hour, never per token), PTU meters by provisioned capacity. When the current deployments show no usage
#     the cost came from deployments that no longer exist and stays unallocated. ---
$depsByAcctModel = @{}
foreach ($d in $ModelHostDeployments) {
    $k = '{0}|{1}' -f $d._AccountId, $d._ModelKey
    if (-not $depsByAcctModel.ContainsKey($k)) { $depsByAcctModel[$k] = [System.Collections.Generic.List[object]]::new() }
    $depsByAcctModel[$k].Add($d)
}
# Usage of deployments that no longer exist but still appear in the metrics (per account and model;
# '*' when the metric set carries no model name). It stays in the denominator so that their share
# of the billed cost remains unallocated instead of inflating the surviving deployments.
$orphanUsage = @{}
foreach ($acct in $modelHosts) {
    $res = $AcctResults[$acct.IdLower]
    if (-not $res -or $res.UsageError -or -not $res.Usage) { continue }
    $current = @{}
    foreach ($d in @($acct.Deployments)) { $current[([string]$d.Deployment).ToLowerInvariant()] = $true }
    foreach ($k in @($res.Usage.Keys)) {
        if ($current.ContainsKey($k)) { continue }
        $u  = $res.Usage[$k]
        $ok = '{0}|{1}' -f $acct.IdLower, $(if ($u.Model) { ([string]$u.Model).ToLowerInvariant() } else { '*' })
        if (-not $orphanUsage.ContainsKey($ok)) { $orphanUsage[$ok] = @{ In = 0.0; Out = 0.0; Total = 0.0 } }
        $orphanUsage[$ok].In    += $u.In
        $orphanUsage[$ok].Out   += $u.Out
        $orphanUsage[$ok].Total += $(if ($u.Total) { $u.Total } else { $u.In + $u.Out })
    }
}
$weightSlot    = @{ 'Input' = 'In'; 'Cached input' = 'In'; 'Cache write' = 'In'; 'Output' = 'Out' }
$weightColumn  = @{ In = 'Input tokens'; Out = 'Output tokens'; Total = 'Total tokens' }
$costMeasures  = @(
    @{ Name = 'Actual'; RowColumn = 'Actual cost'; DeploymentColumn = 'Est. actual cost'; OkSubs = $ActualOkSubs },
    @{ Name = 'Amortized'; RowColumn = 'Amortized cost'; DeploymentColumn = 'Est. amortized cost'; OkSubs = $AmortizedOkSubs }
)
function Add-MeasureValue {
    param([hashtable]$Map, [string]$Key, [string]$Measure, [double]$Value)
    if (-not $Map.ContainsKey($Key)) { $Map[$Key] = @{ Actual = 0.0; Amortized = 0.0 } }
    $Map[$Key][$Measure] += $Value
}
$allocatedByKey = @{}   # account|model -> allocated actual / amortized cost
$costGroups = @($ModelCostRows | Where-Object { $_._ModelKey } | Group-Object -Property {
        '{0}|{1}|{2}|{3}|{4}' -f $_._AccountId, $_._ModelKey, $_._Scope, $_.'Token type', $_._VersionHint })
foreach ($g in $costGroups) {
    $f     = $g.Group[0]
    $type  = [string]$f.'Token type'
    $isPtu = $type -eq 'Provisioned (PTU)'
    $key   = '{0}|{1}' -f $f._AccountId, $f._ModelKey
    $list  = $depsByAcctModel[$key]
    $cands = if ($list) { @($list) } else { @() }
    if ($f._Scope) { $cands = @($cands | Where-Object { $_._Scope -eq $f._Scope }) }
    if ($isPtu) { $cands = @($cands | Where-Object { $_.'Deployment type' -match '(?i)provisioned' }) }
    else { $cands = @($cands | Where-Object { $_.'Deployment type' -notmatch '(?i)provisioned' }) }
    if ($f._VersionHint) {
        # meters such as gpt-4o-0806-... name the model version (MMDD)
        $byVersion = @($cands | Where-Object { ([string]$_.'Model version' -replace '\D', '').EndsWith($f._VersionHint) })
        if ($byVersion.Count) { $cands = $byVersion }
    }
    if ($cands.Count -eq 0) { continue }
    $slot    = if ($weightSlot.ContainsKey($type)) { $weightSlot[$type] } else { 'Total' }
    $weights = @($cands | ForEach-Object { if ($isPtu) { [double]$_.Capacity } else { [double]$_.($weightColumn[$slot]) } })
    $weightTotal = [double](($weights | Measure-Object -Sum).Sum)
    if (-not $isPtu) {
        foreach ($ok in ('{0}|{1}' -f $f._AccountId, $f._ModelKey), ('{0}|*' -f $f._AccountId)) {
            if ($orphanUsage.ContainsKey($ok)) { $weightTotal += [double]$orphanUsage[$ok][$slot] }
        }
    }
    if ($weightTotal -le 0) { continue }
    $reservations = @($g.Group | ForEach-Object { ([string]$_.'Reservation name') -split ';\s*' } | Where-Object { $_ } | Sort-Object -Unique)
    for ($i = 0; $i -lt $cands.Count; $i++) {
        if ($weights[$i] -eq 0) { continue }
        $d = $cands[$i]
        foreach ($cm in $costMeasures) {
            $known = @($g.Group | Where-Object { $null -ne $_.($cm.RowColumn) })
            if ($known.Count -eq 0) { continue }
            $share = [double](($known | Measure-Object -Property $cm.RowColumn -Sum).Sum) * $weights[$i] / $weightTotal
            $d.($cm.DeploymentColumn) = [double]$d.($cm.DeploymentColumn) + $share
            Add-MeasureValue -Map $allocatedByKey -Key $key -Measure $cm.Name -Value $share
        }
        if ($reservations.Count) { $d.'Reservation name' = Join-Unique (@(([string]$d.'Reservation name') -split ';\s*') + $reservations) '; ' }
        $d.Currency = $f.Currency
    }
}
$modelCostByKey  = @{}   # account|model -> billed actual / amortized model cost
$unmatchedByAcct = @{}   # account       -> model cost that could not be tied to a deployed model
foreach ($x in $ModelCostRows) {
    if (-not $hostIndex.ContainsKey($x._AccountId)) { continue }
    foreach ($cm in $costMeasures) {
        if ($x._ModelKey) { Add-MeasureValue -Map $modelCostByKey -Key ('{0}|{1}' -f $x._AccountId, $x._ModelKey) -Measure $cm.Name -Value ([double]$x.($cm.RowColumn)) }
        else { Add-MeasureValue -Map $unmatchedByAcct -Key $x._AccountId -Measure $cm.Name -Value ([double]$x.($cm.RowColumn)) }
    }
}
foreach ($d in $ModelHostDeployments) {
    if ($null -eq $d.'Total tokens') { continue }
    $sub = $d._Account.SubscriptionId
    $k = '{0}|{1}' -f $d._AccountId, $d._ModelKey
    # A known zero: a pay-as-you-go deployment without any traffic, or a model whose billed cost is fully accounted for.
    # Zero tokens alone is not enough: image, audio and video models report requests but no tokens.
    $noTokens = [double]$d.'Total tokens' -eq 0 -and ($null -eq $d.Requests -or [double]$d.Requests -eq 0) -and
                $d.'Deployment type' -notmatch '(?i)provisioned'
    # Fine-tuned deployments pay an hourly hosting fee that is not attributed per deployment: never a known zero.
    if ([string]$d.Model -match '(?i)\.ft-|^ft:') { continue }
    foreach ($cm in $costMeasures) {
        if ($null -ne $d.($cm.DeploymentColumn) -or -not $cm.OkSubs.ContainsKey($sub)) { continue }
        $billed    = if ($modelCostByKey.ContainsKey($k)) { $modelCostByKey[$k][$cm.Name] } else { 0.0 }
        $allocated = if ($allocatedByKey.ContainsKey($k)) { $allocatedByKey[$k][$cm.Name] } else { 0.0 }
        $unmatched = if ($unmatchedByAcct.ContainsKey($d._AccountId)) { $unmatchedByAcct[$d._AccountId][$cm.Name] } else { 0.0 }
        if ($noTokens -or [Math]::Abs($billed - $allocated + $unmatched) -lt 0.000001) {
            $d.($cm.DeploymentColumn) = 0.0
            if (-not $d.Currency) { $d.Currency = [string]$CurrencyBySub[$sub] }
        }
    }
}

# --- Deployed models of hub-based projects / Azure Machine Learning (serverless + managed online) ---
$MlDeploymentRecords = @(foreach ($e in @($MlEndpoints | Where-Object { $_.Kind -in 'serverless', 'onlinedeployment' })) {
        $ws = $e.WorkspaceItem
        [pscustomobject]@{
            'Platform'           = $(if ($ws -and $ws.ServiceKey -eq 'AIHubs') { 'AI Hubs' } else { 'Machine Learning' })
            'Subscription'       = $e.Subscription
            'Resource group'     = $e.ResourceGroup
            'Account'            = $e.WorkspaceName
            'Region'             = $e.Region
            'Deployment'         = $(if ($e.DeploymentName) { '{0}/{1}' -f $e.EndpointName, $e.DeploymentName } else { $e.EndpointName })
            'Model'              = $(if ($e.Model) { $e.Model } else { '(custom)' })
            'Model version'      = $e.ModelVersion
            'Model format'       = $e.ModelSource
            'Deployment type'    = $(if ($e.Kind -eq 'serverless') { 'Serverless API' } else { 'Managed compute' })
            'Capacity'           = $e.Capacity
            'Provisioning state' = $e.ProvisioningState
            'Retirement risk'    = 'NOT APPLICABLE'
            'Est. actual cost'    = $e.ActualCost
            'Est. amortized cost' = $e.AmortizedCost
            'Reservation name'   = $e.Reservation
            'Currency'           = $(if ($null -ne $e.ActualCost -or $null -ne $e.AmortizedCost) { [string]$CurrencyBySub[$e.SubscriptionId] } else { '' })
            'Deployment ID'      = $e.Id
        }
    })

$DeploymentColumns = @('Platform', 'Subscription', 'Resource group', 'Account', 'Region', 'Deployment', 'Model', 'Model version',
    'Model format', 'Deployment type', 'Capacity', 'Tokens per minute', 'Version upgrade', 'Content filter', 'Content filter assessment', 'Provisioning state',
    'Lifecycle', 'Retirement date', 'Days to retirement', 'Retirement risk', 'Retirement impact', 'Suggested upgrade',
    'Input tokens', 'Output tokens', 'Total tokens', 'Requests',
    'Peak TPM (busiest hour)', 'Peak % of TPM limit', 'Throttled requests (429)', 'PTU utilization avg', 'PTU utilization peak',
    'Last request date', 'Idle days', 'Quota', 'Quota used %', 'Spillover deployment', 'Right-sizing', 'Right-sizing advice',
    'Est. actual cost', 'Est. amortized cost', 'Reservation name', 'Currency',
    'Created (UTC)', 'Created by', 'Deployment ID')
$DataDeployments = @(@($ModelHostDeployments) + @($MlDeploymentRecords) | Where-Object { $_ } | Select-Object -Property $DeploymentColumns)

# --- Service retirements: model lifecycle + Advisor + Service Health + classic services ---
$RetirementRows = [System.Collections.Generic.List[object]]::new()
foreach ($d in $ModelHostDeployments) {
    $deprecated = $d.Lifecycle -in 'Deprecating', 'Deprecated'
    if (-not $d.'Retirement date' -and -not $deprecated) { continue }
    $action = if ($d.'Suggested upgrade') { "Upgrade the deployment to $($d.'Suggested upgrade')." }
              elseif ($d.'Version upgrade' -eq 'NoAutoUpgrade') { 'Version is pinned: migrate to a newer model before the retirement date.' }
              else { 'Auto-upgrade moves the deployment to the next default version; validate compatibility.' }
    $RetirementRows.Add([pscustomobject]@{
            'Source'             = 'Model lifecycle (model catalog)'
            'Service'            = $d._Account.Service.Name
            'Subscription'       = $d.Subscription
            'Resource group'     = $d.'Resource group'
            'Resource'           = $d.Account
            'Item'               = "Model $($d.Model) $($d.'Model version') ($($d.'Deployment type')), deployment '$($d.Deployment)'"
            'Retirement date'    = $d.'Retirement date'
            'Days remaining'     = $d.'Days to retirement'
            'Risk'               = $(if ($d.'Retirement date') { $d.'Retirement risk' } else { 'REVIEW' })
            'Impact'             = $(if ($d.'Retirement impact') { $d.'Retirement impact' } elseif (-not $d.'Retirement date') { "Lifecycle: $($d.Lifecycle), no retirement date published" } else { "Lifecycle: $($d.Lifecycle)" })
            'Recommended action' = $action
            'Link'               = $(if ($d.'Model format' -eq 'OpenAI') { 'https://learn.microsoft.com/azure/ai-foundry/openai/concepts/model-retirements' } else { 'https://learn.microsoft.com/azure/ai-foundry/concepts/model-lifecycle-retirement' })
            'Resource ID'        = $d.'Deployment ID'
        })
}
$RetirementRows.AddRange($AdvisorRetirementRows)
$RetirementRows.AddRange($HealthRetirementRows)
foreach ($item in @($Resources | Where-Object { $_.Service.Group -eq $G3 })) {
    $svc = $item.Service
    $RetirementRows.Add([pscustomobject]@{
            'Source'             = 'Service lifecycle (Microsoft Learn)'
            'Service'            = $svc.Name
            'Subscription'       = $item.Subscription
            'Resource group'     = $item.ResourceGroup
            'Resource'           = $item.Name
            'Item'               = "Classic service: $($svc.Name)"
            'Retirement date'    = $svc.RetireDate
            'Days remaining'     = (Get-DaysUntil $svc.RetireDate)
            'Risk'               = $(if ($svc.RetireDate) { Get-RetirementRisk $svc.RetireDate } else { 'REVIEW' })
            'Impact'             = $(if ($svc.RetireDate -and $svc.RetireDate -lt $TodayUtc) { 'Service retired - requests fail or will fail' } elseif ($svc.RetireDate) { 'Service stops working at the retirement date' } else { 'Superseded - no retirement date announced' })
            'Recommended action' = $svc.Guidance
            'Link'               = $svc.Link
            'Resource ID'        = $item.Id
        })
}
$riskRank = @{ RETIRED = 0; CRITICAL = 1; WARNING = 2; REVIEW = 3; OK = 4 }
$RetirementRows = @($RetirementRows | Sort-Object -Property `
    @{ Expression = { if ($null -eq $_.'Days remaining') { [int]::MaxValue } else { $_.'Days remaining' } } },
    @{ Expression = { $x = $riskRank[$_.Risk]; if ($null -eq $x) { 9 } else { $x } } },
    'Service', 'Resource')

# --- Row builders for the per-service sheets ---
function Add-CommonColumns {
    param([System.Collections.Specialized.OrderedDictionary]$Row, $Item)
    $Row['Actual cost']             = $Item.ActualCost
    $Row['Amortized cost']          = $Item.AmortizedCost
    $Row['Reservation name']        = $Item.Reservation
    $Row['Currency']                = $Item.Currency
    $Row['Advisor recommendations'] = $Item.AdvisorCount
    $Row['Defender unhealthy']      = $Item.DefenderUnhealthy
    $Row['Tags']                    = Format-Tags $Item.Raw.tags
    $Row['Resource ID']             = $Item.Id
    $Row['Portal']                  = Get-PortalLink $Item.Id
    return [pscustomobject]$Row
}

function Get-CognitiveRow {
    param($Item)
    $r = $Item.Raw
    $row = [ordered]@{
        'Subscription'           = $Item.Subscription
        'Resource group'         = $Item.ResourceGroup
        'Name'                   = $Item.Name
        'Region'                 = $Item.Region
        'Kind'                   = $Item.Kind
        'SKU'                    = [string]$r.skuName
        'Provisioning state'     = [string]$r.provisioningState
        'Endpoint'               = [string]$r.endpoint
        'Custom subdomain'       = [string]$r.customSubDomainName
        'Public network access'  = (Get-PublicAccess ([string]$r.publicNetworkAccess))
        'Network default action' = $(if ($r.networkDefaultAction) { [string]$r.networkDefaultAction } else { 'Allow' })
        'IP rules'               = [int]$r.ipRules
        'VNet rules'             = [int]$r.vnetRules
        'Private endpoints'      = [int]$r.privateEndpoints
        'Local auth disabled'    = [bool]$r.disableLocalAuth
        'Managed identity'       = (Get-IdentityLabel ([string]$r.identityType))
        'Encryption'             = $(if ($r.encryptionKeySource -eq 'Microsoft.KeyVault') { 'Customer-managed key' } else { 'Microsoft-managed key' })
        'Outbound restricted'    = [bool]$r.restrictOutbound
    }
    if ($Item.Kind -in 'OpenAI', 'AIServices') {
        $row['Model deployments'] = $(if ($Item.DeploymentsError) { $null } else { @($Item.Deployments).Count })
        $row['Models']            = Join-Unique @($Item.Deployments | ForEach-Object { '{0} {1}' -f $_.Model, $_.'Model version' })
        $row['Input tokens']      = $Item.InputTokens
        $row['Output tokens']     = $Item.OutputTokens
        $row['Requests']          = $Item.Requests
    }
    if ($Item.Kind -eq 'AIServices') {
        $row['Project management']      = [bool]$r.allowProjectManagement
        $row['Projects']                = $(if ($Item.ProjectsError) { $null } else { @($Item.Projects).Count })
        $row['Default project']         = [string]$r.defaultProject
        $row['Agent network injection'] = Format-NetworkInjection $r.networkInjections
    }
    $row['API calls'] = $Item.Calls
    if ($Item.Service.Group -eq $G3) {
        $row['Retirement date']    = $Item.Service.RetireDate
        $row['Days to retirement'] = Get-DaysUntil $Item.Service.RetireDate
    }
    $row['Created (UTC)'] = ConvertTo-UtcDateTime $r.dateCreated
    return Add-CommonColumns -Row $row -Item $Item
}

function Get-WorkspaceRow {
    param($Item)
    $r = $Item.Raw
    $row = [ordered]@{
        'Subscription'          = $Item.Subscription
        'Resource group'        = $Item.ResourceGroup
        'Name'                  = $Item.Name
        'Friendly name'         = [string]$r.friendlyName
        'Region'                = $Item.Region
        'Kind'                  = $(if ($Item.Kind) { $Item.Kind } else { 'Default' })
        'SKU'                   = [string]$r.skuName
        'Provisioning state'    = [string]$r.provisioningState
        'Public network access' = (Get-PublicAccess ([string]$r.publicNetworkAccess))
        'Managed network'       = $(if ($r.isolationMode) { [string]$r.isolationMode } else { 'Disabled' })
        'Private endpoints'     = [int]$r.privateEndpoints
        'Managed identity'      = (Get-IdentityLabel ([string]$r.identityType))
        'Storage account'       = (Get-LastSegment ([string]$r.storageAccount))
        'Key vault'             = (Get-LastSegment ([string]$r.keyVault))
        'Application Insights'  = (Get-LastSegment ([string]$r.applicationInsights))
        'Container registry'    = (Get-LastSegment ([string]$r.containerRegistry))
        'Encryption'            = $(if ($r.encryptionStatus -eq 'Enabled') { 'Customer-managed key' } else { 'Microsoft-managed key' })
        'High business impact'  = [bool]$r.hbiWorkspace
        'Datastore auth mode'   = [string]$r.systemDatastoresAuthMode
    }
    if ($Item.ServiceKey -eq 'AIHubs') {
        $row['Projects']      = @($Item.Projects).Count
        $row['Endpoints']     = @(@($Item.Endpoints) + @($Item.Projects | ForEach-Object { @($_.Endpoints) }) | Where-Object { $_ -and $_.Kind -ne 'onlinedeployment' }).Count
        $row['Projects actual cost']    = $Item.ProjectsActualCost
        $row['Projects amortized cost'] = $Item.ProjectsAmortizedCost
    }
    else {
        $row['v1 legacy mode'] = [bool]$r.v1LegacyMode
        $row['Endpoints']      = @($Item.Endpoints | Where-Object { $_ -and $_.Kind -ne 'onlinedeployment' }).Count
    }
    $row['Created (UTC)'] = ConvertTo-UtcDateTime $r.creationTime
    return Add-CommonColumns -Row $row -Item $Item
}

function Get-HubProjectRow {
    param($Item)
    $r = $Item.Raw
    $row = [ordered]@{
        'Hub'                   = $(if ($Item.Hub) { $Item.Hub.Name } else { '(hub not found)' })
        'Subscription'          = $Item.Subscription
        'Resource group'        = $Item.ResourceGroup
        'Project'               = $Item.Name
        'Friendly name'         = [string]$r.friendlyName
        'Region'                = $Item.Region
        'Provisioning state'    = [string]$r.provisioningState
        'Public network access' = (Get-PublicAccess ([string]$r.publicNetworkAccess))
        'Managed identity'      = (Get-IdentityLabel ([string]$r.identityType))
        'Endpoints'             = @($Item.Endpoints | Where-Object { $_ -and $_.Kind -ne 'onlinedeployment' }).Count
        'Created (UTC)'         = (ConvertTo-UtcDateTime $r.creationTime)
    }
    return Add-CommonColumns -Row $row -Item $Item
}

function Get-EndpointRow {
    param($Ep)
    $wsKind = if ($Ep.WorkspaceItem) { if ($Ep.WorkspaceItem.Kind) { $Ep.WorkspaceItem.Kind } else { 'Default' } } else { '' }
    [pscustomobject]@{
        'Workspace'             = $Ep.WorkspaceName
        'Workspace kind'        = $wsKind
        'Type'                  = $Ep.TypeLabel
        'Endpoint'              = $Ep.EndpointName
        'Deployment'            = $Ep.DeploymentName
        'Model'                 = $Ep.Model
        'Model version'         = $Ep.ModelVersion
        'Model source'          = $Ep.ModelSource
        'SKU / instance type'   = $Ep.Sku
        'Capacity'              = $Ep.Capacity
        'Auth mode'             = $Ep.AuthMode
        'Public network access' = $Ep.PublicNetworkAccess
        'Provisioning state'    = $Ep.ProvisioningState
        'Endpoint URI'          = $Ep.EndpointUri
        'Region'                = $Ep.Region
        'Subscription'          = $Ep.Subscription
        'Resource group'        = $Ep.ResourceGroup
        'Actual cost'           = $Ep.ActualCost
        'Amortized cost'        = $Ep.AmortizedCost
        'Reservation name'      = $Ep.Reservation
        'Resource ID'           = $Ep.Id
        'Portal'                = (Get-PortalLink $Ep.Id)
    }
}

function Get-SearchRow {
    param($Item)
    $r = $Item.Raw
    $auth = if ([bool]$r.disableLocalAuth) { 'Microsoft Entra ID only' }
            elseif ($r.authOptions) { (@($r.authOptions.PSObject.Properties.Name) -join ', ') }
            else { 'API keys' }
    $row = [ordered]@{
        'Subscription'          = $Item.Subscription
        'Resource group'        = $Item.ResourceGroup
        'Name'                  = $Item.Name
        'Region'                = $Item.Region
        'SKU'                   = [string]$r.skuName
        'Status'                = [string]$r.status
        'Provisioning state'    = [string]$r.provisioningState
        'Replicas'              = [int]$r.replicaCount
        'Partitions'            = [int]$r.partitionCount
        'Search units'          = ([int]$r.replicaCount * [int]$r.partitionCount)
        'Hosting mode'          = [string]$r.hostingMode
        'Public network access' = (Get-PublicAccess ([string]$r.publicNetworkAccess))
        'IP rules'              = [int]$r.ipRules
        'Network bypass'        = [string]$r.networkBypass
        'Private endpoints'     = [int]$r.privateEndpoints
        'Shared private links'  = [int]$r.sharedPrivateLinks
        'Local auth disabled'   = [bool]$r.disableLocalAuth
        'Authentication'        = $auth
        'Semantic ranker'       = $(if ($r.semanticSearch) { [string]$r.semanticSearch } else { '(not set)' })
        'CMK enforcement'       = $(if ($r.cmkEnforcement) { [string]$r.cmkEnforcement } else { 'Unspecified' })
        'Managed identity'      = (Get-IdentityLabel ([string]$r.identityType))
        'Endpoint'              = $(if ($IsPublicCloud) { "https://$($Item.Name).search.windows.net" } else { '' })
    }
    return Add-CommonColumns -Row $row -Item $Item
}

function Get-BotRow {
    param($Item)
    $r = $Item.Raw
    $row = [ordered]@{
        'Subscription'            = $Item.Subscription
        'Resource group'          = $Item.ResourceGroup
        'Name'                    = $Item.Name
        'Display name'            = [string]$r.displayName
        'Kind'                    = $Item.Kind
        'Region'                  = $Item.Region
        'SKU'                     = [string]$r.skuName
        'Messaging endpoint'      = [string]$r.endpoint
        'App type'                = [string]$r.msaAppType
        'App ID'                  = [string]$r.msaAppId
        'App tenant ID'           = [string]$r.msaAppTenantId
        'Public network access'   = (Get-PublicAccess ([string]$r.publicNetworkAccess))
        'Local auth disabled'     = [bool]$r.disableLocalAuth
        'CMK encryption'          = [bool]$r.isCmekEnabled
        'Channels'                = (Join-Unique @($r.configuredChannels))
        'App Insights configured' = [bool]$r.appInsightsConfigured
        'Streaming endpoint'      = [bool]$r.isStreamingSupported
        'Private endpoints'       = [int]$r.privateEndpoints
        'Provisioning state'      = [string]$r.provisioningState
    }
    return Add-CommonColumns -Row $row -Item $Item
}

function Get-ServiceRows {
    param($Service, [object[]]$Items)
    foreach ($i in @($Items | Sort-Object -Property Subscription, ResourceGroup, Name)) {
        switch ($Service.Family) {
            'Cognitive' { Get-CognitiveRow $i }
            'MLHub'     { Get-WorkspaceRow $i }
            'ML'        { Get-WorkspaceRow $i }
            'Search'    { Get-SearchRow $i }
            'Bot'       { Get-BotRow $i }
        }
    }
}

# --- Flat pivot sources + summary ---
function Get-WithProjects {
    # A hub row carries the figures of its hub-based projects, as it does for cost.
    param($Item, [string]$Property)
    if ($null -eq $Item.$Property) { return $null }
    if ($Item.ServiceKey -ne 'AIHubs') { return $Item.$Property }
    return [int]$Item.$Property + [int]((@($Item.Projects | Where-Object { $_ } | ForEach-Object { [int]$_.$Property }) + 0 | Measure-Object -Sum).Sum)
}
$DataResources = @(foreach ($i in $Resources) {
        [pscustomobject]@{
            'Group'                   = $i.Service.Group
            'Service'                 = $i.Service.Name
            'Subscription'            = $i.Subscription
            'Resource group'          = $i.ResourceGroup
            'Resource'                = $i.Name
            'Region'                  = $i.Region
            'Kind'                    = $(if ($i.Kind) { $i.Kind } else { '(none)' })
            'SKU'                     = [string]$i.Raw.skuName
            'Public network access'   = (Get-PublicAccess ([string]$i.Raw.publicNetworkAccess))
            'Private endpoints'       = [int]$i.Raw.privateEndpoints
            'Actual cost'             = $(if ($null -ne $i.ActualCost) { $i.ActualCost + [double]$i.ProjectsActualCost } else { $null })
            'Amortized cost'          = $(if ($null -ne $i.AmortizedCost) { $i.AmortizedCost + [double]$i.ProjectsAmortizedCost } else { $null })
            'Reservation name'        = $(if ($i.Reservation) { $i.Reservation } else { '(none)' })
            'Currency'                = $(if ($i.Currency) { $i.Currency } else { '(none)' })
            'Advisor recommendations' = (Get-WithProjects $i 'AdvisorCount')
            'Defender unhealthy'      = (Get-WithProjects $i 'DefenderUnhealthy')
            'Resource ID'             = $i.Id
        }
    })

$retireCountByService = @{}
foreach ($x in $RetirementRows) {
    # A Service Health advisory can name several services: it counts once for each of them.
    foreach ($n in @(([string]$x.Service) -split ',\s*' | Where-Object { $_ } | Sort-Object -Unique)) { $retireCountByService[$n] = 1 + [int]$retireCountByService[$n] }
}
$SummaryRows = @(foreach ($svc in $ServiceCatalog) {
        $items = @($Resources | Where-Object { $_.ServiceKey -eq $svc.Key })
        # Hub-based projects are listed on the AI Hubs sheet: their cost, recommendations and findings belong to that service.
        $rollup = @(if ($svc.Key -eq 'AIHubs') { @($items) + @($HubProjects) } else { $items })
        $deps = switch ($svc.Key) {
            'Foundry'         { @($ModelHostDeployments | Where-Object { $_.Platform -eq $svc.Name }).Count }
            'AzureOpenAI'     { @($ModelHostDeployments | Where-Object { $_.Platform -eq $svc.Name }).Count }
            'AIHubs'          { @($MlDeploymentRecords | Where-Object { $_.Platform -eq 'AI Hubs' }).Count }
            'MachineLearning' { @($MlDeploymentRecords | Where-Object { $_.Platform -eq 'Machine Learning' }).Count }
            default           { $null }
        }
        $costItems      = @($rollup | Where-Object { $null -ne $_.ActualCost -or $null -ne $_.AmortizedCost })
        # Zero amounts do not make a currency mix; only sum a service when its costs share one currency.
        $costCurrencies = @($costItems | Where-Object { ([double]$_.ActualCost + [double]$_.AmortizedCost) -ne 0 } |
            ForEach-Object { $_.Currency } | Where-Object { $_ } | Sort-Object -Unique)
        if ($costCurrencies.Count -eq 0) { $costCurrencies = @($costItems | ForEach-Object { $_.Currency } | Where-Object { $_ } | Sort-Object -Unique | Select-Object -First 1) }
        $singleCurrency = $costCurrencies.Count -le 1
        $actualItems    = @($rollup | Where-Object { $null -ne $_.ActualCost })
        $amortizedItems = @($rollup | Where-Object { $null -ne $_.AmortizedCost })
        [pscustomobject]@{
            'Service'                 = $svc.Name
            'Group'                   = $svc.Group
            'Resources'               = $items.Count
            'Regions'                 = @($items | ForEach-Object { $_.Region } | Sort-Object -Unique).Count
            'Subscriptions'           = @($items | ForEach-Object { $_.SubscriptionId } | Sort-Object -Unique).Count
            'Model deployments'       = $deps
            'Actual cost'             = $(if ($actualItems.Count -and $singleCurrency) { [double](($actualItems | ForEach-Object { [double]$_.ActualCost } | Measure-Object -Sum).Sum) } else { $null })
            'Amortized cost'          = $(if ($amortizedItems.Count -and $singleCurrency) { [double](($amortizedItems | ForEach-Object { [double]$_.AmortizedCost } | Measure-Object -Sum).Sum) } else { $null })
            'Reservation name'        = (Join-Unique @($rollup | ForEach-Object { ([string]$_.Reservation) -split ';\s*' }) '; ')
            'Currency'                = $(if (-not $singleCurrency) { 'mixed - see sheet' } elseif ($costCurrencies.Count) { $costCurrencies[0] } else { '' })
            'Advisor recommendations' = $(if ($AdvisorOk) { [int](($rollup | Measure-Object -Property AdvisorCount -Sum).Sum) } else { $null })
            'Defender unhealthy'      = $(if ($AssessmentsOk) { [int](($rollup | Measure-Object -Property DefenderUnhealthy -Sum).Sum) } else { $null })
            'Retirement items'        = [int]$retireCountByService[$svc.Name]
            'Sheet'                   = $svc.Sheet
        }
    })
# What the KPI tiles count but no service row can hold: cost of resources not on the service sheets,
# subscription-level Advisor recommendations and retirement items that name no service of the catalog.
$catalogNameSet = @{}
foreach ($svc in $ServiceCatalog) { $catalogNameSet[$svc.Name] = $true }
$UnattributedAdvisor     = @($AdvisorRows | Where-Object { $_.Service -eq '(subscription)' }).Count
$UnattributedRetirements = @($RetirementRows | Where-Object { -not @(([string]$_.Service) -split ',\s*' | Where-Object { $catalogNameSet.ContainsKey($_) }).Count }).Count

# --- Security hygiene: one row per primary AI resource --------------------------------------------
function Get-CallerType {
    param([string]$Caller)
    if ($Caller -match '@') { return 'User' }
    if ($Caller -match '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$') { return 'App' }
    return 'Other'
}

function Get-DiagnosticProfile {
    # 'All logs' = the allLogs category group, or every log category listed on the settings enabled.
    param($Settings)
    $enabledCats   = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $listedCats    = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $enabledGroups = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $metrics = $false
    $dest    = [System.Collections.Generic.List[string]]::new()
    $list    = @($Settings | Where-Object { $_ })
    foreach ($s in $list) {
        $p = $s.properties
        foreach ($l in @($p.logs | Where-Object { $_ })) {
            $on = "$($l.enabled)" -eq 'True'
            if ($l.category) {
                [void]$listedCats.Add([string]$l.category)
                if ($on) { [void]$enabledCats.Add([string]$l.category) }
            }
            elseif ($l.categoryGroup -and $on) { [void]$enabledGroups.Add([string]$l.categoryGroup) }
        }
        foreach ($m in @($p.metrics | Where-Object { $_ })) { if ("$($m.enabled)" -eq 'True') { $metrics = $true } }
        if ($p.workspaceId)                 { $dest.Add('Log Analytics') }
        if ($p.storageAccountId)            { $dest.Add('Storage account') }
        if ($p.eventHubAuthorizationRuleId) { $dest.Add('Event Hub') }
        if ($p.marketplacePartnerId)        { $dest.Add('Partner solution') }
    }
    $status = if ($list.Count -eq 0) { 'None' }
              elseif ($enabledGroups.Contains('allLogs') -or ($listedCats.Count -gt 0 -and $enabledCats.Count -eq $listedCats.Count)) { 'All logs' }
              elseif ($enabledCats.Count -or $enabledGroups.Count) { 'Partial' }
              elseif ($metrics) { 'Metrics only' }
              else { 'None' }
    [pscustomobject]@{
        Settings     = $list.Count
        Status       = $status
        Categories   = (Join-Unique (@($enabledGroups) + @($enabledCats)))
        Destinations = (Join-Unique @($dest))
    }
}

function Get-ResourceLock {
    # Strongest management lock that applies to the resource: on the resource, its resource group or its subscription.
    param($Item)
    if (-not $LocksBySub.ContainsKey($Item.SubscriptionId)) { return $null }
    $rg   = ('/subscriptions/{0}/resourcegroups/{1}' -f $Item.SubscriptionId, $Item.ResourceGroup).ToLowerInvariant()
    $sub  = ('/subscriptions/{0}' -f $Item.SubscriptionId).ToLowerInvariant()
    $best = $null
    foreach ($l in @($LocksBySub[$Item.SubscriptionId] | Where-Object { $_ })) {
        $lid = ([string]$l.id).ToLowerInvariant()
        $at  = $lid.IndexOf('/providers/microsoft.authorization/locks/')
        if ($at -lt 0) { continue }
        $scope = $lid.Substring(0, $at)
        $label = if ($scope -eq $Item.IdLower) { 'Resource' } elseif ($scope -eq $rg) { 'Resource group' } elseif ($scope -eq $sub) { 'Subscription' } else { $null }
        if (-not $label) { continue }
        $level = [string]$l.properties.level
        $rank  = if ($level -eq 'ReadOnly') { 2 } else { 1 }
        if (-not $best -or $rank -gt $best.Rank) { $best = @{ Level = $level; Scope = $label; Rank = $rank } }
    }
    if (-not $best) { return [pscustomobject]@{ Level = 'None'; Scope = '' } }
    return [pscustomobject]@{ Level = $best.Level; Scope = $best.Scope }
}

$NotRotatedText = "Not rotated (last $ActivityDays days)"
$hygiene = foreach ($i in $Resources) {
    $r      = $i.Raw
    $family = $i.Service.Family
    $isMl   = $family -in 'ML', 'MLHub'
    # Machine Learning workspaces have no local auth switch: their key-based access is the datastore credential mode.
    $localAuth = if ($isMl) { if ([string]$r.systemDatastoresAuthMode -eq 'identity') { 'Disabled' } else { 'Enabled' } }
                 elseif ([bool]$r.disableLocalAuth) { 'Disabled' } else { 'Enabled' }

    # Key activity from the activity log; a hub includes its projects.
    $hubChildren = if ($family -eq 'MLHub') { @($i.Projects | Where-Object { $_ -and $_.IdLower }) } else { @() }
    $acts = @(@($KeyActivity[$i.IdLower]) + @($hubChildren | ForEach-Object { $KeyActivity[$_.IdLower] }) | Where-Object { $_ })
    $activityRead = $DoActivityLog -and $ActivityOk.ContainsKey(('{0}|{1}' -f $i.SubscriptionId, ($i.Type -split '/')[0]))
    $retrievals = $null; $callers = $null; $callerTypes = ''; $lastGet = $null; $regens = $null; $lastRegen = $null; $rotation = ''
    if ($activityRead) {
        $retrievals  = [int](($acts | ForEach-Object { $_.Retrievals } | Measure-Object -Sum).Sum)
        $regens      = [int](($acts | ForEach-Object { $_.Regenerations } | Measure-Object -Sum).Sum)
        $callerSet   = @($acts | ForEach-Object { $_.Callers.Keys } | Where-Object { $_ } | Sort-Object -Unique)
        $callers     = $callerSet.Count
        $callerTypes = (@($callerSet | Group-Object -Property { Get-CallerType $_ } | Sort-Object -Property Name | ForEach-Object { '{0} {1}' -f $_.Name, $_.Count }) -join '; ')
        $lastGet     = $acts | ForEach-Object { $_.LastRetrieval } | Where-Object { $_ } | Sort-Object -Descending | Select-Object -First 1
        $lastRegen   = $acts | ForEach-Object { $_.LastRegeneration } | Where-Object { $_ } | Sort-Object -Descending | Select-Object -First 1
        $rotation    = if ($localAuth -eq 'Disabled') { 'n/a (keys disabled)' } elseif ($regens -gt 0) { 'Rotated' } else { $NotRotatedText }
    }

    $diag = if ($DiagByRes.ContainsKey($i.IdLower)) { Get-DiagnosticProfile $DiagByRes[$i.IdLower] } else { $null }
    $lock = Get-ResourceLock $i
    $pna  = Get-PublicAccess ([string]$r.publicNetworkAccess)
    $exposure = if ($pna -eq 'Disabled') { 'Private only' }
                elseif ($pna -eq 'SecuredByPerimeter') { 'Network security perimeter' }
                elseif (($family -eq 'Cognitive' -and [string]$r.networkDefaultAction -eq 'Deny') -or ($family -eq 'Search' -and [int]$r.ipRules -gt 0)) { 'Selected networks' }
                else { 'All networks' }
    $identity   = if ($family -eq 'Bot') { 'n/a' } else { Get-IdentityLabel ([string]$r.identityType) }
    $encryption = switch ($family) {
        'Cognitive' { if ($r.encryptionKeySource -eq 'Microsoft.KeyVault') { 'Customer-managed key' } else { 'Microsoft-managed key' } }
        'Search'    { if ([string]$r.cmkEnforcement -eq 'Enabled') { 'Customer-managed key (enforced)' } else { 'Microsoft-managed key' } }
        'Bot'       { if ([bool]$r.isCmekEnabled) { 'Customer-managed key' } else { 'Microsoft-managed key' } }
        default     { if ($r.encryptionStatus -eq 'Enabled') { 'Customer-managed key' } else { 'Microsoft-managed key' } }
    }
    # Defender for AI services protects model deployments (Azure OpenAI and Foundry accounts).
    $defender = if ($family -eq 'Cognitive' -and $i.Kind -in 'OpenAI', 'AIServices') {
                    if ($DefenderAiBySub.ContainsKey($i.SubscriptionId)) { $DefenderAiBySub[$i.SubscriptionId] } else { 'Unknown' }
                } else { 'n/a' }

    $findings = [System.Collections.Generic.List[string]]::new()
    if ($localAuth -eq 'Enabled') { $findings.Add($(if ($isMl) { 'Datastores use storage account keys' } else { 'Local (key) authentication enabled' })) }
    if ($rotation -eq $NotRotatedText) { $findings.Add("Keys not rotated in the last $ActivityDays days") }
    if ($diag -and $diag.Status -in 'None', 'Metrics only') { $findings.Add('No diagnostic logs') }
    if ($lock -and $lock.Level -eq 'None') { $findings.Add('No resource lock') }
    if ($exposure -eq 'All networks') { $findings.Add('Reachable from all networks') }
    if ($identity -eq 'None') { $findings.Add('No managed identity') }
    if ($defender -eq 'Off (Free)') { $findings.Add('Defender for AI services off') }

    [pscustomobject]@{
        'Issues'                      = $findings.Count
        'Findings'                    = ($findings -join '; ')
        'Service'                     = $i.Service.Name
        'Resource'                    = $i.Name
        'Subscription'                = $i.Subscription
        'Resource group'              = $i.ResourceGroup
        'Region'                      = $i.Region
        'Local auth (keys)'           = $localAuth
        'Key retrievals'              = $retrievals
        'Key retrieval callers'       = $callers
        'Caller types'                = $callerTypes
        'Last key retrieval (UTC)'    = $lastGet
        'Key regenerations'           = $regens
        'Last key regeneration (UTC)' = $lastRegen
        'Key rotation'                = $rotation
        'Diagnostic settings'         = $(if ($diag) { $diag.Settings } else { $null })
        'Diagnostic logs'             = $(if ($diag) { $diag.Status } else { '' })
        'Log categories enabled'      = $(if ($diag) { $diag.Categories } else { '' })
        'Diagnostic destinations'     = $(if ($diag) { $diag.Destinations } else { '' })
        'Resource lock'               = $(if ($lock) { $lock.Level } else { '' })
        'Lock scope'                  = $(if ($lock) { $lock.Scope } else { '' })
        'Network exposure'            = $exposure
        'Private endpoints'           = [int]$r.privateEndpoints
        'Managed identity'            = $identity
        'Encryption'                  = $encryption
        'Defender for AI services'    = $defender
        'Resource ID'                 = $i.Id
        'Portal'                      = (Get-PortalLink $i.Id)
    }
}
$HygieneRows = @($hygiene | Sort-Object -Property @{ Expression = 'Issues'; Descending = $true }, 'Service', 'Resource')

# --- Content filters: policies and the filter of every model deployment -----------------------------
$depsByPolicy = @{}   # account id|policy (lower-case) -> deployments using it
foreach ($d in $ModelHostDeployments) {
    if (-not $d._RaiProfile) { continue }
    $k = '{0}|{1}' -f $d._AccountId, ([string]$d.'Content filter').ToLowerInvariant()
    if (-not $depsByPolicy.ContainsKey($k)) { $depsByPolicy[$k] = [System.Collections.Generic.List[object]]::new() }
    $depsByPolicy[$k].Add($d)
}
$assessRank = @{ 'Relaxed' = 0; 'Not set' = 1; 'Policy not found' = 2; 'Stricter' = 3; 'Default' = 4 }
$policies = foreach ($acct in $modelHosts) {
    $res = $AcctResults[$acct.IdLower]
    if (-not $res) { continue }
    foreach ($p in @($res.RaiPolicies | Where-Object { $_ -and $_.name })) {
        $k    = '{0}|{1}' -f $acct.IdLower, ([string]$p.name).ToLowerInvariant()
        $prof = $RaiProfiles[$k]
        if (-not $prof) { continue }
        $used = @($depsByPolicy[$k] | Where-Object { $_ })
        # System policies are listed only where a deployment uses them.
        if ($prof.Type -eq 'System' -and -not $used.Count) { continue }
        [pscustomobject]@{
            'Assessment'                   = $prof.Assessment
            'Account'                      = $acct.Name
            'Subscription'                 = $acct.Subscription
            'Policy'                       = $prof.Name
            'Policy type'                  = $prof.Type
            'Base policy'                  = $prof.BasePolicy
            'Mode'                         = $prof.Mode
            'Hate'                         = $prof.Hate
            'Sexual'                       = $prof.Sexual
            'Violence'                     = $prof.Violence
            'Self-harm'                    = $prof.SelfHarm
            'Prompt shields (jailbreak)'   = $prof.Jailbreak
            'Indirect attacks'             = $prof.IndirectAttack
            'Protected material (text)'    = $prof.ProtectedText
            'Protected material (code)'    = $prof.ProtectedCode
            'Profanity'                    = $prof.Profanity
            'Custom blocklists'            = $prof.Blocklists
            'Relaxed vs DefaultV2'         = $prof.Relaxed
            'Stricter vs DefaultV2'        = $prof.Stricter
            'Deployments using the policy' = $used.Count
            'Deployment names'             = (Join-Unique @($used | ForEach-Object { $_.Deployment }))
        }
    }
}
$PolicyRows = @($policies | Sort-Object -Property @{ Expression = { $assessRank[$_.Assessment] } }, 'Account', 'Policy')

$FilterDeploymentRows = @($ModelHostDeployments | ForEach-Object {
        $total    = $_._RaiTotal
        $rejected = $_._RaiRejected
        [pscustomobject]@{
            'Content filter assessment'  = $_.'Content filter assessment'
            'Account'                    = $_.Account
            'Subscription'               = $_.Subscription
            'Region'                     = $_.Region
            'Deployment'                 = $_.Deployment
            'Model'                      = $_.Model
            'Model version'              = $_.'Model version'
            'Deployment type'            = $_.'Deployment type'
            'Content filter'             = $_.'Content filter'
            'Policy type'                = $(if ($_._RaiProfile) { $_._RaiProfile.Type } else { '' })
            'Requests screened'          = $total
            'Harmful requests detected'  = $_._RaiHarmful
            'Blocked requests'           = $rejected
            'Blocked %'                  = $(if ($null -ne $total -and [double]$total -gt 0 -and $null -ne $rejected) { [double]$rejected / [double]$total } else { $null })
            'Defender for AI services'   = $(if ($DefenderAiBySub.ContainsKey($_._Account.SubscriptionId)) { $DefenderAiBySub[$_._Account.SubscriptionId] } else { 'Unknown' })
            'Deployment ID'              = $_.'Deployment ID'
        }
    } | Sort-Object -Property @{ Expression = { if ($assessRank.ContainsKey($_.'Content filter assessment')) { $assessRank[$_.'Content filter assessment'] } else { 9 } } }, 'Account', 'Deployment')

# --- Capacity and quota ---------------------------------------------------------------------------------
# Every Foundry / Azure OpenAI deployment, right-sizing candidates first.
$rightRank = @{ 'Idle' = 0; 'Throttled' = 1; 'PTU saturated' = 2; 'PTU under-used' = 3; 'Over-allocated' = 4; 'New' = 5; 'OK' = 6 }
$RightSizingCandidates = @($ModelHostDeployments | Where-Object { $rightRank.ContainsKey([string]$_.'Right-sizing') -and $rightRank[[string]$_.'Right-sizing'] -le 4 }).Count
$RightSizingRows = @($ModelHostDeployments |
    Sort-Object -Property @{ Expression = { if ($rightRank.ContainsKey([string]$_.'Right-sizing')) { $rightRank[[string]$_.'Right-sizing'] } else { 9 } } }, @{ Expression = { [double]$_.'Est. amortized cost' }; Descending = $true }, 'Account', 'Deployment' |
    ForEach-Object {
        [pscustomobject]@{
            'Right-sizing'             = $(if ($_.'Right-sizing') { $_.'Right-sizing' } else { 'Not assessed' })
            'Right-sizing advice'      = $_.'Right-sizing advice'
            'Account'                  = $_.Account
            'Deployment'               = $_.Deployment
            'Model'                    = $_.Model
            'Model version'            = $_.'Model version'
            'Deployment type'          = $_.'Deployment type'
            'Capacity'                 = $_.Capacity
            'Tokens per minute'        = $_.'Tokens per minute'
            'Peak TPM (busiest hour)'  = $_.'Peak TPM (busiest hour)'
            'Peak % of TPM limit'      = $_.'Peak % of TPM limit'
            'Requests'                 = $_.Requests
            'Throttled requests (429)' = $_.'Throttled requests (429)'
            'PTU utilization avg'      = $_.'PTU utilization avg'
            'PTU utilization peak'     = $_.'PTU utilization peak'
            'Last request date'        = $_.'Last request date'
            'Idle days'                = $_.'Idle days'
            'Quota'                    = $_.Quota
            'Quota used %'             = $_.'Quota used %'
            'Spillover deployment'     = $_.'Spillover deployment'
            'Est. actual cost'         = $_.'Est. actual cost'
            'Est. amortized cost'      = $_.'Est. amortized cost'
            'Currency'                 = $_.Currency
            'Subscription'             = $_.Subscription
            'Region'                   = $_.Region
            'Deployment ID'            = $_.'Deployment ID'
        }
    })

$depsByQuota = @{}   # sub|region|usage name (lower-case) -> deployments consuming it
foreach ($d in $ModelHostDeployments) {
    if (-not $d._Quota) { continue }
    $k = '{0}|{1}|{2}' -f $d._Account.SubscriptionId, $d._Account.Location, ([string]$d._Quota.name.value).ToLowerInvariant()
    if (-not $depsByQuota.ContainsKey($k)) { $depsByQuota[$k] = [System.Collections.Generic.List[object]]::new() }
    $depsByQuota[$k].Add($d)
}
$quotas = foreach ($pair in @($QuotaByPair.Keys | Sort-Object)) {
    $sub, $loc = $pair.Split('|')
    foreach ($u in @($QuotaByPair[$pair])) {
        $name  = [string]$u.name.value
        $deps  = @($depsByQuota[('{0}|{1}' -f $pair, $name.ToLowerInvariant())] | Where-Object { $_ })
        $used  = [double]$u.currentValue
        $limit = [double]$u.limit
        # Only quotas in use or consumed by a deployment; the usages API lists every model the region offers.
        if ($used -le 0 -and -not $deps.Count) { continue }
        $parts = $name.Split('.')
        $type  = if ($name -match '(?i)accountcount$') { '' } elseif ($parts.Count -ge 2) { $parts[1] } else { '' }
        $model = if ($name -match '(?i)accountcount$') { '(accounts)' } elseif ($parts.Count -ge 3) { $parts[2..($parts.Count - 1)] -join '.' } elseif ($parts.Count -eq 2) { '(all models)' } else { $name }
        $idle  = @($deps | Where-Object { $_.'Right-sizing' -eq 'Idle' })
        $pct   = if ($limit -gt 0) { $used / $limit } else { $null }
        [pscustomobject]@{
            'Quota status'                      = $(if ($null -eq $pct) { '' } elseif ($pct -ge 1) { 'Full' } elseif ($pct -ge 0.8) { 'High' } else { 'OK' })
            'Subscription'                      = (Get-SubscriptionName $sub)
            'Region'                            = (Get-RegionName $loc)
            'Quota'                             = $name
            'Deployment type'                   = $type
            'Model'                             = $model
            'Used'                              = $used
            'Limit'                             = $limit
            'Available'                         = [Math]::Max(0, $limit - $used)
            'Used %'                            = $pct
            'Deployments'                       = $deps.Count
            'Idle deployments'                  = $idle.Count
            'Capacity held by idle deployments' = [double](($idle | ForEach-Object { [double]$_.Capacity } | Measure-Object -Sum).Sum)
            'Deployment names'                  = (Join-Unique @($deps | ForEach-Object { '{0}/{1}' -f $_.Account, $_.Deployment }) '; ')
        }
    }
}
$QuotaRows = @($quotas | Sort-Object -Property @{ Expression = { [double]$_.'Used %' }; Descending = $true }, 'Subscription', 'Region', 'Quota')
$QuotaHighCount = @($QuotaRows | Where-Object { $null -ne $_.'Used %' -and $_.'Used %' -ge 0.9 }).Count

# --- Machine Learning computes, workspace dependencies and workspace cost -------------------------------
function ConvertFrom-IsoDuration {
    param([string]$Text)
    if (-not $Text) { return $null }
    try { return [System.Xml.XmlConvert]::ToTimeSpan($Text) } catch { return $null }
}

$seenComputes = [System.Collections.Generic.HashSet[string]]::new()
$computes = foreach ($wsId in @($ComputesByWs.Keys | Sort-Object)) {
    $ws = $ResIndex[$wsId]
    foreach ($c in @($ComputesByWs[$wsId] | Where-Object { $_ -and $_.id })) {
        if (-not $seenComputes.Add(([string]$c.id).ToLowerInvariant())) { continue }
        $cp    = $c.properties
        $pp    = $cp.properties
        $type  = [string]$cp.computeType
        $isCi  = $type -eq 'ComputeInstance'
        $isAml = $type -eq 'AmlCompute'
        $idle  = ConvertFrom-IsoDuration ([string]$pp.idleTimeBeforeShutdown)
        $stops = @(@($pp.schedules.computeStartStop) | Where-Object { $_ -and [string]$_.action -eq 'Stop' -and [string]$_.status -ne 'Disabled' })
        $auto  = if (-not $isCi) { 'n/a' }
                 elseif ($idle -and $stops.Count) { 'Idle shutdown + schedule' }
                 elseif ($idle) { 'Idle shutdown' }
                 elseif ($stops.Count) { 'Stop schedule' }
                 else { 'None' }
        $minNodes = if ($isAml -and $null -ne $pp.scaleSettings.minNodeCount) { [int]$pp.scaleSettings.minNodeCount } else { $null }
        $maxNodes = if ($isAml -and $null -ne $pp.scaleSettings.maxNodeCount) { [int]$pp.scaleSettings.maxNodeCount } else { $null }
        $publicIp = if ($null -ne $pp.enableNodePublicIp) { [bool]$pp.enableNodePublicIp } elseif ($pp.connectivityEndpoints.publicIpAddress) { $true } else { $null }
        $ssh      = if ($isCi) { [string]$pp.sshSettings.sshPublicAccess } elseif ($isAml) { [string]$pp.remoteLoginPortPublicAccess } else { '' }
        $state    = if ($isCi) { [string]$pp.state } elseif ($isAml) { [string]$pp.allocationState } else { [string]$cp.provisioningState }
        $findings = [System.Collections.Generic.List[string]]::new()
        if ($auto -eq 'None') { $findings.Add('No idle shutdown or stop schedule') }
        if ($isAml -and $minNodes -gt 0) { $findings.Add("$minNodes node(s) always on (minimum nodes > 0)") }
        if ($publicIp -eq $true) { $findings.Add('Public IP address') }
        if ($ssh -eq 'Enabled') { $findings.Add('SSH / remote login open to the internet') }
        if ($null -ne $cp.disableLocalAuth -and -not [bool]$cp.disableLocalAuth) { $findings.Add('Local authentication enabled') }
        [pscustomobject]@{
            'Issues'              = $findings.Count
            'Findings'            = ($findings -join '; ')
            'Workspace'           = $(if ($ws) { $ws.Name } else { Get-LastSegment $wsId })
            'Workspace kind'      = $(if ($ws -and $ws.Kind) { $ws.Kind } else { 'Default' })
            'Compute'             = [string]$c.name
            'Type'                = $(if ($type) { $type } else { '(unknown)' })
            'VM size'             = [string]$pp.vmSize
            'Priority'            = [string]$pp.vmPriority
            'State'               = $state
            'Current nodes'       = $(if ($isAml) { $pp.currentNodeCount } else { $null })
            'Min nodes'           = $minNodes
            'Max nodes'           = $maxNodes
            'Idle shutdown (min)' = $(if ($idle) { [int]$idle.TotalMinutes } else { $null })
            'Stop schedules'      = $stops.Count
            'Auto-shutdown'       = $auto
            'Public IP'           = $publicIp
            'SSH public access'   = $ssh
            'Local auth disabled' = $(if ($null -ne $cp.disableLocalAuth) { [bool]$cp.disableLocalAuth } else { $null })
            'Subnet'              = (Get-LastSegment ([string]$pp.subnet.id))
            'Region'              = (Get-RegionName ([string]$c.location))
            'Subscription'        = $(if ($ws) { $ws.Subscription } else { '' })
            'Resource group'      = $(if ($ws) { $ws.ResourceGroup } else { '' })
            'Created (UTC)'       = (ConvertTo-UtcDateTime $cp.createdOn)
            'Resource ID'         = [string]$c.id
        }
    }
}
$ComputeRows = @($computes | Sort-Object -Property @{ Expression = 'Issues'; Descending = $true }, 'Workspace', 'Compute')
$ComputeIssueCount = @($ComputeRows | Where-Object { $_.Issues -gt 0 }).Count

$depKinds = [ordered]@{ storageAccount = 'Storage account'; keyVault = 'Key vault'; containerRegistry = 'Container registry'; applicationInsights = 'Application Insights' }
$depUse = [ordered]@{}   # lower-case dependency id -> kind + workspaces using it
foreach ($w in $MlWorkspaces) {
    foreach ($prop in $depKinds.Keys) {
        $id = [string]$w.Raw.$prop
        if (-not $id) { continue }
        $k = $id.ToLowerInvariant()
        if (-not $depUse.Contains($k)) { $depUse[$k] = [pscustomobject]@{ Id = $id; Kind = $depKinds[$prop]; Workspaces = [System.Collections.Generic.List[string]]::new() } }
        $depUse[$k].Workspaces.Add($w.Name)
    }
}
$dependencies = foreach ($k in $depUse.Keys) {
    $u    = $depUse[$k]
    $info = $DependencyInfo[$k]
    $findings = [System.Collections.Generic.List[string]]::new()
    $pna = $keyAccess = $purge = $soft = $perm = $blob = $tls = $defaultAction = ''
    if ($info) {
        $pna           = Get-PublicAccess ([string]$info.publicNetworkAccess)
        $defaultAction = if ($info.networkDefaultAction) { [string]$info.networkDefaultAction } else { 'Allow' }
        switch ($u.Kind) {
            'Storage account' {
                $keyAccess = if ([string]$info.allowSharedKeyAccess -eq 'false') { 'Disabled' } else { 'Enabled' }
                $blob      = if ([string]$info.allowBlobPublicAccess -eq 'true') { 'Allowed' } elseif ([string]$info.allowBlobPublicAccess -eq 'false') { 'Disabled' } else { '(not set)' }
                $tls       = [string]$info.minimumTlsVersion
                if ($keyAccess -eq 'Enabled') { $findings.Add('Shared key access enabled') }
                if ($blob -eq 'Allowed') { $findings.Add('Anonymous blob access allowed') }
                if ($tls -in 'TLS1_0', 'TLS1_1') { $findings.Add("Minimum TLS $tls") }
            }
            'Key vault' {
                $purge = if ([string]$info.enablePurgeProtection -eq 'true') { 'On' } else { 'Off' }
                $soft  = if ([string]$info.enableSoftDelete -eq 'false') { 'Off' } else { 'On' }
                $perm  = if ([string]$info.enableRbacAuthorization -eq 'true') { 'Azure RBAC' } else { 'Access policies' }
                if ($purge -eq 'Off') { $findings.Add('Purge protection off') }
                if ($soft -eq 'Off') { $findings.Add('Soft delete off') }
                if ($perm -eq 'Access policies') { $findings.Add('Vault access policies instead of Azure RBAC') }
            }
            'Container registry' {
                $keyAccess = if ([string]$info.adminUserEnabled -eq 'true') { 'Enabled' } else { 'Disabled' }
                if ($keyAccess -eq 'Enabled') { $findings.Add('Admin user enabled') }
            }
            'Application Insights' {
                $keyAccess = if ([string]$info.disableLocalAuth -eq 'true') { 'Disabled' } else { 'Enabled' }
                $pna       = if ([string]$info.ingestionAccess) { [string]$info.ingestionAccess } else { 'Enabled' }
                $defaultAction = ''
                if ($keyAccess -eq 'Enabled') { $findings.Add('Local (instrumentation key) authentication enabled') }
                if (-not $info.workspaceResourceId) { $findings.Add('Classic Application Insights (not workspace-based)') }
            }
        }
        if ($u.Kind -ne 'Application Insights' -and $pna -eq 'Enabled' -and $defaultAction -ne 'Deny' -and [int]$info.privateEndpoints -eq 0) { $findings.Add('Reachable from all networks') }
    }
    else { $findings.Add('Not found (deleted, or not readable with the current access)') }
    [pscustomobject]@{
        'Issues'                 = $findings.Count
        'Findings'               = ($findings -join '; ')
        'Dependency'             = $u.Kind
        'Name'                   = (Get-LastSegment $u.Id)
        'Used by workspaces'     = (Join-Unique @($u.Workspaces))
        'Found'                  = $(if ($info) { 'Yes' } else { 'Missing' })
        'SKU'                    = $(if ($info) { [string]$info.skuName } else { '' })
        'Public network access'  = $pna
        'Network default action' = $defaultAction
        'Private endpoints'      = $(if ($info) { [int]$info.privateEndpoints } else { $null })
        'Key-based access'       = $keyAccess
        'Purge protection'       = $purge
        'Soft delete'            = $soft
        'Permission model'       = $perm
        'Blob anonymous access'  = $blob
        'Minimum TLS'            = $tls
        'Subscription'           = $(if ($info) { Get-SubscriptionName ([string]$info.subscriptionId) } else { Get-SubscriptionName (($u.Id -split '/')[2]) })
        'Resource group'         = $(if ($info) { [string]$info.resourceGroup } else { ($u.Id -split '/')[4] })
        'Resource ID'            = $u.Id
    }
}
$DependencyRows = @($dependencies | Sort-Object -Property @{ Expression = 'Issues'; Descending = $true }, 'Dependency', 'Name')

$mlIds = [System.Collections.Generic.HashSet[string]]::new()
foreach ($w in $MlWorkspaces) { [void]$mlIds.Add($w.IdLower) }
$mlCost = [ordered]@{}
foreach ($c in $CostRows) {
    $top = Get-TopLevelId $c.ResourceId
    if (-not $mlIds.Contains($top)) { continue }
    $k = '{0}|{1}|{2}' -f $top, $c.MeterCategory, $c.Currency
    if (-not $mlCost.Contains($k)) { $mlCost[$k] = [pscustomobject]@{ Top = $top; MeterCategory = $c.MeterCategory; Currency = $c.Currency; Rows = [System.Collections.Generic.List[object]]::new() } }
    $mlCost[$k].Rows.Add($c)
}
$MlCostRows = @($mlCost.Values | ForEach-Object {
        $e  = $_
        $ws = $ResIndex[$e.Top]
        [pscustomobject]@{
            'Workspace'        = $(if ($ws) { $ws.Name } else { Get-LastSegment $e.Top })
            'Workspace kind'   = $(if ($ws -and $ws.Kind) { $ws.Kind } else { 'Default' })
            'Hub'              = $(if ($ws -and $ws.Hub) { $ws.Hub.Name } else { '' })
            'Meter category'   = $(if ($e.MeterCategory) { $e.MeterCategory } else { '(none)' })
            'Actual cost'      = $(if ($ActualOkSubs.ContainsKey($e.Rows[0].SubscriptionId)) { [double](($e.Rows | ForEach-Object { [double]$_.ActualCost } | Measure-Object -Sum).Sum) } else { $null })
            'Amortized cost'   = $(if ($AmortizedOkSubs.ContainsKey($e.Rows[0].SubscriptionId)) { [double](($e.Rows | ForEach-Object { [double]$_.AmortizedCost } | Measure-Object -Sum).Sum) } else { $null })
            'Reservation name' = (Join-Unique @($e.Rows | ForEach-Object { ([string]$_.Reservation) -split ';\s*' }) '; ')
            'Currency'         = $e.Currency
            'Subscription'     = $(if ($ws) { $ws.Subscription } else { Get-SubscriptionName $e.Rows[0].SubscriptionId })
            'Resource group'   = $(if ($ws) { $ws.ResourceGroup } else { '' })
        }
    } | Where-Object { [Math]::Abs([double]$_.'Actual cost') -ge 0.005 -or [Math]::Abs([double]$_.'Amortized cost') -ge 0.005 } |
    Sort-Object -Property 'Workspace', @{ Expression = { [double]$_.'Amortized cost' + [double]$_.'Actual cost' }; Descending = $true })

# --- AI cost reconciliation -------------------------------------------------------------------------------
$ReconCurrencies = @(@($SpendRows | ForEach-Object { $_.Currency }) + @($SubTotals.Keys | ForEach-Object { $_.Split('|')[2] }) | Where-Object { $_ } | Sort-Object -Unique)
$ReconLineRows = [System.Collections.Generic.List[object]]::new()
foreach ($cur in $ReconCurrencies) {
    foreach ($line in $ReconLines.Keys) {
        $rows  = @($SpendRows | Where-Object { $_.'Cost line' -eq $line -and $_.Currency -eq $cur })
        $isRes = $line -in 'AI resources (service sheets)', 'AI resources not on the service sheets'
        $okA   = if ($line -eq 'Unused AI reservations') { $false } elseif ($isRes) { $ActualOkSubs.Count -gt 0 } else { $ReconOk.Actual.Count -gt 0 }
        $okM   = if ($line -eq 'AI reservation purchases') { $false } elseif ($isRes) { $AmortizedOkSubs.Count -gt 0 } else { $ReconOk.Amortized.Count -gt 0 }
        $ReconLineRows.Add([pscustomobject]@{
                'Cost line'           = $line
                'Actual cost'         = $(if ($okA) { [double](($rows | ForEach-Object { [double]$_.'Actual cost' } | Measure-Object -Sum).Sum) } else { $null })
                'Amortized cost'      = $(if ($okM) { [double](($rows | ForEach-Object { [double]$_.'Amortized cost' } | Measure-Object -Sum).Sum) } else { $null })
                'Currency'            = $cur
                'Share of actual'     = $null
                'Share of amortized'  = $null
                'What it covers'      = $ReconLines[$line]
            })
    }
    # Totals, non-AI spend and the shares are Excel formulas (filled in when the sheet is written).
    $ReconLineRows.Add([pscustomobject]@{ 'Cost line' = 'Total AI spend'; 'Actual cost' = $null; 'Amortized cost' = $null; 'Currency' = $cur; 'Share of actual' = $null; 'Share of amortized' = $null
            'What it covers' = 'Sum of the lines above.' })
    $ReconLineRows.Add([pscustomobject]@{ 'Cost line' = 'Subscription total (all charges)'
            'Actual cost'    = $(if ($TotalsOk.Actual.Count) { [double]$SubTotalActual[$cur] } else { $null })
            'Amortized cost' = $(if ($TotalsOk.Amortized.Count) { [double]$SubTotalAmortized[$cur] } else { $null })
            'Currency' = $cur; 'Share of actual' = $null; 'Share of amortized' = $null
            'What it covers' = "All charges of the $($ReconScanSubs.Count) scanned subscription(s): subscriptions with AI resources, subscriptions with Power Platform billing policies (Copilot Studio) and the -SubscriptionId list." })
    $ReconLineRows.Add([pscustomobject]@{ 'Cost line' = 'Non-AI spend'; 'Actual cost' = $null; 'Amortized cost' = $null; 'Currency' = $cur; 'Share of actual' = $null; 'Share of amortized' = $null
            'What it covers' = 'Subscription total minus total AI spend.' })
}

$reconSubs = [ordered]@{}
foreach ($x in $SpendRows) { $reconSubs[('{0}|{1}' -f ([string]$x._Sub).ToLowerInvariant(), $x.Currency)] = $true }
foreach ($k in $SubTotals.Keys) { $p = $k.Split('|'); $reconSubs[('{0}|{1}' -f $p[0].ToLowerInvariant(), $p[2])] = $true }
$ReconSubRows = @(foreach ($k in @($reconSubs.Keys | Sort-Object)) {
        $sub, $cur = $k.Split('|')
        $rows = @($SpendRows | Where-Object { ([string]$_._Sub).ToLowerInvariant() -eq $sub -and $_.Currency -eq $cur })
        # Each part has its own query: a part that could not be read stays blank (and so do the total and share).
        # Subscriptions without AI resources have no per-resource query: their AI resource types come with the other AI cost.
        $aiSub  = $AiSubSet.ContainsKey($sub)
        $okResA = if ($aiSub) { $ActualOkSubs.ContainsKey($sub) } else { $ReconOk.Actual.ContainsKey($sub) }
        $okResM = if ($aiSub) { $AmortizedOkSubs.ContainsKey($sub) } else { $ReconOk.Amortized.ContainsKey($sub) }
        $okOthA = $ReconOk.Actual.ContainsKey($sub)
        $okOthM = $ReconOk.Amortized.ContainsKey($sub)
        [pscustomobject]@{
            'Subscription'                = (Get-SubscriptionName $sub)
            'AI resources actual cost'    = $(if ($okResA) { [double](($rows | Where-Object { $_.'Cost line' -like 'AI resources*' } | ForEach-Object { [double]$_.'Actual cost' } | Measure-Object -Sum).Sum) } else { $null })
            'Other AI actual cost'        = $(if ($okOthA) { [double](($rows | Where-Object { $_.'Cost line' -notlike 'AI resources*' } | ForEach-Object { [double]$_.'Actual cost' } | Measure-Object -Sum).Sum) } else { $null })
            'Total AI actual cost'        = $null
            'Subscription actual cost'    = $(if ($TotalsOk.Actual.ContainsKey($sub)) { [double]$SubTotals[('{0}|Actual|{1}' -f $sub, $cur)] } else { $null })
            'AI share (actual)'           = $null
            'AI resources amortized cost' = $(if ($okResM) { [double](($rows | Where-Object { $_.'Cost line' -like 'AI resources*' } | ForEach-Object { [double]$_.'Amortized cost' } | Measure-Object -Sum).Sum) } else { $null })
            'Other AI amortized cost'     = $(if ($okOthM) { [double](($rows | Where-Object { $_.'Cost line' -notlike 'AI resources*' } | ForEach-Object { [double]$_.'Amortized cost' } | Measure-Object -Sum).Sum) } else { $null })
            'Total AI amortized cost'     = $null
            'Subscription amortized cost' = $(if ($TotalsOk.Amortized.ContainsKey($sub)) { [double]$SubTotals[('{0}|Amortized|{1}' -f $sub, $cur)] } else { $null })
            'AI share (amortized)'        = $null
            'Currency'                    = $cur
            'Subscription ID'             = $sub
        }
    })

$detail = [ordered]@{}
foreach ($c in $outsideRows) {
    $top = Get-TopLevelId $c.ResourceId
    $k   = '{0}|{1}|{2}|{3}' -f $top, $c.MeterCategory, $c.MeterSubCategory, $c.Currency
    if (-not $detail.Contains($k)) {
        $detail[$k] = [pscustomobject]@{
            'Cost line' = 'AI resources not on the service sheets'; 'Subscription' = (Get-SubscriptionName $c.SubscriptionId); 'Resource' = (Get-LastSegment $top)
            'Linked AI resource' = ''; 'Resource type' = (($top -split '/providers/')[-1] -replace '/[^/]+$', ''); 'Meter category' = $c.MeterCategory
            'Meter sub-category' = $c.MeterSubCategory; 'Charge type' = 'Usage'; 'Publisher type' = 'Azure'; 'Reservation name' = ''
            'Actual cost' = $null; 'Amortized cost' = $null; 'Currency' = $c.Currency; 'Resource ID' = $top
        }
    }
    $e = $detail[$k]
    if ($null -ne $c.ActualCost) { $e.'Actual cost' = [double]$e.'Actual cost' + [double]$c.ActualCost }
    if ($null -ne $c.AmortizedCost) { $e.'Amortized cost' = [double]$e.'Amortized cost' + [double]$c.AmortizedCost }
    if ($c.Reservation) { $e.'Reservation name' = Join-Unique @(@($e.'Reservation name' -split ';\s*') + @($c.Reservation -split ';\s*')) '; ' }
}
$ReconDetailRows = @(@($detail.Values) + @($ReconRows | ForEach-Object {
            [pscustomobject]@{
                'Cost line'          = $_.Line
                'Subscription'       = (Get-SubscriptionName $_.SubscriptionId)
                'Resource'           = $(if ($_.ResourceId) { Get-LastSegment $_.ResourceId } else { '(no resource)' })
                'Linked AI resource' = $(if ($_.LinkedAccount) { $_.LinkedAccount.Name } else { '' })
                'Resource type'      = $_.ResourceType
                'Meter category'     = $_.MeterCategory
                'Meter sub-category' = $_.MeterSubCategory
                'Charge type'        = $_.ChargeType
                'Publisher type'     = $_.PublisherType
                'Reservation name'   = $_.ReservationName
                'Actual cost'        = $_.ActualCost
                'Amortized cost'     = $_.AmortizedCost
                'Currency'           = $_.Currency
                'Resource ID'        = $_.ResourceId
            }
        }) | Where-Object { [Math]::Abs([double]$_.'Actual cost') -ge 0.005 -or [Math]::Abs([double]$_.'Amortized cost') -ge 0.005 } |
    Sort-Object -Property @{ Expression = { @($ReconLines.Keys).IndexOf($_.'Cost line') } }, @{ Expression = { [double]$_.'Amortized cost' + [double]$_.'Actual cost' }; Descending = $true })

$LocalAuthCount   = @($HygieneRows | Where-Object { $_.'Local auth (keys)' -eq 'Enabled' }).Count
$NoDiagLogsCount  = @($HygieneRows | Where-Object { $_.'Diagnostic logs' -in 'None', 'Metrics only' }).Count
$KeyRetrievalSum  = if ($ActivityOk.Count) { [int](($HygieneRows | ForEach-Object { [int]$_.'Key retrievals' } | Measure-Object -Sum).Sum) } else { $null }
$RelaxedCount     = @($PolicyRows | Where-Object { $_.Assessment -eq 'Relaxed' }).Count
$FilterNotSetCount = @($FilterDeploymentRows | Where-Object { $_.'Content filter assessment' -eq 'Not set' }).Count

#endregion

#region 10. Excel workbook -----------------------------------------------------------------------

Write-Step "Building Excel workbook"

function ConvertTo-Color {
    param([string]$Hex)
    $h = $Hex.TrimStart('#')
    return [System.Drawing.Color]::FromArgb(255, [Convert]::ToInt32($h.Substring(0, 2), 16), [Convert]::ToInt32($h.Substring(2, 2), 16), [Convert]::ToInt32($h.Substring(4, 2), 16))
}

function Get-ColumnFormat {
    param([string]$Header)
    if ($Header -match '\(UTC\)$') { return 'yyyy-mm-dd hh:mm' }
    if ($Header -match '(?i)date$') { return 'yyyy-mm-dd' }
    if ($Header -match '(?i)%|utilization|\bshare\b') { return '0.0%' }
    if ($Header -match '(?i)(^|\s)cost$|^cost') { return '#,##0.00##' }
    if ($Header -eq 'Quantity') { return '#,##0.######' }
    if ($Header -match '(?i)tokens|requests|calls|capacity|tpm|retrievals|regenerations' -or $Header -in 'Used', 'Limit', 'Available') { return '#,##0' }
    if ($Header -match '(?i)^days|days$') { return '0' }
    return $null
}

# Conditional highlights applied to every table column with one of these headers.
$HighlightRules = @{
    'Retirement risk'          = @(@('RETIRED', '#C00000', '#FFFFFF'), @('CRITICAL', '#F4B183'), @('WARNING', '#FFE699'))
    'Risk'                     = @(@('RETIRED', '#C00000', '#FFFFFF'), @('CRITICAL', '#F4B183'), @('WARNING', '#FFE699'), @('REVIEW', '#DDEBF7'))
    'Status'                   = @(@('Unhealthy', '#F8CBAD'), @('Healthy', '#C6EFCE'), @('Active', '#FCE4D6'))
    'Severity'                 = @(@('High', '#F8CBAD'), @('Medium', '#FFE699'), @('Low', '#DDEBF7'))
    'Impact'                   = @(@('High', '#F8CBAD'), @('Medium', '#FFE699'), @('Low', '#DDEBF7'))
    'Level'                    = @(@('Critical', '#F8CBAD'), @('Error', '#F8CBAD'), @('Warning', '#FFE699'))
    'Public network access'    = @(, @('Enabled', '#FFF2CC'))
    'Local auth disabled'      = @(, @('FALSE', '#FFF2CC'))
    'Defender for AI services' = @(@('Off (Free)', '#F8CBAD'), @('On (Standard)', '#C6EFCE'))
    'Defender CSPM'            = @(@('Off (Free)', '#F8CBAD'), @('On (Standard)', '#C6EFCE'))
    'Right-sizing'             = @(@('Idle', '#F8CBAD'), @('Throttled', '#F8CBAD'), @('PTU saturated', '#F8CBAD'), @('Over-allocated', '#FFE699'), @('PTU under-used', '#FFE699'), @('OK', '#C6EFCE'))
    'Assessment'               = @(@('Relaxed', '#F8CBAD'), @('Stricter', '#C6EFCE'))
    'Content filter assessment' = @(@('Relaxed', '#F8CBAD'), @('Not set', '#FFE699'), @('Policy not found', '#FFE699'), @('Stricter', '#C6EFCE'))
    'Quota status'             = @(@('Full', '#F8CBAD'), @('High', '#FFE699'))
    'Local auth (keys)'        = @(, @('Enabled', '#FFE699'))
    'Key rotation'             = @(, @($NotRotatedText, '#FFE699'))
    'Diagnostic logs'          = @(@('None', '#F8CBAD'), @('Metrics only', '#F8CBAD'), @('Partial', '#FFF2CC'), @('All logs', '#C6EFCE'))
    'Resource lock'            = @(, @('None', '#FFF2CC'))
    'Network exposure'         = @(, @('All networks', '#FFE699'))
    'Managed identity'         = @(, @('None', '#FFF2CC'))
    'Found'                    = @(, @('Missing', '#F8CBAD'))
    'Auto-shutdown'            = @(, @('None', '#F8CBAD'))
    'Public IP'                = @(, @('TRUE', '#FFE699'))
    'SSH public access'        = @(, @('Enabled', '#F8CBAD'))
    'Key-based access'         = @(, @('Enabled', '#FFF2CC'))
    'Purge protection'         = @(, @('Off', '#FFE699'))
    'Soft delete'              = @(, @('Off', '#F8CBAD'))
}

function Add-CellHighlight {
    param([OfficeOpenXml.ExcelWorksheet]$Ws, [string]$Address, [string]$Value, [string]$Fill, [string]$Font)
    $cf = $Ws.ConditionalFormatting.AddEqual([OfficeOpenXml.ExcelAddress]::new($Address))
    $cf.Formula = if ($Value -in 'TRUE', 'FALSE') { $Value } else { '"' + $Value.Replace('"', '""') + '"' }
    $cf.Style.Fill.PatternType = [OfficeOpenXml.Style.ExcelFillStyle]::Solid
    $cf.Style.Fill.BackgroundColor.Color = ConvertTo-Color $Fill
    if ($Font) { $cf.Style.Font.Color.Color = ConvertTo-Color $Font }
}

$script:SheetWidths = @{}

function Write-Table {
    param(
        [Parameter(Mandatory)] $Package,
        [Parameter(Mandatory)] [string]$Sheet,
        [Parameter(Mandatory)] [int]$StartRow,
        [object[]]$Data,
        [Parameter(Mandatory)] [string]$TableName,
        [int]$StartColumn = 1,
        [string]$EmptyText = 'No items found in scope.',
        [string]$Style = 'Medium2',
        [switch]$NoAutoFit
    )
    $ws   = $Package.Workbook.Worksheets[$Sheet]
    $rows = @($Data | Where-Object { $null -ne $_ })
    # ImportExcel writes any string starting with '=' as a formula; tags, names and descriptions are
    # tenant-controlled, so neutralise that for every cell.
    foreach ($row in $rows) {
        foreach ($p in $row.PSObject.Properties) {
            if ($p.Value -is [string] -and $p.Value.StartsWith('=')) { $p.Value = ' ' + $p.Value }
        }
    }
    if ($rows.Count -eq 0) {
        $c = $ws.Cells[$StartRow, $StartColumn]
        $c.Value = $EmptyText
        $c.Style.Font.Italic = $true
        $c.Style.Font.Color.SetColor((ConvertTo-Color '#7F7F7F'))
        return [pscustomobject]@{ FirstRow = $StartRow; LastRow = $StartRow; LastColumn = $StartColumn; Range = $null; NextRow = $StartRow + 2; Count = 0; Headers = @() }
    }
    $null = $rows | Export-Excel -ExcelPackage $Package -WorksheetName $Sheet -StartRow $StartRow -StartColumn $StartColumn `
        -TableName $TableName -TableStyle $Style -NoNumberConversion '*' -PassThru
    $headers = @($rows[0].PSObject.Properties.Name)
    $lastRow = $StartRow + $rows.Count
    $lastCol = $StartColumn + $headers.Count - 1
    for ($i = 0; $i -lt $headers.Count; $i++) {
        $col  = $StartColumn + $i
        $h    = $headers[$i]
        $body = $ws.Cells[($StartRow + 1), $col, $lastRow, $col]
        $fmt  = Get-ColumnFormat $h
        if ($fmt) { $body.Style.Numberformat.Format = $fmt }
        if ($h -eq 'Portal' -or $h -match 'link$') {
            for ($r = $StartRow + 1; $r -le $lastRow; $r++) {
                $cell = $ws.Cells[$r, $col]
                if ($cell.Hyperlink) { $cell.Value = 'Open' }
            }
        }
        if ($HighlightRules.ContainsKey($h)) {
            foreach ($rule in $HighlightRules[$h]) { Add-CellHighlight -Ws $ws -Address $body.Address -Value $rule[0] -Fill $rule[1] -Font $(if ($rule.Count -gt 2) { $rule[2] } else { $null }) }
        }
    }
    if (-not $NoAutoFit) {
        $fitLast = [Math]::Min($lastRow, $StartRow + 400)
        try { $ws.Cells[$StartRow, $StartColumn, $fitLast, $lastCol].AutoFitColumns(8, 60) }
        catch { for ($c = $StartColumn; $c -le $lastCol; $c++) { $ws.Column($c).Width = 18 } }
        if (-not $script:SheetWidths.ContainsKey($Sheet)) { $script:SheetWidths[$Sheet] = @{} }
        for ($c = $StartColumn; $c -le $lastCol; $c++) {
            $w = $ws.Column($c).Width
            if (-not $script:SheetWidths[$Sheet].ContainsKey($c) -or $script:SheetWidths[$Sheet][$c] -lt $w) { $script:SheetWidths[$Sheet][$c] = $w }
        }
    }
    return [pscustomobject]@{
        FirstRow = $StartRow; LastRow = $lastRow; LastColumn = $lastCol; NextRow = $lastRow + 3; Count = $rows.Count; Headers = $headers
        Range    = $ws.Cells[$StartRow, $StartColumn, $lastRow, $lastCol]
    }
}

function Write-SheetTitle {
    param([OfficeOpenXml.ExcelWorksheet]$Ws, [string]$Title, [string]$Subtitle, [string]$Note, [string]$NoteColor = '#7F7F7F', [switch]$BackLink)
    $t = $Ws.Cells[1, 1]
    $t.Value = $Title
    $t.Style.Font.Size = 16
    $t.Style.Font.Bold = $true
    $t.Style.Font.Color.SetColor((ConvertTo-Color '#1F4E79'))
    $row = 2
    if ($Subtitle) {
        $Ws.Cells[$row, 1].Value = $Subtitle
        $Ws.Cells[$row, 1].Style.Font.Color.SetColor((ConvertTo-Color '#595959'))
        $row++
    }
    if ($Note) {
        $Ws.Cells[$row, 1].Value = $Note
        $Ws.Cells[$row, 1].Style.Font.Bold = $true
        $Ws.Cells[$row, 1].Style.Font.Color.SetColor((ConvertTo-Color $NoteColor))
        $row++
    }
    if ($BackLink) {
        $c = $Ws.Cells[$row, 1]
        $c.Hyperlink = [OfficeOpenXml.ExcelHyperLink]::new("'Summary'!A1", 'Back to Summary')
        $c.Value = '<< Back to Summary'
        $c.Style.Font.UnderLine = $true
        $c.Style.Font.Color.SetColor((ConvertTo-Color '#0563C1'))
        $row++
    }
    return $row + 1
}

function Write-SectionTitle {
    param([OfficeOpenXml.ExcelWorksheet]$Ws, [int]$Row, [string]$Text, [int]$Column = 1)
    $c = $Ws.Cells[$Row, $Column]
    $c.Value = $Text
    $c.Style.Font.Bold = $true
    $c.Style.Font.Size = 12
    $c.Style.Font.Color.SetColor((ConvertTo-Color '#1F4E79'))
    return $Row + 1
}

function Write-Kpi {
    # KPI tile: label (optionally a link to the sheet with the details) above a large value.
    param([OfficeOpenXml.ExcelWorksheet]$Ws, [int]$Row, [int]$Column, [string]$Label, $Value, [string]$Format, [string]$LinkSheet)
    $l = $Ws.Cells[$Row, $Column]
    if ($LinkSheet) { $l.Hyperlink = [OfficeOpenXml.ExcelHyperLink]::new("'$LinkSheet'!A1", $Label) }
    $l.Value = $Label
    $l.Style.Font.Size = 9
    $l.Style.WrapText = $true
    $l.Style.VerticalAlignment = [OfficeOpenXml.Style.ExcelVerticalAlignment]::Top
    $l.Style.Font.Color.SetColor((ConvertTo-Color $(if ($LinkSheet) { '#0563C1' } else { '#404040' })))
    if ($LinkSheet) { $l.Style.Font.UnderLine = $true }
    $v = $Ws.Cells[($Row + 1), $Column]
    $v.Value = $Value
    $long = $Value -is [string] -and $Value.Length -gt 12
    $v.Style.Font.Size = $(if ($long) { 10 } else { 16 })
    if ($long) { $v.Style.WrapText = $true }
    $v.Style.Font.Bold = $true
    $v.Style.Font.Color.SetColor((ConvertTo-Color '#1F4E79'))
    $v.Style.HorizontalAlignment = [OfficeOpenXml.Style.ExcelHorizontalAlignment]::Left
    if ($Format -and $Value -is [ValueType]) { $v.Style.Numberformat.Format = $Format }
    $box = $Ws.Cells[$Row, $Column, ($Row + 1), $Column]
    $box.Style.Fill.PatternType = [OfficeOpenXml.Style.ExcelFillStyle]::Solid
    $box.Style.Fill.BackgroundColor.SetColor((ConvertTo-Color '#DEEBF7'))
    $box.Style.Border.BorderAround([OfficeOpenXml.Style.ExcelBorderStyle]::Thin, (ConvertTo-Color '#9DC3E6'))
}

function Get-TextWidth {
    # Approximate width of single-line text in Excel column units (1 unit = one Calibri 11 digit), scaled
    # by font size and weight. Works without GDI+ (e.g. PowerShell on Linux / Cloud Shell).
    param([string]$Text, [double]$Size = 11, [switch]$Bold)
    $units = 0.0
    foreach ($ch in $Text.ToCharArray()) {
        $units += if ('.,:;''!|()[]{} ijltfrI-/'.IndexOf($ch) -ge 0) { 0.6 }
                  elseif ('mwMW@%'.IndexOf($ch) -ge 0) { 1.6 }
                  elseif ([char]::IsUpper($ch)) { 1.25 }
                  else { 1.0 }
    }
    return $units * $Size / 11 * $(if ($Bold) { 1.1 } else { 1.0 })
}

function Resize-ColumnToFit {
    # Widens (never narrows) the columns of the given ranges so that every single-line value fits: Excel
    # shows a number that does not fit as "#####". Wrapped and merged cells are ignored.
    param([OfficeOpenXml.ExcelWorksheet]$Ws, [string[]]$Address, [double]$MaxWidth = 60)
    $need = @{}
    foreach ($a in $Address) {
        foreach ($cell in $Ws.Cells[$a]) {
            if ($cell.Merge -or $cell.Style.WrapText) { continue }
            $text = $cell.Text
            if ([string]::IsNullOrEmpty($text)) { continue }
            $w   = (Get-TextWidth -Text $text -Size $cell.Style.Font.Size -Bold:$cell.Style.Font.Bold) + 2
            $col = $cell.Start.Column
            if ($w -gt [double]$need[$col]) { $need[$col] = $w }
        }
    }
    foreach ($col in @($need.Keys)) {
        $w = [Math]::Min($MaxWidth, [Math]::Ceiling($need[$col]))
        if ($Ws.Column($col).Width -lt $w) { $Ws.Column($col).Width = $w }
    }
}

function Set-PivotSortByValue {
    # EPPlus 4.5 only sorts pivot items by label; inject an autoSortScope so Excel sorts the row
    # field descending by the first data field when it refreshes the pivot table.
    param([OfficeOpenXml.Table.PivotTable.ExcelPivotTable]$PivotTable, [string]$FieldName, [int]$DataFieldIndex = 0)
    $xml = $PivotTable.PivotTableXml
    $ns  = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'
    $nsm = [System.Xml.XmlNamespaceManager]::new($xml.NameTable)
    $nsm.AddNamespace('d', $ns)
    $idx = $PivotTable.Fields[$FieldName].Index
    $pf  = $xml.SelectNodes('/d:pivotTableDefinition/d:pivotFields/d:pivotField', $nsm)[$idx]
    if (-not $pf) { return }
    $pf.SetAttribute('sortType', 'descending')
    $auto = $xml.CreateElement('autoSortScope', $ns)
    $area = $xml.CreateElement('pivotArea', $ns)
    $area.SetAttribute('dataOnly', '0')
    $area.SetAttribute('outline', '0')
    $area.SetAttribute('fieldPosition', '0')
    $refs = $xml.CreateElement('references', $ns)
    $refs.SetAttribute('count', '1')
    $ref = $xml.CreateElement('reference', $ns)
    $ref.SetAttribute('field', '4294967294')
    $ref.SetAttribute('count', '1')
    $ref.SetAttribute('selected', '0')
    $x = $xml.CreateElement('x', $ns)
    $x.SetAttribute('v', [string]$DataFieldIndex)
    [void]$ref.AppendChild($x)
    [void]$refs.AppendChild($ref)
    [void]$area.AppendChild($refs)
    [void]$auto.AppendChild($area)
    $ext = $pf.SelectSingleNode('d:extLst', $nsm)
    if ($ext) { [void]$pf.InsertBefore($auto, $ext) } else { [void]$pf.AppendChild($auto) }
}

function Get-DistinctCount {
    param([object[]]$Rows, [string]$Property)
    return @($Rows | ForEach-Object { $v = $_.$Property; if ($null -eq $v -or "$v" -eq '') { '(blank)' } else { "$v" } } | Sort-Object -Unique).Count
}

function Add-PivotBlock {
    # Pivot table at column B with its pivot chart to the right. Returns the number of rows used.
    # EPPlus 4.5 writes the source sheet name and column headers into the pivot cache XML unescaped:
    # keep '&', '<' and '"' out of pivot source sheet names and headers.
    param(
        [OfficeOpenXml.ExcelWorksheet]$Ws, [int]$Row, [string]$Name, [string]$Title, [string]$Subtitle,
        $Source, [string[]]$RowFields, [string[]]$ColumnFields = @(), [object[]]$DataFields,
        [string]$ChartType = 'ColumnClustered', [int]$RowItems = 1, [int]$ColumnItems = 0,
        [switch]$SortByValue, [int]$SortDataField = 0, [switch]$NoLegend, [switch]$NoGrandTotalRow
    )
    $t = $Ws.Cells[$Row, 2]
    $t.Value = $Title
    $t.Style.Font.Bold = $true
    $t.Style.Font.Size = 13
    $t.Style.Font.Color.SetColor((ConvertTo-Color '#1F4E79'))
    if ($Subtitle) {
        $s = $Ws.Cells[($Row + 1), 2]
        $s.Value = $Subtitle
        $s.Style.Font.Italic = $true
        $s.Style.Font.Size = 9
        $s.Style.Font.Color.SetColor((ConvertTo-Color '#7F7F7F'))
    }
    $pt = $Ws.PivotTables.Add($Ws.Cells[($Row + 2), 2], $Source, $Name)
    # Turn off "Autofit column widths on update": the pivots are stacked in shared columns, so each refresh
    # (including the refresh on open) would fit the columns to that pivot only and show '#####' in the others.
    $pt.UseAutoFormatting = $false
    foreach ($f in $RowFields) { $null = $pt.RowFields.Add($pt.Fields[$f]) }
    foreach ($f in $ColumnFields) { $null = $pt.ColumnFields.Add($pt.Fields[$f]) }
    foreach ($d in $DataFields) {
        $df = $pt.DataFields.Add($pt.Fields[$d.Field])
        $df.Function = [OfficeOpenXml.Table.PivotTable.DataFieldFunctions]$d.Function
        $df.Name = $d.Caption   # must differ from every source column name
        if ($d.Format) { $df.Format = $d.Format }
    }
    if ($DataFields.Count -gt 1) { $pt.DataOnRows = $false }
    $pt.RowHeaderCaption = $RowFields[0]
    if ($ColumnFields.Count) { $pt.ColumnHeaderCaption = $ColumnFields[0] }
    $pt.GrandTotalCaption = 'Total'
    $pt.TableStyle = [OfficeOpenXml.Table.TableStyles]::Medium9
    if ($NoGrandTotalRow) { $pt.RowGrandTotals = $false }   # OOXML rowGrandTotals = the bottom "Total" row (e.g. never sum across currencies)
    if ($SortByValue) { Set-PivotSortByValue -PivotTable $pt -FieldName $RowFields[-1] -DataFieldIndex $SortDataField }

    # Reserve the space Excel needs when it renders the pivot (overlapping pivots fail to refresh).
    $headerRows = if ($ColumnFields.Count -gt 0 -or $DataFields.Count -gt 1) { 2 } else { 1 }
    $height = $headerRows + [Math]::Max(1, $RowItems) + 1
    $width  = 1 + ([Math]::Max(1, $ColumnItems) * $DataFields.Count) + $(if ($ColumnFields.Count) { $DataFields.Count } else { 0 })

    $chart = $Ws.Drawings.AddChart("ch_$Name", [OfficeOpenXml.Drawing.Chart.eChartType]$ChartType, $pt)
    $chart.Title.Text = $Title
    $chart.SetPosition($Row - 1, 0, 1 + $width + 1, 10)
    $chart.SetSize(760, 360)
    $chart.EditAs = [OfficeOpenXml.Drawing.eEditAs]::OneCell
    if ($NoLegend) { $chart.Legend.Remove() } else { $chart.Legend.Position = [OfficeOpenXml.Drawing.Chart.eLegendPosition]::Right }
    if ($chart -is [OfficeOpenXml.Drawing.Chart.ExcelPieChart]) { $chart.DataLabel.ShowPercent = $true }
    return ([Math]::Max($height + 2, 19) + 2)
}

function Write-Placeholder {
    param([OfficeOpenXml.ExcelWorksheet]$Ws, [int]$Row, [string]$Title, [string]$Text)
    $t = $Ws.Cells[$Row, 2]
    $t.Value = $Title
    $t.Style.Font.Bold = $true
    $t.Style.Font.Size = 13
    $t.Style.Font.Color.SetColor((ConvertTo-Color '#1F4E79'))
    $s = $Ws.Cells[($Row + 1), 2]
    $s.Value = $Text
    $s.Style.Font.Italic = $true
    $s.Style.Font.Color.SetColor((ConvertTo-Color '#7F7F7F'))
    return 4
}

$pkg = Open-ExcelPackage -Path $OutputPath -Create
$wb  = $pkg.Workbook

# Sheet order: Summary, Visuals, Recommendations, Service Retirements, Service Health, Security Best Practices,
# Security Hygiene, Content Filters, Capacity and Quota, AI Cost Reconciliation, ML Compute and Dependencies,
# 23 service sheets, hidden data sheets.
$wsSummary = $wb.Worksheets.Add('Summary')
$wsVisuals = $wb.Worksheets.Add('Visuals')
$wsReco    = $wb.Worksheets.Add('Recommendations')
$wsRetire  = $wb.Worksheets.Add('Service Retirements')
$wsHealth  = $wb.Worksheets.Add('Service Health')
$wsSec     = $wb.Worksheets.Add('Security Best Practices')
$wsHyg     = $wb.Worksheets.Add('Security Hygiene')
$wsFilter  = $wb.Worksheets.Add('Content Filters')
$wsCap     = $wb.Worksheets.Add('Capacity and Quota')
$wsRecon   = $wb.Worksheets.Add('AI Cost Reconciliation')
$wsMl      = $wb.Worksheets.Add('ML Compute and Dependencies')
foreach ($svc in $ServiceCatalog) {
    $w = $wb.Worksheets.Add($svc.Sheet)
    $w.TabColor = ConvertTo-Color $(if ($svc.Group -eq $G1) { '#7030A0' } elseif ($svc.Group -eq $G2) { '#2E75B6' } else { '#7F7F7F' })
}
$wsDataRes   = $wb.Worksheets.Add('Data_Resources')
$wsDataDep   = $wb.Worksheets.Add('Data_Deployments')
$wsDataCost  = $wb.Worksheets.Add('Data_ModelCost')
$wsDataSpend = $wb.Worksheets.Add('Data_AISpend')
$wsSummary.TabColor = ConvertTo-Color '#1F4E79'
$wsVisuals.TabColor = ConvertTo-Color '#4472C4'
$wsReco.TabColor    = ConvertTo-Color '#C55A11'
$wsRetire.TabColor  = ConvertTo-Color '#BF8F00'
$wsHealth.TabColor  = ConvertTo-Color '#548235'
$wsSec.TabColor     = ConvertTo-Color '#C00000'
$wsHyg.TabColor     = ConvertTo-Color '#C00000'
$wsFilter.TabColor  = ConvertTo-Color '#C00000'
$wsCap.TabColor     = ConvertTo-Color '#0070C0'
$wsRecon.TabColor   = ConvertTo-Color '#00B050'
$wsMl.TabColor      = ConvertTo-Color '#0070C0'

$failedText    = 'INCOMPLETE - the query failed (see Data collection notes on the Summary sheet); rows shown are partial.'
$generatedText = 'Generated {0:yyyy-MM-dd HH:mm} UTC.' -f $RunStartedUtc

# --- Sheet 3: Recommendations (Azure Advisor) ---
$row = Write-SheetTitle -Ws $wsReco -Title 'Recommendations' -BackLink `
    -Subtitle ('Azure Advisor recommendations for the AI resources in scope ({0}). Service retirements and Azure Service Health events are on their own sheets. {1}' -f $AdvisorRows.Count, $generatedText)
$row = Write-SectionTitle -Ws $wsReco -Row $row -Text "Azure Advisor recommendations ($($AdvisorRows.Count))$(if (-not $AdvisorOk) { " - $failedText" })"
$advisorTable = Write-Table -Package $pkg -Sheet 'Recommendations' -StartRow $row -Data $AdvisorRows -TableName 'tblAdvisor' `
    -EmptyText $(if ($AdvisorOk) { 'No active Azure Advisor recommendations for the AI resources in scope.' } else { 'Azure Advisor data could not be collected.' })

# --- Sheet 4: Service Retirements ---
$riskSummary = (@('RETIRED', 'CRITICAL', 'WARNING', 'REVIEW', 'OK') | ForEach-Object {
        $risk = $_
        '{0}: {1}' -f $risk, @($RetirementRows | Where-Object { $_.Risk -eq $risk }).Count
    }) -join ' | '
$sourceSummary = (@($RetirementRows | Group-Object -Property Source | Sort-Object -Property Name | ForEach-Object { '{0}: {1}' -f $_.Name, $_.Count })) -join ' | '
$retireGaps = @(
    if (-not $DoLifecycle) { 'model lifecycle was skipped (-SkipModelLifecycle)' }
    if (-not $AdvisorOk) { 'the Azure Advisor query failed' }
    if (-not $HealthOk) { 'the Azure Service Health query failed' }
)
$row = Write-SheetTitle -Ws $wsRetire -Title 'Service Retirements' -BackLink `
    -Subtitle ('Model lifecycle (model catalog), Azure Advisor retirement recommendations, Azure Service Health retirement notices and classic AI services. Risk: RETIRED = past the retirement date, CRITICAL <= {0} days, WARNING <= {1} days, REVIEW = no retirement date published. {2}' -f $CriticalDays, $WarningDays, $generatedText) `
    -Note $(if ($retireGaps.Count) { "INCOMPLETE - $($retireGaps -join '; ') (see Data collection notes on the Summary sheet)." }) -NoteColor '#C00000'
$row = Write-SectionTitle -Ws $wsRetire -Row $row -Text "Service retirements ($($RetirementRows.Count)) - $riskSummary$(if ($sourceSummary) { " | Sources - $sourceSummary" })"
$null = Write-Table -Package $pkg -Sheet 'Service Retirements' -StartRow $row -Data $RetirementRows -TableName 'tblRetirements' `
    -EmptyText 'No retirements found for the AI resources in scope.'

# --- Sheet 5: Service Health ---
$typeSummary = (@('Service issue', 'Planned maintenance', 'Health advisory', 'Security advisory', 'Billing update') | ForEach-Object {
        $label = $_
        '{0}: {1}' -f $label, @($HealthRows | Where-Object { $_.'Event type' -eq $label }).Count
    }) -join ' | '
$healthScope = if ($AllServiceHealthEvents) { 'for all services in the subscriptions with AI resources (-AllServiceHealthEvents)' } else { 'that affect AI services or AI resources in scope' }
$row = Write-SheetTitle -Ws $wsHealth -Title 'Service Health' -BackLink `
    -Subtitle ('Azure Service Health events {0} - active, or updated in the last {1} days. {2}' -f $healthScope, $EventDays, $generatedText)
$row = Write-SectionTitle -Ws $wsHealth -Row $row -Text "Azure Service Health events ($($HealthRows.Count)) - $typeSummary$(if (-not $HealthOk) { " - $failedText" })"
$null = Write-Table -Package $pkg -Sheet 'Service Health' -StartRow $row -Data $HealthRows -TableName 'tblServiceHealth' `
    -EmptyText $(if ($HealthOk) { "No AI-related Service Health events (active, or updated in the last $EventDays days)." } else { 'Azure Service Health data could not be collected.' })

# --- Sheet 6: Security Best Practices ---
$row = Write-SheetTitle -Ws $wsSec -Title 'Security Best Practices' -BackLink `
    -Subtitle ('Microsoft Defender for Cloud - plan coverage ({0} subscription(s)), recommendations ({1}, {2} unhealthy) and security alerts ({3}, last {4} days) for AI resources.' -f $PlanRows.Count, $AssessmentRows.Count, $UnhealthyCount, $AlertRows.Count, $EventDays)
$row = Write-SectionTitle -Ws $wsSec -Row $row -Text "Defender for Cloud plan coverage (subscriptions hosting AI resources)$(if (-not $PlansOk) { " - $failedText" })"
$t = Write-Table -Package $pkg -Sheet 'Security Best Practices' -StartRow $row -Data $PlanRows -TableName 'tblDefenderPlans'
$row = Write-SectionTitle -Ws $wsSec -Row $t.NextRow -Text "Defender for Cloud recommendations for AI resources ($($AssessmentRows.Count), $UnhealthyCount unhealthy)$(if (-not $AssessmentsOk) { " - $failedText" })"
$assessmentTable = Write-Table -Package $pkg -Sheet 'Security Best Practices' -StartRow $row -Data $AssessmentRows -TableName 'tblDefenderAssessments' `
    -EmptyText $(if ($AssessmentsOk) { 'No Defender for Cloud assessments found for the AI resources (requires Microsoft Defender for Cloud and Security Reader).' } else { 'Defender for Cloud assessments could not be collected.' })
$row = Write-SectionTitle -Ws $wsSec -Row $assessmentTable.NextRow -Text "Security alerts for AI resources - last $EventDays days ($($AlertRows.Count))$(if (-not $AlertsOk) { " - $failedText" })"
$null = Write-Table -Package $pkg -Sheet 'Security Best Practices' -StartRow $row -Data $AlertRows -TableName 'tblDefenderAlerts' `
    -EmptyText $(if ($AlertsOk) { "No Defender for Cloud security alerts for AI resources in the last $EventDays days." } else { 'Defender for Cloud security alerts could not be collected.' })

# --- Sheet 7: Security Hygiene ---
$hygGaps = @(
    if ($hygieneErrors.ContainsKey('diag')) { 'diagnostic settings' }
    if ($hygieneErrors.ContainsKey('locks')) { 'resource locks' }
    if ($hygieneErrors.ContainsKey('activity')) { 'activity log' }
)
$noLockCount  = @($HygieneRows | Where-Object { $_.'Resource lock' -eq 'None' }).Count
$openNetCount = @($HygieneRows | Where-Object { $_.'Network exposure' -eq 'All networks' }).Count
$activityText = if ($DoActivityLog) { "Key retrievals (list keys) and regenerations: activity log, last $ActivityDays days (a hub includes its projects)." }
                else { 'Key retrieval and rotation columns are blank: the activity log was skipped (-SkipActivityLog).' }
$row = Write-SheetTitle -Ws $wsHyg -Title 'Security Hygiene' -BackLink `
    -Subtitle ('Key-based (local) authentication, key usage and rotation, diagnostic logs, resource locks, network exposure, managed identity, encryption and Defender for AI services coverage of every AI resource. {0} {1}' -f $activityText, $generatedText) `
    -Note $(if ($hygGaps.Count) { "INCOMPLETE - $($hygGaps -join ', ') could not be read for some items (see Data collection notes on the Summary sheet)." }) -NoteColor '#C00000'
$row = Write-SectionTitle -Ws $wsHyg -Row $row -Text ('AI resources ({0}) - local auth enabled: {1} | key retrievals: {2} | without diagnostic logs: {3} | without resource lock: {4} | reachable from all networks: {5}' -f `
        $HygieneRows.Count, $LocalAuthCount, $(if ($null -ne $KeyRetrievalSum) { $KeyRetrievalSum } else { 'n/a' }), $NoDiagLogsCount, $noLockCount, $openNetCount)
$null = Write-Table -Package $pkg -Sheet 'Security Hygiene' -StartRow $row -Data $HygieneRows -TableName 'tblSecurityHygiene' -EmptyText 'No AI resources found in scope.'

# --- Sheet 8: Content Filters ---
$row = Write-SheetTitle -Ws $wsFilter -Title 'Content Filters' -BackLink `
    -Subtitle ('Content filter (RAI) policies of the Foundry and Azure OpenAI resources compared with the Microsoft.DefaultV2 baseline: hate, sexual, violence and self-harm block Medium+ on prompts and completions, prompt shields (jailbreak) and protected material (text) block, protected material (code) annotates. Relaxed = weaker than the baseline in at least one setting; Not set = the deployment names no policy (the service default applies where the model supports content filtering). Filter request counts: Azure Monitor, last {0} days. {1}' -f $UsageDays, $generatedText)
$row = Write-SectionTitle -Ws $wsFilter -Row $row -Text ('Content filter policies ({0}) - custom policies and the system policies in use | relaxed: {1}' -f $PolicyRows.Count, $RelaxedCount)
$t = Write-Table -Package $pkg -Sheet 'Content Filters' -StartRow $row -Data $PolicyRows -TableName 'tblContentFilterPolicies' `
    -EmptyText 'No content filter policies found (no Foundry or Azure OpenAI resources, or the policies could not be read).'
$row = Write-SectionTitle -Ws $wsFilter -Row $t.NextRow -Text ('Model deployments by content filter ({0}) - not set: {1}' -f $FilterDeploymentRows.Count, $FilterNotSetCount)
$filterTable = Write-Table -Package $pkg -Sheet 'Content Filters' -StartRow $row -Data $FilterDeploymentRows -TableName 'tblContentFilterDeployments' `
    -EmptyText 'No Foundry or Azure OpenAI model deployments found.'

# --- Sheet 9: Capacity and Quota ---
$row = Write-SheetTitle -Ws $wsCap -Title 'Capacity and Quota' -BackLink `
    -Subtitle ('Utilization of the Foundry and Azure OpenAI model deployments against their capacity - busiest-hour tokens per minute vs the rate limit, HTTP 429 throttling, PTU utilization, days without requests - and the model quota of each subscription and region (Cognitive Services usages API). Usage: last {0} days; idle detection: last {1} days. {2}' -f $UsageDays, $IdleLookbackDays, $generatedText) `
    -Note $(if (-not $DoMetrics) { 'Right-sizing needs Azure Monitor metrics: not assessed (-SkipMetrics).' }) -NoteColor '#C00000'
$row = Write-SectionTitle -Ws $wsCap -Row $row -Text ('Deployment right-sizing ({0} deployment(s), {1} candidate(s)) - Idle: no request for 30+ days | Throttled: 100+ or 1%+ HTTP 429 | PTU saturated: busiest hour 95%+ without spillover | PTU under-used: average below 30% | Over-allocated: busiest hour below 10% of the TPM limit' -f $RightSizingRows.Count, $RightSizingCandidates)
$rightTable = Write-Table -Package $pkg -Sheet 'Capacity and Quota' -StartRow $row -Data $RightSizingRows -TableName 'tblRightSizing' -EmptyText 'No Foundry or Azure OpenAI model deployments found.'
$row = Write-SectionTitle -Ws $wsCap -Row $rightTable.NextRow -Text ('Model quota in use ({0}) - {1} at 90% or more (Full: 100%+, High: 80%+)' -f $QuotaRows.Count, $QuotaHighCount)
$null = Write-Table -Package $pkg -Sheet 'Capacity and Quota' -StartRow $row -Data $QuotaRows -TableName 'tblQuota' -EmptyText 'No model quota in use (or the quota could not be read).'

# --- Sheet 10: AI Cost Reconciliation ---
$shareText = { param($v) if ($null -ne $v) { '{0:P1}' -f $v } else { 'n/a' } }
$reconNote = if (-not $DoCost) { 'Cost collection was skipped (-SkipCost).' }
             elseif (-not $ReconAvailable) { 'The AI cost outside the AI resources could not be read (see Data collection notes on the Summary sheet).' }
             elseif (-not ($SpendOk.Actual -and $SpendOk.Amortized)) {
                 'INCOMPLETE - total AI spend ({0}) is not computed: part of that cost could not be read (see Data collection notes on the Summary sheet).' -f `
                    ((@(if (-not $SpendOk.Actual) { 'actual' }) + @(if (-not $SpendOk.Amortized) { 'amortized' })) -join ' and ')
             }
             else { $null }
$row = Write-SheetTitle -Ws $wsRecon -Title 'AI Cost Reconciliation' -BackLink `
    -Subtitle ('Total AI spend, last {0} days: the AI resources on the service sheets plus the AI cost billed elsewhere - AI reservation purchases (e.g. PTU), unused AI reservations, Marketplace AI models, Copilot Studio and other AI meters - compared with all charges of the scanned subscriptions. Totals, non-AI spend and shares are Excel formulas. {1}' -f $UsageDays, $generatedText) `
    -Note $reconNote -NoteColor '#C00000'
$row = Write-SectionTitle -Ws $wsRecon -Row $row -Text ('AI spend by cost line - total AI spend: actual {0}, amortized {1} | AI share of subscription spend: actual {2}, amortized {3}' -f `
        $AiSpendActualText, $AiSpendAmortizedText, (& $shareText $AiShareActual), (& $shareText $AiShareAmortized))
$lineTable = Write-Table -Package $pkg -Sheet 'AI Cost Reconciliation' -StartRow $row -Data $ReconLineRows -TableName 'tblReconLines' `
    -EmptyText $(if ($reconNote) { $reconNote } else { 'No cost data.' })
if ($lineTable.Count) {
    $h     = @($lineTable.Headers)
    $block = $ReconLines.Count + 3   # cost lines + total AI spend + subscription total + non-AI spend
    $measures = @(
        @{ Col = 1 + $h.IndexOf('Actual cost'); Share = 1 + $h.IndexOf('Share of actual'); AiOk = $SpendOk.Actual; TotOk = [bool]$TotalsOk.Actual.Count },
        @{ Col = 1 + $h.IndexOf('Amortized cost'); Share = 1 + $h.IndexOf('Share of amortized'); AiOk = $SpendOk.Amortized; TotOk = [bool]$TotalsOk.Amortized.Count }
    )
    for ($b = 0; $b -lt $ReconCurrencies.Count; $b++) {
        $r0   = $lineTable.FirstRow + 1 + $b * $block
        $rAi  = $r0 + $ReconLines.Count
        $rSub = $rAi + 1
        $rNon = $rAi + 2
        foreach ($m in $measures) {
            $subCell = $wsRecon.Cells[$rSub, $m.Col].Address
            if ($m.AiOk) { $wsRecon.Cells[$rAi, $m.Col].Formula = 'SUM({0})' -f $wsRecon.Cells[$r0, $m.Col, ($rAi - 1), $m.Col].Address }
            if ($m.AiOk -and $m.TotOk) { $wsRecon.Cells[$rNon, $m.Col].Formula = '{0}-{1}' -f $subCell, $wsRecon.Cells[$rAi, $m.Col].Address }
            if (-not $m.TotOk) { continue }
            for ($r = $r0; $r -le $rNon; $r++) {
                $a = $wsRecon.Cells[$r, $m.Col].Address
                $wsRecon.Cells[$r, $m.Share].Formula = 'IF(AND(ISNUMBER({0}),ISNUMBER({1}),{1}<>0),{0}/{1},"")' -f $a, $subCell
            }
        }
        $wsRecon.Cells[$rAi, 1, $rNon, $lineTable.LastColumn].Style.Font.Bold = $true
        $wsRecon.Cells[$rAi, 1, $rAi, $lineTable.LastColumn].Style.Border.Top.Style = [OfficeOpenXml.Style.ExcelBorderStyle]::Thin
    }
}
$row = Write-SectionTitle -Ws $wsRecon -Row $lineTable.NextRow -Text ('AI spend per subscription ({0}) - AI resources = the AI resource lines, other AI = the other cost lines' -f $ReconSubRows.Count)
$subTable = Write-Table -Package $pkg -Sheet 'AI Cost Reconciliation' -StartRow $row -Data $ReconSubRows -TableName 'tblReconSubscriptions' `
    -EmptyText $(if ($reconNote) { $reconNote } else { 'No cost data.' })
if ($subTable.Count) {
    $h = @($subTable.Headers)
    foreach ($m in 'actual', 'amortized') {
        $cRes = 1 + $h.IndexOf("AI resources $m cost")
        $cOth = 1 + $h.IndexOf("Other AI $m cost")
        $cTot = 1 + $h.IndexOf("Total AI $m cost")
        $cSub = 1 + $h.IndexOf("Subscription $m cost")
        $cShr = 1 + $h.IndexOf("AI share ($m)")
        for ($r = $subTable.FirstRow + 1; $r -le $subTable.LastRow; $r++) {
            $tot = $wsRecon.Cells[$r, $cTot].Address
            $sub = $wsRecon.Cells[$r, $cSub].Address
            if ($null -ne $wsRecon.Cells[$r, $cRes].Value -and $null -ne $wsRecon.Cells[$r, $cOth].Value) {
                $wsRecon.Cells[$r, $cTot].Formula = '{0}+{1}' -f $wsRecon.Cells[$r, $cRes].Address, $wsRecon.Cells[$r, $cOth].Address
            }
            $wsRecon.Cells[$r, $cShr].Formula = 'IF(AND(ISNUMBER({0}),ISNUMBER({1}),{1}<>0),{0}/{1},"")' -f $tot, $sub
        }
    }
}
$row = Write-SectionTitle -Ws $wsRecon -Row $subTable.NextRow -Text ('AI cost outside the service sheets - detail ({0})' -f $ReconDetailRows.Count)
$null = Write-Table -Package $pkg -Sheet 'AI Cost Reconciliation' -StartRow $row -Data $ReconDetailRows -TableName 'tblReconDetail' `
    -EmptyText $(if ($reconNote) { $reconNote } else { 'No AI cost outside the AI resources on the service sheets.' })
# Cached values for the formulas (Excel recalculates them on open; other readers see the values).
try { [OfficeOpenXml.CalculationExtension]::Calculate($wsRecon) } catch { Write-Verbose "Formula pre-calculation skipped: $($_.Exception.Message)" }

# --- Sheet 11: ML Compute and Dependencies ---
$depIssueCount = @($DependencyRows | Where-Object { $_.Issues -gt 0 }).Count
$depMissing    = @($DependencyRows | Where-Object { $_.Found -eq 'Missing' }).Count
$mlGaps = @(
    if ($hygieneErrors.ContainsKey('computes')) { 'the computes of some workspaces' }
    if ($depIds.Count -and -not (Test-ArgComplete 'ML workspace dependencies')) { 'the workspace dependencies (Resource Graph)' }
)
$row = Write-SheetTitle -Ws $wsMl -Title 'ML Compute and Dependencies' -BackLink `
    -Subtitle ('Computes of the Azure Machine Learning workspaces and AI hubs (auto-shutdown, always-on nodes, public IP, SSH, local auth), the workspace dependencies (storage account, key vault, container registry, Application Insights) and the workspace cost by meter category (last {0} days). {1}' -f $UsageDays, $generatedText) `
    -Note $(if ($mlGaps.Count) { "INCOMPLETE - $($mlGaps -join ' and ') could not be read (see Data collection notes on the Summary sheet)." }) -NoteColor '#C00000'
$row = Write-SectionTitle -Ws $wsMl -Row $row -Text ('Computes ({0}) - {1} with findings' -f $ComputeRows.Count, $ComputeIssueCount)
$t = Write-Table -Package $pkg -Sheet 'ML Compute and Dependencies' -StartRow $row -Data $ComputeRows -TableName 'tblMlComputes' `
    -EmptyText $(if ($MlWorkspaces.Count) { 'No computes found in the workspaces.' } else { 'No Machine Learning workspaces or AI hubs found in scope.' })
$row = Write-SectionTitle -Ws $wsMl -Row $t.NextRow -Text ('Workspace dependencies ({0}) - {1} with findings, {2} missing' -f $DependencyRows.Count, $depIssueCount, $depMissing)
$t = Write-Table -Package $pkg -Sheet 'ML Compute and Dependencies' -StartRow $row -Data $DependencyRows -TableName 'tblMlDependencies' -EmptyText 'No workspace dependencies found.'
$row = Write-SectionTitle -Ws $wsMl -Row $t.NextRow -Text ('Workspace cost by meter category ({0}) - compute, storage and other meters billed on the workspaces, AI hubs and hub projects' -f $MlCostRows.Count)
$mlCostTable = Write-Table -Package $pkg -Sheet 'ML Compute and Dependencies' -StartRow $row -Data $MlCostRows -TableName 'tblMlCost' `
    -EmptyText $(if (-not $DoCost) { 'Cost collection was skipped (-SkipCost).' } else { 'No cost billed on the workspaces in the window.' })

# --- Sheets 12-34: one sheet per AI service ---
foreach ($svc in $ServiceCatalog) {
    $ws    = $wb.Worksheets[$svc.Sheet]
    $items = @($Resources | Where-Object { $_.ServiceKey -eq $svc.Key })
    $note  = $null
    $noteColor = '#7F7F7F'
    if ($svc.Group -eq $G3) {
        $noteColor = '#C00000'
        if ($svc.RetireDate) {
            $days = Get-DaysUntil $svc.RetireDate
            $when = if ($days -lt 0) { 'retired on {0:yyyy-MM-dd} ({1} days ago)' -f $svc.RetireDate, (-$days) } else { 'retires on {0:yyyy-MM-dd} ({1} days left)' -f $svc.RetireDate, $days }
            $note = "RETIREMENT: $($svc.Name) $when. $($svc.Guidance) More info: $($svc.Link)"
        }
        else { $note = "LIFECYCLE: $($svc.Guidance) More info: $($svc.Link)" }
    }
    $subtitle = '{0} | {1} | {2} resource(s) | Usage and cost window: last {3} days (actual and amortized cost)' -f $svc.Group, $svc.Scope, $items.Count, $UsageDays
    $row = Write-SheetTitle -Ws $ws -Title $svc.Name -Subtitle $subtitle -Note $note -NoteColor $noteColor -BackLink
    $primaryTitle = switch ($svc.Family) { 'MLHub' { "AI hubs ($($items.Count))" } 'ML' { "Workspaces ($($items.Count))" } default { "Resources ($($items.Count))" } }
    $row = Write-SectionTitle -Ws $ws -Row $row -Text $primaryTitle
    $t = Write-Table -Package $pkg -Sheet $svc.Sheet -StartRow $row -Data @(Get-ServiceRows -Service $svc -Items $items) -TableName "tbl$($svc.Key)" `
        -EmptyText "No $($svc.Name) resources found in scope."
    $row = $t.NextRow

    if ($svc.Key -in 'Foundry', 'AzureOpenAI') {
        $deps = @($ModelHostDeployments | Where-Object { $_.Platform -eq $svc.Name } | Sort-Object -Property Account, Deployment)
        $row = Write-SectionTitle -Ws $ws -Row $row -Text "Model deployments ($($deps.Count)) - lifecycle from the model catalog, tokens from Azure Monitor; Est. actual / amortized cost = billed token cost split by token share across pay-as-you-go deployments, PTU cost by provisioned capacity; blank = not attributable, cost of deleted deployments stays unallocated"
        $t = Write-Table -Package $pkg -Sheet $svc.Sheet -StartRow $row -Data (Select-Export -Rows $deps -Exclude 'Platform') -TableName "tbl$($svc.Key)Deployments" `
            -EmptyText 'No model deployments found.'
        $row = $t.NextRow
    }
    if ($svc.Key -eq 'Foundry') {
        $projects = @($FoundryProjects | Sort-Object -Property 'Foundry resource', 'Project')
        $row = Write-SectionTitle -Ws $ws -Row $row -Text "Foundry projects ($($projects.Count))"
        $null = Write-Table -Package $pkg -Sheet $svc.Sheet -StartRow $row -Data $projects -TableName 'tblFoundryProjects' -EmptyText 'No Foundry projects found.'
    }
    if ($svc.Key -eq 'AIHubs') {
        $projectRows = @($HubProjects | Sort-Object -Property @{ Expression = { if ($_.Hub) { $_.Hub.Name } else { '' } } }, Name | ForEach-Object { Get-HubProjectRow $_ })
        $row = Write-SectionTitle -Ws $ws -Row $row -Text "Hub-based projects ($($projectRows.Count))"
        $t = Write-Table -Package $pkg -Sheet $svc.Sheet -StartRow $row -Data $projectRows -TableName 'tblAIHubsProjects' -EmptyText 'No hub-based projects found.'
        $eps = @($MlEndpoints | Where-Object { $_.WorkspaceItem -and $_.WorkspaceItem.ServiceKey -eq 'AIHubs' } | Sort-Object -Property WorkspaceName, EndpointName, DeploymentName | ForEach-Object { Get-EndpointRow $_ })
        $row = Write-SectionTitle -Ws $ws -Row $t.NextRow -Text "Endpoints and model deployments of hubs / projects ($($eps.Count))"
        $null = Write-Table -Package $pkg -Sheet $svc.Sheet -StartRow $row -Data $eps -TableName 'tblAIHubsEndpoints' -EmptyText 'No serverless or managed online endpoints found.'
    }
    if ($svc.Key -eq 'MachineLearning') {
        $eps = @($MlEndpoints | Where-Object { -not $_.WorkspaceItem -or $_.WorkspaceItem.ServiceKey -eq 'MachineLearning' } | Sort-Object -Property WorkspaceName, EndpointName, DeploymentName | ForEach-Object { Get-EndpointRow $_ })
        $row = Write-SectionTitle -Ws $ws -Row $row -Text "Endpoints and model deployments ($($eps.Count))"
        $null = Write-Table -Package $pkg -Sheet $svc.Sheet -StartRow $row -Data $eps -TableName 'tblMachineLearningEndpoints' -EmptyText 'No online, serverless or batch endpoints found.'
    }
}

# --- Hidden pivot sources ---
$resTable  = Write-Table -Package $pkg -Sheet 'Data_Resources' -StartRow 1 -Data $DataResources -TableName 'tblDataResources' -Style 'Light1' -NoAutoFit -EmptyText 'No data'
$depTable  = Write-Table -Package $pkg -Sheet 'Data_Deployments' -StartRow 1 -Data $DataDeployments -TableName 'tblDataDeployments' -Style 'Light1' -NoAutoFit -EmptyText 'No data'
$costTable = Write-Table -Package $pkg -Sheet 'Data_ModelCost' -StartRow 1 -Data (Select-Export -Rows $ModelCostRows) -TableName 'tblDataModelCost' -Style 'Light1' -NoAutoFit -EmptyText 'No data'
$spendTable = Write-Table -Package $pkg -Sheet 'Data_AISpend' -StartRow 1 -Data (Select-Export -Rows $SpendRows) -TableName 'tblDataAISpend' -Style 'Light1' -NoAutoFit -EmptyText 'No data'
foreach ($w in $wsDataRes, $wsDataDep, $wsDataCost, $wsDataSpend) { for ($c = 1; $c -le 32; $c++) { $w.Column($c).Width = 20 } }

# --- Sheet 1: Summary ---
$ws = $wsSummary
$ws.View.ShowGridLines = $false
$ws.Column(1).Width = 2
$ws.Column(2).Width = 46
for ($c = 3; $c -le 24; $c++) { $ws.Column($c).Width = 18 }

$scopeText = if ($SubscriptionId) { "$($SubscriptionId.Count) selected subscription(s)" } elseif ($ManagementGroupId) { "management group '$ManagementGroupId'" } else { 'all accessible subscriptions of the tenant' }
$ws.Cells['B1'].Value = 'Azure AI Inventory'
$ws.Cells['B1'].Style.Font.Size = 22
$ws.Cells['B1'].Style.Font.Bold = $true
$ws.Cells['B1'].Style.Font.Color.SetColor((ConvertTo-Color '#1F4E79'))
$ws.Cells['B2'].Value = 'Tenant {0} | Signed in as {1} | Scope: {2} ({3} with AI resources) | Generated {4:yyyy-MM-dd HH:mm} (local) / {5:yyyy-MM-dd HH:mm} UTC' -f `
    $TenantId, $AzContext.Account.Id, $scopeText, $AiSubscriptions.Count, (Get-Date), $RunStartedUtc
$ws.Cells['B2'].Style.Font.Color.SetColor((ConvertTo-Color '#595959'))
$actualPartial    = $DoCost -and $ActualOkSubs.Count -gt 0 -and $ActualOkSubs.Count -lt $AiSubscriptions.Count
$amortizedPartial = $DoCost -and $AmortizedOkSubs.Count -gt 0 -and $AmortizedOkSubs.Count -lt $AiSubscriptions.Count
$costGap          = $DoCost -and $AiSubscriptions.Count -gt 0 -and ($ActualOkSubs.Count -lt $AiSubscriptions.Count -or $AmortizedOkSubs.Count -lt $AiSubscriptions.Count)
$ws.Cells['B3'].Value = 'Cost and token usage: last {0} days (actual and amortized cost{1}{2}). Service Health: active + last {3} days; security alerts: last {3} days. Retirement flags: CRITICAL <= {4} days, WARNING <= {5} days.' -f `
    $UsageDays, $(if ($CurrencyLabel) { ", $CurrencyLabel" } else { '' }), $(if ($costGap) { '; incomplete - see Data collection notes' } else { '' }), $EventDays, $CriticalDays, $WarningDays
$ws.Cells['B3'].Style.Font.Italic = $true
$ws.Cells['B3'].Style.Font.Size = 9
$ws.Cells['B3'].Style.Font.Color.SetColor((ConvertTo-Color '#7F7F7F'))

$servicesInUse  = @($SummaryRows | Where-Object { $_.Resources -gt 0 }).Count
$distinctModels = @($DataDeployments | ForEach-Object { $_.Model } | Where-Object { $_ -and $_ -notin '(unknown)', '(custom)' } | Sort-Object -Unique).Count
$retireSoon     = @($RetirementRows | Where-Object { $null -ne $_.'Days remaining' -and $_.'Days remaining' -le $WarningDays }).Count
$activeHealth   = @($HealthRows | Where-Object { $_.Status -eq 'Active' }).Count
$tokenTotal     = [double](($ModelHostDeployments | ForEach-Object { [double]$_.'Total tokens' } | Measure-Object -Sum).Sum)
$costSuffix     = if ($CurrencyLabel -and -not $MultiCurrency) { " ($CurrencyLabel)" } else { '' }
$actualKpi      = if (-not $ActualOkSubs.Count) { 'n/a' } elseif ($MultiCurrency) { $ActualTotalText } else { $TotalActual }
$amortizedKpi   = if (-not $AmortizedOkSubs.Count) { 'n/a' } elseif ($MultiCurrency) { $AmortizedTotalText } else { $TotalAmortized }
$spendCurrency  = @(@($AiSpendAmortized.Keys) + @($AiSpendActual.Keys) | Where-Object { $_ } | Sort-Object -Unique)
$spendSingle    = $ReconAvailable -and $spendCurrency.Count -le 1
$spendSuffix    = if ($spendSingle -and $spendCurrency.Count) { " ($($spendCurrency[0]))" } else { '' }
$aiSpendActualKpi    = if (-not $SpendOk.Actual) { 'n/a' } elseif ($spendSingle) { [double](@($AiSpendActual.Values) + 0 | Measure-Object -Sum).Sum } else { $AiSpendActualText }
$aiSpendAmortizedKpi = if (-not $SpendOk.Amortized) { 'n/a' } elseif ($spendSingle) { [double](@($AiSpendAmortized.Values) + 0 | Measure-Object -Sum).Sum } else { $AiSpendAmortizedText }
# Label, value, number format, sheet the label links to.
$kpis = @(
    @('AI resources', $Resources.Count, '#,##0', $null),
    @('AI services in use', ('{0} / {1}' -f $servicesInUse, $ServiceCatalog.Count), $null, $null),
    @('Subscriptions with AI', $AiSubscriptions.Count, '#,##0', $null),
    @('Regions', @($Resources | ForEach-Object { $_.Region } | Sort-Object -Unique).Count, '#,##0', $null),
    @('Model deployments', $DataDeployments.Count, '#,##0', 'Visuals'),
    @('Distinct models', $distinctModels, '#,##0', 'Visuals'),
    @("Tokens - last $UsageDays days", $(if ($DoMetrics) { $tokenTotal } else { 'n/a' }), '#,##0', 'Visuals'),
    @("Actual cost - last $UsageDays days$costSuffix$(if ($actualPartial) { ' (partial)' })", $actualKpi, '#,##0.00', 'Visuals'),
    @("Amortized cost - last $UsageDays days$costSuffix$(if ($amortizedPartial) { ' (partial)' })", $amortizedKpi, '#,##0.00', 'Visuals'),
    @("Total AI spend - actual$spendSuffix", $aiSpendActualKpi, '#,##0.00', 'AI Cost Reconciliation'),
    @("Total AI spend - amortized$spendSuffix", $aiSpendAmortizedKpi, '#,##0.00', 'AI Cost Reconciliation'),
    @('AI share of subscription spend (amortized)', $(if ($null -ne $AiShareAmortized) { $AiShareAmortized } else { 'n/a' }), '0.0%', 'AI Cost Reconciliation'),
    @('Advisor recommendations', $(if ($AdvisorOk) { $AdvisorRows.Count } else { 'n/a' }), '#,##0', 'Recommendations'),
    @("Retired or retiring within $WarningDays days", $retireSoon, '#,##0', 'Service Retirements'),
    @('Active Service Health events', $(if ($HealthOk) { $activeHealth } else { 'n/a' }), '#,##0', 'Service Health'),
    @('Defender unhealthy findings', $(if ($AssessmentsOk) { $UnhealthyCount } else { 'n/a' }), '#,##0', 'Security Best Practices'),
    @("Security alerts - last $EventDays days", $(if ($AlertsOk) { $AlertRows.Count } else { 'n/a' }), '#,##0', 'Security Best Practices'),
    @('Resources with local auth (keys) enabled', $LocalAuthCount, '#,##0', 'Security Hygiene'),
    @('Resources without diagnostic logs', $(if ($DiagByRes.Count) { $NoDiagLogsCount } else { 'n/a' }), '#,##0', 'Security Hygiene'),
    @('Relaxed content filter policies', $RelaxedCount, '#,##0', 'Content Filters'),
    @('Deployments without content filter', $FilterNotSetCount, '#,##0', 'Content Filters'),
    @('Right-sizing candidates', $(if ($DoMetrics) { $RightSizingCandidates } else { 'n/a' }), '#,##0', 'Capacity and Quota'),
    @('Model quotas 90%+ used', $(if ($QuotaByPair.Count) { $QuotaHighCount } else { 'n/a' }), '#,##0', 'Capacity and Quota'),
    @('ML computes with findings', $ComputeIssueCount, '#,##0', 'ML Compute and Dependencies')
)
$kpisPerRow = 8
for ($i = 0; $i -lt $kpis.Count; $i++) {
    Write-Kpi -Ws $ws -Row ([int](5 + [Math]::Floor($i / $kpisPerRow) * 3)) -Column (2 + ($i % $kpisPerRow)) `
        -Label $kpis[$i][0] -Value $kpis[$i][1] -Format $kpis[$i][2] -LinkSheet $kpis[$i][3]
}
$kpiRows = [int][Math]::Ceiling($kpis.Count / $kpisPerRow)
for ($r = 0; $r -lt $kpiRows; $r++) {
    $labelRow = 5 + $r * 3
    $ws.Row($labelRow).Height = 26   # two lines of 9pt label text
    $tileValues = @($kpis | Select-Object -Skip ($r * $kpisPerRow) -First $kpisPerRow | ForEach-Object { $_[1] })
    if (@($tileValues | Where-Object { $_ -is [string] -and $_.Length -gt 12 }).Count) { $ws.Row($labelRow + 1).Height = 40 }
}

$row = Write-SectionTitle -Ws $ws -Row (5 + $kpiRows * 3 + 1) -Column 2 -Text 'AI services summary (select a sheet name to open it)'
$summaryTable = Write-Table -Package $pkg -Sheet 'Summary' -StartRow $row -StartColumn 2 -Data $SummaryRows -TableName 'tblSummary' -NoAutoFit
$hdr = @($summaryTable.Headers)
for ($i = 1; $i -lt $hdr.Count; $i++) { $ws.Column(2 + $i).Width = [Math]::Max(18, $hdr[$i].Length + 5) }
$longestReservation = [int]((@($SummaryRows | ForEach-Object { ([string]$_.'Reservation name').Length }) + 0 | Measure-Object -Maximum).Maximum)
$ws.Column(2 + $hdr.IndexOf('Reservation name')).Width = [Math]::Min(60, [Math]::Max(20, $longestReservation + 3))
$sheetCol = 2 + $hdr.IndexOf('Sheet')
$ws.Column($sheetCol).Width = 34
for ($r = $summaryTable.FirstRow + 1; $r -le $summaryTable.LastRow; $r++) {
    $cell = $ws.Cells[$r, $sheetCol]
    $name = [string]$cell.Value
    $cell.Hyperlink = [OfficeOpenXml.ExcelHyperLink]::new("'$name'!A1", $name)
    $cell.Value = $name
    $cell.Style.Font.UnderLine = $true
    $cell.Style.Font.Color.SetColor((ConvertTo-Color '#0563C1'))
}
$totalRow = $summaryTable.LastRow + 1
# What the KPI tiles count but no service row holds, on its own line so that the total matches the tiles.
$otherValues = [ordered]@{}
$otherParts  = [System.Collections.Generic.List[string]]::new()
if ($OutsideCount) {
    if ($ActualOkSubs.Count) { $otherValues['Actual cost'] = $(if ($MultiCurrency) { Format-CurrencyTotal -Map $OutsideActualByCurrency -Available $true } else { [double](@($OutsideActualByCurrency.Values) + 0 | Measure-Object -Sum).Sum }) }
    if ($AmortizedOkSubs.Count) { $otherValues['Amortized cost'] = $(if ($MultiCurrency) { Format-CurrencyTotal -Map $OutsideAmortizedByCurrency -Available $true } else { [double](@($OutsideAmortizedByCurrency.Values) + 0 | Measure-Object -Sum).Sum }) }
    $otherParts.Add("cost of $OutsideCount resource(s) no longer in scope or of other kinds")
}
if ($AdvisorOk -and $UnattributedAdvisor) { $otherValues['Advisor recommendations'] = $UnattributedAdvisor; $otherParts.Add("$UnattributedAdvisor subscription-level recommendation(s)") }
if ($UnattributedRetirements) { $otherValues['Retirement items'] = $UnattributedRetirements; $otherParts.Add("$UnattributedRetirements retirement item(s) of other services") }
if ($otherValues.Count) {
    $ws.Cells[$totalRow, 2].Value = 'Not on a service sheet'
    $desc = $ws.Cells[$totalRow, 3, $totalRow, (2 + $hdr.IndexOf('Model deployments'))]
    $desc.Merge = $true
    $ws.Cells[$totalRow, 3].Value = ($otherParts -join '; ')
    foreach ($k in $otherValues.Keys) {
        $cell = $ws.Cells[$totalRow, (2 + $hdr.IndexOf($k))]
        $cell.Value = $otherValues[$k]
        $fmt = Get-ColumnFormat $k
        $cell.Style.Numberformat.Format = $(if ($fmt) { $fmt } else { '#,##0' })
    }
    if ($OutsideCount -and -not $MultiCurrency -and $CurrencyLabel) { $ws.Cells[$totalRow, (2 + $hdr.IndexOf('Currency'))].Value = $CurrencyLabel }
    $otherRange = $ws.Cells[$totalRow, 2, $totalRow, $summaryTable.LastColumn]
    $otherRange.Style.Font.Italic = $true
    $otherRange.Style.Font.Color.SetColor((ConvertTo-Color '#595959'))
    $totalRow++
}
$ws.Cells[$totalRow, 2].Value = 'Total'
foreach ($colName in 'Resources', 'Model deployments', 'Actual cost', 'Amortized cost', 'Advisor recommendations', 'Defender unhealthy', 'Retirement items') {
    $ci   = 2 + $hdr.IndexOf($colName)
    $cell = $ws.Cells[$totalRow, $ci]
    if (($colName -in 'Actual cost', 'Amortized cost') -and $MultiCurrency) { $cell.Value = 'per currency: see KPI'; continue }
    if (($colName -eq 'Actual cost' -and -not $ActualOkSubs.Count) -or ($colName -eq 'Amortized cost' -and -not $AmortizedOkSubs.Count) -or
        ($colName -eq 'Advisor recommendations' -and -not $AdvisorOk) -or ($colName -eq 'Defender unhealthy' -and -not $AssessmentsOk)) { continue }
    $cell.Value = [double](($SummaryRows | ForEach-Object { [double]$_.$colName } | Measure-Object -Sum).Sum) + [double]$otherValues[$colName]
    $fmt = Get-ColumnFormat $colName
    $cell.Style.Numberformat.Format = $(if ($fmt) { $fmt } else { '#,##0' })
}
if (-not $MultiCurrency -and $CurrencyLabel) { $ws.Cells[$totalRow, (2 + $hdr.IndexOf('Currency'))].Value = $CurrencyLabel }
$allReservations = @($SummaryRows | ForEach-Object { ([string]$_.'Reservation name') -split ';\s*' } | Where-Object { $_ } | Sort-Object -Unique)
if ($allReservations.Count) { $ws.Cells[$totalRow, (2 + $hdr.IndexOf('Reservation name'))].Value = '{0} reservation(s)' -f $allReservations.Count }
$ws.Cells[$totalRow, (2 + $hdr.IndexOf('Regions'))].Value = @($Resources | ForEach-Object { $_.Region } | Sort-Object -Unique).Count
$ws.Cells[$totalRow, (2 + $hdr.IndexOf('Subscriptions'))].Value = $AiSubscriptions.Count
$totalRange = $ws.Cells[$totalRow, 2, $totalRow, $summaryTable.LastColumn]
$totalRange.Style.Font.Bold = $true
$totalRange.Style.Border.Top.Style = [OfficeOpenXml.Style.ExcelBorderStyle]::Double
# Autosize to the largest KPI tile value (16pt) and table value, so large numbers never show as "#####".
Resize-ColumnToFit -Ws $ws -Address @(
    $ws.Cells[5, 2, (3 + $kpiRows * 3), (1 + $kpisPerRow)].Address,
    $ws.Cells[$summaryTable.FirstRow, 2, $totalRow, $summaryTable.LastColumn].Address)

# Workbook guide: label, target sheet, description.
$row = Write-SectionTitle -Ws $ws -Row ($totalRow + 3) -Column 2 -Text 'Report sheets'
$sheetGuide = @(
    @('Visuals', 'Visuals', 'Pivot tables and charts: most common models, AI resources per service and region, token cost per deployed model, tokens per model, cost per service, total AI spend by cost line, ML workspace cost, retirement outlook, right-sizing, content filters, Defender and Advisor findings.'),
    @('Recommendations', 'Recommendations', "Azure Advisor recommendations for the AI resources ($(if ($AdvisorOk) { $AdvisorRows.Count } else { 'incomplete' }))."),
    @('Service Retirements', 'Service Retirements', "Model and service retirements with risk, impact and recommended action ($($RetirementRows.Count), $retireSoon retired or due within $WarningDays days)."),
    @('Service Health', 'Service Health', "Azure Service Health events - service issues, planned maintenance, health and security advisories, billing updates ($($HealthRows.Count), $(if ($HealthOk) { "$activeHealth active" } else { 'incomplete' }))."),
    @('Security Best Practices', 'Security Best Practices', "Microsoft Defender for Cloud plan coverage, recommendations and security alerts for the AI resources ($(if ($AssessmentsOk) { "$UnhealthyCount unhealthy findings" } else { 'incomplete' }))."),
    @('Security Hygiene', 'Security Hygiene', "Per-resource hygiene: local auth (keys), key retrievals and rotation from the Activity Log, diagnostic logs, resource locks, network exposure, managed identity and encryption ($LocalAuthCount with keys enabled, $(if ($DiagByRes.Count) { "$NoDiagLogsCount without diagnostic logs" } else { 'diagnostic settings not read' }))."),
    @('Content Filters', 'Content Filters', "Content filter (RAI) policies against the Microsoft default baseline, and the policy and screening results of every deployment ($RelaxedCount relaxed policies, $FilterNotSetCount deployments without a filter)."),
    @('Capacity and Quota', 'Capacity and Quota', "Right-sizing of every model deployment (idle, throttled, PTU utilization, over-allocated) and model quota usage per subscription and region ($(if ($DoMetrics) { "$RightSizingCandidates candidates" } else { 'metrics skipped' }), $QuotaHighCount quotas 90%+ used)."),
    @('AI Cost Reconciliation', 'AI Cost Reconciliation', "Total AI spend - AI resources, PTU reservations, Marketplace models, Copilot Studio and other AI meters - against the subscription total, per subscription and per charge$(if ($null -ne $AiShareAmortized) { " (AI share $('{0:P1}' -f $AiShareAmortized) amortized)" })."),
    @('ML Compute and Dependencies', 'ML Compute and Dependencies', "Azure Machine Learning and Foundry hub compute (idle shutdown, public IP, SSH, min nodes), workspace dependencies (storage, key vault, registry, Application Insights) and cost per workspace ($ComputeIssueCount computes with findings)."),
    @("AI service sheets ($($ServiceCatalog.Count))", $ServiceCatalog[0].Sheet, 'One sheet per AI service with resource inventory details (see the AI services summary above); every sheet links back to this Summary.')
)
foreach ($entry in $sheetGuide) {
    $cell = $ws.Cells[$row, 2]
    $cell.Hyperlink = [OfficeOpenXml.ExcelHyperLink]::new("'$($entry[1])'!A1", $entry[0])
    $cell.Value = $entry[0]
    $cell.Style.Font.UnderLine = $true
    $cell.Style.Font.Color.SetColor((ConvertTo-Color '#0563C1'))
    $ws.Cells[$row, 3].Value = $entry[2]
    $row++
}

$row = Write-SectionTitle -Ws $ws -Row ($row + 1) -Column 2 -Text "Data collection notes ($($Notes.Count))"
if ($Notes.Count -eq 0) { $ws.Cells[$row, 2].Value = 'All data sources were collected successfully.' }
foreach ($n in $Notes) { $ws.Cells[$row, 2].Value = "- $n"; $row++ }

# --- Sheet 2: Visuals ---
$ws = $wsVisuals
$ws.View.ShowGridLines = $false
$ws.Column(1).Width = 2
$ws.Column(2).Width = 46
# Fixed widths (pivot autofit is off): wide enough for the longest captions and column items, e.g. "Amortized cost (sum)".
for ($c = 3; $c -le 64; $c++) { $ws.Column($c).Width = 22 }

$usageLabel = "last $UsageDays days"
# Measure of the token cost chart (-CostType); falls back to the other measure when that dataset could not be read.
$chartMeasure = if ($CostType -eq 'ActualCost') { 'Actual cost' } else { 'Amortized cost' }
$measureOk    = @{ 'Actual cost' = [bool]$ActualOkSubs.Count; 'Amortized cost' = [bool]$AmortizedOkSubs.Count }
if (-not $measureOk[$chartMeasure]) {
    $otherMeasure = if ($chartMeasure -eq 'Actual cost') { 'Amortized cost' } else { 'Actual cost' }
    if ($measureOk[$otherMeasure]) { $chartMeasure = $otherMeasure }
}
$ws.Cells['B1'].Value = 'Visuals'
$ws.Cells['B1'].Style.Font.Size = 22
$ws.Cells['B1'].Style.Font.Bold = $true
$ws.Cells['B1'].Style.Font.Color.SetColor((ConvertTo-Color '#1F4E79'))
$ws.Cells['B2'].Value = 'Pivot tables and pivot charts of the AI inventory. Usage and cost: {0}{1}; the token cost chart shows {2} (-CostType). Pivot tables refresh when the workbook opens in Excel desktop (otherwise Data > Refresh All).' -f `
    $usageLabel, $(if ($CurrencyLabel) { ", $CurrencyLabel" } else { '' }), $chartMeasure.ToLowerInvariant()
$ws.Cells['B2'].Style.Font.Color.SetColor((ConvertTo-Color '#595959'))
$back = $ws.Cells['B3']
$back.Hyperlink = [OfficeOpenXml.ExcelHyperLink]::new("'Summary'!A1", 'Back to Summary')
$back.Value = '<< Back to Summary'
$back.Style.Font.UnderLine = $true
$back.Style.Font.Color.SetColor((ConvertTo-Color '#0563C1'))
$row = 5
$depRows = @($DataDeployments)

if ($depRows.Count) {
    $row += Add-PivotBlock -Ws $ws -Row $row -Name 'ptModels' -Title 'Most common models' -Subtitle 'Model deployments per model (Foundry, Azure OpenAI, AI Hubs and Machine Learning).' `
        -Source $depTable.Range -RowFields 'Model' -DataFields @(@{ Field = 'Deployment'; Function = 'Count'; Caption = 'Deployments'; Format = '#,##0' }) `
        -ChartType 'ColumnClustered' -RowItems (Get-DistinctCount $depRows 'Model') -SortByValue -NoLegend
}
else { $row += Write-Placeholder -Ws $ws -Row $row -Title 'Most common models' -Text 'No model deployments found in scope.' }

if ($DataResources.Count) {
    $row += Add-PivotBlock -Ws $ws -Row $row -Name 'ptResourcesRegion' -Title 'AI resources per service and region' -Subtitle 'Number of AI resources per AI service (category) and Azure region.' `
        -Source $resTable.Range -RowFields 'Service' -ColumnFields 'Region' -DataFields @(@{ Field = 'Resource'; Function = 'Count'; Caption = 'Resources'; Format = '#,##0' }) `
        -ChartType 'ColumnStacked' -RowItems (Get-DistinctCount $DataResources 'Service') -ColumnItems (Get-DistinctCount $DataResources 'Region') -SortByValue
}
else { $row += Write-Placeholder -Ws $ws -Row $row -Title 'AI resources per service and region' -Text 'No AI resources found in scope.' }

$costRowsExport = @(Select-Export -Rows $ModelCostRows)
# With several billing currencies the cost pivots are grouped by currency and have no grand total row.
$costRowFields = if ($MultiCurrency) { @('Currency', 'Model') } else { @('Model') }
if ($costRowsExport.Count) {
    $costRowItems = if ($MultiCurrency) { (Get-DistinctCount $costRowsExport 'Currency') + @($costRowsExport | ForEach-Object { "$($_.Currency)|$($_.Model)" } | Sort-Object -Unique).Count } else { Get-DistinctCount $costRowsExport 'Model' }
    $row += Add-PivotBlock -Ws $ws -Row $row -Name 'ptTokenCost' -Title "Token cost per deployed model ($($chartMeasure.ToLowerInvariant()), $usageLabel$(if ($CurrencyLabel) { ", $CurrencyLabel" }))" `
        -Subtitle "$chartMeasure from Cost Management (-CostType selects the chart measure; the tables show actual and amortized cost). Meters matched to the models deployed on each account (PTU hours to the provisioned deployments, unmatched meters keep the meter name)." `
        -Source $costTable.Range -RowFields $costRowFields -ColumnFields 'Token type' -DataFields @(@{ Field = $chartMeasure; Function = 'Sum'; Caption = 'Token cost'; Format = '#,##0.00##' }) `
        -ChartType 'ColumnStacked' -RowItems $costRowItems -ColumnItems (Get-DistinctCount $costRowsExport 'Token type') -SortByValue -NoGrandTotalRow:$MultiCurrency
}
else {
    $why = if ($AiSubscriptions.Count -eq 0) { 'No AI resources found in scope.' }
           elseif (-not $DoCost) { 'Cost collection was skipped (-SkipCost).' }
           elseif (-not $CostOkSubs.Count) { 'Cost data could not be read (see Data collection notes on the Summary sheet).' }
           else { "No model token cost in the $usageLabel." }
    $row += Write-Placeholder -Ws $ws -Row $row -Title 'Token cost per deployed model' -Text $why
}

if ($depRows.Count) {
    $row += Add-PivotBlock -Ws $ws -Row $row -Name 'ptDeploymentTypes' -Title 'Model deployments by deployment type' -Subtitle 'GlobalStandard, DataZoneStandard, Standard, provisioned (PTU), batch, serverless and managed compute.' `
        -Source $depTable.Range -RowFields 'Deployment type' -DataFields @(@{ Field = 'Deployment'; Function = 'Count'; Caption = 'Deployments'; Format = '#,##0' }) `
        -ChartType 'Pie' -RowItems (Get-DistinctCount $depRows 'Deployment type') -SortByValue
}

if ($depRows.Count -and $DoMetrics -and $tokenTotal -gt 0) {
    $row += Add-PivotBlock -Ws $ws -Row $row -Name 'ptTokenUsage' -Title "Token usage per model ($usageLabel)" -Subtitle 'Input and output tokens from Azure Monitor metrics (InputTokens / OutputTokens per deployment).' `
        -Source $depTable.Range -RowFields 'Model' -DataFields @(
            @{ Field = 'Input tokens'; Function = 'Sum'; Caption = 'Input tokens (sum)'; Format = '#,##0' },
            @{ Field = 'Output tokens'; Function = 'Sum'; Caption = 'Output tokens (sum)'; Format = '#,##0' }) `
        -ChartType 'ColumnStacked' -RowItems (Get-DistinctCount $depRows 'Model') -SortByValue
}

$resourceCostTotal = [double](($DataResources | ForEach-Object { [Math]::Abs([double]$_.'Actual cost') + [Math]::Abs([double]$_.'Amortized cost') } | Measure-Object -Sum).Sum)
if ($DataResources.Count -and $resourceCostTotal -gt 0) {
    $svcRowFields = if ($MultiCurrency) { @('Currency', 'Service') } else { @('Service') }
    $svcRowItems  = if ($MultiCurrency) { (Get-DistinctCount $DataResources 'Currency') + @($DataResources | ForEach-Object { "$($_.Currency)|$($_.Service)" } | Sort-Object -Unique).Count } else { Get-DistinctCount $DataResources 'Service' }
    $row += Add-PivotBlock -Ws $ws -Row $row -Name 'ptCostService' -Title "AI cost per service ($usageLabel$(if ($CurrencyLabel) { ", $CurrencyLabel" }))" `
        -Subtitle 'Actual and amortized cost of every AI resource (hub cost includes its projects); amortized cost spreads reservation purchases such as PTU over the reservation term.' `
        -Source $resTable.Range -RowFields $svcRowFields -DataFields @(
            @{ Field = 'Actual cost'; Function = 'Sum'; Caption = 'Actual cost (sum)'; Format = '#,##0.00##' },
            @{ Field = 'Amortized cost'; Function = 'Sum'; Caption = 'Amortized cost (sum)'; Format = '#,##0.00##' }) `
        -ChartType 'ColumnClustered' -RowItems $svcRowItems -SortByValue -SortDataField $(if ($chartMeasure -eq 'Actual cost') { 0 } else { 1 }) -NoGrandTotalRow:$MultiCurrency
}

$spendExport = @(Select-Export -Rows $SpendRows)
if ($ReconAvailable -and $spendExport.Count -and $spendTable.Count) {
    $spendMulti     = (Get-DistinctCount $spendExport 'Currency') -gt 1
    $spendRowFields = if ($spendMulti) { @('Currency', 'Cost line') } else { @('Cost line') }
    $spendRowItems  = if ($spendMulti) { (Get-DistinctCount $spendExport 'Currency') + @($spendExport | ForEach-Object { "$($_.Currency)|$($_.'Cost line')" } | Sort-Object -Unique).Count } else { Get-DistinctCount $spendExport 'Cost line' }
    $row += Add-PivotBlock -Ws $ws -Row $row -Name 'ptAISpend' -Title "Total AI spend by cost line ($usageLabel)" `
        -Subtitle 'AI resources, AI meters billed outside them, PTU reservation purchases, Marketplace models, Copilot Studio / Power Platform and other AI meters - reconciled against the subscription total on the AI Cost Reconciliation sheet.' `
        -Source $spendTable.Range -RowFields $spendRowFields -DataFields @(
            @{ Field = 'Actual cost'; Function = 'Sum'; Caption = 'Actual cost (sum)'; Format = '#,##0.00##' },
            @{ Field = 'Amortized cost'; Function = 'Sum'; Caption = 'Amortized cost (sum)'; Format = '#,##0.00##' }) `
        -ChartType 'BarClustered' -RowItems $spendRowItems -SortByValue -SortDataField $(if ($chartMeasure -eq 'Actual cost') { 0 } else { 1 }) -NoGrandTotalRow:$spendMulti
}

$mlCostExport = @(Select-Export -Rows $MlCostRows)
if ($mlCostExport.Count -and $mlCostTable.Count) {
    $row += Add-PivotBlock -Ws $ws -Row $row -Name 'ptMlCost' -Title "Machine Learning and Foundry hub cost per workspace ($($chartMeasure.ToLowerInvariant()), $usageLabel$(if ($CurrencyLabel) { ", $CurrencyLabel" }))" `
        -Subtitle 'Workspace cost split by meter category (compute, storage, Foundry models ...) - details on the ML Compute and Dependencies sheet.' `
        -Source $mlCostTable.Range -RowFields 'Workspace' -ColumnFields 'Meter category' -DataFields @(@{ Field = $chartMeasure; Function = 'Sum'; Caption = 'Workspace cost'; Format = '#,##0.00##' }) `
        -ChartType 'ColumnStacked' -RowItems (Get-DistinctCount $mlCostExport 'Workspace') -ColumnItems (Get-DistinctCount $mlCostExport 'Meter category') -SortByValue
}

if ($depRows.Count -and $DoLifecycle) {
    $row += Add-PivotBlock -Ws $ws -Row $row -Name 'ptRetirement' -Title 'Model retirement outlook' -Subtitle "Deployments by retirement risk (CRITICAL <= $CriticalDays days, WARNING <= $WarningDays days) - details on the Service Retirements sheet." `
        -Source $depTable.Range -RowFields 'Retirement risk' -DataFields @(@{ Field = 'Deployment'; Function = 'Count'; Caption = 'Deployments'; Format = '#,##0' }) `
        -ChartType 'Pie' -RowItems (Get-DistinctCount $depRows 'Retirement risk') -SortByValue
}

if ($DoMetrics -and $rightTable.Count) {
    $row += Add-PivotBlock -Ws $ws -Row $row -Name 'ptRightSizing' -Title "Model deployment right-sizing ($usageLabel)" -Subtitle 'Idle, throttled (429), PTU saturated or under-used and over-allocated deployments - details on the Capacity and Quota sheet.' `
        -Source $rightTable.Range -RowFields 'Right-sizing' -DataFields @(@{ Field = 'Deployment'; Function = 'Count'; Caption = 'Deployments'; Format = '#,##0' }) `
        -ChartType 'Pie' -RowItems (Get-DistinctCount $RightSizingRows 'Right-sizing') -SortByValue
}

if ($filterTable.Count) {
    $row += Add-PivotBlock -Ws $ws -Row $row -Name 'ptContentFilter' -Title 'Content filter posture of model deployments' -Subtitle 'Deployments by content filter (RAI policy) assessment against the Microsoft default baseline - details on the Content Filters sheet.' `
        -Source $filterTable.Range -RowFields 'Content filter assessment' -DataFields @(@{ Field = 'Deployment'; Function = 'Count'; Caption = 'Deployments'; Format = '#,##0' }) `
        -ChartType 'Pie' -RowItems (Get-DistinctCount $FilterDeploymentRows 'Content filter assessment') -SortByValue
}

if ($assessmentTable.Count) {
    $row += Add-PivotBlock -Ws $ws -Row $row -Name 'ptDefender' -Title 'Defender for Cloud recommendations by severity and status' -Subtitle 'Assessments of AI resources (see the Security Best Practices sheet).' `
        -Source $assessmentTable.Range -RowFields 'Severity' -ColumnFields 'Status' -DataFields @(@{ Field = 'Recommendation'; Function = 'Count'; Caption = 'Findings'; Format = '#,##0' }) `
        -ChartType 'ColumnStacked' -RowItems (Get-DistinctCount $AssessmentRows 'Severity') -ColumnItems (Get-DistinctCount $AssessmentRows 'Status')
}
else { $row += Write-Placeholder -Ws $ws -Row $row -Title 'Defender for Cloud recommendations' -Text 'No Defender for Cloud assessments found for the AI resources.' }

if ($advisorTable.Count) {
    $row += Add-PivotBlock -Ws $ws -Row $row -Name 'ptAdvisor' -Title 'Azure Advisor recommendations by category and impact' -Subtitle 'Active recommendations for AI resources (see the Recommendations sheet).' `
        -Source $advisorTable.Range -RowFields 'Category' -ColumnFields 'Impact' -DataFields @(@{ Field = 'Recommendation'; Function = 'Count'; Caption = 'Recommendations'; Format = '#,##0' }) `
        -ChartType 'ColumnStacked' -RowItems (Get-DistinctCount $AdvisorRows 'Category') -ColumnItems (Get-DistinctCount $AdvisorRows 'Impact') -SortByValue
}
else { $row += Write-Placeholder -Ws $ws -Row $row -Title 'Azure Advisor recommendations' -Text 'No active Azure Advisor recommendations for the AI resources.' }

# --- Finalize ---
foreach ($sheetName in @($script:SheetWidths.Keys)) {
    $w = $wb.Worksheets[$sheetName]
    foreach ($c in @($script:SheetWidths[$sheetName].Keys)) { $w.Column($c).Width = [Math]::Min(62, [double]$script:SheetWidths[$sheetName][$c] + 2) }
}
foreach ($w in $wb.Worksheets) { $w.View.TabSelected = $false }
# EPPlus 4.5 clears its own flag in the TabSelected setter, so select the Summary tab in the sheet XML.
$nsSheet = [System.Xml.XmlNamespaceManager]::new($wsSummary.WorksheetXml.NameTable)
$nsSheet.AddNamespace('d', 'http://schemas.openxmlformats.org/spreadsheetml/2006/main')
$summaryView = $wsSummary.WorksheetXml.SelectSingleNode('/d:worksheet/d:sheetViews/d:sheetView', $nsSheet)
if ($summaryView) { $summaryView.SetAttribute('tabSelected', '1') }
$wb.View.ActiveTab = 0
if (-not $ShowDataSheets) { foreach ($w in $wsDataRes, $wsDataDep, $wsDataCost, $wsDataSpend) { $w.Hidden = [OfficeOpenXml.eWorkSheetHidden]::Hidden } }
$wb.Properties.Title   = 'Azure AI Inventory'
$wb.Properties.Subject = "Tenant $TenantId"
$wb.Properties.Author  = [string]$AzContext.Account.Id
Close-ExcelPackage -ExcelPackage $pkg -Show:$Show

#endregion

#region Summary ------------------------------------------------------------------------------------

$elapsed = [datetime]::UtcNow - $RunStartedUtc
Write-Host ''
Write-Host "Azure AI Inventory written: $OutputPath" -ForegroundColor Green
Write-Host ('  AI resources            : {0} ({1}/{2} services in use, {3} subscription(s))' -f $Resources.Count, $servicesInUse, $ServiceCatalog.Count, $AiSubscriptions.Count)
Write-Host ('  Model deployments       : {0} ({1} distinct models)' -f $DataDeployments.Count, $distinctModels)
if ($DoCost) {
    $coverage = { param($Ok) if ($Ok.Count -lt $AiSubscriptions.Count) { " (covers $($Ok.Count) of $($AiSubscriptions.Count) subscription(s))" } else { '' } }
    Write-Host ('  {0,-24}: {1}{2}' -f "Actual cost ($UsageDays days)", $ActualTotalText, (& $coverage $ActualOkSubs))
    Write-Host ('  {0,-24}: {1}{2}' -f "Amortized cost ($UsageDays days)", $AmortizedTotalText, (& $coverage $AmortizedOkSubs))
    if ($ReconAvailable) {
        Write-Host ('  Total AI spend          : actual {0}, amortized {1}{2}' -f $AiSpendActualText, $AiSpendAmortizedText, $(if ($null -ne $AiShareAmortized) { " ({0:P1} of the subscription spend, amortized)" -f $AiShareAmortized }))
    }
}
Write-Host ('  Advisor recommendations : {0}' -f $(if ($AdvisorOk) { $AdvisorRows.Count } else { "$($AdvisorRows.Count) (incomplete)" }))
# Mirror the INCOMPLETE flags of the workbook: a count read from a failed source is not a fact.
$incomplete = { param([bool]$Ok) if ($Ok) { '' } else { ' (incomplete)' } }
$raiFailed    = @($AcctResults.Values | Where-Object { $_.RaiError }).Count
$metricFailed = @($AcctResults.Values | Where-Object { $_.PeakError -or $_.DailyError -or $_.PtuError }).Count
Write-Host ('  Retirement items        : {0} ({1} retired or due within {2} days){3}' -f $RetirementRows.Count, $retireSoon, $WarningDays, (& $incomplete (-not $retireGaps.Count)))
Write-Host ('  Service Health events   : {0} ({1} active){2}' -f $HealthRows.Count, $activeHealth, (& $incomplete $HealthOk))
Write-Host ('  Defender findings       : {0} unhealthy of {1} assessments{2}, {3} alert(s){4}' -f $UnhealthyCount, $AssessmentRows.Count, (& $incomplete $AssessmentsOk), $AlertRows.Count, (& $incomplete $AlertsOk))
Write-Host ('  Security hygiene        : {0} with local auth (keys) enabled, {1} without diagnostic logs{2}{3}' -f $LocalAuthCount, $(if ($DiagByRes.Count) { $NoDiagLogsCount } else { 'n/a' }),
    $(if ($null -ne $KeyRetrievalSum) { ", $KeyRetrievalSum key retrieval(s) in $ActivityDays days" }), $(if ($hygGaps.Count) { " (incomplete: $($hygGaps -join ', '))" }))
Write-Host ('  Content filters         : {0} relaxed polic(ies), {1} deployment(s) without a filter{2}' -f $RelaxedCount, $FilterNotSetCount, (& $incomplete (-not $raiFailed)))
Write-Host ('  Capacity and quota      : {0} right-sizing candidate(s), {1} model quota(s) 90%+ used{2}' -f $(if ($DoMetrics) { $RightSizingCandidates } else { 'n/a' }),
    $(if ($QuotaByPair.Count) { $QuotaHighCount } else { 'n/a' }), (& $incomplete (-not ($QuotaFailures -or ($DoMetrics -and $metricFailed)))))
Write-Host ('  ML compute and deps     : {0} compute(s) ({1} with findings), {2} dependenc(ies) ({3} with findings){4}' -f $ComputeRows.Count, $ComputeIssueCount, $DependencyRows.Count,
    @($DependencyRows | Where-Object { $_.Issues -gt 0 }).Count, (& $incomplete (-not $mlGaps.Count)))
if ($Notes.Count) { Write-Host ('  Collection notes        : {0} (listed at the bottom of the Summary sheet)' -f $Notes.Count) -ForegroundColor Yellow }
Write-Host ('  Duration                : {0:mm\:ss}' -f $elapsed)

#endregion
