#requires -Version 7.2

<#
.SYNOPSIS
    Offline checks for the ALZ policy package. Needs no Azure access.

.DESCRIPTION
    Verifies the imported definitions, the generated audit-first initiative, the generated catalog, and runs
    Deploy-AlzPolicy.ps1 end to end against an in-memory stand-in for Azure Resource Manager that applies the same kind
    of validation the Policy service does (effect parameter, allowed values, parameter bindings, referenced definitions).
    Exits with a non-zero code when a check fails. Run it after every ./Import-AlzPolicy.ps1.

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

$deployScript = Join-Path $PSScriptRoot 'Deploy-AlzPolicy.ps1'
$source = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'alz-library-source.json') -Raw | ConvertFrom-Json -AsHashtable
$records = @(Get-AlzPolicyRecord -DefinitionsPath (Join-Path $PSScriptRoot 'definitions'))
$activeRecords = @($records | Where-Object { -not $_.Deprecated })
$scope = '/providers/Microsoft.Management/managementGroups/contoso'

# ---- 1. Imported definitions -------------------------------------------------------------------------------------------
Write-Section 'Imported definitions'
Assert-That ($records.Count -eq $source.definitions.total) "Imported $($records.Count) definitions but alz-library-source.json says $($source.definitions.total)."
Assert-That ($activeRecords.Count -eq $source.definitions.active) "Found $($activeRecords.Count) active definitions, expected $($source.definitions.active)."
Assert-That (($records.Count - $activeRecords.Count) -eq $source.definitions.deprecated) 'The deprecated definition count differs from alz-library-source.json.'
Assert-That (@($records.Name | Sort-Object -Unique).Count -eq $records.Count) 'Policy names are not unique.'
foreach ($record in $records) {
    $leaf = Split-Path -Leaf $record.File
    $folder = Split-Path -Leaf (Split-Path -Parent $record.File)
    Assert-That ($leaf -eq "$($record.Name).json") "$leaf does not hold policy $($record.Name)."
    Assert-That (($folder -eq 'deprecated') -eq $record.Deprecated) "$($record.Name) is in the wrong folder for its deprecated flag."
    Assert-That ($record.Definition.type -eq 'Microsoft.Authorization/policyDefinitions' -and $record.Definition.properties.policyType -eq 'Custom') "$($record.Name) is not a custom policy definition."
}
Assert-That (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'LICENSE-Azure-Landing-Zones-Library.txt')) 'The upstream licence copy is missing.'

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
    @{ Name = 'DenyAction-DiagnosticLogs'; Default = 'AuditAction'; Allowed = 'AuditAction', 'DenyAction', 'Disabled' }
    @{ Name = 'Deploy-Budget'; Default = 'AuditIfNotExists'; Allowed = 'DeployIfNotExists', 'AuditIfNotExists', 'Disabled' }
)
foreach ($expectation in $expectations) {
    $schema = $parameters["$(ConvertTo-AlzKey $expectation.Name)_effect"]
    Assert-That ($null -ne $schema -and $schema.defaultValue -eq $expectation.Default) "$($expectation.Name) should default to $($expectation.Default)."
    Assert-That ($null -ne $schema -and (@($schema.allowedValues) | Sort-Object) -join ',' -eq (@($expectation.Allowed) | Sort-Object) -join ',') "$($expectation.Name) should allow $($expectation.Allowed -join ', ')."
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
    'a changed policy condition'              = { param($p) $p.Definitions[0].Properties.policyRule['if'] = @{ field = 'type'; equals = 'x' } }
    'a duplicate reference id'                = { param($p) $p.Initiative.Properties.policyDefinitions[1].policyDefinitionReferenceId = $p.Initiative.Properties.policyDefinitions[0].policyDefinitionReferenceId }
}
foreach ($mutation in $mutations.GetEnumerator()) {
    $copy = Build-AlzPolicyPackage -Record $sample -Scope $scope -InitiativeName 'x' -DisplayName 'x' -Source $source
    & $mutation.Value $copy
    Assert-That (@(Test-AlzPolicyPackage -Package $copy).Count -gt 0) "The validator did not catch $($mutation.Key)."
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
