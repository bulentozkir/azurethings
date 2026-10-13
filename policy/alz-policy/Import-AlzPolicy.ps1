#requires -Version 7.2

<#
.SYNOPSIS
    Imports the custom Azure Landing Zones (ALZ) policy definitions into ./definitions, converted to audit by default.

.DESCRIPTION
    Downloads a tagged release of https://github.com/Azure/Azure-Landing-Zones-Library (or reads a local checkout),
    converts every platform/alz/policy_definitions file to audit by default and writes it to definitions/
    (definitions/deprecated/ for the ones flagged deprecated upstream). The conversion changes only the effect handling:

      - the effect parameter defaults to Audit or AuditIfNotExists (the audit-mode effect of the policy) instead of
        Deny, DeployIfNotExists, Modify, Append or DenyAction;
      - the audit-mode effect is added to the allowed values when the definition did not offer it, and a hard-coded
        effect becomes a parameter, so the upstream effect stays selectable;
      - the effect that upstream applies by default is kept in metadata.alzUpstreamEffect.

    A few policy rules carry a deliberate adjustment ($script:AlzPolicyRuleAdjustments in AlzPolicy.Common.ps1). The
    import applies it after the conversion, requires that it finds something to change in upstream's rule, and records
    it in metadata.alzAdjustment of the definition and, with the fingerprint of the result, in alz-library-source.json.

    Every converted file is checked before it is written: the conversion alone must keep the fingerprint of its
    upstream original (so nothing but the effect handling changed), and converting or adjusting the written file again
    must change nothing. The script also regenerates alz-library-source.json (provenance, conversion counts, adjustments
    and the upstream fingerprints), the upstream licence copy and policy-catalog.md. Re-run it with a newer -Ref to
    refresh the import, then run Test-AlzPolicy.ps1.

    Edits to the files in definitions/ are overwritten by an import; change an effect per assignment instead. Policies
    that you author yourself belong in local-definitions/, which the import never touches. It refuses to run when
    definitions/ holds files that it did not create (it would delete them) or when a local definition has the name of an
    upstream definition. With -CatalogOnly it regenerates policy-catalog.md from the files on disk without any download,
    for example after editing a local definition.

.PARAMETER Ref
    Tag, branch or commit of the library to import. Release tags look like platform/alz/2026.10.0.

.PARAMETER Repository
    GitHub repository (owner/name) that hosts the library.

.PARAMETER LibraryPath
    Use an existing local checkout of the library instead of downloading it.

.PARAMETER CatalogOnly
    Only regenerate policy-catalog.md from definitions/ and local-definitions/. Cannot be combined with -Ref,
    -Repository or -LibraryPath.

.EXAMPLE
    ./Import-AlzPolicy.ps1 -WhatIf

.EXAMPLE
    ./Import-AlzPolicy.ps1 -Ref platform/alz/2026.10.0

.EXAMPLE
    ./Import-AlzPolicy.ps1 -CatalogOnly
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateNotNullOrEmpty()]
    [string]$Ref = 'platform/alz/2026.10.0',

    [ValidatePattern('^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$')]
    [string]$Repository = 'Azure/Azure-Landing-Zones-Library',

    [string]$LibraryPath,

    [switch]$CatalogOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'AlzPolicy.Common.ps1')

$definitionsPath = Join-Path $PSScriptRoot 'definitions'
$deprecatedPath = Join-Path $definitionsPath 'deprecated'
$localPath = Join-Path $PSScriptRoot 'local-definitions'
$manifestPath = Join-Path $PSScriptRoot 'alz-library-source.json'
$catalogPath = Join-Path $PSScriptRoot 'policy-catalog.md'
$workPath = Join-Path ([System.IO.Path]::GetTempPath()) "alz-import-$([guid]::NewGuid().ToString('N'))"
$commit = 'unknown'
$utf8 = [System.Text.UTF8Encoding]::new($false)

