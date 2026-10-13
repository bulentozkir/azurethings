#requires -Version 7.2

<#
.SYNOPSIS
    Offline checks for the ALZ policy package. Needs no Azure access.

.DESCRIPTION
    Verifies that every imported definition audits by default and still equals its upstream original in everything but
    the effect handling and the documented policy rule adjustments (fingerprints from the import), that every local
    definition (local-definitions/) audits by default as well, the generated audit-first initiative, the generated
    catalog, and runs Deploy-AlzPolicy.ps1 end to end against an in-memory stand-in for Azure Resource Manager that
    applies the same kind of validation the Policy service does (effect values, allowed values, parameter bindings,
    referenced definitions). Exits with a non-zero code when a check fails. Run it after every ./Import-AlzPolicy.ps1.

.EXAMPLE
    ./Test-AlzPolicy.ps1
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'AlzPolicy.Common.ps1')

$script:Failures = [System.Collections.Generic.List[string]]::new()
$script:Checks = 0

function Assert-That {
    param([bool]$Condition, [string]$Message)
    $script:Checks++
    if (-not $Condition) {
        $script:Failures.Add($Message)
        Write-Host "  FAIL: $Message" -ForegroundColor Red
    }
}

function Write-Section { param([string]$Title) Write-Host "`n$Title" -ForegroundColor Cyan }

# Order-independent text of a list. Parenthesise the call in comparisons: `-join` and `-eq` have the same precedence,
# so `$a -join ',' -eq $b -join ','` would not compare the two lists.
function Get-SortedList { param($Values) (@($Values) | Sort-Object { $_ }) -join ',' }

$deployScript = Join-Path $PSScriptRoot 'Deploy-AlzPolicy.ps1'
$source = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'alz-library-source.json') -Raw | ConvertFrom-Json -AsHashtable
$records = @(Get-AlzPolicyRecord -DefinitionsPath (Join-Path $PSScriptRoot 'definitions') -LocalPath (Join-Path $PSScriptRoot 'local-definitions'))
$upstreamRecords = @($records | Where-Object { $_.Origin -eq 'upstream' })
$localRecords = @($records | Where-Object { $_.Origin -eq 'local' })
$activeRecords = @($records | Where-Object { -not $_.Deprecated })
$upstreamActive = @($upstreamRecords | Where-Object { -not $_.Deprecated })
$scope = '/providers/Microsoft.Management/managementGroups/contoso'

# ---- 1. Imported definitions -------------------------------------------------------------------------------------------
Write-Section 'Imported definitions'
Assert-That ($upstreamRecords.Count -eq $source.definitions.total) "Imported $($upstreamRecords.Count) definitions but alz-library-source.json says $($source.definitions.total)."
Assert-That ($upstreamActive.Count -eq $source.definitions.active) "Found $($upstreamActive.Count) active imported definitions, expected $($source.definitions.active)."
Assert-That (($upstreamRecords.Count - $upstreamActive.Count) -eq $source.definitions.deprecated) 'The deprecated definition count differs from alz-library-source.json.'
Assert-That (@($records.Name | Sort-Object -Unique).Count -eq $records.Count) 'Policy names are not unique.'
foreach ($record in $records) {
    $leaf = Split-Path -Leaf $record.File
    $folder = Split-Path -Leaf (Split-Path -Parent $record.File)
    Assert-That ($leaf -eq "$($record.Name).json") "$leaf does not hold policy $($record.Name)."
    Assert-That (($folder -eq 'deprecated') -eq $record.Deprecated) "$($record.Name) is in the wrong folder for its deprecated flag."
    Assert-That ($record.Definition.type -eq 'Microsoft.Authorization/policyDefinitions' -and $record.Definition.properties.policyType -eq 'Custom') "$($record.Name) is not a custom policy definition."
}
Assert-That (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'LICENSE-Azure-Landing-Zones-Library.txt')) 'The upstream licence copy is missing.'

# ---- 1b. Audit by default ----------------------------------------------------------------------------------------------
Write-Section 'Audit by default (every definition)'
$auditSet = @('Audit', 'AuditIfNotExists')
$upstreamEnforcing = 0
foreach ($record in $records) {
    $properties = $record.Definition.properties
    $expression = [string]$properties.policyRule.then.effect
    $isParameter = $expression -match "^\[parameters\('(?<name>[^']+)'\)\]$"
    Assert-That $isParameter "$($record.Name) hard-codes its effect '$expression'; it must be a parameter."
    if (-not $isParameter) { continue }
    $schema = $properties.parameters[$Matches.name]
    Assert-That ($schema.defaultValue -in $auditSet) "$($record.Name) defaults to '$($schema.defaultValue)', not to Audit or AuditIfNotExists."
    Assert-That ('AuditAction' -notin @($schema.allowedValues)) "$($record.Name) offers AuditAction, which is not a documented Azure Policy effect."
    Assert-That ('Disabled' -in @($schema.allowedValues) -and $schema.defaultValue -in @($schema.allowedValues)) "$($record.Name): the allowed effects are inconsistent."
    if ($record.Origin -ne 'upstream') { continue }
    $upstreamEffect = if ($properties.metadata.Contains('alzUpstreamEffect')) { $properties.metadata.alzUpstreamEffect } else { $null }
    Assert-That ($null -ne $upstreamEffect -and $upstreamEffect -in @($schema.allowedValues)) "$($record.Name): the upstream effect '$upstreamEffect' must be recorded and stay selectable."
    if ($upstreamEffect -notin $auditSet) { $upstreamEnforcing++ }
}
Assert-That ($upstreamEnforcing -eq $source.conversion.defaultChanged) "alz-library-source.json counts $($source.conversion.defaultChanged) converted defaults but the definitions record $upstreamEnforcing."
Assert-That ($upstreamEnforcing -gt 0) 'At least one definition should have applied an enforcing effect upstream.'

$examples = @(
    @{ Name = 'Deny-Storage-CopyScope'; Default = 'Audit'; Upstream = 'Deny'; Allowed = 'Audit', 'Deny', 'Disabled' }
    @{ Name = 'Deploy-Storage-sslEnforcement'; Default = 'AuditIfNotExists'; Upstream = 'DeployIfNotExists'; Allowed = 'AuditIfNotExists', 'DeployIfNotExists', 'Disabled' }
    @{ Name = 'Modify-NSG'; Default = 'Audit'; Upstream = 'Modify'; Allowed = 'Audit', 'Modify', 'Disabled' }
    @{ Name = 'Deploy-Budget'; Default = 'AuditIfNotExists'; Upstream = 'DeployIfNotExists'; Allowed = 'AuditIfNotExists', 'DeployIfNotExists', 'Disabled' }
    @{ Name = 'Audit-AzureHybridBenefit'; Default = 'Audit'; Upstream = 'Audit'; Allowed = 'Audit', 'Disabled' }
    @{ Name = 'Deploy-Diagnostics-LogAnalytics'; Default = 'AuditIfNotExists'; Upstream = 'DeployIfNotExists'; Allowed = 'AuditIfNotExists', 'DeployIfNotExists', 'Disabled' }
    # Effect hard-coded upstream: it becomes a parameter that defaults to audit. DenyAction audits with plain Audit.
    @{ Name = 'Append-KV-SoftDelete'; Default = 'Audit'; Upstream = 'Append'; Allowed = 'Audit', 'Append', 'Disabled' }
    @{ Name = 'DenyAction-DiagnosticLogs'; Default = 'Audit'; Upstream = 'DenyAction'; Allowed = 'Audit', 'DenyAction', 'Disabled' }
    @{ Name = 'DenyAction-ActivityLogs'; Default = 'Audit'; Upstream = 'DenyAction'; Allowed = 'Audit', 'DenyAction', 'Disabled' }
    @{ Name = 'DenyAction-DeleteResources'; Default = 'Audit'; Upstream = 'DenyAction'; Allowed = 'Audit', 'DenyAction', 'Disabled' }
    @{ Name = 'Deploy-Vm-autoShutdown'; Default = 'AuditIfNotExists'; Upstream = 'DeployIfNotExists'; Allowed = 'AuditIfNotExists', 'DeployIfNotExists', 'Disabled' }
    @{ Name = 'Deploy-VNET-HubSpoke'; Default = 'AuditIfNotExists'; Upstream = 'DeployIfNotExists'; Allowed = 'AuditIfNotExists', 'DeployIfNotExists', 'Disabled' }
)
foreach ($example in $examples) {
    $record = $records | Where-Object Name -eq $example.Name | Select-Object -First 1
    Assert-That ($null -ne $record) "$($example.Name) is not imported."
    if ($null -eq $record) { continue }
    $properties = $record.Definition.properties
    $schema = $properties.parameters['effect']
    Assert-That ($properties.policyRule.then.effect -eq "[parameters('effect')]") "$($example.Name) should use the effect parameter."
    Assert-That ($schema.defaultValue -eq $example.Default) "$($example.Name) should default to $($example.Default), not $($schema.defaultValue)."
    Assert-That ($properties.metadata.alzUpstreamEffect -eq $example.Upstream) "$($example.Name) should record upstream effect $($example.Upstream)."
    Assert-That ((Get-SortedList $schema.allowedValues) -eq (Get-SortedList $example.Allowed)) "$($example.Name) should allow $($example.Allowed -join ', ')."
}

