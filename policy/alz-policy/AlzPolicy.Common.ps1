# Shared logic for Import-AlzPolicy.ps1, Deploy-AlzPolicy.ps1 and Test-AlzPolicy.ps1. Dot-source this file.
#
# The JSON files under ./definitions are untouched copies of the Azure Landing Zones (ALZ) custom policy definitions.
# The initiative is generated from them in memory with one systematic change per definition: an audit-mode effect is
# added to the allowed values of the definition's effect parameter (a hard-coded effect becomes a parameter whose
# default stays the upstream effect). The initiative then exposes one effect parameter per policy whose default is that
# audit-mode effect, so assigning it audits everything until an effect is switched at assignment time.

$script:AlzManagedBy = 'azurethings-alz-policy'
$script:AlzPolicyApiVersion = '2023-04-01'

# Parameters that are deliberately shared by several policies. Every other parameter is namespaced per policy so that
# unrelated inputs that merely share a name (two different rgName inputs, for example) can never collide.
$script:AlzSharedParameters = @(
    'logAnalytics', 'profileName', 'logsEnabled', 'metricsEnabled', 'logAnalyticsDestinationType',
    'mandatoryTags', 'allowedVnets', 'vulnerabilityAssessmentsStorageID'
)

$script:AlzAuditEffects = @('Audit', 'AuditIfNotExists', 'AuditAction')

# Audit-mode counterpart of every enforcing effect that ALZ definitions use.
$script:AlzAuditEffectFor = @{
    Deny              = 'Audit'
    Modify            = 'Audit'
    Append            = 'Audit'
    DeployIfNotExists = 'AuditIfNotExists'
    DenyAction        = 'AuditAction'
}

$script:AlzEffectNames = @('Audit', 'AuditIfNotExists', 'AuditAction', 'Deny', 'DenyAction', 'DeployIfNotExists', 'Modify', 'Append', 'Disabled')

# Informational only (used by the catalog); unknown role IDs are shown as the GUID.
$script:AlzRoleNames = @{
    'b24988ac-6180-42a0-ab88-20f7382dd24c' = 'Contributor'
    '4633458b-17de-408a-b874-0445c86b69e6' = 'Key Vault Secrets User'
    '92aaf0da-9dab-42b6-94a3-d43ce8d16293' = 'Log Analytics Contributor'
    '749f88d5-cbae-40b8-bcfc-e573ddc772fa' = 'Monitoring Contributor'
    '4d97b98b-1d4f-4787-a291-c67834d212e7' = 'Network Contributor'
    'fb1c8493-542b-48eb-b624-b4c8fea62acd' = 'Security Admin'
    '4939a1f6-9ae0-4e48-a1e0-f2cbe897382d' = 'SQL Managed Instance Contributor'
    '056cd41c-7e88-42e1-933e-88ba6a50c9c3' = 'SQL Security Manager'
    '6d8ee4ec-f05a-4a1d-8b00-a9b17e38b437' = 'SQL Server Contributor'
    '17d1049b-9a84-46fb-8f53-869881c3d3ab' = 'Storage Account Contributor'
    '9980e02c-c2be-4d73-94e8-173b1dc7cf3c' = 'Virtual Machine Contributor'
    'de139f84-1756-47ae-9be6-808fbbe84772' = 'Website Contributor'
}

function ConvertTo-AlzKey {
    # Initiative parameter prefix for a policy: every non-alphanumeric character becomes an underscore.
    param([Parameter(Mandatory)][string]$Name)
    $Name -replace '[^A-Za-z0-9]', '_'
}

function Get-AlzCanonicalEffect {
    param([Parameter(Mandatory)][string]$Effect)
    $match = $script:AlzEffectNames | Where-Object { $_ -ieq $Effect } | Select-Object -First 1
    if (-not $match) { throw "Unsupported policy effect '$Effect'." }
    $match
}

function Copy-AlzObject {
    param([Parameter(Mandatory)]$InputObject)
    ConvertTo-Json -InputObject $InputObject -Depth 100 -Compress | ConvertFrom-Json -AsHashtable -Depth 100
}

