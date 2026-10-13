#requires -Version 7.2

<#
.SYNOPSIS
    Imports the custom Azure Landing Zones (ALZ) policy definitions into ./definitions.

.DESCRIPTION
    Downloads a tagged release of https://github.com/Azure/Azure-Landing-Zones-Library (or reads a local checkout),
    copies every platform/alz/policy_definitions file unchanged into definitions/ (definitions/deprecated/ for the ones
    flagged deprecated upstream), and regenerates alz-library-source.json, the upstream licence copy and
    policy-catalog.md. Re-run it with a newer -Ref to refresh the import, then run Test-AlzPolicy.ps1.

.PARAMETER Ref
    Tag, branch or commit of the library to import. Release tags look like platform/alz/2026.10.0.

.PARAMETER Repository
    GitHub repository (owner/name) that hosts the library.

.PARAMETER LibraryPath
    Use an existing local checkout of the library instead of downloading it.

.EXAMPLE
    ./Import-AlzPolicy.ps1 -WhatIf

.EXAMPLE
    ./Import-AlzPolicy.ps1 -Ref platform/alz/2026.10.0
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateNotNullOrEmpty()]
    [string]$Ref = 'platform/alz/2026.10.0',

    [ValidatePattern('^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$')]
    [string]$Repository = 'Azure/Azure-Landing-Zones-Library',

    [string]$LibraryPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'AlzPolicy.Common.ps1')

$definitionsPath = Join-Path $PSScriptRoot 'definitions'
$deprecatedPath = Join-Path $definitionsPath 'deprecated'
$workPath = Join-Path ([System.IO.Path]::GetTempPath()) "alz-import-$([guid]::NewGuid().ToString('N'))"
$commit = 'unknown'

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

    $plan = foreach ($file in $files) {
        $definition = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json -AsHashtable -Depth 100
        $name = $definition.name
        if ($file.Name -ne "$name.alz_policy_definition.json") { throw "$($file.Name) contains policy '$name'; the file name must match." }
        $metadata = $definition.properties.metadata
        $deprecated = $metadata.Contains('deprecated') -and $metadata.deprecated -eq $true
        $folder = if ($deprecated) { $deprecatedPath } else { $definitionsPath }
        [pscustomobject]@{ Name = $name; Source = $file.FullName; Deprecated = $deprecated; Target = Join-Path $folder "$name.json" }
    }
    $plan = @($plan)
    $deprecatedCount = @($plan | Where-Object Deprecated).Count
    Write-Host "Found $($plan.Count) custom policy definitions ($($plan.Count - $deprecatedCount) active, $deprecatedCount deprecated)."

    if ($PSCmdlet.ShouldProcess($definitionsPath, "Replace the imported definitions with $($plan.Count) policies from $Repository at $Ref")) {
        if (Test-Path -LiteralPath $definitionsPath) {
            Get-ChildItem -LiteralPath $definitionsPath -Filter '*.json' -File -Recurse | Remove-Item -Force
        }
        New-Item -ItemType Directory -Path $deprecatedPath -Force | Out-Null
        foreach ($item in $plan) { Copy-Item -LiteralPath $item.Source -Destination $item.Target -Force }

        $licenseSource = Join-Path $libraryRoot 'LICENSE'
        if (Test-Path -LiteralPath $licenseSource) {
            Copy-Item -LiteralPath $licenseSource -Destination (Join-Path $PSScriptRoot 'LICENSE-Azure-Landing-Zones-Library.txt') -Force
        }
        else {
            Write-Warning 'The library has no LICENSE file at its root; keep the upstream licence notice with the imported files.'
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
        }
        $utf8 = [System.Text.UTF8Encoding]::new($false)
        [System.IO.File]::WriteAllText((Join-Path $PSScriptRoot 'alz-library-source.json'), ((ConvertTo-Json -InputObject $source -Depth 10) + "`n"), $utf8)

        $records = @(Get-AlzPolicyRecord -DefinitionsPath $definitionsPath)
        $catalog = Format-AlzPolicyCatalog -Record $records -Source $source
        [System.IO.File]::WriteAllText((Join-Path $PSScriptRoot 'policy-catalog.md'), ($catalog + "`n"), $utf8)
        Write-Host "Imported $($plan.Count) definitions from $Repository at $Ref ($commit). Run ./Test-AlzPolicy.ps1 next."
    }
}
finally {
    if (Test-Path -LiteralPath $workPath) { Remove-Item -LiteralPath $workPath -Recurse -Force -ErrorAction SilentlyContinue -WhatIf:$false }
}
