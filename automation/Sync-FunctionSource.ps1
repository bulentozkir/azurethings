$ErrorActionPreference = 'Stop'
$templatePath = Join-Path $PSScriptRoot 'deploy-vm-retirement-notifier.json'
$sourcePath = Join-Path $PSScriptRoot 'retirement-lookup.js'
$template = Get-Content -Raw -LiteralPath $templatePath | ConvertFrom-Json -AsHashtable
$function = @($template.resources | Where-Object type -eq 'Microsoft.Web/sites/functions')
if ($function.Count -ne 1) { throw 'Expected exactly one inline Azure Function' }
$function[0].properties.files['index.js'] = [IO.File]::ReadAllText($sourcePath).Replace("`r`n", "`n")
$json = ConvertTo-Json -InputObject $template -Depth 100
[IO.File]::WriteAllText($templatePath, $json + "`n", [Text.UTF8Encoding]::new($false))
