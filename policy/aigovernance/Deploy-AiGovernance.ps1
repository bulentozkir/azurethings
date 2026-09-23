#requires -Version 7.0
#requires -Modules Az.Accounts

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [guid]$TenantId,

    [Parameter(Mandatory)]
    [guid]$SubscriptionId,

    [ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9-]{0,19}$')]
    [string]$DefinitionPrefix = 'ai-gov',

    [ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9-]{0,63}$')]
    [string]$InitiativeName = 'ai-governance-audit',

    [ValidateNotNullOrEmpty()]
    [string]$DisplayName = 'Azure AI Governance - Audit Only',

    [string[]]$ExcludeBuiltInReference = @(),

    [switch]$UseDeviceAuthentication,

    [switch]$SkipLogin
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-AuditSelection {
    param([System.Collections.IDictionary]$Manifest)

    if ($Manifest.assignmentProfile.mode -ne 'AuditOnly' -or
        @(Compare-Object @('Audit', 'AuditIfNotExists') @($Manifest.assignmentProfile.permittedEffects)).Count -ne 0) {
        throw 'The manifest must permit only Audit and AuditIfNotExists.'
    }
    foreach ($policy in $Manifest.policies) {
        if ($Manifest.assignmentProfile.excludedReferences.Contains($policy.reference)) {
            continue
        }
        if ($policy.recommendedInitialEffect -notin @('Audit', 'AuditIfNotExists') -or
            $policy.recommendedInitialEffect -notin $policy.documentedEffects) {
            throw "No supported audit effect selected for $($policy.reference)."
        }
        $policy
    }
}

