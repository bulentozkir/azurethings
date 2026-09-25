#requires -Version 7.0

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Confirm-Assertion {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        throw $Message
    }
}

function Resolve-PolicyLiteral {
    param([AllowNull()][object]$Value, [System.Collections.IDictionary]$Parameters)

    if ($Value -isnot [string]) {
        return ,$Value
    }
    if ($Value -match "^\[parameters\('([^']+)'\)\]$") {
        $parameterName = $Matches[1]
        Confirm-Assertion ($Parameters.Contains($parameterName)) "Undefined parameter: $parameterName"
        return ,$Parameters[$parameterName]
    }
    if ($Value -eq "[concat('tags[', parameters('tagName'), ']')]") {
        return "tags[$($Parameters['tagName'])]"
    }
    if ($Value.StartsWith('[')) {
        throw "Unsupported expression in offline fixture evaluator: $Value"
    }
    return $Value
}

function Test-PolicyCondition {
    param(
        [System.Collections.IDictionary]$Condition,
        [System.Collections.IDictionary]$Fields,
        [System.Collections.IDictionary]$Parameters
    )

    if ($Condition.Contains('allOf')) {
        foreach ($child in $Condition['allOf']) {
            if (-not (Test-PolicyCondition $child $Fields $Parameters)) {
                return $false
            }
        }
        return $true
    }
    if ($Condition.Contains('anyOf')) {
        foreach ($child in $Condition['anyOf']) {
            if (Test-PolicyCondition $child $Fields $Parameters) {
                return $true
            }
        }
        return $false
    }
    if ($Condition.Contains('not')) {
        return -not (Test-PolicyCondition $Condition['not'] $Fields $Parameters)
    }

    if ($Condition.Contains('count')) {
        $countRule = $Condition['count']
        $arrayField = $countRule['field']
        Confirm-Assertion ($arrayField.EndsWith('[*]')) "count.field must be an array alias ending in [*]: $arrayField"
        $actual = 0
        if ($Fields.Contains($arrayField) -and $null -ne $Fields[$arrayField]) {
            foreach ($member in @($Fields[$arrayField])) {
                $memberFields = @{}
                foreach ($entry in $Fields.GetEnumerator()) {
                    $memberFields[$entry.Key] = $entry.Value
                }
                $memberFields[$arrayField] = $member
                if ($member -is [System.Collections.IDictionary]) {
                    foreach ($entry in $member.GetEnumerator()) {
                        $memberFields["$arrayField.$($entry.Key)"] = $entry.Value
                    }
                }
                if (-not $countRule.Contains('where') -or
                    (Test-PolicyCondition $countRule['where'] $memberFields $Parameters)) {
                    $actual++
                }
            }
        }
    }
    elseif ($Condition.Contains('field')) {
        $fieldName = Resolve-PolicyLiteral $Condition['field'] $Parameters
        $exists = $Fields.Contains($fieldName) -and $null -ne $Fields[$fieldName]
        if ($Condition.Contains('exists')) {
            return $exists -eq [bool]::Parse([string]$Condition['exists'])
        }
        $actual = if ($exists) { $Fields[$fieldName] } else { '' }
    }
    elseif ($Condition.Contains('value')) {
        $actual = Resolve-PolicyLiteral $Condition['value'] $Parameters
    }
    else {
        throw 'Unsupported condition in offline fixture evaluator.'
    }

    foreach ($operator in @('equals', 'notEquals', 'in', 'notIn', 'greater', 'less', 'like', 'contains', 'notContains')) {
        if ($Condition.Contains($operator)) {
            $expected = Resolve-PolicyLiteral $Condition[$operator] $Parameters
            switch ($operator) {
                'equals' { return $actual -eq $expected }
                'notEquals' { return $actual -ne $expected }
                'in' { return $actual -in $expected }
                'notIn' { return $actual -notin $expected }
                'greater' { return $actual -gt $expected }
                'less' { return $actual -lt $expected }
                'like' { return $actual -like $expected }
                'contains' { return ([string]$actual).IndexOf([string]$expected, [StringComparison]::OrdinalIgnoreCase) -ge 0 }
                'notContains' { return ([string]$actual).IndexOf([string]$expected, [StringComparison]::OrdinalIgnoreCase) -lt 0 }
            }
        }
    }
    throw 'Unsupported comparison in offline fixture evaluator.'
}

function Invoke-RuleCase {
    param(
        [string]$Name,
        [string]$PolicyName,
        [System.Collections.IDictionary]$Fields,
        [System.Collections.IDictionary]$Parameters = @{},
        [System.Collections.IDictionary]$Changes = @{},
        [string[]]$RemoveFields = @(),
        [System.Collections.IDictionary]$ParameterChanges = @{},
        [object[]]$RelatedResources = @(),
        [bool]$Expected
    )

    $definition = $definitions[$PolicyName]
    $values = @{}
    foreach ($entry in $definition.parameters.GetEnumerator()) {
        if ($entry.Value.Contains('defaultValue')) {
            $values[$entry.Key] = $entry.Value.defaultValue
        }
    }
    foreach ($dictionary in @($Parameters, $ParameterChanges)) {
        foreach ($entry in $dictionary.GetEnumerator()) {
            Confirm-Assertion ($definition.parameters.Contains($entry.Key)) "Unknown parameter in case '$Name': $($entry.Key)"
            $values[$entry.Key] = $entry.Value
        }
    }
    foreach ($parameterName in $definition.parameters.Keys) {
        Confirm-Assertion ($values.Contains($parameterName)) "Missing parameter in case '$Name': $parameterName"
        $parameterDefinition = $definition.parameters[$parameterName]
        if ($parameterDefinition.Contains('allowedValues')) {
            Confirm-Assertion ($values[$parameterName] -in $parameterDefinition.allowedValues) "Unsupported parameter value: $parameterName=$($values[$parameterName])"
        }
    }

    $caseFields = @{}
    foreach ($dictionary in @($Fields, $Changes)) {
        foreach ($entry in $dictionary.GetEnumerator()) {
            $caseFields[$entry.Key] = $entry.Value
        }
    }
    foreach ($fieldName in $RemoveFields) {
        $caseFields.Remove($fieldName)
    }

    $effect = Resolve-PolicyLiteral $definition.policyRule.then.effect $values
    $actual = $effect -ne 'Disabled' -and (Test-PolicyCondition $definition.policyRule.if $caseFields $values)
    if ($actual -and $effect -eq 'AuditIfNotExists') {
        $details = $definition.policyRule.then.details
        foreach ($related in $RelatedResources) {
            if ($related.Contains('type') -and $related.type -eq $details.type -and
                (Test-PolicyCondition $details.existenceCondition $related $values)) {
                $actual = $false
                break
            }
        }
    }
    Confirm-Assertion ($actual -eq $Expected) "Case '$Name' failed for '$PolicyName': expected match=$Expected, actual=$actual"
    $script:ruleCaseCount++
}

$readmePath = Join-Path $PSScriptRoot 'README.md'
$readme = Get-Content -LiteralPath $readmePath -Raw
$rows = @([regex]::Matches($readme, '(?m)^\| (AI-GOV-\d{3,}) \| (P[012]) \|.*$'))
$controlIds = @($rows | ForEach-Object { $_.Groups[1].Value })
Confirm-Assertion ($rows.Count -gt 0) 'Expected catalogue rows with valid priorities.'
Confirm-Assertion (@([regex]::Matches($readme, '(?m)^\| AI-GOV-')).Count -eq $rows.Count) 'Malformed control ID or priority.'
Confirm-Assertion (@($controlIds | Sort-Object -Unique).Count -eq $rows.Count) 'Duplicate control IDs.'

$rowsById = @{}
foreach ($row in $rows) {
    $rowsById[$row.Groups[1].Value] = $row.Value
    Confirm-Assertion ($row.Value.Split('|').Count -eq 8) "Malformed catalogue row: $($row.Groups[1].Value)"
    foreach ($source in [regex]::Matches($row.Value.Split('|')[-2], '\[([A-Za-z][A-Za-z0-9]+)\]')) {
        $sourcePattern = '(?m)^\[' + [regex]::Escape($source.Groups[1].Value) + '\]: https://'
        Confirm-Assertion ($readme -match $sourcePattern) "Unresolved source reference: $($source.Value)"
    }
}
foreach ($link in [regex]::Matches($readme, '\[[^\]\r\n]+\]\(([^)\r\n]+)\)')) {
    $target = $link.Groups[1].Value
    if ($target -notmatch '^(https?://|#)') {
        $localPath = Join-Path $PSScriptRoot ([uri]::UnescapeDataString($target.Split('#')[0]))
        Confirm-Assertion (Test-Path -LiteralPath $localPath -PathType Leaf) "Broken local link: $target"
    }
}

$manifest = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'built-in-references.json') -Raw | ConvertFrom-Json -AsHashtable
Confirm-Assertion ($manifest.policies.Count -gt 0) 'Expected built-in references.'
Confirm-Assertion ($manifest.assignmentProfile.mode -eq 'AuditOnly') 'The assignment profile must be audit-only.'
Confirm-Assertion (@(Compare-Object @('Audit', 'AuditIfNotExists') @($manifest.assignmentProfile.permittedEffects)).Count -eq 0) 'The profile must not permit non-audit effects.'
foreach ($property in @('reference', 'policyDefinitionId')) {
    $uniqueCount = @($manifest.policies | ForEach-Object { $_[$property] } | Sort-Object -Unique).Count
    Confirm-Assertion ($uniqueCount -eq $manifest.policies.Count) "Duplicate built-in $property."
}
foreach ($policy in $manifest.policies) {
    Confirm-Assertion ($policy.policyDefinitionId -match '^/providers/Microsoft\.Authorization/policyDefinitions/[0-9a-f-]{36}$') "Invalid policy ID: $($policy.reference)"
    [void][guid]($policy.policyDefinitionId.Split('/')[-1])
    if ($null -eq $policy.recommendedInitialEffect) {
        Confirm-Assertion ($manifest.assignmentProfile.excludedReferences.Contains($policy.reference)) "Non-auditing policy must be excluded: $($policy.reference)"
        Confirm-Assertion (@($policy.documentedEffects | Where-Object { $_ -in $manifest.assignmentProfile.permittedEffects }).Count -eq 0) "Audit-capable policy missing its audit effect: $($policy.reference)"
    }
    else {
        Confirm-Assertion ($policy.recommendedInitialEffect -in $policy.documentedEffects) "Unsupported effect: $($policy.reference)"
        Confirm-Assertion ($policy.recommendedInitialEffect -in $manifest.assignmentProfile.permittedEffects) "Non-audit effect selected: $($policy.reference)"
    }
    Confirm-Assertion ($manifest.sources.Contains($policy.source)) "Unknown manifest source: $($policy.reference)"
    Confirm-Assertion ($policy.definitionSource.StartsWith('https://github.com/Azure/azure-policy/') -or $policy.definitionSource -eq "https://management.azure.com$($policy.policyDefinitionId)?api-version=2023-04-01") "Invalid definition source: $($policy.reference)"
    Confirm-Assertion ($policy.documentedPreview -eq $policy.documentedVersion.Contains('preview')) "Inconsistent preview flag: $($policy.reference)"
    foreach ($controlId in $policy.controlIds) {
        Confirm-Assertion ($rowsById.ContainsKey($controlId)) "Unknown built-in control ID: $controlId"
        Confirm-Assertion ($rowsById[$controlId] -match ('\b' + $policy.reference + '\b')) "Unlinked built-in reference: $($policy.reference) / $controlId"
    }
}
$manifestReferences = @($manifest.policies | ForEach-Object { $_.reference })
foreach ($reference in $manifest.assignmentProfile.excludedReferences.Keys) {
    Confirm-Assertion ($reference -in $manifestReferences) "Unknown excluded reference: $reference"
    Confirm-Assertion (-not [string]::IsNullOrWhiteSpace($manifest.assignmentProfile.excludedReferences[$reference])) "Missing exclusion reason: $reference"
}
foreach ($reference in @('B02', 'B03')) {
    Confirm-Assertion ($manifest.assignmentProfile.excludedReferences.Contains($reference)) "Private-only overlay would conflict with approved public-source access: $reference"
}
$baselineReferences = @($manifest.policies | Where-Object { $_.reference -in $manifest.assignmentProfile.includedReferences })
Confirm-Assertion ($manifest.assignmentProfile.baseline -eq 'AIPlatformAudit') 'The profile must target the Foundry, Azure ML, and AI services controls.'
Confirm-Assertion (@($baselineReferences).Count -eq 20) 'Expected 20 selected built-ins.'
foreach ($reference in [regex]::Matches(($rows.Value -join "`n"), '\bB\d{2}\b')) {
    Confirm-Assertion ($reference.Value -in $manifestReferences) "Undefined built-in reference: $($reference.Value)"
}