function Get-AlzCanonicalJson {
    # Key-order independent JSON, used to compare schemas and prove that definitions were not changed unintentionally.
    param($Value)
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [System.Collections.IDictionary]) {
        $parts = foreach ($key in ($Value.Keys | Sort-Object -CaseSensitive)) {
            '{0}:{1}' -f (ConvertTo-Json -InputObject ([string]$key) -Compress), (Get-AlzCanonicalJson $Value[$key])
        }
        return '{' + ($parts -join ',') + '}'
    }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        $items = foreach ($item in $Value) { Get-AlzCanonicalJson $item }
        return '[' + ($items -join ',') + ']'
    }
    ConvertTo-Json -InputObject $Value -Compress
}

function Get-AlzSortedRecord {
    # Ordinal sort by policy name. Culture-aware sorting treats hyphens differently between platforms, which would
    # make the generated parameter order and catalog differ from machine to machine.
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Record)
    $list = [System.Collections.Generic.List[object]]::new($Record)
    $list.Sort([System.Comparison[object]] { param($a, $b) [string]::CompareOrdinal($a.Name, $b.Name) })
    $list.ToArray()
}

function Get-AlzSortedKey {
    # Ordinal sort of dictionary keys, so generated output does not depend on the key order of the parsed JSON.
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Dictionary)
    $keys = [string[]]@($Dictionary.Keys)
    [System.Array]::Sort($keys, [System.StringComparer]::Ordinal)
    $keys
}
function Get-AlzPolicyRecord {
    # Loads the definitions folder (including the deprecated sub folder) as records sorted by policy name.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DefinitionsPath)

    $records = [System.Collections.Generic.List[object]]::new()
    foreach ($file in Get-ChildItem -LiteralPath $DefinitionsPath -Filter '*.json' -File -Recurse) {
        $definition = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json -AsHashtable -Depth 100
        $metadata = $definition.properties.metadata
        $records.Add([pscustomobject]@{
                Name              = $definition.name
                Category          = $metadata.category
                Deprecated        = ($metadata.Contains('deprecated') -and $metadata.deprecated -eq $true)
                CloudEnvironments = @($metadata.alzCloudEnvironments)
                File              = $file.FullName
                Definition        = $definition
            })
    }
    Get-AlzSortedRecord -Record $records.ToArray()
}

function ConvertTo-AlzAuditFirstDefinition {
    # Returns the definition properties to publish plus a description of how the effect was adapted.
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Definition)

    $properties = Copy-AlzObject $Definition.properties
    $then = $properties.policyRule.then
    $effectExpression = [string]$then.effect
    $parameterized = $false

    if ($effectExpression -match "^\[parameters\('(?<name>[^']+)'\)\]$") {
        $effectParameter = $Matches.name
        $schema = $properties.parameters[$effectParameter]
        if (-not $schema.Contains('allowedValues') -or -not $schema.Contains('defaultValue')) {
            throw "Effect parameter '$effectParameter' of $($Definition.name) needs allowedValues and a defaultValue."
        }
        $allowed = @($schema.allowedValues | ForEach-Object { Get-AlzCanonicalEffect $_ })
        $upstreamDefault = Get-AlzCanonicalEffect $schema.defaultValue
    }
    else {
        # Hard-coded effect: keep it as the default and make it switchable.
        $effectParameter = 'effect'
        if ($properties.Contains('parameters') -and $properties.parameters.Contains($effectParameter)) {
            throw "$($Definition.name) hard-codes its effect but already defines a parameter named 'effect'."
        }
        $upstreamDefault = Get-AlzCanonicalEffect $effectExpression
        $allowed = @($upstreamDefault, 'Disabled')
        $parameterized = $true
    }

    $enforcing = @($allowed | Where-Object { $_ -ne 'Disabled' -and $_ -notin $script:AlzAuditEffects })
    $auditEffect = $script:AlzAuditEffects | Where-Object { $_ -in $allowed } | Select-Object -First 1
    if (-not $auditEffect) {
        $candidates = @($enforcing | ForEach-Object { $script:AlzAuditEffectFor[$_] } | Select-Object -Unique)
        if ($candidates.Count -ne 1 -or -not $candidates[0]) {
            throw "Cannot choose an audit-mode effect for $($Definition.name) (effects: $($allowed -join ', '))."
        }
        $auditEffect = $candidates[0]
    }
    $extended = $auditEffect -notin $allowed
    if ($extended) { $allowed = @($auditEffect) + $allowed }

    if ($parameterized) {
        $effectSchema = [ordered]@{
            type          = 'String'
            metadata      = [ordered]@{ displayName = 'Effect'; description = 'Enable or disable the execution of the policy' }
            allowedValues = $allowed
            defaultValue  = $upstreamDefault
        }
        $parameters = [ordered]@{ $effectParameter = $effectSchema }
        if ($properties.Contains('parameters')) {
            foreach ($key in $properties.parameters.Keys) { $parameters[$key] = $properties.parameters[$key] }
        }
        $properties['parameters'] = $parameters
        $then['effect'] = "[parameters('$effectParameter')]"
    }
    else {
        $schema['allowedValues'] = $allowed
    }

    $roleNames = @()
    if ($then.Contains('details') -and $then.details -is [System.Collections.IDictionary] -and $then.details.Contains('roleDefinitionIds')) {
        $roleNames = @($then.details.roleDefinitionIds | ForEach-Object {
                $guid = ([string]$_ -split '/')[-1].ToLowerInvariant()
                if ($script:AlzRoleNames.ContainsKey($guid)) { $script:AlzRoleNames[$guid] } else { $guid }
            })
    }

    [pscustomobject]@{
        Name                  = $Definition.name
        DisplayName           = $properties.displayName
        Properties            = $properties
        EffectParameter       = $effectParameter
        AuditEffect           = $auditEffect
        AllowedEffects        = $allowed
        EnforcingEffects      = $enforcing
        UpstreamDefault       = $upstreamDefault
        EffectParameterized   = $parameterized
        AllowedValuesExtended = ($extended -and -not $parameterized)
        RoleNames             = $roleNames
    }
}

