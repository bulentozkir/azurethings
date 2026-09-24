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
    [string]$DisplayName = 'Microsoft Foundry, Azure ML and AI Services - Audit Controls',

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
    if ($Manifest.assignmentProfile.baseline -ne 'AIPlatformAudit' -or
        @(Compare-Object (Get-ExpectedBuiltIns) @($Manifest.assignmentProfile.includedReferences)).Count -ne 0) {
        throw 'The profile must select exactly the built-ins returned by Get-ExpectedBuiltIns.'
    }
    foreach ($policy in $Manifest.policies) {
        if ($policy.reference -notin $Manifest.assignmentProfile.includedReferences) {
            continue
        }
        if ($Manifest.assignmentProfile.excludedReferences.Contains($policy.reference)) {
            throw "Selected Foundry policy is also excluded: $($policy.reference)."
        }
        if ($policy.recommendedInitialEffect -notin @('Audit', 'AuditIfNotExists') -or
            $policy.recommendedInitialEffect -notin $policy.documentedEffects) {
            throw "No supported audit effect selected for $($policy.reference)."
        }
        $policy
    }
}

function Get-ExpectedBuiltIns {
    @(
        'B06', 'B07', 'B10', 'B12', 'B16', 'B29', 'B32', 'B35', 'B36',
        'B01', 'B04', 'B05', 'B11', 'B14', 'B17', 'B28', 'B33', 'B38', 'B39', 'B70', 'B71', 'B72', 'B73', 'B74', 'B30', 'B19'
    )
}