Write-Section 'Stored definitions against the import manifest'
Assert-That (@($source.conversion.upstreamFingerprints.Keys).Count -eq $upstreamRecords.Count) 'alz-library-source.json must hold one upstream fingerprint per imported definition.'
foreach ($record in $upstreamRecords) {
    $problems = @(Test-AlzStoredDefinition -Record $record -Source $source)
    Assert-That ($problems.Count -eq 0) "Stored definition problems: $($problems -join ' | ')"
}
# ---- 1d. Documented policy rule adjustments ------------------------------------------------------------------------------
Write-Section 'Policy rule adjustments'
$adjustedNames = @($source.conversion.adjustments.Keys)
Assert-That ($source.conversion.policyRuleAdjusted -eq $adjustedNames.Count) 'alz-library-source.json counts a different number of adjustments than it lists.'
Assert-That ((Get-SortedList $adjustedNames) -eq (Get-SortedList @($script:AlzPolicyRuleAdjustments.Keys))) 'The adjustments in alz-library-source.json differ from those defined in AlzPolicy.Common.ps1.'

$ahub = $upstreamRecords | Where-Object Name -eq 'Audit-AzureHybridBenefit' | Select-Object -First 1
Assert-That ($null -ne $ahub) 'Audit-AzureHybridBenefit is not imported.'
if ($null -ne $ahub) {
    $ahubRule = Get-AlzCanonicalJson $ahub.Definition.properties.policyRule['if']
    Assert-That ($ahubRule -notmatch 'imageSKU') 'The Audit-AzureHybridBenefit rule must not test the image SKU, which is the Windows Server version.'
    Assert-That ($ahubRule -match 'MicrosoftWindowsServer' -and $ahubRule -match '"WindowsServer"' -and $ahubRule -match 'licenseType' -and $ahubRule -match 'Windows_Server') 'The Audit-AzureHybridBenefit rule must still test publisher, offer and license type.'
    Assert-That ($ahub.Definition.properties.metadata.alzAdjustment -eq 'no-windows-server-version-list') 'Audit-AzureHybridBenefit must record its adjustment.'
}

# The rule-editing function on synthetic rules.
function Get-SyntheticRule {
    param($Conditions)
    [ordered]@{ policyRule = [ordered]@{ 'if' = [ordered]@{ allOf = @($Conditions) }; 'then' = [ordered]@{ effect = "[parameters('effect')]" } }; metadata = [ordered]@{} }
}
function Get-SkuCondition { param([string]$Pattern, [string]$Field = 'Microsoft.Compute/imageSKU') [ordered]@{ field = $Field; like = $Pattern } }
$typeCondition = [ordered]@{ field = 'type'; equals = 'Microsoft.Compute/virtualMachines' }
$licenseCondition = [ordered]@{ field = 'Microsoft.Compute/licenseType'; notEquals = 'Windows_Server' }

$properties = Get-SyntheticRule @($typeCondition, [ordered]@{ anyOf = @((Get-SkuCondition '2016-*'), (Get-SkuCondition '2025-*' 'microsoft.compute/imagesku')) }, $licenseCondition)
Assert-That (Remove-AlzImageSkuCondition -Properties $properties) 'A version list in an anyOf group should be removed, whatever the case of the field name.'
Assert-That ((Get-AlzCanonicalJson $properties.policyRule['if'].allOf) -eq (Get-AlzCanonicalJson @($typeCondition, $licenseCondition))) 'Only the version list may be removed.'
Assert-That (-not (Remove-AlzImageSkuCondition -Properties $properties)) 'Removing again must change nothing.'
$properties = Get-SyntheticRule @($typeCondition, (Get-SkuCondition '2019-*'), $licenseCondition)
Assert-That ((Remove-AlzImageSkuCondition -Properties $properties) -and @($properties.policyRule['if'].allOf).Count -eq 2) 'A single imageSKU condition should be removed.'
$properties = Get-SyntheticRule @($typeCondition, [ordered]@{ allOf = @([ordered]@{ anyOf = @((Get-SkuCondition '2012-*')) }) }, $licenseCondition)
Assert-That ((Remove-AlzImageSkuCondition -Properties $properties) -and @($properties.policyRule['if'].allOf).Count -eq 2) 'A nested group of imageSKU conditions should be removed.'
$properties = Get-SyntheticRule @($typeCondition, [ordered]@{ anyOf = @((Get-SkuCondition '2016-*'), [ordered]@{ field = 'Microsoft.Compute/imageOffer'; equals = 'WindowsServer' }) }, $licenseCondition)
Assert-That ((-not (Remove-AlzImageSkuCondition -Properties $properties)) -and @($properties.policyRule['if'].allOf).Count -eq 3) 'A group that also tests another field must stay.'
$properties = Get-SyntheticRule @($typeCondition, $licenseCondition)
Assert-That (-not (Remove-AlzImageSkuCondition -Properties $properties)) 'A rule without imageSKU conditions has nothing to remove.'
$threw = $false
try { $null = Remove-AlzImageSkuCondition -Properties (Get-SyntheticRule @((Get-SkuCondition '2016-*'))) } catch { $threw = $true }
Assert-That $threw 'Removing every condition of the policy rule must be refused.'

$adjustment = Get-AlzPolicyRuleAdjustment -Name 'Audit-AzureHybridBenefit'
Assert-That ($null -ne $adjustment) 'AlzPolicy.Common.ps1 must define the adjustment of Audit-AzureHybridBenefit.'
if ($null -ne $adjustment) {
    $properties = Get-SyntheticRule @($typeCondition, (Get-SkuCondition '2016-*'), $licenseCondition)
    Assert-That (Invoke-AlzPolicyRuleAdjustment -Adjustment $adjustment -Properties $properties) 'The adjustment should change an upstream-shaped rule.'
    Assert-That ($properties.metadata.alzAdjustment -eq $adjustment.Id) 'The adjustment must be recorded in the metadata.'
    Assert-That (-not (Invoke-AlzPolicyRuleAdjustment -Adjustment $adjustment -Properties $properties)) 'The adjustment must be idempotent.'
}
Assert-That ($null -eq (Get-AlzPolicyRuleAdjustment -Name 'Deny-Storage-CopyScope')) 'A policy without an adjustment must not get one.'

# ---- 1e. Local definitions ----------------------------------------------------------------------------------------------
Write-Section 'Local definitions'
Assert-That ($localRecords.Count -ge 1) 'local-definitions/ should hold at least Audit-RHEL-Hybrid-Benefit.'
foreach ($record in $localRecords) {
    $problems = @(Test-AlzLocalDefinition -Record $record)
    Assert-That ($problems.Count -eq 0) "Local definition problems: $($problems -join ' | ')"
    Assert-That (-not $source.conversion.upstreamFingerprints.Contains($record.Name)) "$($record.Name) is also an upstream definition; the import would refuse to run."
}
Assert-That (@(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'definitions') -Filter '*.json' -File -Recurse | Where-Object { $_.BaseName -notin $source.conversion.upstreamFingerprints.Keys }).Count -eq 0) 'definitions/ holds files that are not imported ALZ definitions; the import would delete them. Move them to local-definitions/.'

