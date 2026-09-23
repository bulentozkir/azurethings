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

    foreach ($operator in @('equals', 'notEquals', 'in', 'notIn', 'greater', 'less', 'like')) {
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
$baselineReferences = @($manifest.policies | Where-Object { -not $manifest.assignmentProfile.excludedReferences.Contains($_.reference) })
Confirm-Assertion ($baselineReferences.Count -gt 0) 'No audit-capable baseline references selected.'
foreach ($reference in @('B04', 'B36', 'B38', 'B39', 'B40') + @(41..55 | ForEach-Object { "B$_" })) {
    Confirm-Assertion ($reference -in @($baselineReferences | ForEach-Object { $_.reference })) "Missing requested private-endpoint-existence audit: $reference"
}
foreach ($reference in @('B06', 'B07', 'B56', 'B57')) {
    Confirm-Assertion ($reference -in @($baselineReferences | ForEach-Object { $_.reference })) "Missing related AI network-isolation audit: $reference"
}
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
}
$definitionFiles = @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'definitions') -Filter '*.json' -File)
Confirm-Assertion ($definitionFiles.Count -eq $expectedModes.Count) 'Unexpected number of custom definitions.'
$definitions = @{}
foreach ($file in $definitionFiles) {
    $definition = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json -AsHashtable
    Confirm-Assertion ($expectedModes.ContainsKey($file.BaseName)) "Untested definition: $($file.Name)"
    Confirm-Assertion ($definition.policyType -eq 'Custom') "Not a custom definition: $($file.Name)"
    Confirm-Assertion ($definition.mode -eq $expectedModes[$file.BaseName]) "Incorrect evaluation mode: $($file.Name)"
    Confirm-Assertion ($definition.parameters.effect.defaultValue -eq 'Audit') "Unsafe default effect: $($file.Name)"
    Confirm-Assertion (@(Compare-Object @('Audit', 'Deny') @($definition.parameters.effect.allowedValues)).Count -eq 0) "Custom effect must support Audit and Deny: $($file.Name)"
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
    Confirm-Assertion ($reference.Value -in @($baselineReferences | ForEach-Object { $_.reference })) "Coverage table references an unselected built-in: $($reference.Value)"
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

$deploymentPath = Join-Path $PSScriptRoot 'Deploy-AiGovernance.ps1'
$deploymentTokens = $null
$deploymentErrors = $null
$deploymentAst = [System.Management.Automation.Language.Parser]::ParseFile($deploymentPath, [ref]$deploymentTokens, [ref]$deploymentErrors)
if ($deploymentErrors.Count -gt 0) {
    throw "Deployment script syntax errors: $(@($deploymentErrors | ForEach-Object { $_.Message }) -join '; ')"
}
foreach ($functionName in @('Get-AuditSelection', 'New-AuditReference', 'New-AuditInitiative', 'Get-PolicyFields')) {
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
    $effectParameter = if ($policy.Contains('effectParameter')) { $policy.effectParameter } else { 'effect' }
    $fixtureBuiltIns[$policy.reference] = @{
        displayName = $policy.displayName
        policyRule = @{ then = @{ effect = "[parameters('$effectParameter')]" } }
        parameters = @{
            $effectParameter = @{ type = 'String'; allowedValues = $policy.documentedEffects; defaultValue = 'Disabled' }
            testRequiredValue = @{ type = 'String'; metadata = @{ displayName = 'Required test value'; assignPermissions = $true } }
        }
    }
}
$fixtureBuiltIns.B43.parameters.effect = @{
    type = 'String'
    allowedValues = @('Audit', 'Deny', 'Disabled')
    defaultValue = 'Audit'
    metadata = @{ deprecated = $true }
}
$filterChoices = @{
    B22 = @('Profanity', 'Jailbreak', 'Indirect Attack', 'Indirect Attack Spotlighting')
    B23 = @('Profanity', 'Protected Material Code', 'Protected Material Text')
    B24 = @('Hate', 'Sexual', 'Violence', 'Selfharm')
    B26 = @('Profanity', 'Jailbreak', 'Indirect Attack', 'Indirect Attack Spotlighting')
    B27 = @('Hate', 'Sexual', 'Violence', 'Selfharm')
}
foreach ($referenceId in $filterChoices.Keys) {
    $fixtureBuiltIns[$referenceId].parameters.filterName = @{
        type = 'String'
        allowedValues = $filterChoices[$referenceId]
        metadata = @{ displayName = 'Content Filter'; description = 'Content filter name.' }
    }
}
foreach ($referenceId in @('B26', 'B27')) {
    $fixtureBuiltIns[$referenceId].parameters.entityKind = @{
        type = 'Array'
        metadata = @{ displayName = 'Entity Kind'; description = 'Entity kinds to assess.' }
    }
}
$fixtureScope = '/providers/Microsoft.Management/managementGroups/00000000-0000-0000-0000-000000000000'
$initiative = New-AuditInitiative -Scope $fixtureScope -Prefix 'test-ai' -Name 'Audit test' -CustomDefinitions $definitions -SelectedPolicies $selection -BuiltInDefinitions $fixtureBuiltIns
$keyVaultReference = $initiative.policyDefinitions | Where-Object { $_.policyDefinitionReferenceId -eq 'B43' } | Select-Object -First 1
Confirm-Assertion ($keyVaultReference.parameters.audit_effect.value -eq 'Audit') 'Key Vault active effect must be fixed to Audit.'
Confirm-Assertion ($keyVaultReference.parameters.effect.value -eq 'Audit') 'Key Vault deprecated effect must be fixed to Audit.'
Confirm-Assertion (-not $initiative.parameters.Contains('B43_effect')) 'Do not expose the deprecated Key Vault effect as an initiative parameter.'
$extraFilterReferences = ($filterChoices.Values | ForEach-Object { $_.Count - 1 } | Measure-Object -Sum).Sum
Confirm-Assertion ($initiative.policyDefinitions.Count -eq 16 + $selection.Count + $extraFilterReferences) 'Unexpected number of initiative references.'
foreach ($referenceId in $filterChoices.Keys) {
    $filterReferences = @($initiative.policyDefinitions | Where-Object { $_.policyDefinitionReferenceId -eq $referenceId -or $_.policyDefinitionReferenceId -like "${referenceId}_*" })
    Confirm-Assertion ($filterReferences.Count -eq $filterChoices[$referenceId].Count) "Missing expanded category for $referenceId"
    Confirm-Assertion (@(Compare-Object $filterChoices[$referenceId] @($filterReferences.parameters.filterName.value)).Count -eq 0) "Wrong filter coverage for $referenceId"
    $legacyName = "${referenceId}_filterName"
    Confirm-Assertion ($initiative.parameters[$legacyName].type -eq 'String') "Preserve the saved scalar parameter type for $legacyName"
    Confirm-Assertion ($initiative.parameters[$legacyName].Contains('defaultValue')) "Unused compatibility parameter must not require assignment input: $legacyName"
    Confirm-Assertion ($initiative.parameters[$legacyName].metadata.description -like '*Changing this value has no effect*') "Compatibility parameter behavior must be explicit: $legacyName"
    foreach ($reference in $filterReferences) {
        Confirm-Assertion ($reference.parameters.effect.value -eq 'Audit') "Expanded filter must remain fixed Audit: $($reference.policyDefinitionReferenceId)"
        Confirm-Assertion ($reference.parameters.testRequiredValue.value -eq "[parameters('${referenceId}_testRequiredValue')]") 'Expanded categories must share the original family parameters.'
    }
}
foreach ($referenceId in @('B26', 'B27')) {
    $entityParameter = $initiative.parameters["${referenceId}_entityKind"]
    Confirm-Assertion ($entityParameter.type -eq 'Array') 'Agent entity kinds must retain the built-in array contract.'
    Confirm-Assertion (-not $entityParameter.Contains('defaultValue')) 'Do not invent an agent-kind default that might skip all agents.'
    Confirm-Assertion ($entityParameter.metadata.description.Contains('[] assesses no agents')) 'Explain the empty agent-kind scope.'
    Confirm-Assertion ($entityParameter.metadata.description.Contains('["<entity-kind>"]')) 'Agent-kind help must show valid JSON array syntax.'
}
Confirm-Assertion (@($initiative.policyDefinitions.policyDefinitionReferenceId | Sort-Object -Unique).Count -eq $initiative.policyDefinitions.Count) 'Duplicate initiative reference IDs.'
foreach ($reference in $initiative.policyDefinitions | Where-Object { $_.policyDefinitionId -notlike '/providers/Microsoft.Authorization/policyDefinitions/*' }) {
    Confirm-Assertion ($reference.policyDefinitionId.StartsWith("$fixtureScope/providers/Microsoft.Authorization/policyDefinitions/")) 'Custom policies must use the root management-group scope.'
}
Confirm-Assertion ($deploymentAst.Extent.Text -notmatch 'policyAssignments|New-AzPolicyAssignment|AssignmentParametersFile') 'Deployment script must not create assignments.'
$initiativeTags = @($initiative.policyDefinitions | Where-Object { $_.policyDefinitionReferenceId -like 'Tag_*' })
Confirm-Assertion ($initiativeTags.Count -eq 7) 'Initiative must reference exactly the seven user-selected AI tags.'
foreach ($reference in $initiativeTags) {
    $tagName = $reference.parameters.tagName.value
    Confirm-Assertion ($reference.parameters.effect.value -eq 'Audit') "Non-audit tag reference: $tagName"
    Confirm-Assertion ($reference.parameters.resourceTypes.value -eq "[parameters('tagResourceTypes')]") "Tag resource scope not shared: $tagName"
    if ($tagName -eq 'ai-workload') {
        Confirm-Assertion (-not $reference.parameters.Contains('allowedTagValues')) 'Workload identifiers must remain free-form.'
    }
    else {
        Confirm-Assertion ($tagValues.Contains($tagName)) "Unexpected initiative tag: $tagName"
        Confirm-Assertion (@(Compare-Object @($tagValues[$tagName]) @($reference.parameters.allowedTagValues.value)).Count -eq 0) "Wrong vocabulary for $tagName"
    }
}
foreach ($reference in $initiative.policyDefinitions) {
    foreach ($binding in $reference.parameters.GetEnumerator()) {
        if ($binding.Key -in @('effect', 'effects')) {
            Confirm-Assertion ($binding.Value.value -in @('Audit', 'AuditIfNotExists')) "Mutable or non-audit initiative effect: $($reference.policyDefinitionReferenceId)"
        }
    }
}
foreach ($parameterName in @('allowedLocations', 'allowedKinds', 'allowedDeploymentSkus', 'allowedIpRules', 'allowedSubnetIds')) {
    Confirm-Assertion ($initiative.parameters.Contains($parameterName)) "Missing customer parameter: $parameterName"
    Confirm-Assertion (-not $initiative.parameters[$parameterName].Contains('defaultValue')) "Customer allowlist must not be invented: $parameterName"
}
foreach ($policy in $selection) {
    $parameterName = "$($policy.reference)_testRequiredValue"
    Confirm-Assertion ($initiative.parameters.Contains($parameterName)) "Built-in parameter not lifted: $parameterName"
    Confirm-Assertion (-not $initiative.parameters[$parameterName].metadata.Contains('assignPermissions')) 'Audit assignment must not request automatic role assignment.'
    Confirm-Assertion ($initiative.parameters[$parameterName].metadata.displayName -like "*($($policy.reference))") "Built-in parameter label must identify its policy: $parameterName"
}
$builtInParameterLabels = @($initiative.parameters.GetEnumerator() | Where-Object { $_.Key -match '^B\d+_' } | ForEach-Object { $_.Value.metadata.displayName })
Confirm-Assertion (@($builtInParameterLabels | Sort-Object -Unique).Count -eq $builtInParameterLabels.Count) 'Built-in parameter labels must be distinguishable in the assignment form.'
$kindReference = $initiative.policyDefinitions | Where-Object { $_.policyDefinitionReferenceId -eq 'AI_AccountKinds' } | Select-Object -First 1
Confirm-Assertion ($kindReference.policyDefinitionId -eq "$fixtureScope/providers/Microsoft.Authorization/policyDefinitions/test-ai-allowed-ai-account-kinds") 'Account-kind audit requires a custom rule because the System Policy built-in is ineligible.'
Confirm-Assertion ($kindReference.parameters.allowedKinds.value -eq "[parameters('allowedKinds')]") 'Existing account-kind assignment parameter must be preserved.'
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
foreach ($referenceId in @('AI_PublicIPs', 'AI_VirtualNetworkRules', 'AI_TrustedServices', 'AI_PrivateEndpoints', 'AI_MonitorPrivateLinkScope', 'AI_FoundryVnetInjection')) {
    $reference = $initiative.policyDefinitions | Where-Object { $_.policyDefinitionReferenceId -eq $referenceId } | Select-Object -First 1
    Confirm-Assertion ($null -ne $reference -and $reference.parameters.effect.value -eq 'Audit') "Missing audit-only network reference: $referenceId"
}
Confirm-Assertion ($initiative.parameters.allowTrustedServices.defaultValue -eq $false) 'Trusted-service bypass must remain unapproved by default.'

Write-Output "PASS: $($rows.Count) controls, $($manifest.policies.Count) built-in references ($($baselineReferences.Count) audit-baseline candidates), $($definitions.Count) Audit/Deny custom definitions defaulting to Audit, and $script:ruleCaseCount rule cases."
Write-Output 'PASS: deployment script syntax, initiative generation, seven tag mappings, customer parameters, and fixed audit effects.'
Write-Output 'Local checks only: fixture aliases are flattened inputs, not provider evaluation. Azure deployment, alias availability, API defaults, and live network behavior are not validated.'