function New-AuditReference {
    param(
        [string]$ReferenceId,
        [string]$DefinitionId,
        [System.Collections.IDictionary]$Definition,
        [string]$Effect,
        [System.Collections.IDictionary]$InitiativeParameters,
        [System.Collections.IDictionary]$FixedParameters = @{},
        [System.Collections.IDictionary]$ParameterNames = @{}
    )

    if ($Effect -notin @('Audit', 'AuditIfNotExists')) {
        throw "Non-audit effect for ${ReferenceId}: $Effect"
    }
    if ($Definition.Contains('metadata') -and $Definition.metadata -is [System.Collections.IDictionary] -and
        $Definition.metadata.Contains('category') -and $Definition.metadata.category -eq 'System Policy') {
        throw "System Policy built-in $ReferenceId is not eligible for this custom initiative. Review an assignable alternative or document the custom-policy gap."
    }
    $effectExpression = $Definition.policyRule.then.effect
    $effectParameter = $null
    if ($effectExpression -match "^\[parameters\('([^']+)'\)\]$") {
        $effectParameter = $Matches[1]
        if (-not $Definition.parameters.Contains($effectParameter) -or
            $Effect -notin $Definition.parameters[$effectParameter].allowedValues) {
            throw "The live definition does not support $Effect for $ReferenceId."
        }
    }
    elseif ($effectExpression -ne $Effect) {
        throw "Cannot prove an audit-only effect for $ReferenceId."
    }
    $policyParameters = if ($Definition.Contains('parameters')) { $Definition.parameters } else { @{} }
    $bindings = [ordered]@{}
    foreach ($parameterName in $FixedParameters.Keys) {
        if (-not $policyParameters.Contains($parameterName) -or $parameterName -eq $effectParameter) {
            throw "Invalid fixed parameter for ${ReferenceId}: $parameterName"
        }
    }
    foreach ($entry in $policyParameters.GetEnumerator()) {
        $parameterName = $entry.Key
        if ($parameterName -eq $effectParameter) {
            $bindings[$parameterName] = @{ value = $Effect }
        }
        elseif ($FixedParameters.Contains($parameterName)) {
            $bindings[$parameterName] = @{ value = $FixedParameters[$parameterName] }
        }
        else {
            $initiativeParameterName = if ($ParameterNames.Contains($parameterName)) {
                $ParameterNames[$parameterName]
            }
            else {
                "${ReferenceId}_$parameterName"
            }
            $parameterSchema = $entry.Value | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable
            if (-not $parameterSchema.Contains('metadata')) {
                $parameterSchema.metadata = @{}
            }
            $parameterSchema.metadata.Remove('assignPermissions')
            if ($DefinitionId.StartsWith('/providers/Microsoft.Authorization/policyDefinitions/')) {
                $parameterContextId = ($ReferenceId -split '_', 2)[0]
                $parameterLabel = if ($parameterSchema.metadata.Contains('displayName')) { $parameterSchema.metadata.displayName } else { $parameterName }
                $policyLabel = switch ($parameterContextId) {
                    'B18' { 'Foundry models: approved publishers and assets' }
                    'B19' { 'Foundry models: deployment eligibility' }
                    'B20' { 'ML deployments: approved registry models' }
                    'B22' { 'Model deployments: prompt filters' }
                    'B23' { 'Model deployments: response filters' }
                    'B24' { 'Model deployments: harmful-content controls' }
                    'B25' { 'Model deployments: streaming filter mode' }
                    'B26' { 'Agents: prompt filters' }
                    'B27' { 'Agents: harmful-content controls' }
                    'B31' { 'AI diagnostic logs: destination and categories' }
                    'B42' { 'Storage private endpoints: managed-service exclusions' }
                    default { if ($Definition.Contains('displayName')) { $Definition.displayName -replace '^\[Preview\]:\s*', '' } else { $parameterContextId } }
                }
                $parameterSchema.metadata.displayName = "$policyLabel - $parameterLabel ($parameterContextId)"
                if ($parameterName -eq 'entityKind') {
                    $parameterSchema.metadata.displayName = "$policyLabel - Agent entity kinds to assess, JSON array ($parameterContextId)"
                    $parameterSchema.metadata.description = 'Required targeting input from the Microsoft built-in. Enter the exact entityKind values used by your agents, not AIServices/OpenAI account kinds or ARM resource types. This built-in supplies neither allowedValues nor a default. Only listed kinds are assessed; [] assesses no agents and "*" is not a wildcard. Replace the placeholder in ["<entity-kind>"] with a verified agent value.'
                }
            }
            if ($parameterSchema.type -eq 'Array') {
                $arrayHelp = if ($parameterSchema.Contains('allowedValues')) {
                    $example = ConvertTo-Json -InputObject @($parameterSchema.allowedValues | Select-Object -First 1) -Compress -Depth 10
                    "Select one or more listed values. In the custom-array editor, use JSON array syntax, for example $example. Quoted values are strings, not JSON booleans."
                }
                else {
                    'Use the custom-array editor (...) and enter a JSON array with double-quoted string items, not plain text or a comma-separated string.'
                }
                $originalDescription = if ($parameterSchema.metadata.Contains('description')) { $parameterSchema.metadata.description } else { '' }
                $parameterSchema.metadata.description = "$originalDescription $arrayHelp".Trim()
            }
            switch ($initiativeParameterName) {
                'allowedLocations' { $parameterSchema.metadata.description = 'ARM resource locations to regard as compliant. JSON example: ["westeurope","northeurope"]. Replace with approved regions; include "global" only when explicitly approved. These are examples, not defaults.' }
                'allowedKinds' { $parameterSchema.metadata.description = 'Cognitive Services account kinds to regard as compliant, including Foundry/OpenAI as applicable. JSON example: ["AIServices","OpenAI"]. These are account kinds, not the agent entity kinds below. Supply your approved list.' }
                'allowedDeploymentSkus' { $parameterSchema.metadata.description = 'Allowed Cognitive Services model deployment SKU names, not VM sizes. JSON example: ["Standard","DataZoneStandard"]. Choose the approved processing geography and SKUs for your organization; examples are not defaults.' }
                'allowedIpRules' { $parameterSchema.metadata.description = 'Exact approved public IPv4 address/CIDR rule strings for Cognitive Services, Search, and ML workspaces. JSON format example: ["203.0.113.10","198.51.100.0/24"]. Replace these documentation addresses with real approved egress addresses. [] approves no IP exceptions. CIDR containment is not inferred.' }
                'allowedSubnetIds' { $parameterSchema.metadata.description = 'Full approved subnet ARM IDs for Cognitive Services inbound VNet rules, including applicable Foundry/OpenAI accounts. JSON format: ["/subscriptions/<subscription-id>/resourceGroups/<resource-group>/providers/Microsoft.Network/virtualNetworks/<vnet>/subnets/<subnet>"]. [] approves no subnet exceptions. This is not Foundry agent VNet injection or private endpoint configuration.' }
                'B31_logAnalytics' { $parameterSchema.metadata.description = 'Expected Log Analytics destination for Cognitive Services diagnostic logs. Select a workspace or supply its full ARM ID: /subscriptions/<subscription-id>/resourceGroups/<resource-group>/providers/Microsoft.OperationalInsights/workspaces/<workspace>. This policy only audits; it does not create a workspace or diagnostic settings.' }
            }
            if (-not $InitiativeParameters.Contains($initiativeParameterName)) {
                $InitiativeParameters[$initiativeParameterName] = $parameterSchema
            }
            elseif (($InitiativeParameters[$initiativeParameterName] | ConvertTo-Json -Depth 100 -Compress) -ne
                ($parameterSchema | ConvertTo-Json -Depth 100 -Compress)) {
                throw "Conflicting schemas for shared initiative parameter $initiativeParameterName."
            }
            $bindings[$parameterName] = @{ value = "[parameters('$initiativeParameterName')]" }
        }
    }
    return [ordered]@{
        policyDefinitionReferenceId = $ReferenceId
        policyDefinitionId = $DefinitionId
        parameters = $bindings
    }
}

