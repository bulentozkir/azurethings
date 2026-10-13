#requires -Version 7.2

<#
.SYNOPSIS
    Publishes the Azure Landing Zones (ALZ) custom policies as one audit-first initiative.

.DESCRIPTION
    Publishes the policy definitions from ./definitions and ./local-definitions and a single policy set definition
    (initiative) that references all of them, at a management group or subscription. The definitions in ./definitions
    are the ALZ policies converted to audit by default (see Import-AlzPolicy.ps1): each one defaults to Audit or
    AuditIfNotExists instead of the Deny, DeployIfNotExists, Modify, Append or DenyAction that upstream applies, so even
    a definition that is assigned on its own audits. The definitions in ./local-definitions are authored in this
    repository and audit by default as well. The initiative defaults to the same effects. Each policy has its own
    <policy>_effect initiative parameter, so an assignment can switch any policy to Deny, DeployIfNotExists, Modify,
    Append, DenyAction or Disabled.

    No assignment is created. Re-running the script updates what it published earlier; it refuses to overwrite
    definitions or an initiative that it did not publish (identified by metadata.managedBy).

    Deprecated upstream policies are left out unless -IncludeDeprecated is used.

.PARAMETER ManagementGroupId
    Management group that receives the definitions and the initiative. Assignable there and at every scope below it.

.PARAMETER SubscriptionId
    Subscription that receives the definitions and the initiative. Assignable there and at every resource group below it.

.PARAMETER TenantId
    Tenant to sign in to. Optional: the current Az context is used when it already matches.

.PARAMETER Environment
    Azure cloud. Definitions that upstream does not support in that cloud are skipped.

.PARAMETER DefinitionPrefix
    Prefix for published definition names, which keeps them apart from definitions deployed by the ALZ accelerators.
    Use an empty string to keep the upstream names. A resource name is limited to 64 characters, so a longer prefix
    plus policy name is shortened with a hash suffix.

.PARAMETER InitiativeName
    Name of the initiative (policy set definition).

.PARAMETER DisplayName
    Display name of the initiative.

.PARAMETER IncludeDeprecated
    Also publish the policies that are flagged deprecated upstream.

.PARAMETER ExcludePolicy
    Policy names (for example Deny-Storage-SFTP) to leave out of the definitions and the initiative.

.PARAMETER OutputPath
    Also write the generated definition and initiative JSON to this folder.

.PARAMETER ExportOnly
    Generate and write the JSON to -OutputPath without signing in or calling Azure.

.PARAMETER Remove
    Remove what this script published earlier at the scope: the initiative and the definitions that have the same
    -DefinitionPrefix, and only those that carry this package's metadata.managedBy marker. Delete the assignments of
    the initiative first. -IncludeDeprecated and -ExcludePolicy are ignored.

.PARAMETER UseDeviceAuthentication
    Sign in with the device code flow.

.PARAMETER SkipLogin
    Fail instead of signing in when the current Az context does not match.

.EXAMPLE
    ./Deploy-AlzPolicy.ps1 -ManagementGroupId contoso -WhatIf

.EXAMPLE
    ./Deploy-AlzPolicy.ps1 -ManagementGroupId contoso -TenantId 00000000-0000-0000-0000-000000000000

.EXAMPLE
    ./Deploy-AlzPolicy.ps1 -SubscriptionId 00000000-0000-0000-0000-000000000000 -ExcludePolicy Deny-Storage-SFTP

.EXAMPLE
    ./Deploy-AlzPolicy.ps1 -ManagementGroupId contoso -ExportOnly -OutputPath ./out

.EXAMPLE
    ./Deploy-AlzPolicy.ps1 -ManagementGroupId contoso -Remove -WhatIf
#>
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'ManagementGroup')]
param(
    [Parameter(Mandatory, ParameterSetName = 'ManagementGroup')]
    [ValidatePattern('^[A-Za-z0-9._()-]{1,90}$')]
    [string]$ManagementGroupId,

    [Parameter(Mandatory, ParameterSetName = 'Subscription')]
    [guid]$SubscriptionId,

    [guid]$TenantId,

    [ValidateSet('AzureCloud', 'AzureUSGovernment', 'AzureChinaCloud')]
    [string]$Environment = 'AzureCloud',

    [AllowEmptyString()]
    [ValidatePattern('^$|^[A-Za-z0-9][A-Za-z0-9_-]{0,30}$')]
    [string]$DefinitionPrefix = 'alz-',

    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$')]
    [string]$InitiativeName = 'alz-custom-policies',

    [ValidateNotNullOrEmpty()]
    [ValidateLength(1, 128)]
    [string]$DisplayName = 'Azure Landing Zones - Custom policies (audit by default)',

    [switch]$IncludeDeprecated,

    [string[]]$ExcludePolicy = @(),

    [string]$OutputPath,

    [switch]$ExportOnly,

    [switch]$Remove,

    [switch]$UseDeviceAuthentication,

    [switch]$SkipLogin
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'AlzPolicy.Common.ps1')

