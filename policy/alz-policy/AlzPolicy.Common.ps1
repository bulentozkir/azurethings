# Shared logic for Import-AlzPolicy.ps1, Deploy-AlzPolicy.ps1 and Test-AlzPolicy.ps1. Dot-source this file.
#
# The JSON files under ./definitions are the Azure Landing Zones (ALZ) custom policy definitions converted to audit by
# default. The conversion (ConvertTo-AlzAuditFirstDefinition, applied by Import-AlzPolicy.ps1) changes only the effect
# handling of each definition: its effect parameter defaults to an audit-mode effect, the upstream effect stays
# selectable and is recorded in metadata.alzUpstreamEffect, and a hard-coded effect becomes a parameter. Everything else
# is upstream's, which the fingerprints in alz-library-source.json prove, except for the few documented policy rule
# adjustments in $script:AlzPolicyRuleAdjustments. Policies that are authored in this repository live in
# ./local-definitions: the import never touches them and they have to audit by default already. The initiative is
# generated from both and exposes one effect parameter per policy that defaults to the same audit-mode effect, so
# assigning the initiative audits everything until an effect is switched at assignment time.

$script:AlzManagedBy = 'azurethings-alz-policy'
$script:AlzPolicyApiVersion = '2023-04-01'

# Metadata that the conversion, the adjustments and publishing add; everything else in a definition must equal upstream.
$script:AlzAddedMetadata = @('alzUpstreamEffect', 'alzAdjustment', 'managedBy', 'alzName', 'alzLibraryVersion')

# Parameters that are deliberately shared by several policies. Every other parameter is namespaced per policy so that
# unrelated inputs that merely share a name (two different rgName inputs, for example) can never collide.
$script:AlzSharedParameters = @(
    'logAnalytics', 'profileName', 'logsEnabled', 'metricsEnabled', 'logAnalyticsDestinationType',
    'mandatoryTags', 'allowedVnets', 'vulnerabilityAssessmentsStorageID'
)

# The only effects that a definition or the initiative may default to.
$script:AlzAuditEffects = @('Audit', 'AuditIfNotExists')

# Audit-mode counterpart of every enforcing effect that ALZ definitions use. AuditIfNotExists is for the effect that
# deploys something (DeployIfNotExists). Everything else, DenyAction included, audits with plain Audit: AuditIfNotExists
# needs a related resource type (details.type), which those definitions do not have.
$script:AlzAuditEffectFor = @{
    Deny              = 'Audit'
    Modify            = 'Audit'
    Append            = 'Audit'
    DeployIfNotExists = 'AuditIfNotExists'
    DenyAction        = 'Audit'
}

$script:AlzEffectNames = @('Audit', 'AuditIfNotExists', 'Deny', 'DenyAction', 'DeployIfNotExists', 'Modify', 'Append', 'Disabled')

# Deliberate changes to the policy rule of single imported definitions. The import applies them after the audit
# conversion and records each one in metadata.alzAdjustment of the definition, in alz-library-source.json (with the
# fingerprint of the result) and in policy-catalog.md. Keep the table short: every entry deviates from upstream and has
# to be reviewed against each new upstream release (the import fails when an adjustment finds nothing left to change).
# Apply names a function that edits the definition properties in place and returns $true when it changed the rule.
$script:AlzPolicyRuleAdjustments = @{
    'Audit-AzureHybridBenefit' = @{
        Id          = 'no-windows-server-version-list'
        Apply       = 'Remove-AlzImageSkuCondition'
        Description = 'Removed the Windows Server version conditions (Microsoft.Compute/imageSKU: 2008-R2-SP1, 2012, 2016, 2019 and 2022 upstream) from the policy rule. Every Windows Server marketplace image without Azure Hybrid Benefit is reported, whatever its version.'
    }
}

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

$script:AlzControlCharacters = [regex]::new('[\x00-\x1f]')

