<#
.SYNOPSIS
    Builds a single consolidated CSV of every deployed Azure OpenAI / Foundry model
    with its retirement (deprecation) date.

.DESCRIPTION
    Azure Resource Graph does NOT expose model retirement dates - the ARM schema for
    Microsoft.CognitiveServices/accounts/deployments has no such property at any
    api-version. Retirement lives only in the subscription+location scoped Models API:

        GET /subscriptions/{sub}/providers/Microsoft.CognitiveServices/locations/{loc}/models

    This script:
      1. Pulls the deployment inventory from Resource Graph (paged, all subscriptions).
      2. Pulls the model catalog from the Models API once per unique (subscription, region).
      3. Joins them on (subscription, region, model name, model version).
      4. Emits one consolidated CSV with lifecycle, retirement date, days remaining,
         a risk verdict, and a suggested replacement (newest GA version of same model).

.PARAMETER OutputPath
    Path of the CSV to write. Defaults to .\AoaiModelRetirements_<yyyyMMdd>.csv

.PARAMETER SubscriptionId
    Optional. One or more subscription IDs to scope to. Default: all accessible subs.

.PARAMETER ResourceGroup
    Optional. One or more resource group names to filter deployments to.

.PARAMETER ApiVersion
    Models API version. Default 2024-10-01 (GA).