function New-AuditInitiative {
    param(
        [string]$Scope,
        [string]$Prefix,
        [string]$Name,
        [System.Collections.IDictionary]$CustomDefinitions,
        [object[]]$SelectedPolicies,
        [System.Collections.IDictionary]$BuiltInDefinitions
    )

    $initiativeParameters = [ordered]@{}
    $references = [System.Collections.Generic.List[object]]::new()
    $customBindings = @(
        @{ file = 'allowed-ai-locations'; reference = 'AI_Locations'; names = @{ allowedLocations = 'allowedLocations'; resourceTypes = 'locationResourceTypes' } },
        @{ file = 'allowed-ai-account-kinds'; reference = 'AI_AccountKinds'; names = @{ allowedKinds = 'allowedKinds' } },
        @{ file = 'allowed-model-deployment-skus'; reference = 'AI_DeploymentSkus'; names = @{ allowedDeploymentSkus = 'allowedDeploymentSkus' } },
        @{ file = 'restrict-ai-public-ip-access'; reference = 'AI_PublicIPs'; names = @{ allowedIpRules = 'allowedIpRules' } },
        @{ file = 'restrict-ai-virtual-network-rules'; reference = 'AI_VirtualNetworkRules'; names = @{ allowedSubnetIds = 'allowedSubnetIds' } },
        @{ file = 'restrict-ai-trusted-services'; reference = 'AI_TrustedServices'; names = @{ allowTrustedServices = 'allowTrustedServices' } },
        @{ file = 'require-ai-private-endpoints'; reference = 'AI_PrivateEndpoints'; names = @{} },
        @{ file = 'require-ai-monitor-private-link-scope'; reference = 'AI_MonitorPrivateLinkScope'; names = @{} },
        @{ file = 'require-foundry-vnet-injection'; reference = 'AI_FoundryVnetInjection'; names = @{} }
    )
    foreach ($binding in $customBindings) {
        if (-not $CustomDefinitions.Contains($binding.file)) { throw "Missing custom definition: $($binding.file)" }
        $reference = New-AuditReference -ReferenceId $binding.reference -DefinitionId "$Scope/providers/Microsoft.Authorization/policyDefinitions/$Prefix-$($binding.file)" -Definition $CustomDefinitions[$binding.file] -Effect Audit -InitiativeParameters $initiativeParameters -ParameterNames $binding.names
        $references.Add($reference)
    }
    $tagValues = [ordered]@{
        'ai-role' = @('model', 'search', 'data', 'app', 'gateway')
        'ai-usage' = @('inference', 'training', 'fine-tuning', 'mixed')
        'ai-audience' = @('internal', 'customer', 'public', 'mixed')
        'ai-sharing' = @('dedicated', 'shared')
        'ai-autonomy' = @('read-only', 'approval-required', 'autonomous')
        'ai-risk' = @('low', 'medium', 'high')
    }
    foreach ($tagName in @('ai-workload') + @($tagValues.Keys)) {
        $fileName = if ($tagName -eq 'ai-workload') { 'require-ai-tag' } else { 'allowed-ai-tag-values' }
        if (-not $CustomDefinitions.Contains($fileName)) { throw "Missing custom definition: $fileName" }
        $fixedParameters = @{ tagName = $tagName }
        if ($tagValues.Contains($tagName)) { $fixedParameters.allowedTagValues = $tagValues[$tagName] }
        $reference = New-AuditReference -ReferenceId "Tag_$tagName" -DefinitionId "$Scope/providers/Microsoft.Authorization/policyDefinitions/$Prefix-$fileName" -Definition $CustomDefinitions[$fileName] -Effect Audit -InitiativeParameters $initiativeParameters -FixedParameters $fixedParameters -ParameterNames @{ resourceTypes = 'tagResourceTypes' }
        $references.Add($reference)
    }
    foreach ($policy in $SelectedPolicies) {
        if (-not $BuiltInDefinitions.Contains($policy.reference)) {
            throw "Missing live built-in: $($policy.reference). No definitions will be published."
        }
        $fixedParameters = if ($policy.Contains('fixedParameters')) { $policy.fixedParameters } else { @{} }
        $definition = $BuiltInDefinitions[$policy.reference]
        if ($policy.Contains('expandByParameter')) {
            $expandedParameter = $policy.expandByParameter
            if (-not $definition.parameters.Contains($expandedParameter) -or
                $definition.parameters[$expandedParameter].type -ne 'String' -or
                -not $definition.parameters[$expandedParameter].Contains('allowedValues') -or
                @($definition.parameters[$expandedParameter].allowedValues).Count -eq 0) {
                throw "Cannot expand $($policy.reference): expected a String parameter with nonempty allowedValues: $expandedParameter"
            }
            $filterValues = @($definition.parameters[$expandedParameter].allowedValues)
            $parameterNames = @{}
            foreach ($parameterName in $definition.parameters.Keys) {
                $parameterNames[$parameterName] = "$($policy.reference)_$parameterName"
            }
            $legacyParameter = $definition.parameters[$expandedParameter] | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable
            $legacyParameter.defaultValue = $filterValues[0]
            $legacyParameter.metadata = @{
                displayName = "Compatibility only: former single-filter selection ($($policy.reference))"
                description = "Unused compatibility field retained because saved initiative parameters cannot be deleted. Every category is now audited independently: $($filterValues -join ', '). Changing this value has no effect. Keep the default."
            }
            $initiativeParameters[$parameterNames[$expandedParameter]] = $legacyParameter
            for ($filterIndex = 0; $filterIndex -lt $filterValues.Count; $filterIndex++) {
                $filterValue = $filterValues[$filterIndex]
                $referenceId = if ($filterIndex -eq 0) { $policy.reference } else { "$($policy.reference)_$($filterValue -replace '[^a-zA-Z0-9]', '')" }
                $filterParameters = @{}
                foreach ($entry in $fixedParameters.GetEnumerator()) { $filterParameters[$entry.Key] = $entry.Value }
                $filterParameters[$expandedParameter] = $filterValue
                $reference = New-AuditReference -ReferenceId $referenceId -DefinitionId $policy.policyDefinitionId -Definition $definition -Effect $policy.recommendedInitialEffect -InitiativeParameters $initiativeParameters -FixedParameters $filterParameters -ParameterNames $parameterNames
                $references.Add($reference)
            }
        }
        else {
            $reference = New-AuditReference -ReferenceId $policy.reference -DefinitionId $policy.policyDefinitionId -Definition $definition -Effect $policy.recommendedInitialEffect -InitiativeParameters $initiativeParameters -FixedParameters $fixedParameters
            $references.Add($reference)
        }
    }
    if (@($references.policyDefinitionReferenceId | Sort-Object -Unique).Count -ne $references.Count) {
        throw 'The generated initiative contains duplicate reference IDs.'
    }
    if ($initiativeParameters.Count -gt 400 -or $references.Count -gt 1000) {
        throw 'The generated initiative exceeds Azure Policy limits.'
    }
    return [ordered]@{
        displayName = $Name
        description = 'Audit-only AI governance, approved-source networking, and seven AI tags. No resource remediation or automatic enforcement. Customer-specific values are supplied at assignment time.'
        policyType = 'Custom'
        metadata = @{
            category = 'AI Governance'
            version = '1.1.0'
            managedBy = 'azurethings-ai-governance'
            auditOnly = $true
            contentFilterCoverage = 'AllSupportedCategories'
        }
        parameters = $initiativeParameters
        policyDefinitions = $references.ToArray()
    }
}