$rhel = $localRecords | Where-Object Name -eq 'Audit-RHEL-Hybrid-Benefit' | Select-Object -First 1
Assert-That ($null -ne $rhel) 'Audit-RHEL-Hybrid-Benefit is missing from local-definitions/.'
if ($null -ne $rhel) {
    $rhelProperties = $rhel.Definition.properties
    $rhelConditions = @($rhelProperties.policyRule['if'].allOf)
    $skuConditions = @($rhelConditions | Where-Object { Test-AlzImageSkuCondition $_ })
    Assert-That ($skuConditions.Count -eq 1) 'The RHEL policy must have exactly one imageSKU condition.'
    if ($skuConditions.Count -eq 1) {
        Assert-That ($skuConditions[0].Contains('like') -and $skuConditions[0].like -eq "[parameters('imageSkuPattern')]" -and -not $skuConditions[0].Contains('in')) 'The RHEL image SKU must be matched with the imageSkuPattern parameter, not with a list of SKUs.'
    }
    $pattern = $rhelProperties.parameters['imageSkuPattern']
    Assert-That ($pattern.type -eq 'String' -and $pattern.defaultValue -eq 'rhel-*') 'imageSkuPattern must be a String that defaults to rhel-*.'
    # Every SKU that Azure published under redhat:rhel-byos when this was written, and the oldest of the former list,
    # must match the default; other publishers' SKUs must not.
    foreach ($sku in 'rhel-lvm74', 'rhel-lvm8', 'rhel-lvm85-gen2', 'rhel-lvm86', 'rhel-lvm95', 'rhel-lvm98-gen2', 'rhel-lvm-92-gen2', 'rhel-raw76') {
        Assert-That ($sku -like $pattern.defaultValue) "The default image SKU pattern must match $sku."
    }
    Assert-That ('2019-datacenter' -notlike $pattern.defaultValue) 'The default image SKU pattern must not match Windows Server SKUs.'
    $rhelRule = Get-AlzCanonicalJson $rhelProperties.policyRule['if']
    Assert-That ($rhelRule -match '"redhat"' -and $rhelRule -match '"rhel-byos"' -and $rhelRule -match 'RHEL_BYOS' -and $rhelRule -match 'virtualMachines') 'The RHEL policy must still test type, publisher, offer and license type.'
    $rhelEffect = $rhelProperties.parameters['effect']
    Assert-That ($rhelEffect.defaultValue -eq 'Audit' -and (Get-SortedList $rhelEffect.allowedValues) -eq (Get-SortedList @('Audit', 'Deny', 'Disabled'))) 'The RHEL policy must default to Audit and offer Audit, Deny and Disabled.'
}

# ---- 1c. The conversion itself -----------------------------------------------------------------------------------------
# The stored files are already converted, so these cases run the conversion on upstream-shaped definitions. They catch
# a wrong effect mapping before the next import would write it into definitions/.
Write-Section 'Conversion of upstream-shaped definitions'
function Get-SyntheticDefinition {
    param([string]$Name, [string]$Effect, $Allowed, $Default, $Details)
    $properties = [ordered]@{
        displayName = $Name
        policyType  = 'Custom'
        mode        = 'All'
        description = 'Synthetic definition for the conversion tests.'
        metadata    = [ordered]@{ category = 'Test'; version = '1.0.0' }
        parameters  = [ordered]@{}
        policyRule  = [ordered]@{ 'if' = [ordered]@{ field = 'type'; equals = 'Microsoft.Test/things' }; 'then' = [ordered]@{ effect = $Effect } }
    }
    if ($Allowed) { $properties.parameters['effect'] = [ordered]@{ type = 'String'; allowedValues = @($Allowed); defaultValue = $Default; metadata = [ordered]@{ displayName = 'Effect' } } }
    if ($Details) { $properties.policyRule['then']['details'] = $Details }
    [ordered]@{ name = $Name; type = 'Microsoft.Authorization/policyDefinitions'; properties = $properties }
}

$conversionCases = @(
    @{ Case = 'Deny'; Allowed = 'Audit', 'Deny', 'Disabled'; Default = 'Deny'; Expect = 'Audit'; ExpectAllowed = 'Audit', 'Deny', 'Disabled' }
    @{ Case = 'Deny without an Audit value'; Allowed = 'Deny', 'Disabled'; Default = 'Deny'; Expect = 'Audit'; ExpectAllowed = 'Audit', 'Deny', 'Disabled' }
    @{ Case = 'DeployIfNotExists'; Allowed = 'DeployIfNotExists', 'Disabled'; Default = 'DeployIfNotExists'; Expect = 'AuditIfNotExists'; ExpectAllowed = 'AuditIfNotExists', 'DeployIfNotExists', 'Disabled' }
    @{ Case = 'DeployIfNotExists with AuditIfNotExists'; Allowed = 'DeployIfNotExists', 'AuditIfNotExists', 'Disabled'; Default = 'DeployIfNotExists'; Expect = 'AuditIfNotExists'; ExpectAllowed = 'DeployIfNotExists', 'AuditIfNotExists', 'Disabled' }
    @{ Case = 'Modify'; Allowed = 'Modify', 'Disabled'; Default = 'Modify'; Expect = 'Audit'; ExpectAllowed = 'Audit', 'Modify', 'Disabled' }
    @{ Case = 'Append parameter'; Allowed = 'Append', 'Disabled'; Default = 'Append'; Expect = 'Audit'; ExpectAllowed = 'Audit', 'Append', 'Disabled' }
    @{ Case = 'DenyAction parameter'; Allowed = 'DenyAction', 'Disabled'; Default = 'DenyAction'; Expect = 'Audit'; ExpectAllowed = 'Audit', 'DenyAction', 'Disabled'; Details = @{ actionNames = @('delete') } }
    @{ Case = 'Audit only'; Allowed = 'Audit', 'Disabled'; Default = 'Audit'; Expect = 'Audit'; ExpectAllowed = 'Audit', 'Disabled' }
    @{ Case = 'hard-coded append'; Effect = 'append'; Upstream = 'Append'; Expect = 'Audit'; ExpectAllowed = 'Audit', 'Append', 'Disabled' }
    @{ Case = 'hard-coded denyAction'; Effect = 'denyAction'; Upstream = 'DenyAction'; Expect = 'Audit'; ExpectAllowed = 'Audit', 'DenyAction', 'Disabled'; Details = @{ actionNames = @('delete') } }
    @{ Case = 'hard-coded deployIfNotExists'; Effect = 'deployIfNotExists'; Upstream = 'DeployIfNotExists'; Expect = 'AuditIfNotExists'; ExpectAllowed = 'AuditIfNotExists', 'DeployIfNotExists', 'Disabled' }
)
foreach ($case in $conversionCases) {
    $effectExpression = if ($case.Contains('Effect')) { $case.Effect } else { "[parameters('effect')]" }
    $allowedEffects = if ($case.Contains('Allowed')) { $case.Allowed } else { $null }
    $defaultEffect = if ($case.Contains('Default')) { $case.Default } else { $null }
    $details = if ($case.Contains('Details')) { $case.Details } else { $null }
    $upstreamEffect = if ($case.Contains('Upstream')) { $case.Upstream } else { $case.Default }
    $definition = Get-SyntheticDefinition -Name "Test-$($case.Case -replace '\W', '-')" -Effect $effectExpression -Allowed $allowedEffects -Default $defaultEffect -Details $details
    $result = ConvertTo-AlzAuditFirstDefinition -Definition $definition
    $schema = $result.Properties.parameters['effect']
    Assert-That ($schema.defaultValue -eq $case.Expect -and $schema.defaultValue -in $auditSet) "Conversion '$($case.Case)': the default should be $($case.Expect), not $($schema.defaultValue)."
    Assert-That ((Get-SortedList $schema.allowedValues) -eq (Get-SortedList $case.ExpectAllowed)) "Conversion '$($case.Case)': the allowed effects should be $($case.ExpectAllowed -join ', ')."
    Assert-That ($result.Properties.policyRule.then.effect -eq "[parameters('effect')]") "Conversion '$($case.Case)': the effect must be the parameter."
    Assert-That ($result.Properties.metadata.alzUpstreamEffect -eq $upstreamEffect) "Conversion '$($case.Case)': the upstream effect should be recorded as $upstreamEffect."

    $converted = [ordered]@{ name = $definition.name; type = $definition.type; properties = $result.Properties }
    $again = ConvertTo-AlzAuditFirstDefinition -Definition $converted
    Assert-That ((Get-AlzCanonicalJson $again.Properties) -eq (Get-AlzCanonicalJson $result.Properties)) "Conversion '$($case.Case)' is not idempotent."
    Assert-That ((Get-AlzDefinitionFingerprint -Definition $definition) -eq (Get-AlzDefinitionFingerprint -Definition $converted)) "Conversion '$($case.Case)' changed more than the effect handling."
}