function ConvertTo-AlzJsonString {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $escaped = $Text.Replace('\', '\\').Replace('"', '\"')
    if ($script:AlzControlCharacters.IsMatch($escaped)) {
        $escaped = $script:AlzControlCharacters.Replace($escaped, [System.Text.RegularExpressions.MatchEvaluator] { param($match) ('\u{0:x4}' -f [int][char]$match.Value) })
    }
    '"' + $escaped + '"'
}

function Get-AlzCanonicalJson {
    # Key-order independent JSON for comparing schemas and fingerprinting definitions. It does not use the PowerShell
    # serializer (ordinal key order, invariant number format, own string escaping), so a fingerprint taken on one
    # machine is valid on every machine and PowerShell version.
    param($Value)

    if ($null -eq $Value) { return 'null' }
    if ($Value -is [string]) { return ConvertTo-AlzJsonString $Value }
    if ($Value -is [bool]) { return $(if ($Value) { 'true' } else { 'false' }) }
    if ($Value -is [System.Collections.IDictionary]) {
        $parts = foreach ($key in (Get-AlzSortedKey $Value)) { '{0}:{1}' -f (ConvertTo-AlzJsonString $key), (Get-AlzCanonicalJson $Value[$key]) }
        return '{' + ($parts -join ',') + '}'
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $items = foreach ($item in $Value) { Get-AlzCanonicalJson $item }
        return '[' + ($items -join ',') + ']'
    }
    if ($Value -is [System.IFormattable]) { return $Value.ToString($null, [System.Globalization.CultureInfo]::InvariantCulture) }
    ConvertTo-AlzJsonString ([string]$Value)
}

function Get-AlzSortedObject {
    # Copy of a parsed JSON value with the keys of every object in ordinal order, which is the layout of the upstream files.
    param($Value)

    if ($Value -is [System.Collections.IDictionary]) {
        $result = [ordered]@{}
        foreach ($key in (Get-AlzSortedKey $Value)) { $result[$key] = Get-AlzSortedObject $Value[$key] }
        return $result
    }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        return , @($Value | ForEach-Object { Get-AlzSortedObject $_ })
    }
    $Value
}

function ConvertTo-AlzDefinitionJson {
    # Text of a definition file in the layout of the upstream files (ordinal key order, two-space indent, LF, no final
    # newline), so that a diff against upstream shows only the real changes.
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Definition)
    $json = ConvertTo-Json -InputObject (Get-AlzSortedObject $Definition) -Depth 100
    ($json -replace "`r`n", "`n").TrimEnd("`n")
}