$expectedModes = @{
    'allowed-ai-locations' = 'All'
    'allowed-ai-account-kinds' = 'All'
    'require-ai-tag' = 'Indexed'
    'allowed-ai-tag-values' = 'Indexed'
    'allowed-model-deployment-skus' = 'All'
    'restrict-ai-public-ip-access' = 'All'
    'restrict-ai-virtual-network-rules' = 'All'
    'restrict-ai-trusted-services' = 'All'
    'require-ai-private-endpoints' = 'All'
    'require-ai-monitor-private-link-scope' = 'All'
    'require-foundry-vnet-injection' = 'All'
    'require-foundry-trusted-services' = 'All'
    'require-foundry-private-endpoint' = 'All'
    'require-foundry-key-vault-connection' = 'All'
    'require-foundry-app-insights-connection' = 'All'
    'require-ai-system-assigned-identity' = 'All'
    'require-ai-deployment-content-filter' = 'All'
    'require-ml-endpoint-entra-auth' = 'All'
    'require-defender-for-ai' = 'All'
    'require-ai-diagnostic-logs' = 'All'
    'require-ml-compute-no-public-ip' = 'All'
    'require-ml-compute-no-ssh' = 'All'
    'require-ai-deployment-auto-upgrade' = 'All'
    'require-ml-workspace-hbi' = 'All'
    'require-ml-compute-instance-assigned-user' = 'All'
    'require-sami-cognitive-accounts' = 'All'
    'require-sami-foundry-projects' = 'All'
    'require-sami-ml-workspaces' = 'All'
    'require-sami-ml-registries' = 'All'
    'require-sami-ml-online-endpoints' = 'All'
    'require-sami-ml-batch-endpoints' = 'All'
    'require-sami-ml-computes' = 'All'
    'require-sami-search' = 'All'
    'require-sami-health-bot' = 'All'
    'require-sami-deid' = 'All'
    'require-sami-video-indexer' = 'All'
}
$definitionFiles = @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'definitions') -Filter '*.json' -File)
Confirm-Assertion ($definitionFiles.Count -eq $expectedModes.Count) 'Unexpected number of custom definitions.'
$definitions = @{}
foreach ($file in $definitionFiles) {
    $definition = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json -AsHashtable
    Confirm-Assertion ($expectedModes.ContainsKey($file.BaseName)) "Untested definition: $($file.Name)"
    Confirm-Assertion ($definition.policyType -eq 'Custom') "Not a custom definition: $($file.Name)"
    Confirm-Assertion ($definition.mode -eq $expectedModes[$file.BaseName]) "Incorrect evaluation mode: $($file.Name)"
    $expectedEffect = if ($definition.policyRule.then.Contains('details')) { 'AuditIfNotExists' } else { 'Audit' }
    $expectedEffects = if ($expectedEffect -eq 'Audit') { @('Audit', 'Deny') } else { @('AuditIfNotExists', 'Disabled') }
    Confirm-Assertion ($definition.parameters.effect.defaultValue -eq $expectedEffect) "Unsafe default effect: $($file.Name)"
    Confirm-Assertion (@(Compare-Object $expectedEffects @($definition.parameters.effect.allowedValues)).Count -eq 0) "Unexpected supported effects: $($file.Name)"
    Confirm-Assertion ($definition.policyRule.then.effect -eq "[parameters('effect')]") "Unparameterized effect: $($file.Name)"
    $ruleJson = $definition.policyRule | ConvertTo-Json -Depth 60
    $usedParameters = @([regex]::Matches($ruleJson, "parameters\('([^']+)'\)") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    Confirm-Assertion (@(Compare-Object @($definition.parameters.Keys) $usedParameters).Count -eq 0) "Undefined or unused parameters: $($file.Name)"
    foreach ($controlId in $definition.metadata.controlIds) {
        Confirm-Assertion ($rowsById.ContainsKey($controlId)) "Unknown custom control ID: $controlId"
        Confirm-Assertion ($rowsById[$controlId].Contains($file.BaseName)) "Unlinked custom definition: $($file.Name) / $controlId"
    }
    $definitions[$file.BaseName] = $definition
}

$coverageSection = [regex]::Match($readme, '(?ms)^### Private Connectivity Coverage\r?\n(?<coverage>.*?)^### Connectivity Limits').Groups['coverage'].Value
$coverageRows = @([regex]::Matches($coverageSection, '(?m)^\| `(Microsoft\.[^`]+)` \| ([^|]+) \|.*$'))
$documentedConnectivityTypes = @($coverageRows | ForEach-Object { $_.Groups[1].Value })
$expectedConnectivityTypes = @($definitions['allowed-ai-locations'].parameters.resourceTypes.defaultValue) + @('Microsoft.Insights/privateLinkScopes')
Confirm-Assertion (@($documentedConnectivityTypes | Sort-Object -Unique).Count -eq $coverageRows.Count) 'Duplicate private-connectivity coverage rows.'
Confirm-Assertion (@(Compare-Object $expectedConnectivityTypes $documentedConnectivityTypes).Count -eq 0) 'Private-connectivity coverage must account for every location type plus the Monitor scope, including explicit limitations.'
Confirm-Assertion (@($coverageRows | Where-Object { $_.Groups[2].Value.Trim() -eq 'Endpoint' }).Count -eq 27) 'Unexpected documented endpoint-owning type count.'
foreach ($reference in [regex]::Matches($coverageSection, '\bB\d{2}\b')) {
    Confirm-Assertion ($reference.Value -in $manifestReferences) "Archived coverage table references an unknown built-in: $($reference.Value)"
}

$script:ruleCaseCount = 0
$coreType = 'Microsoft.CognitiveServices/accounts'
$unrelatedType = 'Microsoft.Storage/storageAccounts'
$deploymentType = 'Microsoft.CognitiveServices/accounts/deployments'

$common = @{ PolicyName = 'allowed-ai-locations'; Fields = @{ type = $coreType; location = 'westeurope' }; Parameters = @{ allowedLocations = @('westeurope') } }
Invoke-RuleCase @common -Name 'approved location' -Expected $false
Invoke-RuleCase @common -Name 'unapproved location' -Changes @{ location = 'eastus' } -Expected $true
Invoke-RuleCase @common -Name 'Deny matches unapproved location' -Changes @{ location = 'eastus' } -ParameterChanges @{ effect = 'Deny' } -Expected $true
Invoke-RuleCase @common -Name 'Deny leaves approved location compliant' -ParameterChanges @{ effect = 'Deny' } -Expected $false
Invoke-RuleCase @common -Name 'global requires explicit approval' -Changes @{ location = 'global' } -Expected $true
Invoke-RuleCase @common -Name 'empty locations allow nothing' -ParameterChanges @{ allowedLocations = @() } -Expected $true
Invoke-RuleCase @common -Name 'unlisted resource location' -Changes @{ type = 'Microsoft.Network/networkSecurityGroups'; location = 'eastus' } -Expected $false
Invoke-RuleCase @common -Name 'shared storage is intentionally in location scope' -Changes @{ type = $unrelatedType; location = 'eastus' } -Expected $true
Invoke-RuleCase @common -Name 'location override can exclude shared storage' -Changes @{ type = $unrelatedType; location = 'eastus' } -ParameterChanges @{ resourceTypes = @($coreType) } -Expected $false
Invoke-RuleCase @common -Name 'locationless Cognitive Services deployment excluded' -Changes @{ type = $deploymentType } -RemoveFields location -Expected $false
Invoke-RuleCase @common -Name 'no wildcard inclusion of unknown child types' -Changes @{ type = "$coreType/projects/unknownChild"; location = 'eastus' } -Expected $false
$locationTypes = @($definitions['allowed-ai-locations'].parameters.resourceTypes.defaultValue)
Confirm-Assertion (@($locationTypes | Sort-Object -Unique).Count -eq $locationTypes.Count) 'Duplicate location resource types.'
foreach ($resourceType in $locationTypes) {
    Invoke-RuleCase @common -Name "location scope $resourceType outside approved region" -Changes @{ type = $resourceType; location = 'eastus' } -Expected $true
    Invoke-RuleCase @common -Name "location scope $resourceType approved region" -Changes @{ type = $resourceType; location = 'westeurope' } -Expected $false
}
foreach ($resourceType in @(
    'Microsoft.CognitiveServices/accounts/projects',
    'Microsoft.MachineLearningServices/workspaces/computes',
    'Microsoft.MachineLearningServices/workspaces/batchEndpoints',
    'Microsoft.MachineLearningServices/workspaces/onlineEndpoints/deployments',
    'Microsoft.MachineLearningServices/workspaces/serverlessEndpoints',
    'Microsoft.VideoIndexer/accounts',
    'Microsoft.HealthBot/healthBots',
    'Microsoft.HealthDataAIServices/deidServices',
    'Microsoft.Databricks/workspaces',
    'Microsoft.ContainerService/managedClusters',
    'Microsoft.App/containerApps',
    'Microsoft.Compute/virtualMachines',
    'Microsoft.Storage/storageAccounts',
    'Microsoft.DocumentDB/databaseAccounts',
    'Microsoft.ApiManagement/service'
)) {
    Confirm-Assertion ($resourceType -in $locationTypes) "Missing prominent AI service or dependency from location defaults: $resourceType"
}

$common = @{ PolicyName = 'allowed-ai-account-kinds'; Fields = @{ type = $coreType; kind = 'OpenAI' }; Parameters = @{ allowedKinds = @('OpenAI', 'AIServices') } }
Invoke-RuleCase @common -Name 'approved account kind' -Expected $false
Invoke-RuleCase @common -Name 'unapproved account kind' -Changes @{ kind = 'UnapprovedKind' } -Expected $true
Invoke-RuleCase @common -Name 'Deny matches unapproved account kind' -Changes @{ kind = 'UnapprovedKind' } -ParameterChanges @{ effect = 'Deny' } -Expected $true
Invoke-RuleCase @common -Name 'missing account kind' -RemoveFields kind -Expected $true
Invoke-RuleCase @common -Name 'unrelated account kind' -Changes @{ type = $unrelatedType } -Expected $false

$common = @{ PolicyName = 'require-ai-tag'; Fields = @{ type = $coreType; 'tags[ai-workload]' = 'support-chatbot' }; Parameters = @{ tagName = 'ai-workload' } }
Invoke-RuleCase @common -Name 'workload tag present' -Expected $false
Invoke-RuleCase @common -Name 'different workload identifier allowed' -Changes @{ 'tags[ai-workload]' = 'document-assistant' } -Expected $false
Invoke-RuleCase @common -Name 'workload tag empty' -Changes @{ 'tags[ai-workload]' = '' } -Expected $true
Invoke-RuleCase @common -Name 'workload tag missing' -RemoveFields 'tags[ai-workload]' -Expected $true
Invoke-RuleCase @common -Name 'Deny matches missing workload tag' -RemoveFields 'tags[ai-workload]' -ParameterChanges @{ effect = 'Deny' } -Expected $true
Invoke-RuleCase @common -Name 'parameterized tag name' -ParameterChanges @{ tagName = 'ai-role' } -Expected $true
Invoke-RuleCase @common -Name 'untaggable child outside parent scope' -Changes @{ type = $deploymentType } -RemoveFields 'tags[ai-workload]' -Expected $false
Invoke-RuleCase @common -Name 'supporting storage outside default tag scope' -Changes @{ type = $unrelatedType } -RemoveFields 'tags[ai-workload]' -Expected $false
Invoke-RuleCase @common -Name 'supporting storage explicitly in tag scope' -Changes @{ type = $unrelatedType } -RemoveFields 'tags[ai-workload]' -ParameterChanges @{ resourceTypes = @($unrelatedType) } -Expected $true

$tagValues = [ordered]@{
    'ai-role' = @('model', 'search', 'data', 'app', 'gateway')
    'ai-usage' = @('inference', 'training', 'fine-tuning', 'mixed')
    'ai-audience' = @('internal', 'customer', 'public', 'mixed')
    'ai-sharing' = @('dedicated', 'shared')
    'ai-autonomy' = @('read-only', 'approval-required', 'autonomous')
    'ai-risk' = @('low', 'medium', 'high')
}
foreach ($tag in $tagValues.GetEnumerator()) {
    $tagField = "tags[$($tag.Key)]"
    $documentedValues = ($tag.Value | ForEach-Object { '`' + $_ + '`' }) -join ', '
    Confirm-Assertion ($readme.Contains('| `' + $tag.Key + '` | ' + $documentedValues + ' |')) "Missing or inconsistent tag vocabulary: $($tag.Key)"
    $common = @{ PolicyName = 'allowed-ai-tag-values'; Fields = @{ type = $coreType; $tagField = $tag.Value[0] }; Parameters = @{ tagName = $tag.Key; allowedTagValues = $tag.Value } }
    foreach ($value in $tag.Value) {
        Invoke-RuleCase @common -Name "$($tag.Key) accepts $value" -Changes @{ $tagField = $value } -Expected $false
    }
    Invoke-RuleCase @common -Name "$($tag.Key) reports unknown value" -Changes @{ $tagField = 'unknown' } -Expected $true
    Invoke-RuleCase @common -Name "$($tag.Key) Deny matches unknown value" -Changes @{ $tagField = 'unknown' } -ParameterChanges @{ effect = 'Deny' } -Expected $true
    Invoke-RuleCase @common -Name "$($tag.Key) Deny leaves approved value compliant" -ParameterChanges @{ effect = 'Deny' } -Expected $false
    Invoke-RuleCase @common -Name "$($tag.Key) reports missing value" -RemoveFields $tagField -Expected $true
    Invoke-RuleCase @common -Name "$($tag.Key) reports empty value even if listed" -Changes @{ $tagField = '' } -ParameterChanges @{ allowedTagValues = @('') } -Expected $true
    Invoke-RuleCase @common -Name "$($tag.Key) leaves unrelated resources out of scope" -Changes @{ type = $unrelatedType } -RemoveFields $tagField -Expected $false
}

$skuField = "$deploymentType/sku.name"
$common = @{ PolicyName = 'allowed-model-deployment-skus'; Fields = @{ type = $deploymentType; $skuField = 'Standard' }; Parameters = @{ allowedDeploymentSkus = @('Standard') } }
Invoke-RuleCase @common -Name 'approved deployment without tags' -Expected $false
Invoke-RuleCase @common -Name 'global deployment not approved' -Changes @{ $skuField = 'GlobalStandard' } -Expected $true
Invoke-RuleCase @common -Name 'Deny matches unapproved deployment SKU' -Changes @{ $skuField = 'GlobalStandard' } -ParameterChanges @{ effect = 'Deny' } -Expected $true
Invoke-RuleCase @common -Name 'data zone deployment not approved' -Changes @{ $skuField = 'DataZoneStandard' } -Expected $true
Invoke-RuleCase @common -Name 'missing deployment SKU' -RemoveFields $skuField -Expected $true
Invoke-RuleCase @common -Name 'parent outside deployment scope' -Changes @{ type = $coreType } -Expected $false
Invoke-RuleCase @common -Name 'explicit Audit reports unapproved SKU' -Changes @{ $skuField = 'GlobalStandard' } -ParameterChanges @{ effect = 'Audit' } -Expected $true

$approvedSubnet = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test/providers/Microsoft.Network/virtualNetworks/approved/subnets/ai'
$networkParameters = @{ allowedIpRules = @('203.0.113.10', '198.51.100.0/24') }
$services = @(
    @{ type = $coreType; rules = 'networkAcls'; defaultAction = $true; bypass = $true; subnets = $true },
    @{ type = 'Microsoft.Search/searchServices'; rules = 'networkRuleSet'; defaultAction = $false; bypass = $true; subnets = $false },
    @{ type = 'Microsoft.MachineLearningServices/workspaces'; rules = 'networkAcls'; defaultAction = $true; bypass = $false; subnets = $false }
)
foreach ($service in $services) {
    $resourceType = $service.type
    $publicField = "$resourceType/publicNetworkAccess"
    $rulesPrefix = "$resourceType/$($service.rules)"
    $ipField = "$rulesPrefix.ipRules[*]"
    $defaultField = "$rulesPrefix.defaultAction"
    $bypassField = "$rulesPrefix.bypass"
    $subnetField = "$rulesPrefix.virtualNetworkRules[*]"
    $fields = @{ type = $resourceType; $publicField = 'Enabled'; $ipField = @(@{ value = '203.0.113.10' }) }
    if ($service.defaultAction) { $fields[$defaultField] = 'Deny' }
    if ($service.bypass) { $fields[$bypassField] = 'None' }
    $common = @{ PolicyName = 'restrict-ai-public-ip-access'; Fields = $fields; Parameters = $networkParameters }

    Invoke-RuleCase @common -Name "$resourceType approved IP" -Expected $false
    Invoke-RuleCase @common -Name "$resourceType approved CIDR" -Changes @{ $ipField = @(@{ value = '198.51.100.0/24' }) } -Expected $false
    Invoke-RuleCase @common -Name "$resourceType unapproved IP" -Changes @{ $ipField = @(@{ value = '192.0.2.10' }) } -Expected $true
    Invoke-RuleCase @common -Name "$resourceType mixed approved and unapproved IPs" -Changes @{ $ipField = @(@{ value = '203.0.113.10' }, @{ value = '192.0.2.10' }) } -Expected $true
    Invoke-RuleCase @common -Name "$resourceType no CIDR containment inference" -Changes @{ $ipField = @(@{ value = '198.51.100.10' }) } -Expected $true
    Invoke-RuleCase @common -Name "$resourceType empty approved list" -ParameterChanges @{ allowedIpRules = @() } -Expected $true
    Invoke-RuleCase @common -Name "$resourceType reject approved /0" -Changes @{ $ipField = @(@{ value = '0.0.0.0/0' }) } -ParameterChanges @{ allowedIpRules = @('0.0.0.0/0') } -Expected $true
    Invoke-RuleCase @common -Name "$resourceType reject approved wildcard" -Changes @{ $ipField = @(@{ value = '*' }) } -ParameterChanges @{ allowedIpRules = @('*') } -Expected $true
    Invoke-RuleCase @common -Name "$resourceType empty rule list" -Changes @{ $ipField = @() } -Expected (-not $service.defaultAction)
    Invoke-RuleCase @common -Name "$resourceType missing rule list" -RemoveFields $ipField -Expected (-not $service.defaultAction)
    Invoke-RuleCase @common -Name "$resourceType disabled public access" -Changes @{ $publicField = 'Disabled'; $ipField = @(@{ value = '192.0.2.10' }) } -Expected $false
    Invoke-RuleCase @common -Name "$resourceType missing public mode" -RemoveFields $publicField -Expected $true
    Invoke-RuleCase @common -Name "$resourceType perimeter needs separate profile" -Changes @{ $publicField = 'SecuredByPerimeter' } -Expected $true
    Invoke-RuleCase @common -Name "$resourceType Audit reports unapproved source" -Changes @{ $ipField = @(@{ value = '192.0.2.10' }) } -ParameterChanges @{ effect = 'Audit' } -Expected $true
    Invoke-RuleCase @common -Name "$resourceType Deny matches unapproved source" -Changes @{ $ipField = @(@{ value = '192.0.2.10' }) } -ParameterChanges @{ effect = 'Deny' } -Expected $true
    Invoke-RuleCase @common -Name "$resourceType Deny leaves approved source compliant" -ParameterChanges @{ effect = 'Deny' } -Expected $false
    foreach ($unsupportedEffect in @('Modify', 'DeployIfNotExists', 'Disabled')) {
        $rejected = $false
        try {
            Invoke-RuleCase @common -Name "$resourceType refuses $unsupportedEffect" -ParameterChanges @{ effect = $unsupportedEffect } -Expected $false
        }
        catch {
            if ($_.Exception.Message -ne "Unsupported parameter value: effect=$unsupportedEffect") { throw }
            $rejected = $true
        }
        Confirm-Assertion $rejected "Unsupported custom effect accepted: $unsupportedEffect"
        $script:ruleCaseCount++
    }

    if ($service.defaultAction) {
        Invoke-RuleCase @common -Name "$resourceType default Allow rejected" -Changes @{ $defaultField = 'Allow' } -Expected $true
        Invoke-RuleCase @common -Name "$resourceType missing default action" -RemoveFields $defaultField -Expected $true
    }
    if ($service.bypass) {
        Invoke-RuleCase @common -Name "$resourceType IP audit does not duplicate bypass audit" -Changes @{ $bypassField = 'AzureServices' } -Expected $false
    }
    if ($service.subnets) {
        Invoke-RuleCase @common -Name 'Cognitive Services approved subnet without IP rules' -Changes @{ $ipField = @(); $subnetField = @(@{ id = $approvedSubnet }) } -Expected $false
        Invoke-RuleCase @common -Name 'IP audit does not duplicate subnet membership audit' -Changes @{ $subnetField = @(@{ id = '/unapproved/subnet' }) } -Expected $false
    }
}
Invoke-RuleCase -Name 'unrelated resource outside IP scope' -PolicyName 'restrict-ai-public-ip-access' -Fields @{ type = $unrelatedType } -Parameters $networkParameters -Expected $false

$subnetField = "$coreType/networkAcls.virtualNetworkRules[*]"
$common = @{ PolicyName = 'restrict-ai-virtual-network-rules'; Fields = @{ type = $coreType; $subnetField = @(@{ id = $approvedSubnet }) }; Parameters = @{ allowedSubnetIds = @($approvedSubnet) } }
Invoke-RuleCase @common -Name 'approved VNet subnet rule' -Expected $false
Invoke-RuleCase @common -Name 'unapproved VNet subnet rule' -Changes @{ $subnetField = @(@{ id = '/unapproved/subnet' }) } -Expected $true
Invoke-RuleCase @common -Name 'mixed approved and unapproved VNet rules' -Changes @{ $subnetField = @(@{ id = $approvedSubnet }, @{ id = '/unapproved/subnet' }) } -Expected $true
Invoke-RuleCase @common -Name 'same VNet does not approve other subnets' -Changes @{ $subnetField = @(@{ id = $approvedSubnet + '-other' }) } -Expected $true
Invoke-RuleCase @common -Name 'empty VNet allowlist reports configured rules' -ParameterChanges @{ allowedSubnetIds = @() } -Expected $true
Invoke-RuleCase @common -Name 'missing subnet ID is not approved' -Changes @{ $subnetField = @(@{}) } -Expected $true
Invoke-RuleCase @common -Name 'no VNet rules needed for IP-only or private access' -RemoveFields $subnetField -Expected $false
Invoke-RuleCase @common -Name 'empty VNet rules compliant' -Changes @{ $subnetField = @() } -Expected $false
Invoke-RuleCase @common -Name 'dormant unapproved VNet rule still reported' -Changes @{ "$coreType/publicNetworkAccess" = 'Disabled'; $subnetField = @(@{ id = '/unapproved/subnet' }) } -Expected $true
Invoke-RuleCase @common -Name 'Deny option for unapproved VNet rule' -Changes @{ $subnetField = @(@{ id = '/unapproved/subnet' }) } -ParameterChanges @{ effect = 'Deny' } -Expected $true
Invoke-RuleCase @common -Name 'Search not evaluated with Cognitive Services VNet aliases' -Changes @{ type = 'Microsoft.Search/searchServices'; $subnetField = @(@{ id = '/unapproved/subnet' }) } -Expected $false

foreach ($service in $services | Where-Object { $_.bypass }) {
    $resourceType = $service.type
    $bypassField = "$resourceType/$($service.rules).bypass"
    $publicField = "$resourceType/publicNetworkAccess"
    $common = @{ PolicyName = 'restrict-ai-trusted-services'; Fields = @{ type = $resourceType; $publicField = 'Enabled'; $bypassField = 'None' } }
    Invoke-RuleCase @common -Name "$resourceType no trusted bypass" -Expected $false
    Invoke-RuleCase @common -Name "$resourceType trusted bypass unapproved by default" -Changes @{ $bypassField = 'AzureServices' } -Expected $true
    Invoke-RuleCase @common -Name "$resourceType trusted bypass explicitly approved" -Changes @{ $bypassField = 'AzureServices' } -ParameterChanges @{ allowTrustedServices = $true } -Expected $false
    Invoke-RuleCase @common -Name "$resourceType trusted approval does not require bypass" -ParameterChanges @{ allowTrustedServices = $true } -Expected $false
    Invoke-RuleCase @common -Name "$resourceType unknown bypass rejected even when trusted services approved" -Changes @{ $bypassField = 'AllServices' } -ParameterChanges @{ allowTrustedServices = $true } -Expected $true
    Invoke-RuleCase @common -Name "$resourceType enabled public access must declare bypass" -RemoveFields $bypassField -Expected $true
    Invoke-RuleCase @common -Name "$resourceType empty bypass value reported" -Changes @{ $bypassField = '' } -Expected $true
    Invoke-RuleCase @common -Name "$resourceType disabled public with omitted bypass" -Changes @{ $publicField = 'Disabled' } -RemoveFields $bypassField -Expected $false
    Invoke-RuleCase @common -Name "$resourceType disabled public with unapproved bypass" -Changes @{ $publicField = 'Disabled'; $bypassField = 'AzureServices' } -Expected $true
    Invoke-RuleCase @common -Name "$resourceType Deny option for unapproved bypass" -Changes @{ $bypassField = 'AzureServices' } -ParameterChanges @{ effect = 'Deny' } -Expected $true
}
Invoke-RuleCase -Name 'ML workspace not evaluated with invented bypass setting' -PolicyName 'restrict-ai-trusted-services' -Fields @{ type = 'Microsoft.MachineLearningServices/workspaces' } -Expected $false

$supplementalEndpointTypes = @(
    'Microsoft.MachineLearningServices/registries',
    'Microsoft.VideoIndexer/accounts',
    'Microsoft.App/managedEnvironments',
    'Microsoft.ApiManagement/service',
    'Microsoft.DocumentDB/mongoClusters',
    'Microsoft.Sql/managedInstances'
)
$actualEndpointTypes = @($definitions['require-ai-private-endpoints'].policyRule.if.anyOf | ForEach-Object { $_.allOf[0].equals })
Confirm-Assertion (@(Compare-Object $supplementalEndpointTypes $actualEndpointTypes).Count -eq 0) 'Supplemental private-endpoint scope must contain only resource types with verified policy aliases.'
Confirm-Assertion (-not $definitions['require-ai-private-endpoints'].parameters.Contains('resourceTypes')) 'Do not inherit the broader location type list into private-endpoint checks.'
foreach ($resourceType in $supplementalEndpointTypes) {
    $connectionField = "$resourceType/privateEndpointConnections[*]"
    $statusProperty = 'privateLinkServiceConnectionState.status'
    $approvedConnection = @{ $statusProperty = 'Approved' }
    $common = @{ PolicyName = 'require-ai-private-endpoints'; Fields = @{ type = $resourceType; $connectionField = @($approvedConnection) } }
    Invoke-RuleCase @common -Name "$resourceType Approved private endpoint" -Expected $false
    Invoke-RuleCase @common -Name "$resourceType missing private endpoint field" -RemoveFields $connectionField -Expected $true
    Invoke-RuleCase @common -Name "$resourceType empty private endpoint array" -Changes @{ $connectionField = @() } -Expected $true
    foreach ($status in @('Pending', 'Rejected', 'Disconnected', '')) {
        Invoke-RuleCase @common -Name "$resourceType non-Approved status $status" -Changes @{ $connectionField = @(@{ $statusProperty = $status }) } -Expected $true
    }
    Invoke-RuleCase @common -Name "$resourceType mixed Approved and Pending" -Changes @{ $connectionField = @(@{ $statusProperty = 'Pending' }, $approvedConnection) } -Expected $false
    Invoke-RuleCase @common -Name "$resourceType public disabled still needs endpoint" -RemoveFields $connectionField -Changes @{ "$resourceType/publicNetworkAccess" = 'Disabled' } -Expected $true
    Invoke-RuleCase @common -Name "$resourceType public enabled with endpoint" -Changes @{ "$resourceType/publicNetworkAccess" = 'Enabled' } -Expected $false
    Invoke-RuleCase @common -Name "$resourceType Deny available for missing endpoint" -RemoveFields $connectionField -ParameterChanges @{ effect = 'Deny' } -Expected $true
}
$registryType = 'Microsoft.MachineLearningServices/registries'
$legacyConnectionField = "$registryType/registryPrivateEndpointConnections[*]"
$common = @{ PolicyName = 'require-ai-private-endpoints'; Fields = @{ type = $registryType; $legacyConnectionField = @(@{ 'registryPrivateLinkServiceConnectionState.status' = 'Approved' }) } }
Invoke-RuleCase @common -Name 'registry legacy Approved connection' -Expected $false
Invoke-RuleCase @common -Name 'registry legacy Pending connection' -Changes @{ $legacyConnectionField = @(@{ 'registryPrivateLinkServiceConnectionState.status' = 'Pending' }) } -Expected $true
Invoke-RuleCase @common -Name 'Video Indexer cannot use a registry connection' -Changes @{ type = 'Microsoft.VideoIndexer/accounts' } -Expected $true
foreach ($resourceType in @(
    $coreType,
    'Microsoft.Search/searchServices',
    'Microsoft.MachineLearningServices/workspaces',
    'Microsoft.BotService/botServices',
    'Microsoft.Databricks/workspaces',
    'Microsoft.ContainerRegistry/registries',
    'Microsoft.Storage/storageAccounts',
    'Microsoft.KeyVault/vaults',
    'Microsoft.KeyVault/managedHSMs',
    'Microsoft.DocumentDB/databaseAccounts',
    'Microsoft.DBforPostgreSQL/flexibleServers',
    'Microsoft.Sql/servers',
    'Microsoft.Cache/redis',
    'Microsoft.Cache/redisEnterprise',
    'Microsoft.Batch/batchAccounts',
    'Microsoft.Web/sites',
    'Microsoft.Synapse/workspaces',
    'Microsoft.DataFactory/factories',
    'Microsoft.Purview/accounts',
    'Microsoft.Insights/privateLinkScopes',
    'Microsoft.App/containerApps',
    'Microsoft.App/jobs',
    $unrelatedType,
    'Microsoft.HealthBot/healthBots',
    'Microsoft.Fabric/capacities',
    'Microsoft.CognitiveServices/accounts/projects',
    'Microsoft.CognitiveServices/accounts/deployments',
    'Microsoft.MachineLearningServices/workspaces/computes',
    'Microsoft.MachineLearningServices/workspaces/onlineEndpoints'
)) {
    Invoke-RuleCase -Name "supplemental endpoint policy avoids duplicate or unrelated type $resourceType" -PolicyName 'require-ai-private-endpoints' -Fields @{ type = $resourceType } -Expected $false
}

$monitorScopeTypes = @(
    @{ type = 'Microsoft.OperationalInsights/workspaces'; field = 'Microsoft.OperationalInsights/workspaces/privateLinkScopedResources[*]'; member = 'scopeId' },
    @{ type = 'Microsoft.Insights/components'; field = 'Microsoft.Insights/components/PrivateLinkScopedResources[*]'; member = 'ScopeId' }
)
foreach ($monitor in $monitorScopeTypes) {
    $scopeField = $monitor.field
    $scopeMember = $monitor.member
    $scopeAssociation = @{ $scopeMember = '/subscriptions/test/resourceGroups/monitoring/providers/Microsoft.Insights/privateLinkScopes/ai-monitor' }
    $common = @{ PolicyName = 'require-ai-monitor-private-link-scope'; Fields = @{ type = $monitor.type; $scopeField = @($scopeAssociation) } }
    Invoke-RuleCase @common -Name "$($monitor.type) Monitor scope association present" -Expected $false
    Invoke-RuleCase @common -Name "$($monitor.type) missing Monitor scope association" -RemoveFields $scopeField -Expected $true
    Invoke-RuleCase @common -Name "$($monitor.type) empty Monitor scope associations" -Changes @{ $scopeField = @() } -Expected $true
    Invoke-RuleCase @common -Name "$($monitor.type) empty Monitor scope entry" -Changes @{ $scopeField = @(@{}) } -Expected $true
    Invoke-RuleCase @common -Name "$($monitor.type) empty Monitor scope ID" -Changes @{ $scopeField = @(@{ $scopeMember = '' }) } -Expected $true
    Invoke-RuleCase @common -Name "$($monitor.type) null Monitor scope ID" -Changes @{ $scopeField = @(@{ $scopeMember = $null }) } -Expected $true
    Invoke-RuleCase @common -Name "$($monitor.type) one valid Monitor association" -Changes @{ $scopeField = @(@{}, $scopeAssociation) } -Expected $false
    Invoke-RuleCase @common -Name "$($monitor.type) public disabled still needs Monitor association" -RemoveFields $scopeField -Changes @{ "$($monitor.type)/publicNetworkAccessForIngestion" = 'Disabled' } -Expected $true
    Invoke-RuleCase @common -Name "$($monitor.type) endpoint on another resource does not establish membership" -RemoveFields $scopeField -Changes @{ 'Microsoft.Insights/privateLinkScopes/privateEndpointConnections[*]' = @(@{ 'privateLinkServiceConnectionState.status' = 'Approved' }) } -Expected $true
    Invoke-RuleCase @common -Name "$($monitor.type) Deny available for missing membership" -RemoveFields $scopeField -ParameterChanges @{ effect = 'Deny' } -Expected $true
}
Invoke-RuleCase -Name 'Monitor scope itself uses the existing endpoint built-in' -PolicyName 'require-ai-monitor-private-link-scope' -Fields @{ type = 'Microsoft.Insights/privateLinkScopes' } -Expected $false
Invoke-RuleCase -Name 'Foundry account is not a Monitor resource' -PolicyName 'require-ai-monitor-private-link-scope' -Fields @{ type = $coreType } -Expected $false

$injectionField = "$coreType/networkInjections[*]"
$projectManagementField = "$coreType/allowProjectManagement"
$customerInjection = @{ scenario = 'agent'; subnetArmId = $approvedSubnet; useMicrosoftManagedNetwork = $false }
$common = @{ PolicyName = 'require-foundry-vnet-injection'; Fields = @{ type = $coreType; kind = 'AIServices'; $projectManagementField = $true; $injectionField = @($customerInjection) } }
Invoke-RuleCase @common -Name 'Foundry customer subnet injection present' -Expected $false
Invoke-RuleCase @common -Name 'Foundry missing injection' -RemoveFields $injectionField -Expected $true
Invoke-RuleCase @common -Name 'Foundry empty injection array' -Changes @{ $injectionField = @() } -Expected $true
Invoke-RuleCase @common -Name 'Foundry scenario none is not injection' -Changes @{ $injectionField = @(@{ scenario = 'none'; subnetArmId = $approvedSubnet }) } -Expected $true
Invoke-RuleCase @common -Name 'Foundry injection missing subnet' -Changes @{ $injectionField = @(@{ scenario = 'agent' }) } -Expected $true
Invoke-RuleCase @common -Name 'Foundry injection empty subnet' -Changes @{ $injectionField = @(@{ scenario = 'agent'; subnetArmId = '' }) } -Expected $true
Invoke-RuleCase @common -Name 'Foundry Microsoft-managed network is not customer injection' -Changes @{ $injectionField = @(@{ scenario = 'agent'; subnetArmId = $approvedSubnet; useMicrosoftManagedNetwork = $true }) } -Expected $true
Invoke-RuleCase @common -Name 'Foundry omitted managed flag with customer subnet' -Changes @{ $injectionField = @(@{ scenario = 'agent'; subnetArmId = $approvedSubnet }) } -Expected $false
Invoke-RuleCase @common -Name 'Foundry scenario and subnet must belong to same entry' -Changes @{ $injectionField = @(@{ scenario = 'agent' }, @{ scenario = 'none'; subnetArmId = $approvedSubnet }) } -Expected $true
Invoke-RuleCase @common -Name 'Foundry one valid injection among others' -Changes @{ $injectionField = @(@{ scenario = 'none' }, $customerInjection) } -Expected $false
Invoke-RuleCase @common -Name 'Foundry private endpoint alone is not injection' -RemoveFields $injectionField -Changes @{ "$coreType/privateEndpointConnections[*]" = @(@{ 'privateLinkServiceConnectionState.status' = 'Approved' }) } -Expected $true
Invoke-RuleCase @common -Name 'Foundry Deny option for absent injection' -RemoveFields $injectionField -ParameterChanges @{ effect = 'Deny' } -Expected $true
Invoke-RuleCase @common -Name 'OpenAI-only account outside injection scope' -Changes @{ kind = 'OpenAI' } -RemoveFields $injectionField -Expected $false
Invoke-RuleCase @common -Name 'non-project AIServices account outside injection scope' -Changes @{ $projectManagementField = $false } -RemoveFields $injectionField -Expected $false
Invoke-RuleCase @common -Name 'ML hub outside Foundry account injection scope' -Changes @{ type = 'Microsoft.MachineLearningServices/workspaces'; kind = 'Hub' } -RemoveFields $injectionField -Expected $false

$foundryFields = @{ type = $coreType; kind = 'AIServices'; $projectManagementField = $true }
$bypassField = "$coreType/networkAcls.bypass"
$trustedFields = $foundryFields.Clone()
$trustedFields["$coreType/publicNetworkAccess"] = 'Enabled'
$trustedFields["$coreType/networkAcls.defaultAction"] = 'Deny'
$common = @{ PolicyName = 'require-foundry-trusted-services'; Fields = $trustedFields }
Invoke-RuleCase @common -Name 'Foundry trusted access missing' -Expected $true
Invoke-RuleCase @common -Name 'Foundry trusted access None' -Changes @{ $bypassField = 'None' } -Expected $true
Invoke-RuleCase @common -Name 'Foundry trusted access enabled' -Changes @{ $bypassField = 'AzureServices' } -Expected $false
Invoke-RuleCase @common -Name 'Trusted exception does not permit unrestricted public access' -Changes @{ $bypassField = 'AzureServices'; "$coreType/networkAcls.defaultAction" = 'Allow' } -Expected $true
Invoke-RuleCase @common -Name 'Trusted exception needs explicit public firewall default' -Changes @{ $bypassField = 'AzureServices' } -RemoveFields "$coreType/networkAcls.defaultAction" -Expected $true
Invoke-RuleCase @common -Name 'Trusted exception needs explicit public-access state' -Changes @{ $bypassField = 'AzureServices' } -RemoveFields "$coreType/publicNetworkAccess" -Expected $true
Invoke-RuleCase @common -Name 'Private-only trusted configuration does not need a public firewall default' -Changes @{ $bypassField = 'AzureServices'; "$coreType/publicNetworkAccess" = 'Disabled' } -RemoveFields "$coreType/networkAcls.defaultAction" -Expected $false
Invoke-RuleCase @common -Name 'Foundry unknown bypass is not trusted access' -Changes @{ $bypassField = 'AllServices' } -Expected $true
Invoke-RuleCase @common -Name 'Public access disabled does not invent trusted exception' -Changes @{ "$coreType/publicNetworkAccess" = 'Disabled' } -Expected $true
Invoke-RuleCase @common -Name 'Trusted exception does not require unrestricted public access' -Changes @{ $bypassField = 'AzureServices'; "$coreType/publicNetworkAccess" = 'Disabled' } -Expected $false
Invoke-RuleCase @common -Name 'Trusted exception excludes OpenAI-only accounts' -Changes @{ kind = 'OpenAI' } -Expected $false
Invoke-RuleCase @common -Name 'Trusted exception excludes non-project AIServices' -Changes @{ $projectManagementField = $false } -Expected $false
Invoke-RuleCase @common -Name 'Trusted exception excludes missing project marker' -RemoveFields $projectManagementField -Expected $false
Invoke-RuleCase @common -Name 'Trusted exception excludes ML hubs' -Changes @{ type = 'Microsoft.MachineLearningServices/workspaces' } -Expected $false

$peField = "$coreType/privateEndpointConnections[*]"
$approvedConnection = @{ 'privateLinkServiceConnectionState.status' = 'Approved' }
$common = @{ PolicyName = 'require-foundry-private-endpoint'; Fields = $foundryFields }
Invoke-RuleCase @common -Name 'Foundry private endpoint missing' -Expected $true
Invoke-RuleCase @common -Name 'Foundry empty private endpoint list' -Changes @{ $peField = @() } -Expected $true
Invoke-RuleCase @common -Name 'Foundry approved private endpoint' -Changes @{ $peField = @($approvedConnection) } -Expected $false
Invoke-RuleCase @common -Name 'Foundry pending private endpoint only' -Changes @{ $peField = @(@{ 'privateLinkServiceConnectionState.status' = 'Pending' }) } -Expected $true
Invoke-RuleCase @common -Name 'Foundry rejected plus approved endpoint' -Changes @{ $peField = @(@{ 'privateLinkServiceConnectionState.status' = 'Rejected' }, $approvedConnection) } -Expected $false
Invoke-RuleCase @common -Name 'Disabled public access does not replace a private endpoint' -Changes @{ "$coreType/publicNetworkAccess" = 'Disabled' } -Expected $true
Invoke-RuleCase @common -Name 'Private endpoint check excludes OpenAI-only accounts' -Changes @{ kind = 'OpenAI' } -Expected $false
Invoke-RuleCase @common -Name 'Private endpoint check excludes other Cognitive Services kinds' -Changes @{ kind = 'SpeechServices' } -Expected $false
Invoke-RuleCase @common -Name 'Private endpoint check excludes non-project AIServices' -Changes @{ $projectManagementField = $false } -Expected $false
Invoke-RuleCase @common -Name 'Private endpoint check excludes Azure AI Search' -Changes @{ type = 'Microsoft.Search/searchServices' } -Expected $false
Invoke-RuleCase @common -Name 'Private endpoint Deny option' -ParameterChanges @{ effect = 'Deny' } -Expected $true

foreach ($connectionCase in @(
    @{ policy = 'require-foundry-key-vault-connection'; category = 'AzureKeyVault' }
)) {
    $connectionType = "$coreType/connections"
    $categoryField = "$connectionType/category"
    $targetField = "$connectionType/target"
    $related = @{ type = $connectionType; $categoryField = $connectionCase.category; $targetField = 'https://connection.example.invalid' }
    $common = @{ PolicyName = $connectionCase.policy; Fields = $foundryFields }
    Invoke-RuleCase @common -Name "$($connectionCase.category) missing connection" -Expected $true
    Invoke-RuleCase @common -Name "$($connectionCase.category) connection present" -RelatedResources @($related) -Expected $false
    Invoke-RuleCase @common -Name "$($connectionCase.category) wrong category" -RelatedResources @(@{ type = $connectionType; $categoryField = 'AzureBlob'; $targetField = 'https://example.invalid' }) -Expected $true
    Invoke-RuleCase @common -Name "$($connectionCase.category) missing target" -RelatedResources @(@{ type = $connectionType; $categoryField = $connectionCase.category }) -Expected $true
    Invoke-RuleCase @common -Name "$($connectionCase.category) empty target" -RelatedResources @(@{ type = $connectionType; $categoryField = $connectionCase.category; $targetField = '' }) -Expected $true
    Invoke-RuleCase @common -Name "$($connectionCase.category) null target" -RelatedResources @(@{ type = $connectionType; $categoryField = $connectionCase.category; $targetField = $null }) -Expected $true
    Invoke-RuleCase @common -Name "$($connectionCase.category) target and category must belong to same connection" -RelatedResources @(@{ type = $connectionType; $categoryField = $connectionCase.category }, @{ type = $connectionType; $categoryField = 'AzureBlob'; $targetField = 'https://example.invalid' }) -Expected $true
    Invoke-RuleCase @common -Name "$($connectionCase.category) one valid connection among others" -RelatedResources @(@{ type = $connectionType; $categoryField = 'AzureBlob' }, $related) -Expected $false
    $projectConnection = $related.Clone()
    $projectConnection.type = "$coreType/projects/connections"
    Invoke-RuleCase @common -Name "$($connectionCase.category) project-only connection is outside account-level contract" -RelatedResources @($projectConnection) -Expected $true
    Invoke-RuleCase @common -Name "$($connectionCase.category) standalone resource is not integration" -RelatedResources @(@{ type = 'Microsoft.KeyVault/vaults' }, @{ type = 'Microsoft.Insights/components' }) -Expected $true
    Invoke-RuleCase @common -Name "$($connectionCase.category) OpenAI-only account excluded" -Changes @{ kind = 'OpenAI' } -Expected $false
    Invoke-RuleCase @common -Name "$($connectionCase.category) non-project AIServices excluded" -Changes @{ $projectManagementField = $false } -Expected $false
    Invoke-RuleCase @common -Name "$($connectionCase.category) ML hub excluded" -Changes @{ type = 'Microsoft.MachineLearningServices/workspaces' } -Expected $false
    Invoke-RuleCase @common -Name "$($connectionCase.category) project child is not an account" -Changes @{ type = "$coreType/projects" } -Expected $false
    Invoke-RuleCase @common -Name "$($connectionCase.category) standalone disabled effect" -ParameterChanges @{ effect = 'Disabled' } -Expected $false
    Confirm-Assertion ($definitions[$connectionCase.policy].policyRule.then.details.type -eq $connectionType) 'Related-resource lookup must stay beneath the evaluated account.'
}

$projectType = "$coreType/projects"
$projectConnectionType = "$projectType/connections"
$projectCategoryField = "$projectConnectionType/category"
$projectTargetField = "$projectConnectionType/target"
$projectInsights = @{ type = $projectConnectionType; $projectCategoryField = 'AppInsights'; $projectTargetField = '/subscriptions/example/providers/Microsoft.Insights/components/example' }
$common = @{ PolicyName = 'require-foundry-app-insights-connection'; Fields = @{ type = $projectType } }
Invoke-RuleCase @common -Name 'Project without App Insights connection' -Expected $true
Invoke-RuleCase @common -Name 'Project with App Insights connection' -RelatedResources @($projectInsights) -Expected $false
Invoke-RuleCase @common -Name 'Project connection with wrong category' -RelatedResources @(@{ type = $projectConnectionType; $projectCategoryField = 'AzureKeyVault'; $projectTargetField = 'https://example.invalid' }) -Expected $true
Invoke-RuleCase @common -Name 'Project App Insights connection with empty target' -RelatedResources @(@{ type = $projectConnectionType; $projectCategoryField = 'AppInsights'; $projectTargetField = '' }) -Expected $true
Invoke-RuleCase @common -Name 'Account-level App Insights connection does not satisfy the project check' -RelatedResources @(@{ type = "$coreType/connections"; "$coreType/connections/category" = 'AppInsights'; "$coreType/connections/target" = 'https://example.invalid' }) -Expected $true
Invoke-RuleCase @common -Name 'Standalone App Insights component is not a connection' -RelatedResources @(@{ type = 'Microsoft.Insights/components' }) -Expected $true
Invoke-RuleCase @common -Name 'Foundry accounts are not assessed by the project check' -Changes @{ type = $coreType; kind = 'AIServices'; $projectManagementField = $true } -Expected $false
Invoke-RuleCase @common -Name 'ML projects are not assessed by the Foundry project check' -Changes @{ type = 'Microsoft.MachineLearningServices/workspaces' } -Expected $false
Invoke-RuleCase @common -Name 'Project App Insights disabled effect' -ParameterChanges @{ effect = 'Disabled' } -Expected $false
Confirm-Assertion ($definitions['require-foundry-app-insights-connection'].policyRule.then.details.type -eq $projectConnectionType) 'App Insights lookup must stay beneath the evaluated project.'

$raiField = "$deploymentType/raiPolicyName"
$common = @{ PolicyName = 'require-ai-deployment-content-filter'; Fields = @{ type = $deploymentType; $raiField = 'Microsoft.DefaultV2' } }
Invoke-RuleCase @common -Name 'Default content filter compliant' -Expected $false
Invoke-RuleCase @common -Name 'Named custom content filter compliant' -Changes @{ $raiField = 'contoso-strict' } -Expected $false
Invoke-RuleCase @common -Name 'Missing content filter reported' -RemoveFields $raiField -Expected $true
Invoke-RuleCase @common -Name 'Empty content filter reported' -Changes @{ $raiField = '' } -Expected $true
Invoke-RuleCase @common -Name 'Microsoft.Nil content filter reported' -Changes @{ $raiField = 'Microsoft.Nil' } -Expected $true
Invoke-RuleCase @common -Name 'Content filter Deny option' -Changes @{ $raiField = 'Microsoft.Nil' } -ParameterChanges @{ effect = 'Deny' } -Expected $true
Invoke-RuleCase @common -Name 'Accounts are not assessed by the content filter check' -Changes @{ type = $coreType } -RemoveFields $raiField -Expected $false

$endpointType = 'Microsoft.MachineLearningServices/workspaces/onlineEndpoints'
$authField = "$endpointType/authMode"
$common = @{ PolicyName = 'require-ml-endpoint-entra-auth'; Fields = @{ type = $endpointType; $authField = 'AADToken' } }
Invoke-RuleCase @common -Name 'Entra ID endpoint auth compliant' -Expected $false
Invoke-RuleCase @common -Name 'Key endpoint auth reported' -Changes @{ $authField = 'Key' } -Expected $true
Invoke-RuleCase @common -Name 'Azure ML token endpoint auth reported' -Changes @{ $authField = 'AMLToken' } -Expected $true
Invoke-RuleCase @common -Name 'Missing endpoint auth mode reported' -RemoveFields $authField -Expected $true
Invoke-RuleCase @common -Name 'Endpoint auth Deny option' -Changes @{ $authField = 'Key' } -ParameterChanges @{ effect = 'Deny' } -Expected $true
Invoke-RuleCase @common -Name 'Batch endpoints are not assessed by the online endpoint check' -Changes @{ type = 'Microsoft.MachineLearningServices/workspaces/batchEndpoints'; $authField = 'Key' } -Expected $false

$pricing = @{ type = 'Microsoft.Security/pricings'; 'Microsoft.Security/pricings/pricingTier' = 'Standard' }
$common = @{ PolicyName = 'require-defender-for-ai'; Fields = @{ type = 'Microsoft.Resources/subscriptions' } }
Invoke-RuleCase @common -Name 'Defender for AI missing' -Expected $true
Invoke-RuleCase @common -Name 'Defender for AI Standard' -RelatedResources @($pricing) -Expected $false
Invoke-RuleCase @common -Name 'Defender for AI Free' -RelatedResources @(@{ type = 'Microsoft.Security/pricings'; 'Microsoft.Security/pricings/pricingTier' = 'Free' }) -Expected $true
Invoke-RuleCase @common -Name 'Defender check ignores resource groups' -Changes @{ type = 'Microsoft.Resources/resourceGroups' } -Expected $false
Confirm-Assertion ($definitions['require-defender-for-ai'].policyRule.then.details.name -eq 'AI') 'Defender check must target the AI pricing plan.'

$logsField = 'Microsoft.Insights/diagnosticSettings/logs[*]'
$enabledLogs = @{ type = 'Microsoft.Insights/diagnosticSettings'; $logsField = @(@{ enabled = 'true' }) }
$common = @{ PolicyName = 'require-ai-diagnostic-logs'; Fields = @{ type = 'Microsoft.BotService/botServices' } }
foreach ($logType in 'Microsoft.MachineLearningServices/workspaces/onlineEndpoints', 'Microsoft.MachineLearningServices/registries', 'Microsoft.BotService/botServices', 'Microsoft.VideoIndexer/accounts') {
    Invoke-RuleCase @common -Name "$logType without logs" -Changes @{ type = $logType } -Expected $true
    Invoke-RuleCase @common -Name "$logType with enabled logs" -Changes @{ type = $logType } -RelatedResources @($enabledLogs) -Expected $false
}
Invoke-RuleCase @common -Name 'Diagnostic setting with only disabled logs' -RelatedResources @(@{ type = 'Microsoft.Insights/diagnosticSettings'; $logsField = @(@{ enabled = 'false' }) }) -Expected $true
Invoke-RuleCase @common -Name 'Diagnostic logs check ignores Cognitive accounts (B28)' -Changes @{ type = $coreType } -Expected $false

$computeType = 'Microsoft.MachineLearningServices/workspaces/computes'
$computeTypeField = "$computeType/computeType"
$common = @{ PolicyName = 'require-ml-compute-no-public-ip'; Fields = @{ type = $computeType; $computeTypeField = 'AmlCompute'; "$computeType/enableNodePublicIp" = $false } }
Invoke-RuleCase @common -Name 'Compute without public IP compliant' -Expected $false
Invoke-RuleCase @common -Name 'Compute with public IP reported' -Changes @{ "$computeType/enableNodePublicIp" = $true } -Expected $true
Invoke-RuleCase @common -Name 'Compute public IP unset reported' -RemoveFields "$computeType/enableNodePublicIp" -Expected $true
Invoke-RuleCase @common -Name 'Compute instance public IP reported' -Changes @{ $computeTypeField = 'ComputeInstance'; "$computeType/enableNodePublicIp" = $true } -Expected $true
Invoke-RuleCase @common -Name 'Attached compute not assessed for public IP' -Changes @{ $computeTypeField = 'Kubernetes'; "$computeType/enableNodePublicIp" = $true } -Expected $false

$common = @{ PolicyName = 'require-ml-compute-no-ssh'; Fields = @{ type = $computeType; $computeTypeField = 'AmlCompute'; "$computeType/remoteLoginPortPublicAccess" = 'Disabled' } }
Invoke-RuleCase @common -Name 'Cluster SSH disabled compliant' -Expected $false
Invoke-RuleCase @common -Name 'Cluster SSH enabled reported' -Changes @{ "$computeType/remoteLoginPortPublicAccess" = 'Enabled' } -Expected $true
Invoke-RuleCase @common -Name 'Cluster SSH NotSpecified reported' -Changes @{ "$computeType/remoteLoginPortPublicAccess" = 'NotSpecified' } -Expected $true
Invoke-RuleCase @common -Name 'Instance SSH disabled compliant' -Changes @{ $computeTypeField = 'ComputeInstance'; "$computeType/sshSettings.sshPublicAccess" = 'Disabled' } -Expected $false
Invoke-RuleCase @common -Name 'Instance SSH enabled reported' -Changes @{ $computeTypeField = 'ComputeInstance'; "$computeType/sshSettings.sshPublicAccess" = 'Enabled' } -Expected $true
Invoke-RuleCase @common -Name 'Attached compute not assessed for SSH' -Changes @{ $computeTypeField = 'Kubernetes' } -Expected $false

$upgradeField = "$deploymentType/versionUpgradeOption"
$common = @{ PolicyName = 'require-ai-deployment-auto-upgrade'; Fields = @{ type = $deploymentType; $upgradeField = 'OnceNewDefaultVersionAvailable' } }
Invoke-RuleCase @common -Name 'Auto-upgrade deployment compliant' -Expected $false
Invoke-RuleCase @common -Name 'Upgrade on expiry compliant' -Changes @{ $upgradeField = 'OnceCurrentVersionExpired' } -Expected $false
Invoke-RuleCase @common -Name 'No auto-upgrade reported' -Changes @{ $upgradeField = 'NoAutoUpgrade' } -Expected $true

$hbiField = 'Microsoft.MachineLearningServices/workspaces/hbiWorkspace'
$common = @{ PolicyName = 'require-ml-workspace-hbi'; Fields = @{ type = 'Microsoft.MachineLearningServices/workspaces'; kind = 'Hub'; $hbiField = $true } }
Invoke-RuleCase @common -Name 'HBI hub compliant' -Expected $false
Invoke-RuleCase @common -Name 'Non-HBI hub reported' -Changes @{ $hbiField = $false } -Expected $true
Invoke-RuleCase @common -Name 'Default workspace without HBI reported' -Changes @{ kind = 'Default' } -RemoveFields $hbiField -Expected $true
Invoke-RuleCase @common -Name 'Project workspace skipped for HBI' -Changes @{ kind = 'Project'; $hbiField = $false } -Expected $false

$assignedField = "$computeType/personalComputeInstanceSettings.assignedUser.objectId"
$common = @{ PolicyName = 'require-ml-compute-instance-assigned-user'; Fields = @{ type = $computeType; $computeTypeField = 'ComputeInstance'; $assignedField = '00000000-0000-0000-0000-000000000001' } }
Invoke-RuleCase @common -Name 'Assigned compute instance compliant' -Expected $false
Invoke-RuleCase @common -Name 'Unassigned compute instance reported' -RemoveFields $assignedField -Expected $true
Invoke-RuleCase @common -Name 'Empty assigned user reported' -Changes @{ $assignedField = '' } -Expected $true
Invoke-RuleCase @common -Name 'Clusters not assessed for assigned user' -Changes @{ $computeTypeField = 'AmlCompute' } -RemoveFields $assignedField -Expected $false

$samiTypes = [ordered]@{
    'require-sami-cognitive-accounts' = 'Microsoft.CognitiveServices/accounts'
    'require-sami-foundry-projects' = 'Microsoft.CognitiveServices/accounts/projects'
    'require-sami-ml-workspaces' = 'Microsoft.MachineLearningServices/workspaces'
    'require-sami-ml-registries' = 'Microsoft.MachineLearningServices/registries'
    'require-sami-ml-online-endpoints' = 'Microsoft.MachineLearningServices/workspaces/onlineEndpoints'
    'require-sami-ml-batch-endpoints' = 'Microsoft.MachineLearningServices/workspaces/batchEndpoints'
    'require-sami-ml-computes' = $computeType
    'require-sami-search' = 'Microsoft.Search/searchServices'
    'require-sami-health-bot' = 'Microsoft.HealthBot/healthBots'
    'require-sami-deid' = 'Microsoft.HealthDataAIServices/deidServices'
    'require-sami-video-indexer' = 'Microsoft.VideoIndexer/accounts'
}
foreach ($entry in $samiTypes.GetEnumerator()) {
    $common = @{ PolicyName = $entry.Key; Fields = @{ type = $entry.Value; $computeTypeField = 'ComputeInstance'; 'identity.type' = 'SystemAssigned' } }
    Invoke-RuleCase @common -Name "$($entry.Key) system-assigned compliant" -Expected $false
    Invoke-RuleCase @common -Name "$($entry.Key) both identities compliant" -Changes @{ 'identity.type' = 'SystemAssigned, UserAssigned' } -Expected $false
    Invoke-RuleCase @common -Name "$($entry.Key) user-assigned only reported" -Changes @{ 'identity.type' = 'UserAssigned' } -Expected $true
    Invoke-RuleCase @common -Name "$($entry.Key) missing identity reported" -RemoveFields 'identity.type' -Expected $true
    Invoke-RuleCase @common -Name "$($entry.Key) other type ignored" -Changes @{ type = $unrelatedType } -RemoveFields 'identity.type' -Expected $false
}
Invoke-RuleCase -Name 'SAMI compute attached Kubernetes ignored' -PolicyName 'require-sami-ml-computes' -Fields @{ type = $computeType; $computeTypeField = 'Kubernetes' } -Expected $false

$computeType = 'Microsoft.MachineLearningServices/workspaces/computes'
$common = @{ PolicyName = 'require-ai-system-assigned-identity'; Fields = @{ type = $coreType; kind = 'OpenAI'; 'identity.type' = 'SystemAssigned' } }
Invoke-RuleCase @common -Name 'System-assigned identity compliant' -Expected $false
Invoke-RuleCase @common -Name 'System plus user-assigned identity compliant' -Changes @{ 'identity.type' = 'SystemAssigned, UserAssigned' } -Expected $false
Invoke-RuleCase @common -Name 'System plus user-assigned identity without space compliant' -Changes @{ 'identity.type' = 'SystemAssigned,UserAssigned' } -Expected $false
Invoke-RuleCase @common -Name 'User-assigned only is reported' -Changes @{ 'identity.type' = 'UserAssigned' } -Expected $true
Invoke-RuleCase @common -Name 'Identity None is reported' -Changes @{ 'identity.type' = 'None' } -Expected $true
Invoke-RuleCase @common -Name 'Missing identity is reported' -RemoveFields 'identity.type' -Expected $true
Invoke-RuleCase @common -Name 'System identity Deny option' -Changes @{ 'identity.type' = 'UserAssigned' } -ParameterChanges @{ effect = 'Deny' } -Expected $true
foreach ($identityType in @("$coreType/projects", 'Microsoft.MachineLearningServices/workspaces', 'Microsoft.MachineLearningServices/registries', 'Microsoft.MachineLearningServices/workspaces/onlineEndpoints', 'Microsoft.MachineLearningServices/workspaces/batchEndpoints', 'Microsoft.Search/searchServices', 'Microsoft.HealthBot/healthBots', 'Microsoft.HealthDataAIServices/deidServices', 'Microsoft.VideoIndexer/accounts')) {
    Invoke-RuleCase @common -Name "$identityType without system identity" -Changes @{ type = $identityType } -RemoveFields 'identity.type' -Expected $true
    Invoke-RuleCase @common -Name "$identityType with system identity" -Changes @{ type = $identityType } -Expected $false
}
foreach ($computeKind in @('AmlCompute', 'ComputeInstance')) {
    Invoke-RuleCase @common -Name "$computeKind without system identity" -Changes @{ type = $computeType; "$computeType/computeType" = $computeKind } -RemoveFields 'identity.type' -Expected $true
}
Invoke-RuleCase @common -Name 'Attached Kubernetes compute not assessed' -Changes @{ type = $computeType; "$computeType/computeType" = 'Kubernetes' } -RemoveFields 'identity.type' -Expected $false
Invoke-RuleCase @common -Name 'Bot Service has no ARM identity and is not assessed' -Changes @{ type = 'Microsoft.BotService/botServices' } -RemoveFields 'identity.type' -Expected $false
Invoke-RuleCase @common -Name 'Model deployments are not assessed' -Changes @{ type = $deploymentType } -RemoveFields 'identity.type' -Expected $false
Invoke-RuleCase @common -Name 'Unrelated resources are not assessed' -Changes @{ type = $unrelatedType } -RemoveFields 'identity.type' -Expected $false

$deploymentPath = Join-Path $PSScriptRoot 'Deploy-AiGovernance.ps1'
$deploymentTokens = $null
$deploymentErrors = $null
$deploymentAst = [System.Management.Automation.Language.Parser]::ParseFile($deploymentPath, [ref]$deploymentTokens, [ref]$deploymentErrors)
if ($deploymentErrors.Count -gt 0) {
    throw "Deployment script syntax errors: $(@($deploymentErrors | ForEach-Object { $_.Message }) -join '; ')"
}
foreach ($functionName in @('Get-AuditSelection', 'Get-ExpectedBuiltIns', 'Get-FoundryBindings', 'New-AuditReference', 'New-AuditInitiative', 'Get-PolicyFields')) {
    $functionAst = $deploymentAst.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName
    }, $true)
    Confirm-Assertion ($null -ne $functionAst) "Missing deployment helper: $functionName"
    . ([scriptblock]::Create($functionAst.Extent.Text))
}
$selection = @(Get-AuditSelection $manifest)
Confirm-Assertion ($selection.Count -eq $baselineReferences.Count) 'Deployment selection differs from the audit-only manifest.'
$fixtureBuiltIns = @{}
foreach ($policy in $selection) {
    $effectName = if ($policy.Contains('effectParameter') -and $policy.effectParameter) { $policy.effectParameter } else { 'effect' }
    $fixtureBuiltIns[$policy.reference] = @{
        displayName = $policy.displayName
        policyRule = @{ then = @{ effect = "[parameters('$effectName')]" } }
        parameters = @{
            $effectName = @{ type = 'String'; allowedValues = $policy.documentedEffects; defaultValue = 'Disabled' }
        }
    }
}
$fixtureBuiltIns.B06.parameters.isolationMode = @{ type = 'String'; allowedValues = @('AllowInternetOutbound', 'AllowOnlyApprovedOutbound', 'Disabled'); defaultValue = 'Disabled' }
$fixtureBuiltIns.B29.parameters.requiredRetentionDays = @{ type = 'String'; defaultValue = '365' }
$fixtureBuiltIns.B30.parameters.requiredRetentionDays = @{ type = 'String'; defaultValue = '365' }
$fixtureBuiltIns.B19.parameters.denyPreviewModels = @{ type = 'Boolean'; defaultValue = $false }
$fixtureBuiltIns.B19.parameters.onlyAllowDirectFromAzure = @{ type = 'Boolean'; defaultValue = $false }
$fixtureScope = '/providers/Microsoft.Management/managementGroups/00000000-0000-0000-0000-000000000000'
$initiative = New-AuditInitiative -Scope $fixtureScope -Prefix 'test-ai' -Name 'Audit test' -CustomDefinitions $definitions -SelectedPolicies $selection -BuiltInDefinitions $fixtureBuiltIns
Confirm-Assertion ($initiative.metadata.baseline -eq 'AIPlatformAudit' -and $initiative.metadata.version -eq '6.2.0') 'Incorrect profile version.'
Confirm-Assertion ($initiative.description.Length -le 512 -and $initiative.displayName.Length -le 128) 'Azure limits initiative descriptions to 512 and display names to 128 characters.'
Confirm-Assertion ($initiative.metadata.accountScope -eq 'FoundryAccountsOnly' -and -not $initiative.metadata.Contains('modelDeploymentScope')) 'Scope boundaries must be explicit.'
Confirm-Assertion ($initiative.metadata.integrationScope -eq 'KeyVaultOnAccountAppInsightsOnProject') 'The Key Vault account and App Insights project contract must be explicit.'
Confirm-Assertion (@(Compare-Object (Get-ExpectedBuiltIns) @($baselineReferences.reference)).Count -eq 0) 'Manifest selection must match Get-ExpectedBuiltIns.'
$expectedReferences = @(Get-FoundryBindings | ForEach-Object { $_.reference }) + @(Get-ExpectedBuiltIns)
Confirm-Assertion ($initiative.policyDefinitions.Count -eq 45 -and @(Compare-Object $expectedReferences @($initiative.policyDefinitions.policyDefinitionReferenceId)).Count -eq 0) 'The initiative must contain the 25 custom checks and 20 built-ins.'
Confirm-Assertion (@($initiative.policyDefinitions.policyDefinitionId | Sort-Object -Unique).Count -eq 45) 'Each check must have its own definition.'
Confirm-Assertion ('B11' -notin $expectedReferences -and 'B12' -notin $expectedReferences) 'Identity is covered by the system-assigned identity check only.'
Confirm-Assertion (@('B14', 'B16', 'B72', 'B73' | Where-Object { $_ -in $expectedReferences -or -not $manifest.assignmentProfile.excludedReferences.Contains($_) }).Count -eq 0) 'Customer-managed key policies must stay excluded.'
Confirm-Assertion (@('B02', 'B03', 'B09' | Where-Object { $_ -in $expectedReferences }).Count -eq 0) 'Duplicate Search local-auth and public-disable checks must stay out.'
$mlNetwork = $initiative.policyDefinitions | Where-Object { $_.policyDefinitionReferenceId -eq 'B06' } | Select-Object -First 1
Confirm-Assertion ($mlNetwork.parameters.isolationMode.value -eq 'AllowOnlyApprovedOutbound') 'ML managed network must be fixed to approved-outbound, not the Disabled default.'
$mlLogs = $initiative.policyDefinitions | Where-Object { $_.policyDefinitionReferenceId -eq 'B29' } | Select-Object -First 1
Confirm-Assertion ($mlLogs.parameters.requiredRetentionDays.value -eq '0') 'ML log check must not impose a retention period.'
$searchLogs = $initiative.policyDefinitions | Where-Object { $_.policyDefinitionReferenceId -eq 'B30' } | Select-Object -First 1
Confirm-Assertion ($searchLogs.parameters.requiredRetentionDays.value -eq '0') 'Search log check must not impose a retention period.'
$eligibility = $initiative.policyDefinitions | Where-Object { $_.policyDefinitionReferenceId -eq 'B19' } | Select-Object -First 1
Confirm-Assertion ($eligibility.parameters.denyPreviewModels.value -eq $true -and $eligibility.parameters.onlyAllowDirectFromAzure.value -eq $false) 'Model eligibility must report preview models only.'
Confirm-Assertion (@(Get-FoundryBindings).Count -eq 25) 'Only 25 custom definitions should be published.'
Confirm-Assertion ($initiative.parameters.Count -eq 45 -and @($initiative.parameters.Keys | Where-Object { $_ -notlike '*_effect' }).Count -eq 0) 'Fresh initiatives must expose exactly one effect override per policy and no other parameters.'
foreach ($reference in $initiative.policyDefinitions) {
    $overrideName = "$($reference.policyDefinitionReferenceId)_effect"
    $override = $initiative.parameters[$overrideName]
    $boundEffect = @($reference.parameters.GetEnumerator() | Where-Object { $_.Key -in 'effect', 'effects', 'audit_effect' })
    Confirm-Assertion ($null -ne $override -and $override.Contains('defaultValue') -and $override.type -eq 'String') "Effect override must be optional: $overrideName"
    Confirm-Assertion ($boundEffect.Count -eq 1 -and $boundEffect[0].Value.value -eq "[parameters('$overrideName')]") "Policy effect must bind to its override: $($reference.policyDefinitionReferenceId)"
    Confirm-Assertion ($override.defaultValue -in @('Audit', 'AuditIfNotExists') -and $override.defaultValue -in $override.allowedValues) "Effect override must default to an audit effect: $overrideName"
}
foreach ($policy in $selection) {
    $effectName = if ($policy.Contains('effectParameter') -and $policy.effectParameter) { $policy.effectParameter } else { 'effect' }
    Confirm-Assertion (@(Compare-Object @($fixtureBuiltIns[$policy.reference].parameters[$effectName].allowedValues) @($initiative.parameters["$($policy.reference)_effect"].allowedValues)).Count -eq 0) "Effect override must offer every effect the policy supports: $($policy.reference)"
}
Confirm-Assertion ('B18' -notin $expectedReferences -and $manifest.assignmentProfile.excludedReferences.Contains('B18')) 'The allowed-models check needs parameter lists and must stay excluded.'
foreach ($binding in Get-FoundryBindings) {
    $reference = $initiative.policyDefinitions | Where-Object { $_.policyDefinitionReferenceId -eq $binding.reference } | Select-Object -First 1
    Confirm-Assertion ($reference.parameters.Count -eq 1 -and $reference.parameters.effect.value -eq "[parameters('$($binding.reference)_effect')]" -and
        $initiative.parameters["$($binding.reference)_effect"].defaultValue -eq $binding.effect -and
        @(Compare-Object @($definitions[$binding.file].parameters.effect.allowedValues) @($initiative.parameters["$($binding.reference)_effect"].allowedValues)).Count -eq 0) "Custom Foundry effect override is wrong: $($binding.reference)"
}
$boundEffects = @($initiative.parameters.Values | ForEach-Object { $_.defaultValue })
Confirm-Assertion ((Get-FoundryBindings | Where-Object reference -eq 'B32') -eq $null -and ($initiative.policyDefinitions | Where-Object policyDefinitionReferenceId -eq 'B32').parameters.effects.value -eq "[parameters('B32_effect')]") 'B32 must bind its real effects parameter to its override.'
Confirm-Assertion (@($boundEffects | Where-Object { $_ -eq 'Audit' }).Count -eq 38) 'Expected 38 Audit effects.'
Confirm-Assertion (@($boundEffects | Where-Object { $_ -eq 'AuditIfNotExists' }).Count -eq 7) 'Expected seven AuditIfNotExists effects.'
Confirm-Assertion ($definitions.ContainsKey('restrict-ai-virtual-network-rules')) 'Removing the subnet check from the initiative must not delete its standalone definition.'
$retiredParameters = @{
    allowedLocations = @{ type = 'Array'; metadata = @{ displayName = 'Approved locations' } }
    allowedIpRules = @{ type = 'Array'; metadata = @{ displayName = 'Approved public IP rules' } }
    locationResourceTypes = @{ type = 'Array'; defaultValue = @('Microsoft.Storage/storageAccounts') }
    tagResourceTypes = @{ type = 'Array'; defaultValue = @('Microsoft.CognitiveServices/accounts') }
    allowTrustedServices = @{ type = 'Boolean'; defaultValue = $false }
    allowedKinds = @{ type = 'Array'; metadata = @{ displayName = 'Approved service kinds' } }
    allowedDeploymentSkus = @{ type = 'Array'; metadata = @{ displayName = 'Approved deployment SKUs' } }
    allowedSubnetIds = @{ type = 'Array'; metadata = @{ displayName = 'Approved subnets'; assignPermissions = $true } }
    B13_excludedKinds = @{ type = 'Array'; defaultValue = @() }
    B18_allowedPublishers = @{ type = 'Array'; defaultValue = @('Microsoft') }
    B19_onlyAllowDirectFromAzure = @{ type = 'Boolean'; defaultValue = $false }
    B20_allowedAssetIds = @{ type = 'Array'; defaultValue = @() }
    B22_filterName = @{ type = 'String'; allowedValues = @('Profanity', 'Jailbreak'); metadata = @{ displayName = 'Content Filter' } }
    B23_allowedEnabledForCompletion = @{ type = 'Array'; allowedValues = @('true', 'false'); defaultValue = @('true') }
    B24_allowedSeveritiesForPrompt = @{ type = 'Array'; allowedValues = @('Low', 'Medium', 'High'); defaultValue = @('Medium', 'High') }
    B25_raiPolicyMode = @{ type = 'Array'; allowedValues = @('Default', 'Asynchronous_filter'); defaultValue = @('Default', 'Asynchronous_filter') }
    B31_logAnalytics = @{ type = 'String'; metadata = @{ strongType = 'omsWorkspace'; assignPermissions = $true } }
    B06_isolationMode = @{ type = 'String'; allowedValues = @('AllowInternetOutbound', 'AllowOnlyApprovedOutbound', 'Disabled'); defaultValue = 'Disabled' }
    B29_requiredRetentionDays = @{ type = 'String'; defaultValue = '365' }
    B30_requiredRetentionDays = @{ type = 'String'; defaultValue = '365' }
    B42_excludedManagedByResourceProviders = @{ type = 'Array'; defaultValue = @() }
    B26_entityKind = @{ type = 'Array'; metadata = @{ displayName = 'Entity Kind' } }
    B27_entityKind = @{ type = 'Array'; metadata = @{ displayName = 'Entity Kind' } }
    B26_filterName = @{ type = 'String'; allowedValues = @('Profanity', 'Jailbreak'); metadata = @{ displayName = 'Content Filter' } }
    B27_filterName = @{ type = 'String'; allowedValues = @('Hate', 'Sexual', 'Violence', 'Selfharm'); defaultValue = 'Hate'; metadata = @{ displayName = 'Content Filter' } }
    B26_allowedEnabledForPrompt = @{ type = 'Array'; allowedValues = @('true', 'false'); defaultValue = @('true') }
    B27_allowedSeveritiesForPrompt = @{ type = 'Array'; allowedValues = @('Low', 'Medium', 'High'); defaultValue = @('Medium', 'High') }
}
$previousParameters = $retiredParameters | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable
$originalParametersJson = $previousParameters | ConvertTo-Json -Depth 100 -Compress
$upgradedInitiative = New-AuditInitiative -Scope $fixtureScope -Prefix 'test-ai' -Name 'Audit test' -CustomDefinitions $definitions -SelectedPolicies $selection -BuiltInDefinitions $fixtureBuiltIns -ExistingParameters $previousParameters
Confirm-Assertion (($previousParameters | ConvertTo-Json -Depth 100 -Compress) -eq $originalParametersJson) 'Compatibility migration must not mutate existing parameter schemas in memory.'
Confirm-Assertion (($upgradedInitiative.policyDefinitions | ConvertTo-Json -Depth 100 -Compress) -eq ($initiative.policyDefinitions | ConvertTo-Json -Depth 100 -Compress)) 'Retired parameters must not reintroduce removed references or change active bindings.'
foreach ($parameterName in $initiative.parameters.Keys) {
    Confirm-Assertion (($initiative.policyDefinitions | ConvertTo-Json -Depth 100 -Compress).Contains("[parameters('$parameterName')]")) "Fresh initiatives must not contain unused parameters: $parameterName"
}
foreach ($parameterName in $retiredParameters.Keys) {
    $retiredSchema = $upgradedInitiative.parameters[$parameterName]
    Confirm-Assertion ($retiredSchema.type -eq $retiredParameters[$parameterName].type) "Retired parameter type must stay compatible: $parameterName"
    Confirm-Assertion ($retiredSchema.Contains('defaultValue')) "Retired field must not require assignment input: $parameterName"
    Confirm-Assertion ($retiredSchema.metadata.displayName.StartsWith('Retired (not used):')) "Clearly label retired parameters: $parameterName"
    Confirm-Assertion (-not $retiredSchema.metadata.Contains('assignPermissions')) 'Retired parameters must not request permission assignments.'
    Confirm-Assertion (-not ($upgradedInitiative.policyDefinitions | ConvertTo-Json -Depth 100 -Compress).Contains("[parameters('$parameterName')]")) "Removed policy parameter remains bound: $parameterName"
}
foreach ($parameterName in @('allowedKinds', 'allowedDeploymentSkus', 'allowedSubnetIds', 'B26_entityKind', 'B27_entityKind')) {
    Confirm-Assertion (@($upgradedInitiative.parameters[$parameterName].defaultValue).Count -eq 0) 'Unused retired array parameters may have an empty default without affecting any active policy.'
}
$secondUpgrade = New-AuditInitiative -Scope $fixtureScope -Prefix 'test-ai' -Name 'Audit test' -CustomDefinitions $definitions -SelectedPolicies $selection -BuiltInDefinitions $fixtureBuiltIns -ExistingParameters $upgradedInitiative.parameters
Confirm-Assertion (($secondUpgrade.parameters | ConvertTo-Json -Depth 100 -Compress) -eq ($upgradedInitiative.parameters | ConvertTo-Json -Depth 100 -Compress)) 'Retired-parameter migration must be idempotent.'
$unexpectedRemovalRejected = $false
try {
    $null = New-AuditInitiative -Scope $fixtureScope -Prefix 'test-ai' -Name 'Audit test' -CustomDefinitions $definitions -SelectedPolicies $selection -BuiltInDefinitions $fixtureBuiltIns -ExistingParameters @{ unrelatedSavedParameter = @{ type = 'String'; defaultValue = 'keep' } }
}
catch {
    if ($_.Exception.Message -notlike 'Cannot remove saved initiative parameter:*') { throw }
    $unexpectedRemovalRejected = $true
}
Confirm-Assertion $unexpectedRemovalRejected 'Do not silently remove unrelated saved initiative parameters.'
Confirm-Assertion (@($initiative.policyDefinitions.policyDefinitionReferenceId | Sort-Object -Unique).Count -eq $initiative.policyDefinitions.Count) 'Duplicate initiative reference IDs.'
foreach ($reference in $initiative.policyDefinitions | Where-Object { $_.policyDefinitionId -notlike '/providers/Microsoft.Authorization/policyDefinitions/*' }) {
    Confirm-Assertion ($reference.policyDefinitionId.StartsWith("$fixtureScope/providers/Microsoft.Authorization/policyDefinitions/")) 'Custom policies must use the root management-group scope.'
}
Confirm-Assertion ($deploymentAst.Extent.Text -notmatch 'policyAssignments|New-AzPolicyAssignment|AssignmentParametersFile') 'Deployment script must not create assignments.'
$initiativeTags = @($initiative.policyDefinitions | Where-Object { $_.policyDefinitionReferenceId -like 'Tag_*' })
Confirm-Assertion ($initiativeTags.Count -eq 0) 'Tags are not among the six requested policies.'
foreach ($reference in $initiative.policyDefinitions) {
    foreach ($binding in $reference.parameters.GetEnumerator()) {
        if ($binding.Key -in @('effect', 'effects')) {
            Confirm-Assertion ($binding.Value.value -eq "[parameters('$($reference.policyDefinitionReferenceId)_effect')]") "Effect must be overridable at assignment: $($reference.policyDefinitionReferenceId)"
        }
    }
}
$builtInParameterLabels = @($initiative.parameters.Values | ForEach-Object { $_.metadata.displayName })
Confirm-Assertion (@($builtInParameterLabels | Sort-Object -Unique).Count -eq $builtInParameterLabels.Count) 'Built-in parameter labels must be distinguishable in the assignment form.'
Confirm-Assertion ($definitions.ContainsKey('allowed-ai-account-kinds') -and $definitions.ContainsKey('allowed-model-deployment-skus')) 'Removing allowlists from the baseline must not delete standalone policy files.'
Confirm-Assertion ($manifest.assignmentProfile.excludedReferences.Contains('B37')) 'The ineligible System Policy built-in must remain excluded.'
Confirm-Assertion (-not [string]::IsNullOrWhiteSpace($definitions['allowed-ai-account-kinds'].metadata.builtInReview.gap)) 'Retained custom account-kind policy needs its verified built-in gap.'
$systemPolicyRejected = $false
try {
    $systemDefinition = @{ metadata = @{ category = 'System Policy' }; policyRule = @{ then = @{ effect = 'audit' } }; parameters = @{} }
    $null = New-AuditReference -ReferenceId 'B37' -DefinitionId '/test/system-policy' -Definition $systemDefinition -Effect Audit -InitiativeParameters @{}
}
catch {
    if ($_.Exception.Message -notlike 'System Policy built-in*') { throw }
    $systemPolicyRejected = $true
}
Confirm-Assertion $systemPolicyRejected 'System Policy built-in must be rejected before publication.'
$rejected = $false
try {
    $null = New-AuditReference -ReferenceId 'invalid-effect' -DefinitionId '/test' -Definition $definitions['allowed-ai-locations'] -Effect Deny -InitiativeParameters @{}
}
catch {
    if ($_.Exception.Message -notlike 'Non-audit effect*') { throw }
    $rejected = $true
}
Confirm-Assertion $rejected 'Initiative generator accepted a Deny effect.'
$networkAliases = @(@('restrict-ai-public-ip-access', 'restrict-ai-virtual-network-rules') | ForEach-Object { Get-PolicyFields $definitions[$_].policyRule } | Sort-Object -Unique)
Confirm-Assertion ('Microsoft.Search/searchServices/networkRuleSet.ipRules[*].value' -in $networkAliases) 'Nested field-count alias not discovered.'
Confirm-Assertion ('Microsoft.CognitiveServices/accounts/networkAcls.virtualNetworkRules[*].id' -in $networkAliases) 'Subnet alias not discovered.'
Confirm-Assertion (-not $definitions.ContainsKey('restrict-ai-public-network-access')) 'The combined public-access policy must not be republished alongside its replacements.'
foreach ($binding in Get-FoundryBindings | Where-Object { $_.file -like 'require-foundry-*' -and $_.file -ne 'require-foundry-app-insights-connection' }) {
    $aliases = @(Get-PolicyFields $definitions[$binding.file].policyRule)
    Confirm-Assertion ('Microsoft.CognitiveServices/accounts/allowProjectManagement' -in $aliases) "Missing Foundry scope guard: $($binding.file)"
}

Write-Output "PASS: $($rows.Count) catalogue controls, $($manifest.policies.Count) documented built-ins, $($definitions.Count) retained custom definitions, and $script:ruleCaseCount rule cases."
Write-Output 'PASS: exactly 45 references (25 custom incl. 11 per-type system-assigned identity checks + 20 built-ins; defaults 38 Audit, 7 AuditIfNotExists), one optional effect override per policy and no other parameters, fixed hidden settings, compatible parameter retirement, and no assignments.'
Write-Output 'Local checks only: flattened field and already-scoped related-resource fixtures are not the Azure Policy engine. Live compliance, child enumeration, connection usability, and network behavior require validation after manual assignment.'