function Get-AlzPlaceholderDefault {
    # Neutral value for parameters that have no upstream default, so that the initiative can be assigned without
    # supplying inputs that only matter once a policy is switched to a deploying effect.
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Schema, [Parameter(Mandatory)][string]$Context)

    if ($Schema.Contains('allowedValues') -and @($Schema.allowedValues).Count -gt 0) { return @($Schema.allowedValues)[0] }
    switch (([string]$Schema.type).ToLowerInvariant()) {
        'string' { return '' }
        'array' { return , @() }
        'object' { return @{} }
        'boolean' { return $false }
        'integer' { return 0 }
        'float' { return 0.0 }
        default { throw "No placeholder default for parameter type '$($Schema.type)' ($Context)." }
    }
}

function Get-AlzDefinitionName {
    # The resource name of a policy definition is limited to 64 characters (the display name allows 128). A longer
    # prefix + policy name is cut short and gets a hash of the full policy name, so it stays deterministic and unique.
    param([AllowEmptyString()][string]$Prefix, [Parameter(Mandatory)][string]$Name)

    $full = "$Prefix$Name"
    if ($full.Length -le 64) { return $full }
    $bytes = [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($Name))
    $hash = [System.Convert]::ToHexString($bytes).Substring(0, 8).ToLowerInvariant()
    $room = 64 - $Prefix.Length - 9
    if ($room -lt 1) { throw "The prefix '$Prefix' is too long for policy definition names." }
    "$Prefix$($Name.Substring(0, $room).TrimEnd('-', '_', '.'))-$hash"
}
function Build-AlzPolicyPackage {
    # Builds the definitions to publish and the single initiative that references them.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Record,
        [Parameter(Mandatory)][string]$Scope,
        [AllowEmptyString()][string]$DefinitionPrefix = '',
        [Parameter(Mandatory)][string]$InitiativeName,
        [Parameter(Mandatory)][string]$DisplayName,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Source
    )

    $definitions = [System.Collections.Generic.List[object]]::new()
    $references = [System.Collections.Generic.List[object]]::new()
    $initiativeParameters = [ordered]@{}
    $keys = @{}

    foreach ($item in (Get-AlzSortedRecord -Record $Record)) {
        $adapted = ConvertTo-AlzAuditFirstDefinition -Definition $item.Definition
        $key = ConvertTo-AlzKey $item.Name
        if ($keys.ContainsKey($key)) { throw "Policies '$($keys[$key])' and '$($item.Name)' map to the same parameter prefix '$key'." }
        $keys[$key] = $item.Name

        $effectName = "${key}_effect"
        $initiativeParameters[$effectName] = [ordered]@{
            type          = 'String'
            allowedValues = @($adapted.AllowedEffects)
            defaultValue  = $adapted.AuditEffect
            metadata      = [ordered]@{
                displayName = "[$($item.Name)] Effect"
                description = "$($adapted.DisplayName.Trim().TrimEnd('.')). Default $($adapted.AuditEffect) (audit only). Allowed: $($adapted.AllowedEffects -join ', ')."
            }
        }
        $bindings = [ordered]@{ $adapted.EffectParameter = [ordered]@{ value = "[parameters('$effectName')]" } }

        foreach ($parameterName in (Get-AlzSortedKey $adapted.Properties.parameters)) {
            if ($parameterName -eq $adapted.EffectParameter) { continue }
            $schema = Copy-AlzObject $adapted.Properties.parameters[$parameterName]
            if (-not $schema.Contains('metadata')) { $schema['metadata'] = [ordered]@{} }

            $shared = $parameterName -in $script:AlzSharedParameters
            $initiativeParameter = if ($shared) { $parameterName } else { "${key}_$parameterName" }
            if (-not $shared) {
                $label = if ($schema.metadata.Contains('displayName')) { $schema.metadata.displayName } else { $parameterName }
                $schema.metadata['displayName'] = "[$($item.Name)] $label"
            }
            if (-not $schema.Contains('defaultValue')) {
                $schema['defaultValue'] = Get-AlzPlaceholderDefault -Schema $schema -Context "$($item.Name).$parameterName"
                $original = if ($schema.metadata.Contains('description')) { $schema.metadata.description } else { '' }
                $schema.metadata['description'] = "Placeholder default: no upstream default exists. Set a real value before switching this policy to a deploying effect. $original".Trim()
                $schema.metadata['alzPlaceholderDefault'] = $true
            }

            if ($initiativeParameters.Contains($initiativeParameter)) {
                if ((Get-AlzCanonicalJson $initiativeParameters[$initiativeParameter]) -ne (Get-AlzCanonicalJson $schema)) {
                    throw "Parameter '$parameterName' is shared as '$initiativeParameter' but $($item.Name) defines it differently."
                }
            }
            else {
                $initiativeParameters[$initiativeParameter] = $schema
            }
            $bindings[$parameterName] = [ordered]@{ value = "[parameters('$initiativeParameter')]" }
        }

        if (-not $adapted.Properties.Contains('metadata')) { $adapted.Properties['metadata'] = [ordered]@{} }
        $metadata = $adapted.Properties.metadata
        $metadata['managedBy'] = $script:AlzManagedBy
        $metadata['alzName'] = $item.Name
        $metadata['alzLibraryVersion'] = $Source.version

        $definitionName = Get-AlzDefinitionName -Prefix $DefinitionPrefix -Name $item.Name
        $definitionId = "$Scope/providers/Microsoft.Authorization/policyDefinitions/$definitionName"
        $definitions.Add([pscustomobject]@{
                Name       = $definitionName
                PolicyName = $item.Name
                Id         = $definitionId
                Properties = $adapted.Properties
                Adapted    = $adapted
                Record     = $item
            })
        $references.Add([ordered]@{
                policyDefinitionReferenceId = $item.Name
                policyDefinitionId          = $definitionId
                parameters                  = $bindings
            })
    }

    $initiative = [ordered]@{
        displayName       = $DisplayName
        description       = "All custom Azure Landing Zones policies in one initiative. Every policy audits by default (Audit, AuditIfNotExists or AuditAction); switch a policy to Deny, DeployIfNotExists, Modify, Append or DenyAction through its <policy>_effect parameter when assigning. ALZ Library $($Source.version)."
        policyType        = 'Custom'
        metadata          = [ordered]@{
            category          = 'Azure Landing Zones'
            version           = $Source.version
            source            = $Source.repository
            alzLibraryRef     = $Source.ref
            alzLibraryCommit  = $Source.commit
            managedBy         = $script:AlzManagedBy
            defaultEffects    = 'AuditOnly'
            effectOverrides   = 'PerPolicyAtAssignment'
        }
        parameters        = $initiativeParameters
        policyDefinitions = $references.ToArray()
    }

    [pscustomobject]@{
        Scope       = $Scope
        Definitions = $definitions.ToArray()
        Initiative  = [pscustomobject]@{
            Name       = $InitiativeName
            Id         = "$Scope/providers/Microsoft.Authorization/policySetDefinitions/$InitiativeName"
            Properties = $initiative
        }
    }
}