if ($ExportOnly -and -not $OutputPath) { throw '-ExportOnly requires -OutputPath.' }
if ($Remove -and ($ExportOnly -or $OutputPath)) { throw '-Remove cannot be combined with -ExportOnly or -OutputPath.' }

$bySubscription = $PSCmdlet.ParameterSetName -eq 'Subscription'
$scope = if ($bySubscription) { "/subscriptions/$SubscriptionId" } else { "/providers/Microsoft.Management/managementGroups/$ManagementGroupId" }

# ---- Select and generate (offline) ---------------------------------------------------------------------------------
$source = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'alz-library-source.json') -Raw | ConvertFrom-Json -AsHashtable
$allRecords = @(Get-AlzPolicyRecord -DefinitionsPath (Join-Path $PSScriptRoot 'definitions') -LocalPath (Join-Path $PSScriptRoot 'local-definitions'))
if ($allRecords.Count -eq 0) { throw 'No policy definitions found. Run ./Import-AlzPolicy.ps1 first.' }

$unknownExclusions = @($ExcludePolicy | Where-Object { $_ -notin $allRecords.Name })
if ($unknownExclusions.Count -gt 0) { throw "Unknown policy name(s) in -ExcludePolicy: $($unknownExclusions -join ', ')." }

$selected = [System.Collections.Generic.List[object]]::new()
$skippedDeprecated = 0
$skippedForCloud = [System.Collections.Generic.List[string]]::new()
foreach ($record in $allRecords) {
    if ($Remove) { $selected.Add($record); continue }
    if ($record.Deprecated -and -not $IncludeDeprecated) { $skippedDeprecated++; continue }
    if ($record.Name -in $ExcludePolicy) { continue }
    if ($record.CloudEnvironments.Count -gt 0 -and $Environment -notin $record.CloudEnvironments) { $skippedForCloud.Add($record.Name); continue }
    $selected.Add($record)
}
if ($skippedForCloud.Count -gt 0) { Write-Warning "Skipped $($skippedForCloud.Count) policies that upstream does not support in ${Environment}: $($skippedForCloud -join ', ')." }
if ($selected.Count -eq 0) { throw 'No policies were selected.' }

$package = Build-AlzPolicyPackage -Record $selected.ToArray() -Scope $scope -DefinitionPrefix $DefinitionPrefix -InitiativeName $InitiativeName -DisplayName $DisplayName -Source $source
$problems = @(Test-AlzPolicyPackage -Package $package)
if ($problems.Count -gt 0) { throw "The generated package is invalid:`n - $($problems -join "`n - ")" }
$parameterCount = $package.Initiative.Properties.parameters.Count
if (-not $Remove) {
    Write-Host "Generated $($package.Definitions.Count) definitions and initiative '$InitiativeName' with $parameterCount parameters (ALZ Library $($source.version); $skippedDeprecated deprecated policies left out)."
}

if ($OutputPath) {
    if ($PSCmdlet.ShouldProcess($OutputPath, 'Write the generated definition and initiative JSON')) {
        $definitionsFolder = Join-Path $OutputPath 'definitions'
        $null = New-Item -ItemType Directory -Path $definitionsFolder -Force
        $utf8 = [System.Text.UTF8Encoding]::new($false)
        foreach ($definition in $package.Definitions) {
            $document = [ordered]@{ name = $definition.Name; type = 'Microsoft.Authorization/policyDefinitions'; properties = $definition.Properties }
            [System.IO.File]::WriteAllText((Join-Path $definitionsFolder "$($definition.Name).json"), ((ConvertTo-Json -InputObject $document -Depth 100) + "`n"), $utf8)
        }
        $document = [ordered]@{ name = $package.Initiative.Name; type = 'Microsoft.Authorization/policySetDefinitions'; properties = $package.Initiative.Properties }
        [System.IO.File]::WriteAllText((Join-Path $OutputPath "$($package.Initiative.Name).json"), ((ConvertTo-Json -InputObject $document -Depth 100) + "`n"), $utf8)
        Write-Host "Wrote the generated JSON to $OutputPath."
    }
}

