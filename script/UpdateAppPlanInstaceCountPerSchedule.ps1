# Azure Automation PowerShell Core script to update App Service Plan Worker Count based on date ranges

##### CHANGE THESE VARIABLES PER YOUR ENVIRONMENT

# Define your Azure App Service Plan details
$resourceGroupName = "app1bulento_group"
$appServicePlanName = "ASP-app1bulentogroup-98d9"

# Define your Subscription Id
$subId = "a0fdc749-441a-43a5-8297-29192ed42f79"

# Define date ranges (Month and Day of Month) when Worker Count should be set to 6
$dateRanges = @(
    @{Month = "January"; Start = 1; End = 5},
    @{Month = "February"; Start = 1; End = 5},
    @{Month = "March"; Start = 1; End = 5},
    @{Month = "April"; Start = 15; End = 20},
    @{Month = "July"; Start = 1; End = 10},
    @{Month = "September"; Start = 1; End = 3}
    @{Month = "September"; Start = 15; End = 25}
    @{Month = "December"; Start = 25; End = 31}
    # Add more date ranges as needed, you can the same month several times but avoid overlapping date ranges such as September above
)

##### END OF VARIABLES


# Import the Az.Accounts and Az.Websites modules
Import-Module Az.Accounts
Import-Module Az.Websites

# Enable verbose output
$VerbosePreference = "Continue"

# Function to log messages
function Log-Message {
    param([string]$message)
    Write-Output "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss'): $message"
}

try {
    # Connect to Azure with system-assigned managed identity
    Log-Message "Connecting to Azure..."
    Connect-AzAccount -Identity -ErrorAction Stop
    Log-Message "Connected successfully."

    # Select Azure subscription that includes the App Plan
    Log-Message "Setting Azure context..."
    $context = Set-AzContext -Subscription $subId -ErrorAction Stop
    Log-Message "Azure context set to subscription: $($context.Subscription.Name)"

    # Get current date
    $currentDate = Get-Date
    Log-Message "Current date: $($currentDate.ToString('MMMM dd'))"

    # Function to check if current date is within any of the specified ranges
    function IsWithinDateRanges($currentDate, $ranges) {
        $currentMonth = $currentDate.ToString("MMMM")
        $currentDay = $currentDate.Day

        foreach ($range in $ranges) {
            if ($currentMonth -eq $range.Month -and $currentDay -ge $range.Start -and $currentDay -le $range.End) {
                return $true
            }
        }
        return $false
    }

    # Check if current date is within the specified ranges
    $isWithinRange = IsWithinDateRanges -currentDate $currentDate -ranges $dateRanges
    Log-Message "Within specified range: $isWithinRange"

    # Set Worker Count value based on the date check
    $workerCount = if ($isWithinRange) { 6 } else { 2 }
    Log-Message "Worker Count to be set: $workerCount"

    # Get the current App Service Plan
    Log-Message "Retrieving App Service Plan..."
    $appServicePlan = Get-AzAppServicePlan -ResourceGroupName $resourceGroupName -Name $appServicePlanName -ErrorAction Stop
    Log-Message "Retrieved App Service Plan: $($appServicePlan.Name)"

    # Scale Web App to 3 or 6 Instances
    Log-Message "Updating App Service Plan..."
    $updatedPlan = Set-AzAppServicePlan -ResourceGroupName $resourceGroupName -Name $appServicePlanName -NumberOfWorkers $workerCount -ErrorAction Stop
    Log-Message "App Service Plan updated successfully."

    Log-Message "App Service Plan '$appServicePlanName' has been updated."
    Log-Message "New Worker Count: $($updatedPlan.Sku.Capacity)"
}
catch {
    Log-Message "An error occurred: $_"
    Log-Message "Stack Trace: $($_.Exception.StackTrace)"
    throw
}