function Get-AlzDefinitionFingerprint {
    # SHA-256 of a definition without everything that the audit conversion may change: the effect parameter, the effect
    # of the policy rule and the metadata that this package adds. A converted definition has the same fingerprint as its
    # upstream original, which proves that nothing but the effect handling changed.
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Definition)

    $copy = Copy-AlzObject $Definition
    $properties = $copy.properties
    if (-not $properties.Contains('parameters')) { $properties['parameters'] = [ordered]@{} }
    $then = $properties.policyRule.then
    if (([string]$then.effect) -match "^\[parameters\('(?<name>[^']+)'\)\]$") { $null = $properties.parameters.Remove($Matches.name) }
    $null = $then.Remove('effect')
    if ($properties.Contains('metadata')) {
        foreach ($key in $script:AlzAddedMetadata) { $null = $properties.metadata.Remove($key) }
    }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes((Get-AlzCanonicalJson $copy))
    [System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function Test-AlzImageSkuCondition {
    # True for a condition that tests nothing but Microsoft.Compute/imageSKU: a single condition on that field, or an
    # anyOf/allOf group made only of such conditions.
    param($Condition)

    if ($Condition -isnot [System.Collections.IDictionary]) { return $false }
    if ($Condition.Contains('field')) { return ([string]$Condition['field'] -ieq 'Microsoft.Compute/imageSKU') }
    foreach ($operator in 'anyOf', 'allOf') {
        if ($Condition.Contains($operator)) {
            $members = @($Condition[$operator])
            return ($members.Count -gt 0 -and @($members | Where-Object { -not (Test-AlzImageSkuCondition $_) }).Count -eq 0)
        }
    }
    return $false
}

function Remove-AlzImageSkuCondition {
    # Removes the conditions on Microsoft.Compute/imageSKU, which is how a list of image versions is written, from the
    # top level of the policy condition. Returns $true when something was removed and $false when nothing is left to
    # remove, so applying it to an adjusted definition changes nothing.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Edits an in-memory definition only; nothing outside the process changes.')]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Properties)

    $condition = $Properties['policyRule']['if']
    if ($condition -isnot [System.Collections.IDictionary] -or -not $condition.Contains('allOf')) { return $false }
    $all = @($condition['allOf'])
    $kept = @($all | Where-Object { -not (Test-AlzImageSkuCondition $_) })
    if ($kept.Count -eq $all.Count) { return $false }
    if ($kept.Count -eq 0) { throw 'Removing the imageSKU conditions would leave the policy condition empty.' }
    $condition['allOf'] = $kept
    return $true
}

function Get-AlzPolicyRuleAdjustment {
    # The documented policy rule adjustment of a policy, or $null when it has none.
    param([Parameter(Mandatory)][string]$Name)
    if ($script:AlzPolicyRuleAdjustments.ContainsKey($Name)) { $script:AlzPolicyRuleAdjustments[$Name] }
}

function Invoke-AlzPolicyRuleAdjustment {
    # Applies an adjustment to definition properties in place and records it in metadata.alzAdjustment. Returns $true
    # when the policy rule changed. It is idempotent: on an adjusted definition it returns $false and changes nothing.
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Adjustment,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Properties
    )

    $changed = [bool](& $Adjustment['Apply'] -Properties $Properties)
    if (-not $Properties.Contains('metadata')) { $Properties['metadata'] = [ordered]@{} }
    $Properties['metadata']['alzAdjustment'] = $Adjustment['Id']
    return $changed
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
    # Loads the definition files as records sorted by policy name: the imported ALZ definitions (origin 'upstream',
    # including the deprecated sub folder) and, when a folder is given, the definitions that are authored in this
    # repository (origin 'local'). Optional metadata is read defensively because local definitions may omit it.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DefinitionsPath,
        [string]$LocalPath
    )

    $folders = [System.Collections.Generic.List[object]]::new()
    $folders.Add(@{ Path = $DefinitionsPath; Origin = 'upstream' })
    if ($LocalPath -and (Test-Path -LiteralPath $LocalPath)) { $folders.Add(@{ Path = $LocalPath; Origin = 'local' }) }

    $records = [System.Collections.Generic.List[object]]::new()
    foreach ($folder in $folders) {
        foreach ($file in Get-ChildItem -LiteralPath $folder['Path'] -Filter '*.json' -File -Recurse) {
            $definition = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json -AsHashtable -Depth 100
            if ($definition -isnot [System.Collections.IDictionary] -or -not $definition.Contains('name') -or
                -not $definition.Contains('properties') -or $definition['properties'] -isnot [System.Collections.IDictionary]) {
                throw "$($file.FullName) is not a policy definition in the { name, type, properties } form."
            }
            $metadata = if ($definition['properties'].Contains('metadata')) { $definition['properties']['metadata'] } else { @{} }
            $records.Add([pscustomobject]@{
                    Name              = $definition['name']
                    Origin            = $folder['Origin']
                    Category          = $(if ($metadata.Contains('category')) { $metadata['category'] } else { '' })
                    Deprecated        = ($metadata.Contains('deprecated') -and $metadata['deprecated'] -eq $true)
                    CloudEnvironments = @($(if ($metadata.Contains('alzCloudEnvironments')) { $metadata['alzCloudEnvironments'] }))
                    File              = $file.FullName
                    Definition        = $definition
                })
        }
    }
    $duplicates = @($records | Group-Object Name | Where-Object { $_.Count -gt 1 })
    if ($duplicates.Count -gt 0) { throw "Policy definition name(s) used more than once: $(($duplicates | ForEach-Object { $_.Name }) -join ', ')." }
    Get-AlzSortedRecord -Record $records.ToArray()
}