$refused = @(
    @{ Case = 'a hard-coded AuditAction'; Effect = 'AuditAction' }
    @{ Case = 'an unknown effect value'; Effect = "[parameters('effect')]"; Allowed = 'Deny', 'Bogus', 'Disabled'; Default = 'Deny' }
)
foreach ($case in $refused) {
    $allowedEffects = if ($case.Contains('Allowed')) { $case.Allowed } else { $null }
    $defaultEffect = if ($case.Contains('Default')) { $case.Default } else { $null }
    $definition = Get-SyntheticDefinition -Name 'Test-Refused' -Effect $case.Effect -Allowed $allowedEffects -Default $defaultEffect
    $threw = $false
    try { $null = ConvertTo-AlzAuditFirstDefinition -Definition $definition } catch { $threw = $true }
    Assert-That $threw "The conversion must refuse $($case.Case)."
}

# ---- 2. Generated initiative -------------------------------------------------------------------------------------------
Write-Section 'Generated initiative (active policies)'
$active = Build-AlzPolicyPackage -Record $activeRecords -Scope $scope -DefinitionPrefix 'alz-' -InitiativeName 'alz-custom-policies' -DisplayName 'Test' -Source $source
$problems = @(Test-AlzPolicyPackage -Package $active)
Assert-That ($problems.Count -eq 0) "Active package problems: $($problems -join ' | ')"
Assert-That ($active.Initiative.Name -eq 'alz-custom-policies') 'The initiative name was not preserved.'
Assert-That ($active.Initiative.Id -eq "$scope/providers/Microsoft.Authorization/policySetDefinitions/alz-custom-policies") 'The initiative id is wrong.'
$parameters = $active.Initiative.Properties.parameters
$effects = @($parameters.GetEnumerator() | Where-Object { $_.Key.EndsWith('_effect') })
Assert-That ($effects.Count -eq $activeRecords.Count) 'There must be exactly one effect parameter per policy.'
Assert-That (@($effects | Where-Object { $_.Value.defaultValue -notin $script:AlzAuditEffects }).Count -eq 0) 'Every effect parameter must default to an audit-mode effect.'
Assert-That (@($parameters.GetEnumerator() | Where-Object { -not $_.Value.Contains('defaultValue') }).Count -eq 0) 'Every initiative parameter must have a default so assignment needs no input.'

$expectations = @(
    @{ Name = 'Deny-Storage-CopyScope'; Default = 'Audit'; Allowed = 'Audit', 'Deny', 'Disabled' }
    @{ Name = 'Deploy-Storage-sslEnforcement'; Default = 'AuditIfNotExists'; Allowed = 'AuditIfNotExists', 'DeployIfNotExists', 'Disabled' }
    @{ Name = 'Deploy-Vm-autoShutdown'; Default = 'AuditIfNotExists'; Allowed = 'AuditIfNotExists', 'DeployIfNotExists', 'Disabled' }
    @{ Name = 'Modify-NSG'; Default = 'Audit'; Allowed = 'Audit', 'Modify', 'Disabled' }
    @{ Name = 'Append-KV-SoftDelete'; Default = 'Audit'; Allowed = 'Audit', 'Append', 'Disabled' }
    @{ Name = 'DenyAction-DiagnosticLogs'; Default = 'Audit'; Allowed = 'Audit', 'DenyAction', 'Disabled' }
    @{ Name = 'Deploy-Budget'; Default = 'AuditIfNotExists'; Allowed = 'DeployIfNotExists', 'AuditIfNotExists', 'Disabled' }
)
foreach ($expectation in $expectations) {
    $schema = $parameters["$(ConvertTo-AlzKey $expectation.Name)_effect"]
    Assert-That ($null -ne $schema -and $schema.defaultValue -eq $expectation.Default) "$($expectation.Name) should default to $($expectation.Default)."
    Assert-That ($null -ne $schema -and (Get-SortedList $schema.allowedValues) -eq (Get-SortedList $expectation.Allowed)) "$($expectation.Name) should allow $($expectation.Allowed -join ', ')."
}
foreach ($definition in $active.Definitions) {
    $definitionDefault = $definition.Properties.parameters[$definition.Adapted.EffectParameter].defaultValue
    $initiativeDefault = $parameters["$(ConvertTo-AlzKey $definition.PolicyName)_effect"].defaultValue
    Assert-That ($definitionDefault -eq $initiativeDefault -and $definitionDefault -in $script:AlzAuditEffects) "$($definition.PolicyName): the definition ($definitionDefault) and the initiative ($initiativeDefault) must default to the same audit-mode effect."
}
Assert-That ($parameters.Contains('mandatoryTags') -and -not $parameters.Contains('Audit_Tags_Mandatory_mandatoryTags')) 'mandatoryTags should be shared by the two tag policies.'
Assert-That ($parameters.Contains('Deploy_DDoSProtection_rgName') -and $parameters.Contains('Deploy_FirewallPolicy_rgName') -and -not $parameters.Contains('rgName')) 'rgName must stay per policy.'
Assert-That ($parameters['Deploy_DDoSProtection_rgName'].defaultValue -eq '' -and $parameters['Deploy_DDoSProtection_rgName'].metadata.alzPlaceholderDefault -eq $true) 'Parameters without an upstream default need a flagged placeholder.'

# ---- 3. Deprecated policies and stable names ---------------------------------------------------------------------------
Write-Section 'Generated initiative (including deprecated policies)'
$all = Build-AlzPolicyPackage -Record $records -Scope $scope -DefinitionPrefix 'alz-' -InitiativeName 'alz-custom-policies' -DisplayName 'Test' -Source $source
$problems = @(Test-AlzPolicyPackage -Package $all)
Assert-That ($problems.Count -eq 0) "Full package problems: $($problems -join ' | ')"
Assert-That ($all.Initiative.Properties.parameters.Count -le 400) 'The full initiative exceeds the 400 parameter limit.'
foreach ($entry in $parameters.GetEnumerator()) {
    $other = $all.Initiative.Properties.parameters[$entry.Key]
    Assert-That ($null -ne $other -and (Get-AlzCanonicalJson $other) -eq (Get-AlzCanonicalJson $entry.Value)) "Parameter $($entry.Key) differs once deprecated policies are included, which would break existing assignments."
}

# Publishing adds the ownership metadata and nothing else to what is stored in definitions/.
foreach ($definition in $all.Definitions) {
    $published = Copy-AlzObject $definition.Properties
    foreach ($key in 'managedBy', 'alzName', 'alzLibraryVersion', 'alzOrigin') { if ($published.metadata.Contains($key)) { $null = $published.metadata.Remove($key) } }
    Assert-That ((Get-AlzCanonicalJson $published) -eq (Get-AlzCanonicalJson $definition.Record.Definition.properties)) "$($definition.PolicyName): the published definition differs from its file in $(if ($definition.Record.Origin -eq 'local') { 'local-definitions/' } else { 'definitions/' })."
}
$localPublished = @($all.Definitions | Where-Object { $_.Record.Origin -eq 'local' })
Assert-That ($localPublished.Count -eq $localRecords.Count) 'Every local definition must be part of the package.'
foreach ($definition in $localPublished) {
    Assert-That ($definition.Properties.metadata.alzOrigin -eq 'local' -and -not $definition.Properties.metadata.Contains('alzLibraryVersion') -and -not $definition.Properties.metadata.Contains('alzUpstreamEffect')) "$($definition.PolicyName): a published local definition is marked alzOrigin=local and has no library version or upstream effect."
}