function Invoke-PolicyRequest {
    param(
        [ValidateSet('GET', 'PUT')][string]$Method,
        [string]$Path,
        [System.Collections.IDictionary]$Body,
        [switch]$AllowNotFound
    )

    $requestParameters = @{
        Method = $Method
        Path = $Path
        DefaultProfile = $context
        ErrorAction = 'Stop'
    }
    if ($Method -eq 'GET') { $requestParameters.WhatIf = $false }
    if ($null -ne $Body) { $requestParameters.Payload = $Body | ConvertTo-Json -Depth 100 -Compress }
    $response = Invoke-AzRestMethod @requestParameters
    if ($AllowNotFound -and [int]$response.StatusCode -eq 404) { return $null }
    if ([int]$response.StatusCode -notin @(200, 201)) {
        throw "Azure $Method $Path failed ($($response.StatusCode)): $($response.Content)"
    }
    if (-not [string]::IsNullOrWhiteSpace($response.Content)) {
        return ($response.Content | ConvertFrom-Json -AsHashtable)
    }
}

function Get-PolicyFields {
    param([AllowNull()][object]$Node)

    if ($Node -is [System.Collections.IDictionary]) {
        if ($Node.Contains('count') -and $Node['count'].Contains('field') -and -not $Node['count']['field'].EndsWith('[*]')) {
            throw "count.field must be an array alias ending in [*]: $($Node['count']['field'])"
        }
        if ($Node.Contains('field') -and $Node['field'] -match '^Microsoft\.[^/]+/') { $Node['field'] }
        foreach ($value in $Node.Values) { Get-PolicyFields $value }
    }
    elseif ($Node -is [array]) {
        foreach ($value in $Node) { Get-PolicyFields $value }
    }
}