function Test-AlzPolicyPackage {
    # Offline validation of a package. Returns a list of problems (empty when the package is sound). It reports
    # malformed input as problems instead of throwing.
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Package)

    $problems = [System.Collections.Generic.List[string]]::new()
    $initiative = $Package.Initiative.Properties
    $parameters = $initiative.parameters

    if ($Package.Definitions.Count -eq 0) { $problems.Add('The package contains no policy definitions.') }
    if ($parameters.Count -gt 400) { $problems.Add("The initiative has $($parameters.Count) parameters; Azure allows at most 400.") }
    if ($initiative.policyDefinitions.Count -gt 1000) { $problems.Add("The initiative has $($initiative.policyDefinitions.Count) policies; Azure allows at most 1000.") }
    if ($initiative.policyDefinitions.Count -ne $Package.Definitions.Count) { $problems.Add('Initiative references and definitions differ in number.') }
    if ($initiative.displayName.Length -gt 128) { $problems.Add('The initiative display name exceeds 128 characters.') }
    if ([System.Text.Encoding]::UTF8.GetByteCount((ConvertTo-Json -InputObject @{ properties = $initiative } -Depth 100 -Compress)) -gt 1048576) { $problems.Add('The initiative request body exceeds 1 MiB.') }
    if ($Package.Initiative.Name.Length -gt 64) { $problems.Add('The initiative name exceeds 64 characters.') }

    foreach ($definition in $Package.Definitions) {
        $name = $definition.PolicyName
        try {
            $adapted = $definition.Adapted
            $upstream = $definition.Record.Definition.properties
            $properties = $definition.Properties

            if ($definition.Name.Length -gt 64 -or $definition.Name -match '[#<>%&:\\?/\p{Cc}]' -or $definition.Name -match '[. ]$') {
                $problems.Add("${name}: '$($definition.Name)' is not a valid policy definition name (1-64 characters, none of # < > % & : \ ? /, not ending in a period or space).")
            }
            if ($properties.parameters.Count -gt 20) { $problems.Add("${name}: $($properties.parameters.Count) parameters; a definition allows at most 20.") }
            if ([System.Text.Encoding]::UTF8.GetByteCount((ConvertTo-Json -InputObject @{ properties = $properties } -Depth 100 -Compress)) -gt 1048576) { $problems.Add("${name}: the request body exceeds 1 MiB.") }
            if ($properties.policyType -ne 'Custom') { $problems.Add("${name}: policyType must be Custom.") }
            if ($properties.metadata.managedBy -ne $script:AlzManagedBy) { $problems.Add("${name}: the managedBy marker is missing.") }
            if ($properties.policyRule.then.effect -ne "[parameters('$($adapted.EffectParameter)')]") { $problems.Add("${name}: the effect is not bound to its effect parameter.") }

            $effectSchema = $properties.parameters[$adapted.EffectParameter]
            if ($effectSchema.type -ne 'String') { $problems.Add("${name}: the effect parameter must be a String.") }
            if (@($effectSchema.allowedValues) -notcontains $effectSchema.defaultValue) { $problems.Add("${name}: the default effect is not an allowed value.") }
            if ($effectSchema.defaultValue -ne $adapted.UpstreamDefault) { $problems.Add("${name}: the definition default changed from $($adapted.UpstreamDefault).") }
            if ($adapted.AuditEffect -notin @($effectSchema.allowedValues)) { $problems.Add("${name}: the audit-mode effect $($adapted.AuditEffect) is not allowed.") }
            if ('Disabled' -notin @($effectSchema.allowedValues)) { $problems.Add("${name}: Disabled must stay allowed.") }
            if (-not $adapted.EffectParameterized) {
                $removed = @($upstream.parameters[$adapted.EffectParameter].allowedValues | Where-Object { $_ -notin @($effectSchema.allowedValues) })
                if ($removed.Count -gt 0) { $problems.Add("${name}: upstream effects were removed from the allowed values: $($removed -join ', ').") }
            }

            # Only the effect handling may differ from the upstream definition.
            foreach ($key in $upstream.Keys) {
                if ($key -in 'metadata', 'parameters', 'policyRule') { continue }
                if ((Get-AlzCanonicalJson $upstream[$key]) -ne (Get-AlzCanonicalJson $properties[$key])) { $problems.Add("${name}: property '$key' differs from upstream.") }
            }
            if ((Get-AlzCanonicalJson $upstream.policyRule['if']) -ne (Get-AlzCanonicalJson $properties.policyRule['if'])) { $problems.Add("${name}: the policy condition differs from upstream.") }
            foreach ($key in $upstream.policyRule.then.Keys) {
                if ($key -eq 'effect') { continue }
                if ((Get-AlzCanonicalJson $upstream.policyRule.then[$key]) -ne (Get-AlzCanonicalJson $properties.policyRule.then[$key])) { $problems.Add("${name}: then.$key differs from upstream.") }
            }
            $upstreamParameters = if ($upstream.Contains('parameters')) { $upstream.parameters } else { @{} }
            foreach ($key in $upstreamParameters.Keys) {
                if ($key -eq $adapted.EffectParameter) { continue }
                if ((Get-AlzCanonicalJson $upstreamParameters[$key]) -ne (Get-AlzCanonicalJson $properties.parameters[$key])) { $problems.Add("${name}: parameter '$key' differs from upstream.") }
            }
        }
        catch {
            $problems.Add("${name}: the definition is malformed ($($_.Exception.Message)).")
        }
    }

    $referenced = [System.Collections.Generic.HashSet[string]]::new()
    $referenceIds = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($reference in $initiative.policyDefinitions) {
        $name = $reference.policyDefinitionReferenceId
        try {
            if (-not $referenceIds.Add($name)) { $problems.Add("Duplicate policyDefinitionReferenceId '$name'.") }
            $definition = $Package.Definitions | Where-Object { $_.PolicyName -eq $name } | Select-Object -First 1
            if (-not $definition) { $problems.Add("${name}: no matching definition."); continue }
            if ($reference.policyDefinitionId -ne $definition.Id) { $problems.Add("${name}: policyDefinitionId does not match the published definition.") }

            foreach ($binding in $reference.parameters.GetEnumerator()) {
                if ($binding.Value.value -notmatch "^\[parameters\('(?<name>[^']+)'\)\]$") { $problems.Add("${name}: parameter '$($binding.Key)' is not bound to an initiative parameter."); continue }
                $initiativeParameter = $Matches.name
                $null = $referenced.Add($initiativeParameter)
                if (-not $parameters.Contains($initiativeParameter)) { $problems.Add("${name}: initiative parameter '$initiativeParameter' does not exist."); continue }
                if (-not $definition.Properties.parameters.Contains($binding.Key)) { $problems.Add("${name}: the definition has no parameter '$($binding.Key)'."); continue }
                $initiativeSchema = $parameters[$initiativeParameter]
                $definitionSchema = $definition.Properties.parameters[$binding.Key]
                if (([string]$initiativeSchema.type).ToLowerInvariant() -ne ([string]$definitionSchema.type).ToLowerInvariant()) { $problems.Add("${name}: type of '$initiativeParameter' differs from the definition parameter.") }
            }
            foreach ($definitionParameter in $definition.Properties.parameters.Keys) {
                if (-not $reference.parameters.Contains($definitionParameter)) { $problems.Add("${name}: definition parameter '$definitionParameter' is not bound.") }
            }

            $effectName = "$(ConvertTo-AlzKey $name)_effect"
            if (-not $parameters.Contains($effectName)) { $problems.Add("${name}: missing initiative parameter $effectName."); continue }
            $effect = $parameters[$effectName]
            if ($effect.defaultValue -notin $script:AlzAuditEffects) { $problems.Add("${name}: default effect '$($effect.defaultValue)' is not an audit-mode effect.") }
            $definitionEffect = $definition.Properties.parameters[$definition.Adapted.EffectParameter]
            if ((Get-AlzCanonicalJson @($effect.allowedValues)) -ne (Get-AlzCanonicalJson @($definitionEffect.allowedValues))) { $problems.Add("${name}: initiative and definition allowed effects differ.") }
        }
        catch {
            $problems.Add("${name}: the initiative reference is malformed ($($_.Exception.Message)).")
        }
    }

    foreach ($entry in $parameters.GetEnumerator()) {
        try {
            $schema = $entry.Value
            if (-not $referenced.Contains($entry.Key)) { $problems.Add("Initiative parameter '$($entry.Key)' is not used.") }
            if (-not $schema.Contains('defaultValue')) { $problems.Add("Initiative parameter '$($entry.Key)' has no default value, so assignment would require input."); continue }
            if ($schema.Contains('allowedValues')) {
                # Array parameters list the allowed items and default to an array of them.
                $defaults = if (([string]$schema.type).ToLowerInvariant() -eq 'array') { @($schema.defaultValue) } else { @(, $schema.defaultValue) }
                if (@($defaults | Where-Object { @($schema.allowedValues) -notcontains $_ }).Count -gt 0) { $problems.Add("Initiative parameter '$($entry.Key)': the default is not within the allowed values.") }
            }
            $default = $schema.defaultValue
            $typeOk = switch (([string]$schema.type).ToLowerInvariant()) {
                'string' { $default -is [string] }
                'array' { $default -is [System.Collections.IEnumerable] -and $default -isnot [string] -and $default -isnot [System.Collections.IDictionary] }
                'object' { $default -is [System.Collections.IDictionary] }
                'boolean' { $default -is [bool] }
                'integer' { $default -is [int] -or $default -is [long] }
                'float' { $default -is [double] -or $default -is [int] -or $default -is [long] }
                default { $false }
            }
            if (-not $typeOk) { $problems.Add("Initiative parameter '$($entry.Key)': the default does not match type '$($schema.type)'.") }
        }
        catch {
            $problems.Add("Initiative parameter '$($entry.Key)' is malformed ($($_.Exception.Message)).")
        }
    }

    $problems.ToArray()
}
function Format-AlzPolicyCatalog {
    # Markdown catalog of every imported policy and every initiative parameter. Generated; do not edit by hand.
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Record, [Parameter(Mandatory)][System.Collections.IDictionary]$Source)

    $package = Build-AlzPolicyPackage -Record $Record -Scope '/subscriptions/00000000-0000-0000-0000-000000000000' -InitiativeName 'catalog' -DisplayName 'catalog' -Source $Source
    $escape = { param($text) ([string]$text) -replace '\|', '\|' }
    $rows = foreach ($definition in $package.Definitions) {
        $adapted = $definition.Adapted
        [pscustomobject]@{
            Name       = $definition.PolicyName
            Display    = $adapted.DisplayName
            Category   = $definition.Record.Category
            Deprecated = $definition.Record.Deprecated
            Default    = $adapted.AuditEffect
            SwitchTo   = @($adapted.AllowedEffects | Where-Object { $_ -ne 'Disabled' -and $_ -ne $adapted.AuditEffect }) -join ', '
            Roles      = (@($adapted.RoleNames | Select-Object -Unique | Sort-Object { $_ } -Culture ([cultureinfo]::InvariantCulture) -CaseSensitive)) -join ', '
            Parameter  = "$(ConvertTo-AlzKey $definition.PolicyName)_effect"
            Upstream   = $adapted.UpstreamDefault
            Extended   = $adapted.AllowedValuesExtended
            Static     = $adapted.EffectParameterized
        }
    }
    $active = @($rows | Where-Object { -not $_.Deprecated })
    $deprecated = @($rows | Where-Object { $_.Deprecated })

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('# ALZ custom policy catalog')
    $lines.Add('')
    $lines.Add("Generated by ``Import-AlzPolicy.ps1`` from $($Source.repository) at ``$($Source.ref)`` (commit ``$($Source.commit)``). Do not edit by hand.")
    $lines.Add('')
    $lines.Add("- **$($rows.Count)** custom policy definitions imported: **$($active.Count)** active and **$($deprecated.Count)** deprecated upstream. Deprecated ones are published only with ``-IncludeDeprecated``.")
    $lines.Add("- Every policy audits by default and also accepts ``Disabled``. **$(@($rows | Where-Object Extended).Count)** definitions get an audit-mode effect added to their allowed values and **$(@($rows | Where-Object Static).Count)** turn a hard-coded effect into a parameter whose default stays the upstream effect.")
    $lines.Add('- Effect parameter name: the policy name with every non-alphanumeric character replaced by `_`, followed by `_effect`.')
    $lines.Add('- The roles column lists what the assignment identity needs when the policy is switched to a deploying or modifying effect.')
    $lines.Add('')

    $render = {
        param($items)
        $out = [System.Collections.Generic.List[string]]::new()
        $out.Add('| Policy | Display name | Category | Default | Switch to | Roles for Deploy/Modify | Effect parameter |')
        $out.Add('| --- | --- | --- | --- | --- | --- | --- |')
        foreach ($row in $items) {
            $out.Add("| ``$($row.Name)`` | $(& $escape $row.Display) | $($row.Category) | $($row.Default) | $($row.SwitchTo) | $($row.Roles) | ``$($row.Parameter)`` |")
        }
        $out
    }

    $lines.Add("## Active policies ($($active.Count))")
    $lines.Add('')
    foreach ($line in (& $render $active)) { $lines.Add($line) }
    $lines.Add('')

    $usage = [ordered]@{}
    foreach ($reference in $package.Initiative.Properties.policyDefinitions) {
        $ownEffect = "$(ConvertTo-AlzKey $reference.policyDefinitionReferenceId)_effect"
        foreach ($binding in $reference.parameters.GetEnumerator()) {
            $initiativeParameter = ($binding.Value.value -replace "^\[parameters\('", '' -replace "'\)\]$", '')
            if ($initiativeParameter -eq $ownEffect) { continue }
            if (-not $usage.Contains($initiativeParameter)) { $usage[$initiativeParameter] = [System.Collections.Generic.List[string]]::new() }
            $usage[$initiativeParameter].Add($reference.policyDefinitionReferenceId)
        }
    }
    $deprecatedNames = @($deprecated | ForEach-Object { $_.Name })
    $lines.Add("## Other initiative parameters ($($usage.Count))")
    $lines.Add('')
    $lines.Add('Parameters that are not effects. Those marked *placeholder* have no upstream default, so an empty value is used until you set one; it only matters once the policy is switched to a deploying effect. Parameters used only by deprecated policies exist only with `-IncludeDeprecated`.')
    $lines.Add('')
    $lines.Add('| Initiative parameter | Used by | Type | Default | Origin |')
    $lines.Add('| --- | --- | --- | --- | --- |')
    foreach ($entry in $usage.GetEnumerator()) {
        $schema = $package.Initiative.Properties.parameters[$entry.Key]
        $default = (ConvertTo-Json -InputObject $schema.defaultValue -Compress -Depth 20)
        if ($default.Length -gt 80) { $default = $default.Substring(0, 77) + '...' }
        $origin = if ($schema.metadata.Contains('alzPlaceholderDefault')) { 'placeholder' } else { 'upstream' }
        $activeUsers = @($entry.Value | Where-Object { $_ -notin $deprecatedNames })
        $deprecatedUsers = @($entry.Value | Where-Object { $_ -in $deprecatedNames })
        $usedBy = [System.Collections.Generic.List[string]]::new()
        if ($activeUsers.Count -gt 0) { $usedBy.Add($activeUsers -join ', ') }
        if ($deprecatedUsers.Count -gt 0) { $usedBy.Add("$($deprecatedUsers.Count) deprecated (e.g. $(($deprecatedUsers | Select-Object -First 2) -join ', '))") }
        $lines.Add("| ``$($entry.Key)`` | $($usedBy -join '; ') | $($schema.type) | ``$(& $escape $default)`` | $origin |")
    }
    $lines.Add('')

    $lines.Add("## Deprecated policies ($($deprecated.Count))")
    $lines.Add('')
    $lines.Add('Flagged `deprecated` upstream (mostly the legacy Deploy-Diagnostics family, superseded by built-in policies). Not part of the initiative unless `-IncludeDeprecated` is used.')
    $lines.Add('')
    foreach ($line in (& $render $deprecated)) { $lines.Add($line) }
    $lines.Add('')
    $lines -join "`n"
}