# ---- 3b. Definition names ----------------------------------------------------------------------------------------------
Write-Section 'Definition names'
$longest = $records | Sort-Object { $_.Name.Length } | Select-Object -Last 1
Assert-That ($longest.Name.Length -le 64) 'Upstream names must fit the 64 character limit.'
foreach ($definition in $all.Definitions) {
    Assert-That ($definition.Name.Length -le 64) "$($definition.Name) exceeds 64 characters."
}
Assert-That (@($all.Definitions.Name | Sort-Object -Unique).Count -eq $all.Definitions.Count) 'Published definition names must be unique.'
$byPolicy = @{}; foreach ($definition in $all.Definitions) { $byPolicy[$definition.PolicyName] = $definition.Name }
Assert-That ($byPolicy['Deny-Storage-CopyScope'] -eq 'alz-Deny-Storage-CopyScope') 'Short names must just get the prefix.'
Assert-That ($byPolicy[$longest.Name] -match '^alz-.+-[0-9a-f]{8}$' -and $byPolicy[$longest.Name].Length -le 64) "The over-long name $($longest.Name) must be shortened with a hash suffix."
Assert-That ((Get-AlzDefinitionName -Prefix 'alz-' -Name $longest.Name) -eq $byPolicy[$longest.Name]) 'Shortened names must be deterministic.'
Assert-That ((Get-AlzDefinitionName -Prefix ('x' * 31) -Name $longest.Name).Length -le 64) 'The longest allowed prefix must still produce valid names.'
Assert-That ((Get-AlzDefinitionName -Prefix '' -Name $longest.Name) -eq $longest.Name) 'Without a prefix every upstream name is kept.'
# ---- 4. The validator must catch mistakes ------------------------------------------------------------------------------
Write-Section 'Validator negative tests'
$sample = @($activeRecords | Where-Object { $_.Name -in 'Deny-Storage-CopyScope', 'Deploy-Storage-sslEnforcement' })
$mutations = [ordered]@{
    'a default that enforces'                 = { param($p) $p.Initiative.Properties.parameters['Deny_Storage_CopyScope_effect'].defaultValue = 'Deny' }
    'an effect that the definition rejects'   = { param($p) $p.Initiative.Properties.parameters['Deploy_Storage_sslEnforcement_effect'].allowedValues = @('AuditIfNotExists', 'Disabled', 'Bogus') }
    'a dangling parameter binding'            = { param($p) $p.Initiative.Properties.policyDefinitions[0].parameters.effect.value = "[parameters('Nope')]" }
    'a parameter without a default'           = { param($p) $null = $p.Initiative.Properties.parameters['Deny_Storage_CopyScope_effect'].Remove('defaultValue') }
    'a definition that defaults to an enforcing effect' = { param($p) $p.Definitions[0].Properties.parameters['effect'].defaultValue = 'Deny' }
    'a definition that defaults to AuditAction' = { param($p) $p.Definitions[0].Properties.parameters['effect'].defaultValue = 'AuditAction' }
    'a definition that dropped its upstream effect' = { param($p) $p.Definitions[1].Properties.parameters['effect'].allowedValues = @('AuditIfNotExists', 'Disabled') }
    'a duplicate reference id'                = { param($p) $p.Initiative.Properties.policyDefinitions[1].policyDefinitionReferenceId = $p.Initiative.Properties.policyDefinitions[0].policyDefinitionReferenceId }
}
foreach ($mutation in $mutations.GetEnumerator()) {
    $copy = Build-AlzPolicyPackage -Record $sample -Scope $scope -InitiativeName 'x' -DisplayName 'x' -Source $source
    & $mutation.Value $copy
    Assert-That (@(Test-AlzPolicyPackage -Package $copy).Count -gt 0) "The validator did not catch $($mutation.Key)."
}

# ---- 4b. The stored-definition check must catch mistakes ---------------------------------------------------------------
Write-Section 'Stored definition negative tests'
$template = $records | Where-Object Name -eq 'Deny-Storage-CopyScope' | Select-Object -First 1
$control = [pscustomobject]@{ Name = $template.Name; Definition = (Copy-AlzObject $template.Definition) }
Assert-That (@(Test-AlzStoredDefinition -Record $control -Source $source).Count -eq 0) 'An unmodified copy of a stored definition must pass the check.'
$storedMutations = [ordered]@{
    'a default that enforces'            = { param($d) $d.properties.parameters.effect.defaultValue = 'Deny' }
    'a default of AuditAction'           = { param($d) $d.properties.parameters.effect.defaultValue = 'AuditAction' }
    'a hard-coded effect'                = { param($d) $d.properties.policyRule.then.effect = 'deny' }
    'a changed policy condition'         = { param($d) $d.properties.policyRule['if'] = @{ field = 'type'; equals = 'x' } }
    'a changed parameter'                = { param($d) $d.properties.parameters.Remove('effect'); $d.properties.parameters['other'] = @{ type = 'String' } }
    'a changed description'              = { param($d) $d.properties.description = 'changed' }
    'a lost upstream effect record'      = { param($d) $null = $d.properties.metadata.Remove('alzUpstreamEffect') }
    'an upstream effect that is gone'    = { param($d) $d.properties.parameters.effect.allowedValues = @('Audit', 'Disabled') }
    'an unknown policy'                  = { param($d) $d.name = 'Not-In-The-Manifest' }
}
foreach ($mutation in $storedMutations.GetEnumerator()) {
    $copy = [pscustomobject]@{ Name = $template.Name; Definition = (Copy-AlzObject $template.Definition) }
    & $mutation.Value $copy.Definition
    if ($mutation.Key -eq 'an unknown policy') { $copy.Name = 'Not-In-The-Manifest' }
    Assert-That (@(Test-AlzStoredDefinition -Record $copy -Source $source).Count -gt 0) "The stored definition check did not catch $($mutation.Key)."
}
# ---- 4c. The adjustment and local-definition checks must catch mistakes -------------------------------------------------
Write-Section 'Adjustment and local definition negative tests'
$ahubTemplate = $upstreamRecords | Where-Object Name -eq 'Audit-AzureHybridBenefit' | Select-Object -First 1
$ahubControl = [pscustomobject]@{ Name = $ahubTemplate.Name; Definition = (Copy-AlzObject $ahubTemplate.Definition) }
Assert-That (@(Test-AlzStoredDefinition -Record $ahubControl -Source $source).Count -eq 0) 'An unmodified copy of the adjusted definition must pass the check.'
$adjustmentMutations = [ordered]@{
    'the version list restored'      = { param($d) $conditions = @($d.properties.policyRule['if'].allOf); $d.properties.policyRule['if']['allOf'] = @($conditions[0..2]) + @([ordered]@{ anyOf = @([ordered]@{ field = 'Microsoft.Compute/imageSKU'; like = '2016-*' }) }) + @($conditions[3]) }
    'the adjustment record removed'  = { param($d) $null = $d.properties.metadata.Remove('alzAdjustment') }
    'a wrong adjustment record'      = { param($d) $d.properties.metadata['alzAdjustment'] = 'something-else' }
    'another rule change'            = { param($d) $d.properties.policyRule['if'].allOf[1]['equals'] = 'SomeoneElse' }
    'another effect-free change'     = { param($d) $d.properties.description = 'changed' }
}
foreach ($mutation in $adjustmentMutations.GetEnumerator()) {
    $copy = [pscustomobject]@{ Name = $ahubTemplate.Name; Definition = (Copy-AlzObject $ahubTemplate.Definition) }
    & $mutation.Value $copy.Definition
    Assert-That (@(Test-AlzStoredDefinition -Record $copy -Source $source).Count -gt 0) "The stored definition check did not catch $($mutation.Key) in an adjusted definition."
}
$stray = [pscustomobject]@{ Name = $template.Name; Definition = (Copy-AlzObject $template.Definition) }
$stray.Definition.properties.metadata['alzAdjustment'] = 'no-windows-server-version-list'
Assert-That (@(Test-AlzStoredDefinition -Record $stray -Source $source).Count -gt 0) 'An adjustment record on a definition that has no adjustment must be caught.'
$tampered = Copy-AlzObject $source
$tampered.conversion.adjustments['Audit-AzureHybridBenefit'].adjustedFingerprint = '0' * 64
Assert-That (@(Test-AlzStoredDefinition -Record $ahubControl -Source $tampered).Count -gt 0) 'A wrong adjusted fingerprint in the manifest must be caught.'
$unrecorded = Copy-AlzObject $source
$null = $unrecorded.conversion.adjustments.Remove('Audit-AzureHybridBenefit')
Assert-That (@(Test-AlzStoredDefinition -Record $ahubControl -Source $unrecorded).Count -gt 0) 'An adjustment that the manifest does not record must be caught.'