if ($ExportOnly) {
    return [pscustomobject]@{
        Published                = $false
        Scope                    = $scope
        InitiativeId             = $package.Initiative.Id
        DefinitionCount          = $package.Definitions.Count
        InitiativeParameterCount = $parameterCount
        OutputPath               = $OutputPath
    }
}

# ---- Sign in and verify the target ---------------------------------------------------------------------------------
if (-not (Get-Command Invoke-AzRestMethod -ErrorAction SilentlyContinue)) { Import-Module Az.Accounts -ErrorAction Stop }

function Test-ContextMatch {
    param($Context)
    if ($null -eq $Context -or $null -eq $Context.Account) { return $false }
    if ($Context.Environment.Name -ne $Environment) { return $false }
    if ($TenantId -and $Context.Tenant.Id -ne $TenantId.ToString()) { return $false }
    if ($bySubscription -and ($null -eq $Context.Subscription -or $Context.Subscription.Id -ne $SubscriptionId.ToString())) { return $false }
    $true
}

$context = Get-AzContext -ErrorAction SilentlyContinue
if (-not (Test-ContextMatch $context)) {
    if ($SkipLogin) { throw "The active Az context does not match $Environment$(if ($TenantId) { ", tenant $TenantId" })$(if ($bySubscription) { ", subscription $SubscriptionId" }). Sign in with Connect-AzAccount or omit -SkipLogin." }
    $login = @{ Environment = $Environment; Scope = 'Process'; ErrorAction = 'Stop'; WhatIf = $false }
    if ($TenantId) { $login.Tenant = $TenantId.ToString() }
    if ($bySubscription) { $login.Subscription = $SubscriptionId.ToString() }
    if ($UseDeviceAuthentication) { $login.UseDeviceAuthentication = $true }
    $null = Connect-AzAccount @login
    $context = Get-AzContext -ErrorAction Stop
    if (-not (Test-ContextMatch $context)) { throw 'Azure sign-in did not select the requested cloud, tenant and subscription.' }
}

function Invoke-AlzRest {
    param(
        [Parameter(Mandatory)][ValidateSet('GET', 'PUT', 'DELETE')][string]$Method,
        [string]$Path,
        [string]$Uri,
        [System.Collections.IDictionary]$Body,
        [switch]$AllowNotFound
    )

    $request = @{ Method = $Method; DefaultProfile = $context; WhatIf = $false; Confirm = $false; ErrorAction = 'Stop' }
    if ($Uri) { $request.Uri = $Uri } else { $request.Path = $Path }
    if ($null -ne $Body) { $request.Payload = ConvertTo-Json -InputObject $Body -Depth 100 -Compress }

    for ($attempt = 1; ; $attempt++) {
        $response = Invoke-AzRestMethod @request
        $status = [int]$response.StatusCode
        if ($status -notin 429, 500, 502, 503, 504 -or $attempt -ge 6) { break }
        $delay = [math]::Min(60, [math]::Pow(2, $attempt))
        $retryAfter = $response.Headers | Where-Object { $_.Key -eq 'Retry-After' } | Select-Object -First 1
        if ($retryAfter -and [int]::TryParse(@($retryAfter.Value)[0], [ref]$null)) { $delay = [math]::Min(120, [int]@($retryAfter.Value)[0]) }
        Write-Verbose "HTTP $status from $Method $Path$Uri; retrying in $delay s."
        Start-Sleep -Seconds $delay
    }
    if ($AllowNotFound -and $status -eq 404) { return $null }
    if ($status -notin 200, 201, 204) {
        $failure = [System.InvalidOperationException]::new("$Method $Path$Uri failed (HTTP $status): $($response.Content)")
        $failure.Data['StatusCode'] = $status
        throw $failure
    }
    if (-not [string]::IsNullOrWhiteSpace($response.Content)) { $response.Content | ConvertFrom-Json -AsHashtable -Depth 100 }
}

function Get-AlzExactScopeResource {
    param([Parameter(Mandatory)][string]$Collection)
    $found = @{}
    $page = Invoke-AlzRest -Method GET -Path "$scope/providers/Microsoft.Authorization/${Collection}?api-version=$script:AlzPolicyApiVersion&`$filter=atExactScope()"
    while ($true) {
        if ($page.Contains('value')) { foreach ($item in $page.value) { $found[$item.id.ToLowerInvariant()] = $item } }
        if (-not $page.Contains('nextLink') -or [string]::IsNullOrEmpty($page.nextLink)) { break }
        $page = Invoke-AlzRest -Method GET -Uri $page.nextLink
    }
    $found
}

