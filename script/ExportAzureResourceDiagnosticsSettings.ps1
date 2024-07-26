# Install necessary Azure modules if the latest version is not installed
$modules = @('Az.Accounts', 'Az.Resources')
foreach ($module in $modules) {
    $currentModule = Get-Module -ListAvailable -Name $module | Sort-Object Version -Descending | Select-Object -First 1
    if ($null -eq $currentModule -or $currentModule.Version -lt (Find-Module -Name $module).Version) {
        Install-Module -Name $module -Force
    }
}

# Import the Az.Resources module
Import-Module -Name Az.Resources
# Import the Az.Accounts module
Import-Module -Name Az.Accounts

# Connect to Azure account
Connect-AzAccount

# Get all Azure Subscriptions
$Subs = Get-AzSubscription

# Initialize an array to store diagnostic results
$DiagResults = @()

# Loop through all Azure Subscriptions
foreach ($Sub in $Subs) {
    # Set the context to the current subscription
    Set-AzContext $Sub.id | Out-Null
    Write-Output "Processing Subscription:" $($Sub).name
    
    # Get all Azure resources for the current subscription
    $Resources = Get-AZResource
    
    # Get all Azure resources which have Diagnostic settings enabled and configured
    foreach ($res in $Resources) {
        $resId = $res.ResourceId
        $DiagSettings = Get-AzDiagnosticSetting -ResourceId $resId -WarningAction SilentlyContinue -ErrorAction SilentlyContinue | Where-Object { $_.Id -ne $null }
        
        foreach ($diag in $DiagSettings) {
            # Initialize variables
            [string]$StorageAccountName = ""
            [string]$StorageAccountId = ""
            [string]$EventHubName = ""
            [string]$EventHubId = ""
            [string]$WorkspaceName = ""
            [string]$WorkspaceId = ""
            
            # Check and extract Storage Account information if present
            If ($diag.StorageAccountId) {
                $StorageAccountId = $diag.StorageAccountId
                $StorageAccountName = $StorageAccountId.Split('/')[-1]
            }
            # Check and extract Event Hub information if present
            If ($diag.EventHubAuthorizationRuleId) {
                $EventHubId = $diag.EventHubAuthorizationRuleId
                $EventHubName = $EventHubId.Split('/')[-3]
            }
            # Check and extract Log Analytics Workspace information if present
            If ($diag.WorkspaceId) {
                $WorkspaceId = $diag.WorkspaceId
                $WorkspaceName = $WorkspaceId.Split('/')[-1]
            }
            
            # Store all results for the resource in a PowerShell custom object
            $item = [PSCustomObject]@{
                Subscription = [string]$Sub.Name                
                ResourceName = [string]$res.name
                ResourceId = [string]$resId
                DiagnosticSettingsName = [string]$diag.name
                DiagnosticSettingsId = [string]$diag.Id
                StorageAccountName = [string]$StorageAccountName
                StorageAccountId = [string]$StorageAccountId
                EventHubName = [string]$EventHubName
                EventHubId = [string]$EventHubId
                WorkspaceName = [string]$WorkspaceName
                WorkspaceId = [string]$WorkspaceId
                Metrics = [string](($diag.Metrics | ConvertTo-Json -Compress | Out-String).Trim())
                Logs = [string](($diag.Logs | ConvertTo-Json -Compress | Out-String).Trim())
            }
            
            Write-Output $item
            
            # Add the custom object to the array
            $DiagResults += $item
        }
    }
}

# Save diagnostic settings to a CSV file as tabular data
$DiagResults | Export-Csv -Force -Path ".\AzureResourceDiagnosticSettings-$(get-date -f yyyy-MM-dd-HHmm).csv" -NoTypeInformation