$rhelTemplate = $localRecords | Where-Object Name -eq 'Audit-RHEL-Hybrid-Benefit' | Select-Object -First 1
$localControl = [pscustomobject]@{ Name = $rhelTemplate.Name; Definition = (Copy-AlzObject $rhelTemplate.Definition) }
Assert-That (@(Test-AlzLocalDefinition -Record $localControl).Count -eq 0) 'An unmodified copy of a local definition must pass the check.'
$localMutations = [ordered]@{
    'a default that enforces'        = { param($d) $d.properties.parameters.effect.defaultValue = 'Deny' }
    'a hard-coded effect'            = { param($d) $d.properties.policyRule.then.effect = 'audit' }
    'a default that is not offered'  = { param($d) $d.properties.parameters.effect.allowedValues = @('Deny', 'Disabled') }
    'an effect parameter without Disabled' = { param($d) $d.properties.parameters.effect.allowedValues = @('Deny', 'Audit') }
    'AuditAction'                    = { param($d) $d.properties.parameters.effect.allowedValues = @('AuditAction', 'Audit', 'Disabled') }
    'a missing policyType'           = { param($d) $null = $d.properties.Remove('policyType') }
    'the wrong resource type'        = { param($d) $d.type = 'Microsoft.Authorization/policySetDefinitions' }
    'a metadata key of the package'  = { param($d) $d.properties.metadata['managedBy'] = 'someone' }
}
foreach ($mutation in $localMutations.GetEnumerator()) {
    $copy = [pscustomobject]@{ Name = $rhelTemplate.Name; Definition = (Copy-AlzObject $rhelTemplate.Definition) }
    & $mutation.Value $copy.Definition
    Assert-That (@(Test-AlzLocalDefinition -Record $copy).Count -gt 0) "The local definition check did not catch $($mutation.Key)."
}

# ---- 5. Catalog ---------------------------------------------------------------------------------------------------------
Write-Section 'Catalog'
$catalog = (Format-AlzPolicyCatalog -Record $records -Source $source) + "`n"
$onDisk = (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'policy-catalog.md') -Raw) -replace "`r`n", "`n"
Assert-That ($catalog -eq $onDisk) 'policy-catalog.md is stale. Run ./Import-AlzPolicy.ps1 to regenerate it.'

# ---- 6. Deploy-AlzPolicy.ps1 against an in-memory Azure Resource Manager -------------------------------------------------
Write-Section 'Deploy-AlzPolicy.ps1 against a simulated Azure Resource Manager'

$tenantId = '11111111-1111-1111-1111-111111111111'
$subscriptionId = '22222222-2222-2222-2222-222222222222'

# The stand-in is a dynamic module: it shadows the Az cmdlets that the script calls and keeps its own state. It rejects
# what the Policy service rejects: an effect parameter without a valid default, a policy set that references a missing
# definition or parameter, or an effect value that the referenced definition does not allow.
$null = New-Module -Name AlzMockArm -ArgumentList $tenantId, $subscriptionId -ScriptBlock {
    param($TenantId, $SubscriptionId)

    function Initialize-AlzMockArm {
        $script:Arm = [pscustomobject]@{
            Store              = @{}
            Calls              = [System.Collections.Generic.List[string]]::new()
            Throttle           = 0
            HideDefinitionsFor = 0
            RejectDefinition   = $null
            PageSize           = 40
            Assigned           = $false
            Environment        = 'AzureCloud'
        }
        $script:Arm
    }

    function ConvertTo-ArmResponse {
        param([int]$Status, $Body, [string]$RetryAfter)
        $headers = @()
        if ($RetryAfter) { $headers += [System.Collections.Generic.KeyValuePair[string, string[]]]::new('Retry-After', [string[]]@($RetryAfter)) }
        [pscustomobject]@{ StatusCode = $Status; Content = $(if ($null -eq $Body) { '' } else { ConvertTo-Json -InputObject $Body -Depth 100 -Compress }); Headers = $headers }
    }

    function ConvertTo-ArmErrorResponse { param([int]$Status, [string]$Code, [string]$Message) ConvertTo-ArmResponse $Status @{ error = @{ code = $Code; message = $Message } } }

    function Get-ArmDefinitionProblem {
        param($Properties)
        if ($Properties.policyRule.then.effect -notmatch "^\[parameters\('(?<name>[^']+)'\)\]$") { return $null }
        $schema = $Properties.parameters[$Matches.name]
        if ($null -eq $schema) { return "The effect parameter '$($Matches.name)' is not defined." }
        $known = 'Audit', 'AuditIfNotExists', 'Deny', 'DenyAction', 'DeployIfNotExists', 'Modify', 'Append', 'Disabled'
        foreach ($value in @($schema.allowedValues) + @($schema.defaultValue)) {
            if ($null -ne $value -and $value -notin $known) { return "'$value' is not a policy effect." }
        }
        if ($schema.Contains('allowedValues') -and $schema.Contains('defaultValue') -and @($schema.allowedValues) -notcontains $schema.defaultValue) { return 'The default effect is not an allowed value.' }
    }

    function Get-ArmInitiativeProblem {
        param($Properties)
        if ($Properties.parameters.Count -gt 400) { return 'Too many parameters.' }
        foreach ($reference in $Properties.policyDefinitions) {
            $definition = $script:Arm.Store[$reference.policyDefinitionId.ToLowerInvariant()]
            if ($null -eq $definition) { return @{ Code = 'PolicyDefinitionNotFound'; Message = "The policy definition '$($reference.policyDefinitionId)' could not be found." } }
            foreach ($binding in $reference.parameters.GetEnumerator()) {
                $definitionSchema = $definition.properties.parameters[$binding.Key]
                if ($null -eq $definitionSchema) { return "Policy '$($reference.policyDefinitionReferenceId)' has no parameter '$($binding.Key)'." }
                if ($binding.Value.value -notmatch "^\[parameters\('(?<name>[^']+)'\)\]$") { continue }
                $initiativeSchema = $Properties.parameters[$Matches.name]
                if ($null -eq $initiativeSchema) { return "Initiative parameter '$($Matches.name)' is not defined." }
                if ($definitionSchema.Contains('allowedValues') -and ([string]$definitionSchema.type) -ne 'Array') {
                    foreach ($value in @($initiativeSchema.defaultValue) + @($initiativeSchema.allowedValues)) {
                        if ($null -ne $value -and @($definitionSchema.allowedValues) -notcontains $value) { return "Value '$value' of '$($Matches.name)' is not allowed by policy '$($reference.policyDefinitionReferenceId)'." }
                    }
                }
            }
            foreach ($name in $definition.properties.parameters.Keys) {
                if (-not $reference.parameters.Contains($name) -and -not $definition.properties.parameters[$name].Contains('defaultValue')) { return "Parameter '$name' of '$($reference.policyDefinitionReferenceId)' needs a value." }
            }
        }
    }

    function Get-AzContext {
        [pscustomobject]@{
            Account      = [pscustomobject]@{ Id = 'tester@example.com' }
            Environment  = [pscustomobject]@{ Name = $script:Arm.Environment }
            Tenant       = [pscustomobject]@{ Id = $TenantId }
            Subscription = [pscustomobject]@{ Id = $SubscriptionId }
        }
    }

    function Connect-AzAccount { throw 'Connect-AzAccount must not be called when the context matches.' }

    function Start-Sleep { param($Seconds) }

    function Invoke-AzRestMethod {
        [CmdletBinding(SupportsShouldProcess)]
        param($Method, $Path, $Uri, $Payload, $DefaultProfile)

        $target = if ($Uri) { ([uri]$Uri).PathAndQuery } else { $Path }
        $route = ($target -split '\?')[0]
        $query = if ($target.Contains('?')) { $target.Substring($target.IndexOf('?') + 1) } else { '' }
        $script:Arm.Calls.Add("$Method $route")

        if ($Method -eq 'PUT' -and $script:Arm.Throttle -gt 0) { $script:Arm.Throttle--; return ConvertTo-ArmResponse 429 @{ error = @{ code = 'TooManyRequests' } } '0' }

        if ($route -match '^/providers/Microsoft.Management/managementGroups/(?<id>[^/]+)$') {
            if ($Matches.id -ne 'contoso') { return ConvertTo-ArmErrorResponse 404 'NotFound' 'Management group not found.' }
            return ConvertTo-ArmResponse 200 @{ id = $route; properties = @{ tenantId = $TenantId; displayName = 'Contoso' } }
        }
        if ($route -match '^/subscriptions/(?<id>[^/]+)$') {
            if ($Matches.id -ne $SubscriptionId) { return ConvertTo-ArmErrorResponse 404 'SubscriptionNotFound' 'Subscription not found.' }
            return ConvertTo-ArmResponse 200 @{ id = $route; displayName = 'Test subscription'; tenantId = $TenantId }
        }
        if ($route -match '^(?<scope>.+)/providers/Microsoft.Authorization/(?<kind>policyDefinitions|policySetDefinitions)$' -and $Method -eq 'GET') {
            $prefix = "$($Matches.scope)/providers/Microsoft.Authorization/$($Matches.kind)/".ToLowerInvariant()
            $items = @($script:Arm.Store.Keys | Sort-Object | Where-Object { $_.StartsWith($prefix) } | ForEach-Object { $script:Arm.Store[$_] })
            $skip = if ($query -match 'skip=(?<n>\d+)') { [int]$Matches.n } else { 0 }
            $page = @{ value = @($items | Select-Object -Skip $skip -First $script:Arm.PageSize) }
            if ($skip + $script:Arm.PageSize -lt $items.Count) { $page.nextLink = "https://management.azure.com$route`?api-version=x&skip=$($skip + $script:Arm.PageSize)" }
            return ConvertTo-ArmResponse 200 $page
        }
        if ($route -match '^(?<scope>.+)/providers/Microsoft.Authorization/(?<kind>policyDefinitions|policySetDefinitions)/(?<name>[^/]+)$') {
            $key = $route.ToLowerInvariant()
            if ($Method -eq 'PUT' -and ($Matches.name.Length -gt 64 -or $Matches.name -match '[#<>%&:\\?/]' -or $Matches.name -match '[. ]$')) { return ConvertTo-ArmErrorResponse 400 'InvalidResourceName' 'The resource name is not valid.' }
            if ($Method -eq 'GET') {
                if ($script:Arm.Store.ContainsKey($key)) { return ConvertTo-ArmResponse 200 $script:Arm.Store[$key] }
                return ConvertTo-ArmErrorResponse 404 'PolicyDefinitionNotFound' 'Not found.'
            }
            if ($Method -eq 'DELETE') {
                if (-not $script:Arm.Store.ContainsKey($key)) { return ConvertTo-ArmResponse 204 $null }
                if ($Matches.kind -eq 'policySetDefinitions' -and $script:Arm.Assigned) { return ConvertTo-ArmErrorResponse 409 'PolicySetDefinitionInUse' 'The initiative is assigned.' }
                if ($Matches.kind -eq 'policyDefinitions') {
                    $users = @($script:Arm.Store.Values | Where-Object { $_.type -like '*policySetDefinitions' -and @($_.properties.policyDefinitions | Where-Object { $_.policyDefinitionId -ieq $route }).Count -gt 0 })
                    if ($users.Count -gt 0) { return ConvertTo-ArmErrorResponse 409 'PolicyDefinitionInUse' 'The definition is referenced by an initiative.' }
                }
                $script:Arm.Store.Remove($key)
                return ConvertTo-ArmResponse 200 $null
            }            $body = $Payload | ConvertFrom-Json -AsHashtable -Depth 100
            if ($Matches.kind -eq 'policyDefinitions') {
                if ($script:Arm.RejectDefinition -and $Matches.name -eq $script:Arm.RejectDefinition) { return ConvertTo-ArmErrorResponse 400 'InvalidPolicyRule' 'Rejected by the test.' }
                $problem = Get-ArmDefinitionProblem $body.properties
                if ($problem) { return ConvertTo-ArmErrorResponse 400 'InvalidPolicyRule' $problem }
            }
            else {
                if ($script:Arm.HideDefinitionsFor -gt 0) { $script:Arm.HideDefinitionsFor--; return ConvertTo-ArmErrorResponse 400 'PolicyDefinitionNotFound' 'The policy definition could not be found.' }
                $problem = Get-ArmInitiativeProblem $body.properties
                if ($problem -is [hashtable]) { return ConvertTo-ArmErrorResponse 400 $problem.Code $problem.Message }
                if ($problem) { return ConvertTo-ArmErrorResponse 400 'InvalidPolicySetDefinition' $problem }
            }
            $status = if ($script:Arm.Store.ContainsKey($key)) { 200 } else { 201 }
            $stored = @{ id = $route; name = $Matches.name; type = "Microsoft.Authorization/$($Matches.kind)"; properties = $body.properties }
            $script:Arm.Store[$key] = $stored
            return ConvertTo-ArmResponse $status $stored
        }
        ConvertTo-ArmErrorResponse 404 'NotFound' "Unexpected request $Method $target"
    }

    $null = Initialize-AlzMockArm
    Export-ModuleMember -Function Initialize-AlzMockArm, Get-AzContext, Connect-AzAccount, Start-Sleep, Invoke-AzRestMethod
} | Import-Module -Force
function Invoke-Deploy {
    # Runs the real script; returns its result and any error message.
    param([hashtable]$Arguments)
    $outcome = @{ Result = $null; Error = $null }
    try { $outcome.Result = & $deployScript @Arguments -SkipLogin 6>$null 3>$null }
    catch { $outcome.Error = $_.Exception.Message }
    $outcome
}