function Get-FoundryBindings {
    @(
        @{ file = 'require-foundry-trusted-services'; reference = 'Foundry_TrustedServices'; effect = 'Audit' },
        @{ file = 'require-foundry-private-endpoint'; reference = 'Foundry_PrivateEndpoint'; effect = 'Audit' },
        @{ file = 'require-foundry-vnet-injection'; reference = 'AI_FoundryVnetInjection'; effect = 'Audit' },
        @{ file = 'require-foundry-key-vault-connection'; reference = 'Foundry_KeyVault'; effect = 'AuditIfNotExists' },
        @{ file = 'require-foundry-app-insights-connection'; reference = 'Foundry_AppInsights'; effect = 'AuditIfNotExists' },
        @{ file = 'require-ai-system-assigned-identity'; reference = 'AI_SystemAssignedIdentity'; effect = 'Audit' },
        @{ file = 'require-ai-deployment-content-filter'; reference = 'AI_DeploymentContentFilter'; effect = 'Audit' },
        @{ file = 'require-ml-endpoint-entra-auth'; reference = 'ML_EndpointEntraAuth'; effect = 'Audit' }
    )
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
            $overrideName = "${ReferenceId}_effect"
            if ($InitiativeParameters.Contains($overrideName)) {
                throw "Duplicate effect override parameter: $overrideName"
            }
            $allowedEffects = @($entry.Value.allowedValues)
            $defaultEffect = $allowedEffects | Where-Object { $_ -eq $Effect } | Select-Object -First 1
            $policyLabel = if ($Definition.Contains('displayName')) { $Definition.displayName -replace '^\[Preview\]:\s*', '' } else { $ReferenceId }
            $InitiativeParameters[$overrideName] = [ordered]@{
                type = 'String'
                allowedValues = $allowedEffects
                defaultValue = $defaultEffect
                metadata = [ordered]@{
                    displayName = "Effect: $policyLabel ($ReferenceId)"
                    description = "Default $defaultEffect. Select another effect supported by this policy to override it for this assignment."
                }
            }
            $bindings[$parameterName] = @{ value = "[parameters('$overrideName')]" }
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
                'allowedKinds' { $parameterSchema.metadata.description = 'Cognitive Services account kinds to regard as compliant, including Foundry/OpenAI as applicable. JSON example: ["AIServices","OpenAI"]. These are account kinds, not agent entity kinds. Supply your approved list.' }
                'allowedDeploymentSkus' { $parameterSchema.metadata.description = 'Allowed Cognitive Services model deployment SKU names, not VM sizes. JSON example: ["Standard","DataZoneStandard"]. Choose the approved processing geography and SKUs for your organization; examples are not defaults.' }
                'allowedIpRules' { $parameterSchema.metadata.description = 'Exact approved public IPv4 address/CIDR rule strings for Cognitive Services, Search, and ML workspaces. JSON format example: ["203.0.113.10","198.51.100.0/24"]. Replace these documentation addresses with real approved egress addresses. [] approves no IP exceptions. CIDR containment is not inferred.' }
                'allowedSubnetIds' { $parameterSchema.metadata.description = 'Full approved subnet ARM IDs for Cognitive Services inbound VNet rules, including applicable Foundry/OpenAI accounts. JSON format: ["/subscriptions/<subscription-id>/resourceGroups/<resource-group>/providers/Microsoft.Network/virtualNetworks/<vnet>/subnets/<subnet>"]. [] approves no subnet exceptions. This is not Foundry agent VNet injection or private endpoint configuration.' }
                'allowedModelPublishers' { $parameterSchema.metadata.description = 'Approved model publishers for the Microsoft Foundry built-in. A publisher match OR a model asset match is sufficient. [] approves no publishers; no publisher is preapproved. Enter a JSON array of verified publisher identifiers.' }
                'allowedModelAssetIds' { $parameterSchema.metadata.description = 'Approved model asset identifiers for the Microsoft Foundry built-in. Entries use substring matching, not exact model-name matching. Prefer narrow full identifiers. [] approves no assets; do not include an empty string. A publisher match OR an asset match is sufficient.' }
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
        [System.Collections.IDictionary]$BuiltInDefinitions,
        [System.Collections.IDictionary]$ExistingParameters = @{}
    )

    $initiativeParameters = [ordered]@{}
    $references = [System.Collections.Generic.List[object]]::new()
    if (@(Compare-Object (Get-ExpectedBuiltIns) @($SelectedPolicies.reference)).Count -ne 0) {
        throw 'The initiative requires exactly the built-ins returned by Get-ExpectedBuiltIns.'
    }
    foreach ($binding in Get-FoundryBindings) {
        if (-not $CustomDefinitions.Contains($binding.file)) { throw "Missing custom definition: $($binding.file)" }
        $reference = New-AuditReference -ReferenceId $binding.reference -DefinitionId "$Scope/providers/Microsoft.Authorization/policyDefinitions/$Prefix-$($binding.file)" -Definition $CustomDefinitions[$binding.file] -Effect $binding.effect -InitiativeParameters $initiativeParameters
        $references.Add($reference)
    }
    foreach ($policy in $SelectedPolicies) {
        if (-not $BuiltInDefinitions.Contains($policy.reference)) {
            throw "Missing live built-in: $($policy.reference). No definitions will be published."
        }
        $fixedParameters = if ($policy.Contains('fixedParameters')) { $policy.fixedParameters } else { @{} }
        $definition = $BuiltInDefinitions[$policy.reference]
        $reference = New-AuditReference -ReferenceId $policy.reference -DefinitionId $policy.policyDefinitionId -Definition $definition -Effect $policy.recommendedInitialEffect -InitiativeParameters $initiativeParameters -FixedParameters $fixedParameters
        $references.Add($reference)
    }
    $nonEffectParameters = @($initiativeParameters.Keys | Where-Object { $_ -notlike '*_effect' })
    if ($nonEffectParameters.Count -ne 0) {
        throw "Selected policies must not ask for assignment parameters other than effect overrides: $($nonEffectParameters -join ', ')"
    }
    if (@($references.policyDefinitionReferenceId | Sort-Object -Unique).Count -ne $references.Count) {
        throw 'The generated initiative contains duplicate reference IDs.'
    }
    foreach ($parameterName in $ExistingParameters.Keys) {
        if ($initiativeParameters.Contains($parameterName)) { continue }
        if ($parameterName -notin @('allowedModelPublishers', 'allowedModelAssetIds', 'allowedLocations', 'locationResourceTypes', 'allowedIpRules', 'allowTrustedServices', 'tagResourceTypes', 'allowedSubnetIds', 'allowedKinds', 'allowedDeploymentSkus', 'B06_isolationMode', 'B29_requiredRetentionDays', 'B30_requiredRetentionDays', 'B42_excludedManagedByResourceProviders') -and
            $parameterName -notmatch '^B(05|12|13|14|16|17|18|19|20|22|23|24|25|26|27|31|32|33|34|35)_') {
            throw "Cannot remove saved initiative parameter: $parameterName. Review compatibility before publication."
        }
        $retiredParameter = $ExistingParameters[$parameterName] | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable
        if (-not $retiredParameter.Contains('defaultValue')) {
            if ($retiredParameter.type -eq 'Array') {
                $retiredParameter.defaultValue = @()
            }
            elseif ($retiredParameter.type -eq 'String' -and $retiredParameter.Contains('allowedValues') -and
                @($retiredParameter.allowedValues).Count -gt 0) {
                $retiredParameter.defaultValue = $retiredParameter.allowedValues[0]
            }
            elseif ($parameterName -eq 'B31_logAnalytics' -and $retiredParameter.type -eq 'String') {
                $retiredParameter.defaultValue = ''
            }
            else {
                throw "Cannot make retired parameter optional without a compatible default: $parameterName"
            }
        }
        if (-not $retiredParameter.Contains('metadata')) { $retiredParameter.metadata = @{} }
        $retiredParameter.metadata.Remove('assignPermissions')
        $retiredParameter.metadata.displayName = "Retired (not used): $parameterName"
        $retiredParameter.metadata.description = 'This input is not used by the six Foundry controls. It is retained only because Azure does not allow saved initiative parameters to be deleted. No input is required; its value has no effect on assessment.'
        $initiativeParameters[$parameterName] = $retiredParameter
    }
    if ($initiativeParameters.Count -gt 400 -or $references.Count -gt 1000) {
        throw 'The generated initiative exceeds Azure Policy limits.'
    }
    return [ordered]@{
        displayName = $Name
        description = 'Audit by default; every effect can be overridden at assignment. Foundry: trusted services, private endpoint, VNet injection, Key Vault connection, project App Insights. Model deployments: content filter, no preview models. Azure ML: private link, managed network, logs, CMK, identity, compute hardening, Entra endpoint auth. AI services, Search, Bot, Health Bot, de-identification: private link, local auth, identity, network, logs, CMK, storage, HTTPS, RBAC. All AI types: system-assigned identity.'
        policyType = 'Custom'
        metadata = @{
            category = 'AI Governance'
            version = '5.4.0'
            managedBy = 'azurethings-ai-governance'
            defaultEffectsAuditOnly = $true
            effectOverrides = 'PerPolicyAtAssignment'
            baseline = 'AIPlatformAudit'
            mlScope = 'MachineLearningWorkspacesAndComputes'
            accountScope = 'FoundryAccountsOnly'
            integrationScope = 'KeyVaultOnAccountAppInsightsOnProject'
            identityScope = 'SystemAssignedOnAllAIResourceTypes'
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
    param([string]$ResourceId, [switch]$PassThru)

    $existing = Invoke-PolicyRequest -Method GET -Path "${ResourceId}?api-version=2023-04-01" -AllowNotFound
    if ($null -ne $existing -and
        (-not $existing.properties.Contains('metadata') -or
            -not $existing.properties.metadata.Contains('managedBy') -or
            $existing.properties.metadata.managedBy -ne 'azurethings-ai-governance')) {
        throw "Refusing to overwrite an unrelated resource: $ResourceId. Choose a different name/prefix."
    }
    if ($PassThru) { return $existing }
}

$manifest = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'built-in-references.json') -Raw | ConvertFrom-Json -AsHashtable
$candidates = @(Get-AuditSelection -Manifest $manifest)
if ($ExcludeBuiltInReference.Count -gt 0) {
    throw 'ExcludeBuiltInReference is not supported by the exact six-control Foundry profile.'
}
$selectedPolicies = $candidates
$customDefinitions = [ordered]@{}
foreach ($binding in Get-FoundryBindings) {
    $definitionPath = Join-Path $PSScriptRoot "definitions/$($binding.file).json"
    $definition = Get-Content -LiteralPath $definitionPath -Raw | ConvertFrom-Json -AsHashtable
    $allowedEffects = if ($binding.effect -eq 'Audit') { @('Audit', 'Deny') } else { @('AuditIfNotExists', 'Disabled') }
    if ($definition.policyType -ne 'Custom' -or $definition.parameters.effect.defaultValue -ne $binding.effect -or
        @(Compare-Object $allowedEffects @($definition.parameters.effect.allowedValues)).Count -ne 0 -or
        $definition.policyRule.then.effect -ne "[parameters('effect')]") {
        throw "Custom definition has an unexpected audit contract: $($binding.file)"
    }
    $definition.metadata.managedBy = 'azurethings-ai-governance'
    $definition.metadata.Remove('auditOnly')
    $definition.metadata.defaultEffect = $binding.effect
    $customDefinitions[$binding.file] = $definition
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
foreach ($fileName in $customDefinitions.Keys) {
    Confirm-ManagedResource "$scope/providers/Microsoft.Authorization/policyDefinitions/$DefinitionPrefix-$fileName"
}
$existingInitiative = Confirm-ManagedResource $initiativeId -PassThru
$existingParameters = if ($null -ne $existingInitiative -and $existingInitiative.properties.Contains('parameters')) { $existingInitiative.properties.parameters } else { @{} }
$initiative = New-AuditInitiative -Scope $scope -Prefix $DefinitionPrefix -Name $DisplayName -CustomDefinitions $customDefinitions -SelectedPolicies $selectedPolicies -BuiltInDefinitions $builtInDefinitions -ExistingParameters $existingParameters
$initiative.metadata.excludedBuiltInReferences = @($manifest.policies | Where-Object { $_.reference -notin $manifest.assignmentProfile.includedReferences } | ForEach-Object { $_.reference })

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
            $verified.properties.parameters.effect.defaultValue -ne $entry.Value.parameters.effect.defaultValue -or
            @(Compare-Object @($entry.Value.parameters.effect.allowedValues) @($verified.properties.parameters.effect.allowedValues)).Count -ne 0) {
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