function Confirm-ManagedResource {
    param([string]$ResourceId)

    $existing = Invoke-PolicyRequest -Method GET -Path "${ResourceId}?api-version=2023-04-01" -AllowNotFound
    if ($null -ne $existing -and
        (-not $existing.properties.Contains('metadata') -or
            -not $existing.properties.metadata.Contains('managedBy') -or
            $existing.properties.metadata.managedBy -ne 'azurethings-ai-governance')) {
        throw "Refusing to overwrite an unrelated resource: $ResourceId. Choose a different name/prefix."
    }
}

$manifest = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'built-in-references.json') -Raw | ConvertFrom-Json -AsHashtable
$candidates = @(Get-AuditSelection -Manifest $manifest)
foreach ($reference in $ExcludeBuiltInReference) {
    if ($reference -notin @($candidates | ForEach-Object { $_.reference })) { throw "Unknown audit-baseline reference: $reference" }
}
$selectedPolicies = @($candidates | Where-Object { $_.reference -notin $ExcludeBuiltInReference })
$customDefinitions = [ordered]@{}
foreach ($file in Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'definitions') -Filter '*.json' -File | Sort-Object Name) {
    $definition = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json -AsHashtable
    if ($definition.policyType -ne 'Custom' -or $definition.parameters.effect.defaultValue -ne 'Audit' -or
        @(Compare-Object @('Audit', 'Deny') @($definition.parameters.effect.allowedValues)).Count -ne 0 -or
        $definition.policyRule.then.effect -ne "[parameters('effect')]") {
        throw "Custom definition must support Audit/Deny with Audit as its default: $($file.Name)"
    }
    $definition.metadata.managedBy = 'azurethings-ai-governance'
    $definition.metadata.Remove('auditOnly')
    $definition.metadata.defaultEffect = 'Audit'
    $customDefinitions[$file.BaseName] = $definition
}
$context = Get-AzContext -ErrorAction SilentlyContinue
if ($null -eq $context -or $context.Tenant.Id -ne $TenantId.ToString() -or $context.Subscription.Id -ne $SubscriptionId.ToString()) {
    if ($SkipLogin) {
        throw 'The active Az context does not match TenantId and SubscriptionId. Sign in to the target or omit SkipLogin.'
    }
    $loginParameters = @{
        Tenant = $TenantId.ToString()
        Subscription = $SubscriptionId.ToString()
        Scope = 'Process'
        ErrorAction = 'Stop'
    }
    if ($UseDeviceAuthentication) {
        $loginParameters.UseDeviceAuthentication = $true
    }
    $null = Connect-AzAccount @loginParameters
    $context = Get-AzContext -ErrorAction Stop
}
if ($null -eq $context -or $context.Tenant.Id -ne $TenantId.ToString() -or $context.Subscription.Id -ne $SubscriptionId.ToString()) {
    throw 'Azure authentication did not select the requested tenant and subscription.'
}