function ConvertTo-AlzAuditFirstDefinition {
    # Converts a definition to audit by default and returns its properties plus a description of what was done:
    #  - the effect parameter defaults to an audit-mode effect (Audit or AuditIfNotExists);
    #  - that effect is added to the allowed values when the definition did not offer it;
    #  - a hard-coded effect becomes a parameter, so that it can be switched;
    #  - the effect that upstream applies by default stays selectable and is kept in metadata.alzUpstreamEffect.
    # The conversion is idempotent: a definition that is already converted comes back unchanged.
    # With -Local the definition is authored in this repository and has no upstream: it is never converted silently but
    # has to audit by default already (effect parameter defaulting to Audit or AuditIfNotExists, and offering that
    # default), otherwise this throws. No metadata.alzUpstreamEffect is recorded for it.
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Definition, [switch]$Local)

    $properties = Copy-AlzObject $Definition.properties
    if (-not $properties.Contains('metadata')) { $properties['metadata'] = [ordered]@{} }
    if (-not $properties.Contains('parameters')) { $properties['parameters'] = [ordered]@{} }
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
        $originalDefault = Get-AlzCanonicalEffect $schema.defaultValue
    }
    else {
        # Hard-coded effect: make it a parameter that can be switched.
        $effectParameter = 'effect'
        if ($properties.parameters.Contains($effectParameter)) {
            throw "$($Definition.name) hard-codes its effect but already defines a parameter named 'effect'."
        }
        $originalDefault = Get-AlzCanonicalEffect $effectExpression
        $allowed = @($originalDefault, 'Disabled')
        $parameterized = $true
    }
    # A definition that was converted before remembers the effect that upstream applies by default.
    $upstreamEffect = if ($properties.metadata.Contains('alzUpstreamEffect')) { Get-AlzCanonicalEffect $properties.metadata.alzUpstreamEffect } else { $originalDefault }

    $enforcing = @($allowed | Where-Object { $_ -ne 'Disabled' -and $_ -notin $script:AlzAuditEffects })
    if ($Local) {
        if ($parameterized) { throw "$($Definition.name) is a local definition and must define its effect as a parameter." }
        if ($originalDefault -notin $script:AlzAuditEffects) { throw "$($Definition.name) is a local definition and must default to Audit or AuditIfNotExists, not $originalDefault." }
        $auditEffect = $originalDefault
    }
    else {
        $auditEffect = $script:AlzAuditEffects | Where-Object { $_ -in $allowed } | Select-Object -First 1
        if (-not $auditEffect) {
            $candidates = @($enforcing | ForEach-Object { $script:AlzAuditEffectFor[$_] } | Select-Object -Unique)
            if ($candidates.Count -ne 1 -or -not $candidates[0]) {
                throw "Cannot choose an audit-mode effect for $($Definition.name) (effects: $($allowed -join ', '))."
            }
            $auditEffect = $candidates[0]
        }
    }
    $extended = $auditEffect -notin $allowed
    if ($extended -and $Local) { throw "$($Definition.name) is a local definition and must list its default effect $auditEffect in the allowed values of its effect parameter." }
    if ($extended) { $allowed = @($auditEffect) + $allowed }

    if ($parameterized) {
        $properties.parameters[$effectParameter] = [ordered]@{
            allowedValues = $allowed
            defaultValue  = $auditEffect
            metadata      = [ordered]@{ description = 'Enable or disable the execution of the policy'; displayName = 'Effect' }
            type          = 'String'
        }
        $then['effect'] = "[parameters('$effectParameter')]"
    }
    else {
        if ($extended) { $schema['allowedValues'] = @($auditEffect) + @($schema.allowedValues) }
        $schema['defaultValue'] = $auditEffect
    }
    if (-not $Local) { $properties.metadata['alzUpstreamEffect'] = $upstreamEffect }

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
        UpstreamEffect        = $upstreamEffect
        DefaultChanged        = ($originalDefault -ne $auditEffect)
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
        $isLocal = $item.Origin -eq 'local'
        $adapted = ConvertTo-AlzAuditFirstDefinition -Definition $item.Definition -Local:$isLocal
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
        if ($isLocal) { $metadata['alzOrigin'] = 'local' } else { $metadata['alzLibraryVersion'] = $Source.version }

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
        description       = "All custom Azure Landing Zones policies in one initiative. Every policy audits by default (Audit or AuditIfNotExists); switch a policy to Deny, DeployIfNotExists, Modify, Append or DenyAction through its <policy>_effect parameter when assigning. ALZ Library $($Source.version)."
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
            if ($effectSchema.defaultValue -notin $script:AlzAuditEffects -or $effectSchema.defaultValue -ne $adapted.AuditEffect) {
                $problems.Add("${name}: the definition must default to its audit-mode effect $($adapted.AuditEffect), not '$($effectSchema.defaultValue)'.")
            }
            if ('Disabled' -notin @($effectSchema.allowedValues)) { $problems.Add("${name}: Disabled must stay allowed.") }
            if ($adapted.UpstreamEffect -notin @($effectSchema.allowedValues)) { $problems.Add("${name}: the upstream effect $($adapted.UpstreamEffect) is no longer selectable.") }
            if ($definition.Record.Origin -eq 'upstream' -and $properties.metadata.alzUpstreamEffect -ne $adapted.UpstreamEffect) { $problems.Add("${name}: metadata.alzUpstreamEffect is missing or wrong.") }
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