if ($CatalogOnly) {
    if ($PSBoundParameters.ContainsKey('Ref') -or $PSBoundParameters.ContainsKey('Repository') -or $PSBoundParameters.ContainsKey('LibraryPath')) {
        throw '-CatalogOnly regenerates policy-catalog.md from the files on disk and does not download anything; do not combine it with -Ref, -Repository or -LibraryPath.'
    }
    $source = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -AsHashtable
    $records = @(Get-AlzPolicyRecord -DefinitionsPath $definitionsPath -LocalPath $localPath)
    $catalog = Format-AlzPolicyCatalog -Record $records -Source $source
    if ($PSCmdlet.ShouldProcess($catalogPath, "Regenerate the catalog from $($records.Count) definition files")) {
        [System.IO.File]::WriteAllText($catalogPath, ($catalog + "`n"), $utf8)
        Write-Host "Regenerated policy-catalog.md from $($records.Count) definitions ($(@($records | Where-Object { $_.Origin -eq 'local' }).Count) local)."
    }
    return
}

try {
    if ($LibraryPath) {
        $libraryRoot = (Resolve-Path -LiteralPath $LibraryPath).Path
        $git = Get-Command git -ErrorAction SilentlyContinue
        if ($git) {
            $head = & $git.Source -C $libraryRoot rev-parse HEAD 2>$null
            if ($LASTEXITCODE -eq 0 -and $head) { $commit = $head.Trim() }
        }
    }
    else {
        New-Item -ItemType Directory -Path $workPath -WhatIf:$false | Out-Null
        $zipPath = Join-Path $workPath 'library.zip'
        Write-Host "Downloading $Repository at $Ref ..."
        Invoke-WebRequest -Uri "https://codeload.github.com/$Repository/zip/$Ref" -OutFile $zipPath
        Expand-Archive -LiteralPath $zipPath -DestinationPath $workPath -WhatIf:$false
        $libraryRoot = (Get-ChildItem -LiteralPath $workPath -Directory | Select-Object -First 1).FullName
        try {
            $commit = (Invoke-RestMethod -Uri "https://api.github.com/repos/$Repository/commits/$([uri]::EscapeDataString($Ref))" -Headers @{ Accept = 'application/vnd.github.sha'; 'User-Agent' = 'azurethings-alz-import' }).ToString().Trim()
        }
        catch {
            Write-Warning "Could not resolve the commit for $Ref ($($_.Exception.Message)); recording 'unknown'."
        }
    }

    $sourcePath = Join-Path $libraryRoot 'platform/alz/policy_definitions'
    if (-not (Test-Path -LiteralPath $sourcePath)) { $sourcePath = Join-Path $libraryRoot 'policy_definitions' }
    if (-not (Test-Path -LiteralPath $sourcePath)) { throw "No platform/alz/policy_definitions folder found under $libraryRoot." }
    $files = @(Get-ChildItem -LiteralPath $sourcePath -Filter '*.alz_policy_definition.json' -File)
    if ($files.Count -eq 0) { throw "No *.alz_policy_definition.json files found in $sourcePath." }

    # Convert and check every definition before anything is written.
    $plan = [System.Collections.Generic.List[object]]::new()
    foreach ($file in $files) {
        $definition = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json -AsHashtable -Depth 100
        $name = $definition.name
        if ($file.Name -ne "$name.alz_policy_definition.json") { throw "$($file.Name) contains policy '$name'; the file name must match." }
        $metadata = $definition.properties.metadata
        $deprecated = $metadata.Contains('deprecated') -and $metadata.deprecated -eq $true

        $conversion = ConvertTo-AlzAuditFirstDefinition -Definition $definition
        $converted = [ordered]@{}
        foreach ($key in $definition.Keys) { $converted[$key] = if ($key -eq 'properties') { $conversion.Properties } else { $definition[$key] } }

        # Proof 1: the audit conversion alone changes nothing but the effect handling.
        $fingerprint = Get-AlzDefinitionFingerprint -Definition $definition
        if ((Get-AlzDefinitionFingerprint -Definition $converted) -ne $fingerprint) { throw "${name}: the converted definition differs from upstream in more than its effect handling. Nothing was written." }

        # A documented policy rule adjustment is applied on top and has to find something to change in upstream's rule.
        $adjustment = Get-AlzPolicyRuleAdjustment -Name $name
        if ($adjustment -and -not (Invoke-AlzPolicyRuleAdjustment -Adjustment $adjustment -Properties $conversion.Properties)) {
            throw "${name}: the adjustment '$($adjustment.Id)' found nothing to change in the upstream policy rule. Upstream may have changed it; review `$script:AlzPolicyRuleAdjustments in AlzPolicy.Common.ps1. Nothing was written."
        }

        # Proof 2: what is written reads back identically, converting or adjusting it again changes nothing, and without
        # an adjustment it still has the upstream fingerprint.
        $json = ConvertTo-AlzDefinitionJson -Definition $converted
        $readBack = $json | ConvertFrom-Json -AsHashtable -Depth 100
        $storedFingerprint = Get-AlzDefinitionFingerprint -Definition $readBack
        if (-not $adjustment -and $storedFingerprint -ne $fingerprint) { throw "${name}: the written definition differs from upstream in more than its effect handling. Nothing was written." }
        $again = ConvertTo-AlzAuditFirstDefinition -Definition $readBack
        if ((Get-AlzCanonicalJson $again.Properties) -ne (Get-AlzCanonicalJson $readBack.properties)) { throw "${name}: converting the converted definition changes it again. Nothing was written." }
        if ($adjustment) {
            $copy = Copy-AlzObject $readBack.properties
            if ((Invoke-AlzPolicyRuleAdjustment -Adjustment $adjustment -Properties $copy) -or (Get-AlzCanonicalJson $copy) -ne (Get-AlzCanonicalJson $readBack.properties)) {
                throw "${name}: applying the adjustment again changes the adjusted definition. Nothing was written."
            }
        }

        $folder = if ($deprecated) { $deprecatedPath } else { $definitionsPath }
        $plan.Add([pscustomobject]@{
                Name              = $name
                Deprecated        = $deprecated
                Target            = Join-Path $folder "$name.json"
                Json              = $json
                Fingerprint       = $fingerprint
                StoredFingerprint = $storedFingerprint
                Adjustment        = $adjustment
                Conversion        = $conversion
            })
    }
    $plan = @(Get-AlzSortedRecord -Record $plan.ToArray())

    # Protect what the import did not create: it replaces definitions/ completely.
    $localNames = @(if (Test-Path -LiteralPath $localPath) { Get-ChildItem -LiteralPath $localPath -Filter '*.json' -File -Recurse | ForEach-Object { $_.BaseName } })
    $clashes = @($plan | Where-Object { $_.Name -in $localNames } | ForEach-Object { $_.Name })
    if ($clashes.Count -gt 0) { throw "Local definition(s) in local-definitions/ have the name of an upstream definition: $($clashes -join ', '). Rename or delete the local one. Nothing was written." }
    $previousNames = @()
    if (Test-Path -LiteralPath $manifestPath) {
        $previous = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -AsHashtable
        if ($previous.Contains('conversion') -and $previous.conversion.Contains('upstreamFingerprints')) { $previousNames = @($previous.conversion.upstreamFingerprints.Keys) }
    }
    $knownNames = @($previousNames) + @($plan | ForEach-Object { $_.Name })
    $stray = @(if (Test-Path -LiteralPath $definitionsPath) { Get-ChildItem -LiteralPath $definitionsPath -Filter '*.json' -File -Recurse | Where-Object { $_.BaseName -notin $knownNames } })
    if ($stray.Count -gt 0) {
        throw "definitions/ holds $($stray.Count) file(s) that are not ALZ definitions and that the import would delete: $(($stray | ForEach-Object { $_.Name }) -join ', '). Move your own policy definitions to local-definitions/ (see README.md) or delete the files. Nothing was written."
    }

    $deprecatedCount = @($plan | Where-Object { $_.Deprecated }).Count
    $changed = @($plan | Where-Object { $_.Conversion.DefaultChanged })
    $added = @($plan | Where-Object { $_.Conversion.AllowedValuesExtended })
    $parameterized = @($plan | Where-Object { $_.Conversion.EffectParameterized })
    $adjusted = @($plan | Where-Object { $_.Adjustment })
    Write-Host "Found $($plan.Count) custom policy definitions ($($plan.Count - $deprecatedCount) active, $deprecatedCount deprecated)."
    Write-Host "Converted to audit by default: $($changed.Count) applied another effect upstream, $($plan.Count - $changed.Count) already audited. $($added.Count) got an audit-mode effect added to their allowed values; $($parameterized.Count) hard-coded effects became parameters."
    if ($adjusted.Count -gt 0) { Write-Host "Policy rule adjusted: $(($adjusted | ForEach-Object { "$($_.Name) ($($_.Adjustment.Id))" }) -join ', ')." }

    if ($PSCmdlet.ShouldProcess($definitionsPath, "Replace the imported definitions with $($plan.Count) policies from $Repository at $Ref, converted to audit by default")) {
        if (Test-Path -LiteralPath $definitionsPath) {
            Get-ChildItem -LiteralPath $definitionsPath -Filter '*.json' -File -Recurse | Remove-Item -Force
        }
        New-Item -ItemType Directory -Path $deprecatedPath -Force | Out-Null
        foreach ($item in $plan) { [System.IO.File]::WriteAllText($item.Target, $item.Json, $utf8) }

        $licenseSource = Join-Path $libraryRoot 'LICENSE'
        if (Test-Path -LiteralPath $licenseSource) {
            Copy-Item -LiteralPath $licenseSource -Destination (Join-Path $PSScriptRoot 'LICENSE-Azure-Landing-Zones-Library.txt') -Force
        }
        else {
            Write-Warning 'The library has no LICENSE file at its root; keep the upstream licence notice with the imported files.'
        }

        $fingerprints = [ordered]@{}
        foreach ($item in $plan) { $fingerprints[$item.Name] = $item.Fingerprint }
        $adjustments = [ordered]@{}
        foreach ($item in $adjusted) {
            $adjustments[$item.Name] = [ordered]@{ id = $item.Adjustment.Id; description = $item.Adjustment.Description; adjustedFingerprint = $item.StoredFingerprint }
        }
        $version = if ($Ref -match '(\d{4}\.\d{2}\.\d+)$') { $Matches[1] } else { $Ref }
        $source = [ordered]@{
            repository  = "https://github.com/$Repository"
            path        = 'platform/alz/policy_definitions'
            ref         = $Ref
            version     = $version
            commit      = $commit
            importedOn  = (Get-Date -Format 'yyyy-MM-dd')
            license     = 'MIT'
            definitions = [ordered]@{ total = $plan.Count; active = $plan.Count - $deprecatedCount; deprecated = $deprecatedCount }
            conversion  = [ordered]@{
                summary              = "Every definition defaults to Audit or AuditIfNotExists. The upstream effect stays selectable and is recorded in metadata.alzUpstreamEffect. Policy rules are upstream's except for the documented adjustments."
                defaultChanged       = $changed.Count
                auditEffectAdded     = $added.Count
                effectParameterized  = $parameterized.Count
                policyRuleAdjusted   = $adjusted.Count
                fingerprintOf        = 'SHA-256 of the upstream definition without its effect parameter, the effect of its policy rule and the metadata keys that this package adds (Get-AlzDefinitionFingerprint in AlzPolicy.Common.ps1). For an adjusted definition, adjustments[name].adjustedFingerprint is the same fingerprint of the stored, adjusted definition.'
                adjustments          = $adjustments
                upstreamFingerprints = $fingerprints
            }
        }
        [System.IO.File]::WriteAllText($manifestPath, (((ConvertTo-Json -InputObject $source -Depth 10) -replace "`r`n", "`n") + "`n"), $utf8)

        $records = @(Get-AlzPolicyRecord -DefinitionsPath $definitionsPath -LocalPath $localPath)
        $readBack = @($records | Where-Object { $_.Origin -eq 'upstream' })
        if ($readBack.Count -ne $plan.Count) { throw "Wrote $($plan.Count) definitions but read back $($readBack.Count)." }
        $catalog = Format-AlzPolicyCatalog -Record $records -Source $source
        [System.IO.File]::WriteAllText($catalogPath, ($catalog + "`n"), $utf8)
        Write-Host "Imported $($plan.Count) definitions from $Repository at $Ref ($commit). Run ./Test-AlzPolicy.ps1 next."
    }
}
finally {
    if (Test-Path -LiteralPath $workPath) { Remove-Item -LiteralPath $workPath -Recurse -Force -ErrorAction SilentlyContinue -WhatIf:$false }
}