Write-Host "Target verified: tenant $TenantId; subscription $SubscriptionId."
$subscriptionScope = "/subscriptions/$SubscriptionId"
$scope = "/providers/Microsoft.Management/managementGroups/$TenantId"
$rootGroup = Invoke-PolicyRequest -Method GET -Path "${scope}?api-version=2020-05-01"
if ($rootGroup.id -ne $scope -or $rootGroup.properties.tenantId -ne $TenantId.ToString() -or
    ($rootGroup.properties.Contains('details') -and $rootGroup.properties.details.Contains('parent') -and
        $null -ne $rootGroup.properties.details.parent -and
        -not [string]::IsNullOrWhiteSpace($rootGroup.properties.details.parent['id']))) {
    throw 'The requested management group is not the verified tenant root. No writes performed.'
}
Write-Host "Definition scope: $scope ($($rootGroup.properties.displayName)). No assignment will be created."
$initiativeId = "$scope/providers/Microsoft.Authorization/policySetDefinitions/$InitiativeName"
$builtInDefinitions = @{}
$missingBuiltIns = [System.Collections.Generic.List[string]]::new()
foreach ($policy in $selectedPolicies) {
    $liveDefinition = Invoke-PolicyRequest -Method GET -Path "$($policy.policyDefinitionId)?api-version=2023-04-01" -AllowNotFound
    if ($null -eq $liveDefinition) {
        $missingBuiltIns.Add($policy.reference)
    }
    else {
        $builtInDefinitions[$policy.reference] = $liveDefinition.properties
    }
}
if ($missingBuiltIns.Count) {
    throw "Unavailable built-ins: $($missingBuiltIns -join ', '). No writes performed. Review the IDs or explicitly supply ExcludeBuiltInReference after accepting the coverage gap."
}