function Test-AlzStoredDefinition {
    # Checks one imported definition file against the import manifest. Returns a list of problems (empty when it is
    # sound): it must be in converted form (the conversion changes nothing), record its upstream effect, and equal the
    # upstream original in everything but the effect handling (fingerprint). A definition with a documented policy rule
    # adjustment must also be in adjusted form and match the fingerprint that the import recorded for the adjusted result.
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Record, [Parameter(Mandatory)][System.Collections.IDictionary]$Source)

    $problems = [System.Collections.Generic.List[string]]::new()
    $name = $Record.Name
    try {
        $stored = $Record.Definition
        $converted = ConvertTo-AlzAuditFirstDefinition -Definition $stored
        $effectSchema = $stored.properties.parameters[$converted.EffectParameter]

        if ($stored.properties.policyRule.then.effect -ne "[parameters('$($converted.EffectParameter)')]") { $problems.Add("${name}: the effect is not a parameter.") }
        if ($effectSchema.defaultValue -notin $script:AlzAuditEffects) { $problems.Add("${name}: defaults to '$($effectSchema.defaultValue)', not to an audit-mode effect.") }
        if (-not $stored.properties.metadata.Contains('alzUpstreamEffect')) { $problems.Add("${name}: metadata.alzUpstreamEffect is missing.") }
        elseif ($converted.UpstreamEffect -notin @($effectSchema.allowedValues)) { $problems.Add("${name}: the upstream effect $($converted.UpstreamEffect) is not selectable.") }
        if ((Get-AlzCanonicalJson $converted.Properties) -ne (Get-AlzCanonicalJson $stored.properties)) { $problems.Add("${name}: not in audit-by-default form; run Import-AlzPolicy.ps1.") }

        $conversion = if ($Source.Contains('conversion')) { $Source.conversion } else { @{} }
        $adjustment = Get-AlzPolicyRuleAdjustment -Name $name
        $recorded = if ($conversion.Contains('adjustments') -and $conversion.adjustments.Contains($name)) { $conversion.adjustments[$name] } else { $null }
        $storedAdjustment = if ($stored.properties.metadata.Contains('alzAdjustment')) { $stored.properties.metadata.alzAdjustment } else { $null }

        $expected = $null
        if ($adjustment) {
            if ($storedAdjustment -ne $adjustment.Id) { $problems.Add("${name}: metadata.alzAdjustment should be '$($adjustment.Id)'.") }
            $copy = Copy-AlzObject $stored.properties
            if (Invoke-AlzPolicyRuleAdjustment -Adjustment $adjustment -Properties $copy) { $problems.Add("${name}: the policy rule is not adjusted ($($adjustment.Id)); run Import-AlzPolicy.ps1.") }
            if ($null -eq $recorded) { $problems.Add("${name}: alz-library-source.json does not record the adjustment $($adjustment.Id).") }
            else {
                if ($recorded.id -ne $adjustment.Id -or $recorded.description -ne $adjustment.Description) { $problems.Add("${name}: the adjustment in alz-library-source.json is out of date; run Import-AlzPolicy.ps1.") }
                $expected = $recorded.adjustedFingerprint
            }
        }
        else {
            if ($null -ne $storedAdjustment) { $problems.Add("${name}: metadata.alzAdjustment is '$storedAdjustment', but no such adjustment is defined in AlzPolicy.Common.ps1.") }
            if ($null -ne $recorded) { $problems.Add("${name}: alz-library-source.json records an adjustment that is not defined in AlzPolicy.Common.ps1.") }
            if ($conversion.Contains('upstreamFingerprints') -and $conversion.upstreamFingerprints.Contains($name)) { $expected = $conversion.upstreamFingerprints[$name] }
        }
        if (-not $expected) { $problems.Add("${name}: no fingerprint in alz-library-source.json.") }
        elseif ((Get-AlzDefinitionFingerprint -Definition $stored) -ne $expected) {
            $problems.Add("${name}: differs from the $(if ($adjustment) { 'recorded adjusted' } else { 'upstream' }) definition in more than its effect handling.")
        }
    }
    catch {
        $problems.Add("${name}: the definition is malformed ($($_.Exception.Message)).")
    }
    $problems.ToArray()
}