function Test-AlzManagedResource {
    param($Resource)
    $properties = $Resource.properties
    $properties.Contains('metadata') -and $properties.metadata -is [System.Collections.IDictionary] -and
    $properties.metadata.Contains('managedBy') -and $properties.metadata.managedBy -eq $script:AlzManagedBy
}

if ($bySubscription) {
    $target = Invoke-AlzRest -Method GET -Path "${scope}?api-version=2022-12-01" -AllowNotFound
    if ($null -eq $target) { throw "Subscription $SubscriptionId was not found or is not readable. No writes performed." }
    $targetName = $target.displayName
    $targetTenant = if ($target.Contains('tenantId')) { $target.tenantId } else { $null }
}
else {
    $target = Invoke-AlzRest -Method GET -Path "${scope}?api-version=2020-05-01" -AllowNotFound
    if ($null -eq $target) { throw "Management group '$ManagementGroupId' was not found or is not readable. No writes performed." }
    $targetName = $target.properties.displayName
    $targetTenant = $target.properties.tenantId
}
if ($TenantId -and $targetTenant -and $targetTenant -ne $TenantId.ToString()) { throw "The target belongs to tenant $targetTenant, not $TenantId. No writes performed." }
Write-Host "Target verified: $scope ($targetName).$(if (-not $Remove) { ' The definitions and the initiative are assignable there and below. No assignment will be created.' })"

# ---- What already exists at the scope --------------------------------------------------------------------------------
$existingDefinitions = Get-AlzExactScopeResource -Collection 'policyDefinitions'
$existingInitiatives = Get-AlzExactScopeResource -Collection 'policySetDefinitions'

# ---- Remove: only what this package published, initiative first ----------------------------------------------------
if ($Remove) {
    $ownedDefinitions = @($package.Definitions | Where-Object {
            $existing = $existingDefinitions[$_.Id.ToLowerInvariant()]
            $null -ne $existing -and (Test-AlzManagedResource $existing)
        })
    $existingInitiative = $existingInitiatives[$package.Initiative.Id.ToLowerInvariant()]
    $removeInitiative = $null -ne $existingInitiative -and (Test-AlzManagedResource $existingInitiative)
    if ($null -ne $existingInitiative -and -not $removeInitiative) { Write-Warning "Initiative '$InitiativeName' exists but was not published by this package; leaving it alone." }
    $foreign = @($package.Definitions | Where-Object { $existingDefinitions.ContainsKey($_.Id.ToLowerInvariant()) }).Count - $ownedDefinitions.Count
    if ($foreign -gt 0) { Write-Warning "$foreign definition(s) with matching names were not published by this package; leaving them alone." }
    Write-Host "Found $($ownedDefinitions.Count) definitions$(if ($removeInitiative) { " and initiative '$InitiativeName'" }) published by this package."

    $removed = $false
    if (($ownedDefinitions.Count -gt 0 -or $removeInitiative) -and
        $PSCmdlet.ShouldProcess($scope, "REMOVE $(if ($removeInitiative) { "initiative '$InitiativeName' and " })$($ownedDefinitions.Count) policy definitions published by this package")) {
        # Definitions cannot be deleted while the initiative references them, and the initiative cannot be deleted while it is assigned.
        if ($removeInitiative) { $null = Invoke-AlzRest -Method DELETE -Path "$($package.Initiative.Id)?api-version=$script:AlzPolicyApiVersion" }
        foreach ($definition in $ownedDefinitions) { $null = Invoke-AlzRest -Method DELETE -Path "$($definition.Id)?api-version=$script:AlzPolicyApiVersion" }
        $removed = $true
        Write-Host 'Removed.'
    }
    return [pscustomobject]@{
        Removed           = $removed
        Scope             = $scope
        InitiativeRemoved = ($removed -and $removeInitiative)
        DefinitionsFound  = $ownedDefinitions.Count
    }
}