$fields = @($customDefinitions.Values | ForEach-Object { Get-PolicyFields $_.policyRule } | Sort-Object -Unique)
foreach ($providerName in @($fields | ForEach-Object { $_.Split('/')[0] } | Sort-Object -Unique)) {
    $provider = Invoke-PolicyRequest -Method GET -Path "$subscriptionScope/providers/${providerName}?api-version=2021-04-01&`$expand=resourceTypes/aliases"
    $aliases = @($provider.resourceTypes | Where-Object { $_.Contains('aliases') } | ForEach-Object { $_.aliases } | ForEach-Object { $_.name })
    foreach ($field in $fields | Where-Object { $_.StartsWith("$providerName/") }) {
        if ($field -notin $aliases) { throw "Azure Policy alias unavailable in the target: $field. No writes performed." }
    }
}
$initiative = New-AuditInitiative -Scope $scope -Prefix $DefinitionPrefix -Name $DisplayName -CustomDefinitions $customDefinitions -SelectedPolicies $selectedPolicies -BuiltInDefinitions $builtInDefinitions
$initiative.metadata.excludedBuiltInReferences = @($manifest.assignmentProfile.excludedReferences.Keys) + @($ExcludeBuiltInReference)
foreach ($fileName in $customDefinitions.Keys) {
    Confirm-ManagedResource "$scope/providers/Microsoft.Authorization/policyDefinitions/$DefinitionPrefix-$fileName"
}
Confirm-ManagedResource $initiativeId

$parameterSummary = @($initiative.parameters.GetEnumerator() | ForEach-Object {
    [pscustomobject]@{ Name = $_.Key; Type = $_.Value.type; Required = -not $_.Value.Contains('defaultValue') }
})
Write-Host "Preflight passed: $($customDefinitions.Count) custom definitions; $($initiative.policyDefinitions.Count) initiative references; $($selectedPolicies.Count) built-ins."
$published = $false
if ($PSCmdlet.ShouldProcess($scope, "Publish $InitiativeName and its custom audit definitions; no assignment")) {
    foreach ($entry in $customDefinitions.GetEnumerator()) {
        $definitionId = "$scope/providers/Microsoft.Authorization/policyDefinitions/$DefinitionPrefix-$($entry.Key)"
        $null = Invoke-PolicyRequest -Method PUT -Path "${definitionId}?api-version=2023-04-01" -Body @{ properties = $entry.Value }
        $verified = Invoke-PolicyRequest -Method GET -Path "${definitionId}?api-version=2023-04-01"
        if ($verified.properties.policyRule.then.effect -ne "[parameters('effect')]" -or
            $verified.properties.parameters.effect.defaultValue -ne 'Audit' -or
            @(Compare-Object @('Audit', 'Deny') @($verified.properties.parameters.effect.allowedValues)).Count -ne 0) {
            throw "Published definition failed effect/default verification: $definitionId"
        }
    }
    $null = Invoke-PolicyRequest -Method PUT -Path "${initiativeId}?api-version=2023-04-01" -Body @{ properties = $initiative }
    $verified = Invoke-PolicyRequest -Method GET -Path "${initiativeId}?api-version=2023-04-01"
    if ($verified.properties.policyDefinitions.Count -ne $initiative.policyDefinitions.Count) {
        throw 'Published initiative reference count does not match the requested definition.'
    }
    foreach ($expectedReference in $initiative.policyDefinitions) {
        $actualReference = $verified.properties.policyDefinitions | Where-Object { $_.policyDefinitionReferenceId -eq $expectedReference.policyDefinitionReferenceId } | Select-Object -First 1
        if ($null -eq $actualReference -or $actualReference.policyDefinitionId -ne $expectedReference.policyDefinitionId -or
            ($actualReference.parameters | ConvertTo-Json -Depth 100 -Compress) -ne ($expectedReference.parameters | ConvertTo-Json -Depth 100 -Compress)) {
            throw "Published initiative binding mismatch: $($expectedReference.policyDefinitionReferenceId)"
        }
    }
    $published = $true
}

[pscustomobject]@{
    Published = $published
    TenantId = $TenantId.ToString()
    SubscriptionId = $SubscriptionId.ToString()
    DefinitionScope = $scope
    InitiativeId = $initiativeId
    CustomDefinitionCount = $customDefinitions.Count
    PolicyReferenceCount = $initiative.policyDefinitions.Count
    BuiltInCount = $selectedPolicies.Count
    AssignmentCreated = $false
    AssignmentParameters = $parameterSummary
    ExcludedBuiltInReferences = $initiative.metadata.excludedBuiltInReferences
}