function Get-ArmWrite { @($arm.Calls | Where-Object { $_.StartsWith('PUT ') }) }

# fresh deployment at a management group, with pagination (page size 40) and throttling
$arm = Initialize-AlzMockArm; $arm.Throttle = 2
$run = Invoke-Deploy @{ ManagementGroupId = 'contoso'; TenantId = $tenantId }
Assert-That ($null -eq $run.Error) "Fresh deployment failed: $($run.Error)"
Assert-That ($null -ne $run.Result -and $run.Result.Published -eq $true -and $run.Result.AssignmentCreated -eq $false) 'A fresh deployment must publish and must not assign.'
Assert-That (@(Get-ArmWrite).Count -eq ($activeRecords.Count + 1 + 2)) "Expected $($activeRecords.Count + 1) writes plus 2 throttled retries, saw $(@(Get-ArmWrite).Count)."
$initiativeKey = "$scope/providers/Microsoft.Authorization/policySetDefinitions/alz-custom-policies".ToLowerInvariant()
Assert-That ($arm.Store.ContainsKey($initiativeKey)) 'The initiative was not stored.'
Assert-That ($arm.Store[$initiativeKey].properties.policyDefinitions.Count -eq $activeRecords.Count) 'The stored initiative has the wrong number of policies.'
Assert-That (@($arm.Store.Keys | Where-Object { $_ -like '*/policydefinitions/alz-*' }).Count -eq $activeRecords.Count) 'Definitions were not stored with the prefix.'

# What Azure ends up storing audits by default: the definitions (assigned on their own) and the initiative.
$storedDefinitions = @($arm.Store.Values | Where-Object { $_.type -eq 'Microsoft.Authorization/policyDefinitions' })
$enforcingStored = @($storedDefinitions | Where-Object {
        $effectName = [regex]::Match([string]$_.properties.policyRule.then.effect, "^\[parameters\('(?<n>[^']+)'\)\]$").Groups['n'].Value
        $effectName -eq '' -or $_.properties.parameters[$effectName].defaultValue -notin $script:AlzAuditEffects
    })
Assert-That ($storedDefinitions.Count -eq $activeRecords.Count -and $enforcingStored.Count -eq 0) "Every published definition must default to an audit-mode effect; $($enforcingStored.Count) do not."
$enforcingInitiative = @($arm.Store[$initiativeKey].properties.parameters.GetEnumerator() | Where-Object { $_.Key.EndsWith('_effect') -and $_.Value.defaultValue -notin $script:AlzAuditEffects })
Assert-That ($enforcingInitiative.Count -eq 0) 'Every effect parameter of the published initiative must default to an audit-mode effect.'
# re-running updates in place (the list is paged, so existing resources must still be recognised)
$arm.Calls.Clear()
$run = Invoke-Deploy @{ ManagementGroupId = 'contoso' }
Assert-That ($null -eq $run.Error -and $run.Result.Published) "Re-run failed: $($run.Error)"
Assert-That (@($arm.Calls | Where-Object { $_ -like 'GET *policyDefinitions' }).Count -ge 3) 'The existing definitions should have been listed across several pages.'

# -WhatIf performs no writes
$arm = Initialize-AlzMockArm
$run = Invoke-Deploy @{ ManagementGroupId = 'contoso'; WhatIf = $true }
Assert-That ($null -eq $run.Error -and $run.Result.Published -eq $false) "-WhatIf failed: $($run.Error)"
Assert-That (@(Get-ArmWrite).Count -eq 0) '-WhatIf must not write.'

# unmanaged resources are never overwritten
$arm = Initialize-AlzMockArm
$foreign = "$scope/providers/Microsoft.Authorization/policyDefinitions/alz-Deny-Storage-SFTP"
$arm.Store[$foreign.ToLowerInvariant()] = @{ id = $foreign; name = 'alz-Deny-Storage-SFTP'; properties = @{ metadata = @{ source = 'someone else' } } }
$run = Invoke-Deploy @{ ManagementGroupId = 'contoso' }
Assert-That ($run.Error -like '*Refusing to overwrite*') 'A definition that the script did not publish must not be overwritten.'
Assert-That (@(Get-ArmWrite).Count -eq 0) 'Nothing may be written when there is a conflict.'