function Test-AlzLocalDefinition {
    # Checks one definition that is authored in this repository (local-definitions/). It is never converted, so it has
    # to audit by default already: an effect parameter that defaults to Audit or AuditIfNotExists, offers that default
    # and Disabled, and uses only documented effects. Returns a list of problems (empty when it is sound).
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Record)

    $problems = [System.Collections.Generic.List[string]]::new()
    $name = $Record.Name
    try {
        $stored = $Record.Definition
        $properties = $stored.properties
        if (-not $stored.Contains('type') -or $stored.type -ne 'Microsoft.Authorization/policyDefinitions') { $problems.Add("${name}: type must be Microsoft.Authorization/policyDefinitions.") }
        if (-not $properties.Contains('policyType') -or $properties.policyType -ne 'Custom') { $problems.Add("${name}: policyType must be Custom.") }
        $converted = ConvertTo-AlzAuditFirstDefinition -Definition $stored -Local
        $effectSchema = $properties.parameters[$converted.EffectParameter]
        if ($effectSchema.type -ne 'String') { $problems.Add("${name}: the effect parameter must be a String.") }
        if ('Disabled' -notin @($effectSchema.allowedValues)) { $problems.Add("${name}: the effect parameter must allow Disabled.") }
        $reserved = @(($script:AlzAddedMetadata + 'alzOrigin') | Where-Object { $properties.Contains('metadata') -and $properties.metadata.Contains($_) })
        if ($reserved.Count -gt 0) { $problems.Add("${name}: metadata $($reserved -join ', ') is set by the package; remove it from the file.") }
    }
    catch {
        $problems.Add("${name}: $($_.Exception.Message)")
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
            Origin     = $definition.Record.Origin
            Default    = $adapted.AuditEffect
            SwitchTo   = @($adapted.AllowedEffects | Where-Object { $_ -ne 'Disabled' -and $_ -ne $adapted.AuditEffect }) -join ', '
            Roles      = (@($adapted.RoleNames | Select-Object -Unique | Sort-Object { $_ } -Culture ([cultureinfo]::InvariantCulture) -CaseSensitive)) -join ', '
            Parameter  = "$(ConvertTo-AlzKey $definition.PolicyName)_effect"
            Upstream   = $(if ($definition.Record.Origin -eq 'local') { 'n/a (local)' } else { $adapted.UpstreamEffect })
        }
    }
    $upstreamRows = @($rows | Where-Object { $_.Origin -eq 'upstream' })
    $localRows = @($rows | Where-Object { $_.Origin -eq 'local' })
    $localNames = @($localRows | ForEach-Object { $_.Name })
    $active = @($rows | Where-Object { -not $_.Deprecated })
    $deprecated = @($rows | Where-Object { $_.Deprecated })
    $upstreamActive = @($upstreamRows | Where-Object { -not $_.Deprecated })
    $converted = @($upstreamRows | Where-Object { $_.Upstream -ne $_.Default })
    $convertedActive = @($converted | Where-Object { -not $_.Deprecated })
    $details = if ($Source.Contains('conversion')) { $Source.conversion } else { @{} }
    $extended = if ($details.Contains('auditEffectAdded')) { $details.auditEffectAdded } else { 0 }
    $parameterized = if ($details.Contains('effectParameterized')) { $details.effectParameterized } else { 0 }
    $adjustments = if ($details.Contains('adjustments')) { $details['adjustments'] } else { @{} }

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('# ALZ custom policy catalog')
    $lines.Add('')
    $lines.Add("Generated by ``Import-AlzPolicy.ps1`` from $($Source.repository) at ``$($Source.ref)`` (commit ``$($Source.commit)``). Do not edit by hand.")
    $lines.Add('')
    $lines.Add("- **$($upstreamRows.Count)** custom policy definitions imported from ALZ: **$($upstreamActive.Count)** active and **$($upstreamRows.Count - $upstreamActive.Count)** deprecated upstream. Deprecated ones are published only with ``-IncludeDeprecated``.")
    if ($localRows.Count -gt 0) {
        $localList = ($localRows | ForEach-Object { '`' + $_.Name + '`' }) -join ', '
        $lines.Add("- **$($localRows.Count)** local definition(s) authored in this repository (``local-definitions/``), not imported from ALZ: $localList. They audit by default like the others, are part of the initiative and are never touched by the import.")
    }
    $lines.Add("- Every imported definition is converted to audit by default. **$($converted.Count)** of them (**$($convertedActive.Count)** active) applied an enforcing effect upstream (Deny, DeployIfNotExists, Modify, Append or DenyAction); the others already audited. The **Default** column is the effect that applies unless you choose another one, both when a definition is assigned on its own and through the initiative. The upstream effect stays selectable, is shown as **Upstream default** and is recorded in each definition's ``metadata.alzUpstreamEffect``. Every policy also accepts ``Disabled``.")
    $lines.Add("- To default to audit, **$extended** of the $($upstreamRows.Count) imported definitions got an audit-mode effect added to their allowed values and **$parameterized** turned a hard-coded effect into a parameter.")
    if ($adjustments.Count -gt 0) {
        $lines.Add("- **$($adjustments.Count)** imported policy rule(s) are adjusted compared to upstream (see [Adjusted policy rules](#adjusted-policy-rules)); every other policy rule is upstream's.")
    }
    $lines.Add('- Effect parameter name: the policy name with every non-alphanumeric character replaced by `_`, followed by `_effect`.')
    $lines.Add('- The roles column lists what the assignment identity needs when the policy is switched to a deploying or modifying effect.')
    $lines.Add('')

    $render = {
        param($items)
        $out = [System.Collections.Generic.List[string]]::new()
        $out.Add('| Policy | Display name | Category | Default | Upstream default | Switch to | Roles for Deploy/Modify | Effect parameter |')
        $out.Add('| --- | --- | --- | --- | --- | --- | --- | --- |')
        foreach ($row in $items) {
            $out.Add("| ``$($row.Name)`` | $(& $escape $row.Display) | $($row.Category) | $($row.Default) | $($row.Upstream) | $($row.SwitchTo) | $($row.Roles) | ``$($row.Parameter)`` |")
        }
        $out
    }

    if ($adjustments.Count -gt 0) {
        $lines.Add('## Adjusted policy rules')
        $lines.Add('')
        $lines.Add('Deliberate changes to an imported policy rule. `Import-AlzPolicy.ps1` applies them and records each one in `metadata.alzAdjustment` of the definition and in `alz-library-source.json`. The import fails when an adjustment no longer finds anything to change, so each one is reviewed against every new upstream release.')
        $lines.Add('')
        $lines.Add('| Policy | Adjustment | What changed |')
        $lines.Add('| --- | --- | --- |')
        foreach ($adjusted in $adjustments.GetEnumerator()) {
            $lines.Add("| ``$($adjusted.Key)`` | ``$($adjusted.Value['id'])`` | $(& $escape $adjusted.Value['description']) |")
        }
        $lines.Add('')
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
    $lines.Add('Parameters that are not effects. Those marked *placeholder* have no default in their definition, so an empty value is used until you set one; it only matters once the policy is switched to a deploying effect. Those marked *local* belong to a local definition, the others to an imported one. Parameters used only by deprecated policies exist only with `-IncludeDeprecated`.')
    $lines.Add('')
    $lines.Add('| Initiative parameter | Used by | Type | Default | Origin |')
    $lines.Add('| --- | --- | --- | --- | --- |')
    foreach ($entry in $usage.GetEnumerator()) {
        $schema = $package.Initiative.Properties.parameters[$entry.Key]
        $default = (ConvertTo-Json -InputObject $schema.defaultValue -Compress -Depth 20)
        if ($default.Length -gt 80) { $default = $default.Substring(0, 77) + '...' }
        $origin = if ($schema.metadata.Contains('alzPlaceholderDefault')) { 'placeholder' } elseif (@($entry.Value | Where-Object { $_ -notin $localNames }).Count -eq 0) { 'local' } else { 'upstream' }
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