.PARAMETER CriticalDays
    Days-to-retirement at or below which a row is flagged CRITICAL. Default 60
    (matches Microsoft's 60-day GA retirement notice window).

.PARAMETER WarningDays
    Days-to-retirement at or below which a row is flagged WARNING. Default 180.

.PARAMETER PassThru
    Also emit the result objects to the pipeline.

.EXAMPLE
    ./Get-AoaiModelRetirements.ps1 -OutputPath .\sunexpress-aoai.csv

.EXAMPLE
    ./Get-AoaiModelRetirements.ps1 -SubscriptionId $subs -PassThru |
        Where-Object Risk -in 'RETIRED','CRITICAL' | Format-Table

.NOTES
    Requires: Az.Accounts, Az.ResourceGraph. Connect-AzAccount first.
    RBAC:     Reader on the target subscriptions is sufficient
              (Microsoft.CognitiveServices/locations/models/read).
#>
[CmdletBinding()]
param(
    [string]   $OutputPath    = ".\AoaiModelRetirements_$(Get-Date -Format 'yyyyMMdd').csv",
    [string[]] $SubscriptionId,
    [string[]] $ResourceGroup,
    [string]   $ApiVersion    = '2024-10-01',
    [int]      $CriticalDays  = 60,
    [int]      $WarningDays   = 180,
    [switch]   $PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region Preflight -------------------------------------------------------------

foreach ($m in 'Az.Accounts', 'Az.ResourceGraph') {
    if (-not (Get-Module -ListAvailable -Name $m)) {
        throw "Module '$m' is not installed. Run: Install-Module $m -Scope CurrentUser"
    }
    Import-Module $m -ErrorAction Stop | Out-Null
}

$ctx = Get-AzContext
if (-not $ctx) { throw "Not signed in. Run Connect-AzAccount first." }
Write-Verbose "Signed in as $($ctx.Account.Id) on tenant $($ctx.Tenant.Id)"

#endregion

#region 1. Resource Graph inventory ------------------------------------------

# Build optional RG filter as a literal KQL fragment.
$rgFilter = ''
if ($ResourceGroup) {
    $rgList   = ($ResourceGroup | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ','
    $rgFilter = "| where resourceGroup in~ ($rgList)"
}

$kql = @"
resources
| where type =~ 'microsoft.cognitiveservices/accounts/deployments'
$rgFilter
| extend AccountId = tolower(strcat_array(array_slice(split(id, '/'), 0, 8), '/'))
| project
    AccountId,
    DeploymentId   = id,
    Deployment     = name,
    resourceGroup,
    subscriptionId,
    ModelName      = tostring(properties.model.name),
    ModelVersion   = tostring(properties.model.version),
    ModelFormat    = tostring(properties.model.format),
    UpgradeOption  = tostring(properties.versionUpgradeOption),
    DeploymentSku  = tostring(sku.name),
    Capacity       = toint(sku.capacity),
    ProvisioningState = tostring(properties.provisioningState)
| join kind=inner (
    resources
    | where type =~ 'microsoft.cognitiveservices/accounts'
    | where kind in~ ('OpenAI','AIServices')
    | project
        AccountId = tolower(id),
        Account   = name,
        Region    = location,
        Kind      = iff(kind =~ 'OpenAI', 'Azure OpenAI', 'Microsoft Foundry (AI Services)'),
        Endpoint  = tostring(properties.endpoint)
  ) on AccountId
| project-away AccountId1
| join kind=leftouter (
    resourcecontainers
    | where type =~ 'microsoft.resources/subscriptions'
    | project subscriptionId, Subscription = name
  ) on subscriptionId
| project-away subscriptionId1
| order by Subscription asc, Account asc, Deployment asc
"@

Write-Verbose "Querying Resource Graph for model deployments..."

$graphArgs = @{ Query = $kql; First = 1000 }
if ($SubscriptionId) { $graphArgs['Subscription'] = $SubscriptionId }

$deployments = [System.Collections.Generic.List[object]]::new()
$skip = 0
do {
    if ($skip -gt 0) { $graphArgs['Skip'] = $skip }
    $page = Search-AzGraph @graphArgs
    if ($page) { $deployments.AddRange(@($page)) }
    $skip += 1000
} while ($page -and $page.Count -eq 1000)

if ($deployments.Count -eq 0) {
    Write-Warning "No Azure OpenAI / Foundry model deployments found in scope. Nothing to write."
    return
}
Write-Verbose "Found $($deployments.Count) deployment(s)."

#endregion

#region 2. Models API catalog -------------------------------------------------

# Reusable ARM token (Az context -> bearer).
function Get-ArmToken {
    $t = Get-AzAccessToken -ResourceUrl 'https://management.azure.com/'
    # Az 14+ returns Token as SecureString; older returns plain string.
    if ($t.Token -is [System.Security.SecureString]) {
        return [System.Net.NetworkCredential]::new('', $t.Token).Password
    }
    return $t.Token
}

$token   = Get-ArmToken
$headers = @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' }

# key: "<sub>|<region-lower>|<model-lower>|<version>"  -> catalog entry
$catalog = @{}
# key: "<sub>|<region-lower>|<model-lower>" -> list of entries (for replacement lookup)
$byModel = @{}

# NOTE: do NOT use `Select-Object -Property a,b -Unique` here. On Windows
# PowerShell 5.1 -Unique compares whole objects via ToString(), which returns the
# same type name for every PSCustomObject and silently collapses the set to a
# single row - you would then query only ONE region. Group-Object on a composite
# key behaves correctly on both 5.1 and 7.x.
$pairs = @(
    $deployments |
        Where-Object { $_.subscriptionId -and $_.Region } |
        Group-Object -Property { "$($_.subscriptionId)|$($_.Region.ToLower())" } |
        ForEach-Object {
            [pscustomobject]@{
                subscriptionId = $_.Group[0].subscriptionId
                Region         = $_.Group[0].Region
            }
        }
)

$i = 0
foreach ($pair in $pairs) {
    $i++
    $sub = $pair.subscriptionId
    $loc = $pair.Region
    Write-Progress -Activity 'Querying Models API' `
                   -Status "$sub / $loc" `
                   -PercentComplete (($i / [Math]::Max($pairs.Count, 1)) * 100)

    $url = "https://management.azure.com/subscriptions/$sub/providers/Microsoft.CognitiveServices/locations/$loc/models?api-version=$ApiVersion"

    try {
        while ($url) {
            $resp = Invoke-RestMethod -Method Get -Uri $url -Headers $headers -ErrorAction Stop

            foreach ($entry in @($resp.value)) {
                $m = $entry.model
                if (-not $m -or -not $m.name) { continue }

                # Earliest SKU-level deprecation, if any.
                $skuDep = $null
                if ($m.PSObject.Properties.Name -contains 'skus' -and $m.skus) {
                    $skuDep = $m.skus |
                        Where-Object { $_.PSObject.Properties.Name -contains 'deprecationDate' -and $_.deprecationDate } |
                        ForEach-Object { [datetime]$_.deprecationDate } |
                        Sort-Object | Select-Object -First 1
                }

                $infDep = $null
                $ftDep  = $null
                if ($m.PSObject.Properties.Name -contains 'deprecation' -and $m.deprecation) {
                    if ($m.deprecation.PSObject.Properties.Name -contains 'inference' -and $m.deprecation.inference) {
                        $infDep = [datetime]$m.deprecation.inference
                    }
                    if ($m.deprecation.PSObject.Properties.Name -contains 'fineTune' -and $m.deprecation.fineTune) {
                        $ftDep = [datetime]$m.deprecation.fineTune
                    }
                }

                $rec = [pscustomobject]@{
                    Lifecycle        = if ($m.PSObject.Properties.Name -contains 'lifecycleStatus') { $m.lifecycleStatus } else { $null }
                    IsDefaultVersion = if ($m.PSObject.Properties.Name -contains 'isDefaultVersion') { [bool]$m.isDefaultVersion } else { $false }
                    InferenceRetire  = $infDep
                    FineTuneRetire   = $ftDep
                    SkuRetire        = $skuDep
                    Version          = [string]$m.version
                }

                $mk = "$sub|$($loc.ToLower())|$($m.name.ToLower())"
                $catalog["$mk|$([string]$m.version)"] = $rec
                if (-not $byModel.ContainsKey($mk)) {
                    $byModel[$mk] = [System.Collections.Generic.List[object]]::new()
                }
                $byModel[$mk].Add($rec)
            }

            $url = if ($resp.PSObject.Properties.Name -contains 'nextLink') { $resp.nextLink } else { $null }
        }
    }
    catch {
        Write-Warning "Models API failed for $sub / $loc : $($_.Exception.Message)"
    }
}
Write-Progress -Activity 'Querying Models API' -Completed

#endregion

#region 3. Join + risk scoring ------------------------------------------------

$now = (Get-Date).ToUniversalTime()

$rows = foreach ($d in $deployments) {
    $mk  = "$($d.subscriptionId)|$($d.Region.ToLower())|$($d.ModelName.ToLower())"
    $key = "$mk|$($d.ModelVersion)"
    $hit = if ($catalog.ContainsKey($key)) { $catalog[$key] } else { $null }

    # Effective retirement = earliest of inference deprecation and SKU deprecation.
    $retire = $null
    if ($hit) {
        $cands = @($hit.InferenceRetire, $hit.SkuRetire) | Where-Object { $_ }
        if ($cands) { $retire = ($cands | Sort-Object | Select-Object -First 1) }
    }

    $days = if ($retire) { [int][Math]::Floor(($retire - $now).TotalDays) } else { $null }

    $risk = if (-not $hit)              { 'UNKNOWN - not in catalog' }
            elseif (-not $retire)       { 'NO DATE PUBLISHED' }
            elseif ($days -lt 0)        { 'RETIRED' }
            elseif ($days -le $CriticalDays) { 'CRITICAL' }
            elseif ($days -le $WarningDays)  { 'WARNING' }
            else                        { 'OK' }

    # Pinned deployments hard-fail at retirement; auto-upgrade ones roll forward.
    $pinned = ($d.UpgradeOption -eq 'NoAutoUpgrade')
    $impact = if ($risk -in 'RETIRED','CRITICAL','WARNING') {
                  if ($pinned) { 'BREAKS - version pinned (NoAutoUpgrade)' }
                  else         { 'Mitigated - auto-upgrades to newer version' }
              } else { '' }

    # Suggested replacement: newest non-deprecated version of the same model in-region.
    $replacement = ''
    if ($byModel.ContainsKey($mk)) {
        $better = $byModel[$mk] |
            Where-Object {
                $_.Version -ne $d.ModelVersion -and
                $_.Lifecycle -notin 'Deprecated','Deprecating' -and
                (-not $_.InferenceRetire -or $_.InferenceRetire -gt $now) -and
                (-not $retire -or -not $_.InferenceRetire -or $_.InferenceRetire -gt $retire)
            } |
            Sort-Object -Property @{ Expression = { $_.IsDefaultVersion }; Descending = $true },
                                  @{ Expression = { $_.InferenceRetire   }; Descending = $true } |
            Select-Object -First 1
        if ($better) { $replacement = "$($d.ModelName) $($better.Version)" }
    }

    [pscustomobject]@{
        Subscription      = $d.Subscription
        Account           = $d.Account
        Kind              = $d.Kind
        ResourceGroup     = $d.resourceGroup
        Region            = $d.Region
        Deployment        = $d.Deployment
        Model             = $d.ModelName
        ModelVersion      = $d.ModelVersion
        ModelFormat       = $d.ModelFormat
        DeploymentSku     = $d.DeploymentSku
        Capacity          = $d.Capacity
        ProvisioningState = $d.ProvisioningState
        VersionUpgrade    = $d.UpgradeOption
        Lifecycle         = if ($hit) { $hit.Lifecycle } else { '' }
        IsDefaultVersion  = if ($hit) { $hit.IsDefaultVersion } else { '' }
        RetirementDate    = if ($retire) { $retire.ToString('yyyy-MM-dd') } else { '' }
        FineTuneRetire    = if ($hit -and $hit.FineTuneRetire) { $hit.FineTuneRetire.ToString('yyyy-MM-dd') } else { '' }
        DaysRemaining     = $days
        Risk              = $risk
        Impact            = $impact
        SuggestedUpgrade  = $replacement
        Endpoint          = $d.Endpoint
        ResourceId        = $d.DeploymentId
        CollectedUtc      = $now.ToString('yyyy-MM-dd HH:mm:ss')
    }
}

# Worst-first ordering so the deliverable leads with what actually hurts.
$rank = @{ 'RETIRED' = 0; 'CRITICAL' = 1; 'WARNING' = 2; 'UNKNOWN - not in catalog' = 3; 'NO DATE PUBLISHED' = 4; 'OK' = 5 }
$sorted = $rows | Sort-Object -Property @{ Expression = { $rank[$_.Risk] } },
                                        @{ Expression = { if ($null -eq $_.DaysRemaining) { [int]::MaxValue } else { $_.DaysRemaining } } },
                                        Subscription, Account, Deployment

#endregion

#region 4. Emit ---------------------------------------------------------------

$dir = Split-Path -Parent $OutputPath
if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

$sorted | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8

Write-Host ""
Write-Host "Consolidated CSV written: $OutputPath" -ForegroundColor Green
Write-Host "  Deployments:  $($sorted.Count)"
Write-Host "  Accounts:     $(($sorted | Select-Object -ExpandProperty Account -Unique).Count)"
Write-Host "  Subscriptions:$(($sorted | Select-Object -ExpandProperty Subscription -Unique).Count)"
Write-Host ""
Write-Host "Risk summary:" -ForegroundColor Cyan
$sorted | Group-Object Risk |
    Sort-Object { $rank[$_.Name] } |
    ForEach-Object { '  {0,-26} {1}' -f $_.Name, $_.Count } |
    Write-Host

$breaking = @($sorted | Where-Object { $_.Impact -like 'BREAKS*' })
if ($breaking.Count -gt 0) {
    Write-Host ""
    Write-Host "$($breaking.Count) pinned deployment(s) will BREAK at retirement:" -ForegroundColor Red
    $breaking | Select-Object Subscription, Account, Deployment, Model, ModelVersion, RetirementDate, DaysRemaining |
        Format-Table -AutoSize | Out-String | Write-Host
}

if ($PassThru) { $sorted }

#endregion