# a definition that Azure rejects stops the initiative
$arm = Initialize-AlzMockArm; $arm.RejectDefinition = 'alz-Modify-UDR'
$run = Invoke-Deploy @{ ManagementGroupId = 'contoso' }
Assert-That ($run.Error -like '*1 definition(s) failed*Modify-UDR*') 'A rejected definition must be reported.'
Assert-That (@($arm.Calls | Where-Object { $_ -like '*policySetDefinitions*' -and $_.StartsWith('PUT') }).Count -eq 0) 'The initiative must not be published when a definition failed.'

# new definitions may take a moment to become visible to the initiative
$arm = Initialize-AlzMockArm; $arm.HideDefinitionsFor = 2
$run = Invoke-Deploy @{ ManagementGroupId = 'contoso' }
Assert-That ($null -eq $run.Error -and $run.Result.Published) "The initiative retry failed: $($run.Error)"

# subscription scope, no prefix, a left-out policy
$arm = Initialize-AlzMockArm
$run = Invoke-Deploy @{ SubscriptionId = $subscriptionId; DefinitionPrefix = ''; ExcludePolicy = @('Deny-Storage-SFTP'); InitiativeName = 'alz-sub' }
Assert-That ($null -eq $run.Error -and $run.Result.Published) "Subscription deployment failed: $($run.Error)"
$subscriptionKey = "/subscriptions/$($subscriptionId)/providers/Microsoft.Authorization/policySetDefinitions/alz-sub".ToLowerInvariant()
Assert-That ($arm.Store.ContainsKey($subscriptionKey) -and $arm.Store[$subscriptionKey].properties.policyDefinitions.Count -eq ($activeRecords.Count - 1)) 'The excluded policy must be left out of the initiative.'
Assert-That (-not $arm.Store.ContainsKey("/subscriptions/$($subscriptionId)/providers/Microsoft.Authorization/policyDefinitions/Deny-Storage-SFTP".ToLowerInvariant())) 'The excluded policy must not be published.'
Assert-That ($arm.Store.ContainsKey("/subscriptions/$($subscriptionId)/providers/Microsoft.Authorization/policyDefinitions/Deny-Storage-CopyScope".ToLowerInvariant())) 'An empty prefix must keep the upstream names.'

# deprecated policies are opt in
$arm = Initialize-AlzMockArm
$run = Invoke-Deploy @{ ManagementGroupId = 'contoso'; IncludeDeprecated = $true }
Assert-That ($null -eq $run.Error -and $run.Result.DefinitionCount -eq $records.Count) "-IncludeDeprecated failed: $($run.Error)"

# -Remove deletes only what the package published, initiative first, and never something else with a similar name
$arm = Initialize-AlzMockArm
$null = Invoke-Deploy @{ ManagementGroupId = 'contoso'; IncludeDeprecated = $true }
$unrelated = "$scope/providers/Microsoft.Authorization/policyDefinitions/alz-unrelated"
$arm.Store[$unrelated.ToLowerInvariant()] = @{ id = $unrelated; name = 'alz-unrelated'; type = 'Microsoft.Authorization/policyDefinitions'; properties = @{ metadata = @{ source = 'someone else' } } }
$arm.Calls.Clear()
$run = Invoke-Deploy @{ ManagementGroupId = 'contoso'; Remove = $true; WhatIf = $true }
Assert-That ($null -eq $run.Error -and $run.Result.Removed -eq $false -and $run.Result.DefinitionsFound -eq $records.Count) "-Remove -WhatIf failed: $($run.Error)"
Assert-That (@($arm.Calls | Where-Object { $_.StartsWith('DELETE ') }).Count -eq 0) '-Remove -WhatIf must not delete.'
$run = Invoke-Deploy @{ ManagementGroupId = 'contoso'; Remove = $true }
$deletes = @($arm.Calls | Where-Object { $_.StartsWith('DELETE ') })
Assert-That ($null -eq $run.Error -and $run.Result.Removed -and $run.Result.InitiativeRemoved) "-Remove failed: $($run.Error)"
Assert-That ($deletes.Count -eq $records.Count + 1 -and $deletes[0] -like '*policySetDefinitions*') 'The initiative must be deleted first, then every definition.'
Assert-That ($arm.Store.Count -eq 1 -and $arm.Store.ContainsKey($unrelated.ToLowerInvariant())) 'Only the unrelated definition may remain.'

# an assigned initiative blocks the removal and leaves the definitions alone
$arm = Initialize-AlzMockArm
$null = Invoke-Deploy @{ ManagementGroupId = 'contoso' }
$arm.Assigned = $true
$run = Invoke-Deploy @{ ManagementGroupId = 'contoso'; Remove = $true }
Assert-That ($run.Error -like '*409*') 'An assigned initiative must stop the removal.'
Assert-That ($arm.Store.Count -eq $activeRecords.Count + 1) 'Nothing may be deleted when the initiative is still assigned.'

# an initiative that the package did not publish is left alone
$arm = Initialize-AlzMockArm
$foreignInitiative = "$scope/providers/Microsoft.Authorization/policySetDefinitions/alz-custom-policies"
$arm.Store[$foreignInitiative.ToLowerInvariant()] = @{ id = $foreignInitiative; name = 'alz-custom-policies'; type = 'Microsoft.Authorization/policySetDefinitions'; properties = @{ metadata = @{} ; policyDefinitions = @() } }
$run = Invoke-Deploy @{ ManagementGroupId = 'contoso'; Remove = $true }
Assert-That ($null -eq $run.Error -and -not $run.Result.Removed -and $arm.Store.Count -eq 1) 'A foreign initiative must not be removed.'
$run = Invoke-Deploy @{ ManagementGroupId = 'contoso'; Remove = $true; ExportOnly = $true; OutputPath = 'x' }
Assert-That ($run.Error -like '*cannot be combined*') '-Remove must not be combined with -ExportOnly.'
# the context must match, and unknown names are rejected
$arm = Initialize-AlzMockArm
$run = Invoke-Deploy @{ ManagementGroupId = 'contoso'; TenantId = '33333333-3333-3333-3333-333333333333' }
Assert-That ($null -ne $run.Error) 'A tenant mismatch with -SkipLogin must fail.'
$run = Invoke-Deploy @{ ManagementGroupId = 'does-not-exist' }
Assert-That ($run.Error -like '*not found*') 'An unknown management group must fail before any write.'
$run = Invoke-Deploy @{ ManagementGroupId = 'contoso'; ExcludePolicy = @('Not-A-Policy') }
Assert-That ($run.Error -like '*Unknown policy*') 'An unknown -ExcludePolicy name must fail.'

# policies that upstream does not support in a cloud are skipped (offline export, no sign-in)
$exportPath = Join-Path ([System.IO.Path]::GetTempPath()) "alz-test-$([guid]::NewGuid().ToString('N'))"
try {
    $arm = Initialize-AlzMockArm
    $run = Invoke-Deploy @{ ManagementGroupId = 'contoso'; Environment = 'AzureUSGovernment'; ExportOnly = $true; OutputPath = $exportPath }
    $supported = @($activeRecords | Where-Object { $_.CloudEnvironments.Count -eq 0 -or 'AzureUSGovernment' -in $_.CloudEnvironments })
    Assert-That ($null -eq $run.Error -and $run.Result.DefinitionCount -eq $supported.Count -and $supported.Count -lt $activeRecords.Count) "Cloud filtering failed: $($run.Error)"
    Assert-That ($arm.Calls.Count -eq 0) '-ExportOnly must not call Azure.'
    Assert-That ((Get-ChildItem -LiteralPath (Join-Path $exportPath 'definitions') -Filter '*.json').Count -eq $supported.Count -and (Test-Path -LiteralPath (Join-Path $exportPath 'alz-custom-policies.json'))) '-ExportOnly must write the definitions and the initiative.'
}
finally {
    if (Test-Path -LiteralPath $exportPath) { Remove-Item -LiteralPath $exportPath -Recurse -Force }
}

# ---- Result ---------------------------------------------------------------------------------------------------------
Write-Host ''
if ($script:Failures.Count -gt 0) {
    Write-Host "$($script:Failures.Count) of $($script:Checks) checks failed." -ForegroundColor Red
    exit 1
}
Write-Host "All $($script:Checks) checks passed." -ForegroundColor Green