# ---- Preflight: never overwrite what this script did not publish ---------------------------------------------------
$conflicts = [System.Collections.Generic.List[string]]::new()
$updates = 0
foreach ($definition in $package.Definitions) {
    $existing = $existingDefinitions[$definition.Id.ToLowerInvariant()]
    if ($null -eq $existing) { continue }
    if (Test-AlzManagedResource $existing) { $updates++ } else { $conflicts.Add($definition.Id) }
}
$existingInitiative = $existingInitiatives[$package.Initiative.Id.ToLowerInvariant()]
if ($null -ne $existingInitiative -and -not (Test-AlzManagedResource $existingInitiative)) { $conflicts.Add($package.Initiative.Id) }
if ($conflicts.Count -gt 0) {
    throw "Refusing to overwrite $($conflicts.Count) resource(s) that this script did not publish. Use another -DefinitionPrefix or -InitiativeName, or another scope. First conflict: $($conflicts[0])"
}
Write-Host "Preflight passed: $($package.Definitions.Count - $updates) definitions to create, $updates to update; initiative $(if ($existingInitiative) { 'updated' } else { 'created' })."

# ---- Publish ---------------------------------------------------------------------------------------------------------
$published = $false
if ($PSCmdlet.ShouldProcess($scope, "Publish $($package.Definitions.Count) policy definitions and initiative '$InitiativeName' (no assignment)")) {
    $failures = [System.Collections.Generic.List[string]]::new()
    $done = 0
    foreach ($definition in $package.Definitions) {
        $done++
        Write-Progress -Activity 'Publishing policy definitions' -Status "$done of $($package.Definitions.Count): $($definition.Name)" -PercentComplete (100 * $done / $package.Definitions.Count)
        try {
            $response = Invoke-AlzRest -Method PUT -Path "$($definition.Id)?api-version=$script:AlzPolicyApiVersion" -Body @{ properties = $definition.Properties }
            $effectName = $definition.Adapted.EffectParameter
            $expected = $definition.Properties.parameters[$effectName]
            $actual = $response.properties.parameters[$effectName]
            if ($response.properties.policyRule.then.effect -ne "[parameters('$effectName')]" -or
                (Get-AlzCanonicalJson @($expected.allowedValues)) -ne (Get-AlzCanonicalJson @($actual.allowedValues)) -or
                $expected.defaultValue -ne $actual.defaultValue) {
                throw 'The published effect parameter does not match the requested one.'
            }
        }
        catch {
            $failures.Add("$($definition.Name): $($_.Exception.Message)")
        }
    }
    Write-Progress -Activity 'Publishing policy definitions' -Completed
    if ($failures.Count -gt 0) {
        throw "$($failures.Count) definition(s) failed; the initiative was not published. Fix the cause or leave a policy out with -ExcludePolicy, then run again (publishing is idempotent).`n - $($failures -join "`n - ")"
    }

    # A new definition can take a moment to become visible to the policy set that references it.
    for ($attempt = 1; ; $attempt++) {
        try {
            $response = Invoke-AlzRest -Method PUT -Path "$($package.Initiative.Id)?api-version=$script:AlzPolicyApiVersion" -Body @{ properties = $package.Initiative.Properties }
            break
        }
        catch {
            $notVisibleYet = $_.Exception.Data['StatusCode'] -in 400, 404 -and $_.Exception.Message -match 'not found|could not be found|NotFound'
            if (-not $notVisibleYet -or $attempt -ge 6) { throw }
            Write-Verbose "Definitions are not visible yet; retrying the initiative in 10 s (attempt $attempt)."
            Start-Sleep -Seconds 10
        }
    }

    $actualReferences = @($response.properties.policyDefinitions)
    if ($actualReferences.Count -ne $package.Initiative.Properties.policyDefinitions.Count -or $response.properties.parameters.Count -ne $parameterCount) {
        throw 'The published initiative does not contain the requested policies and parameters.'
    }
    foreach ($expectedReference in $package.Initiative.Properties.policyDefinitions) {
        $actualReference = $actualReferences | Where-Object { $_.policyDefinitionReferenceId -eq $expectedReference.policyDefinitionReferenceId } | Select-Object -First 1
        if ($null -eq $actualReference -or $actualReference.policyDefinitionId -ine $expectedReference.policyDefinitionId -or
            (Get-AlzCanonicalJson $actualReference.parameters) -ne (Get-AlzCanonicalJson $expectedReference.parameters)) {
            throw "The published initiative differs from the request for $($expectedReference.policyDefinitionReferenceId)."
        }
    }
    $published = $true
    Write-Host "Published initiative $($package.Initiative.Id). Assign it to audit; see README.md to switch effects."
}

[pscustomobject]@{
    Published                = $published
    Scope                    = $scope
    InitiativeId             = $package.Initiative.Id
    DefinitionPrefix         = $DefinitionPrefix
    DefinitionCount          = $package.Definitions.Count
    InitiativeParameterCount = $parameterCount
    DeprecatedIncluded       = [bool]$IncludeDeprecated
    AssignmentCreated        = $false
}
