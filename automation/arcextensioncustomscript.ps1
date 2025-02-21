# this Azuare Automation script uses Azure Arc Windows VM custom script extension to run powershell code hosted on Azure Storage account as SAS uri

# Module import
Import-Module Az.Accounts
Import-Module Az.ConnectedMachine

# Connect to Azure (if not already connected through Automation Account)
Connect-AzAccount -Identity

# Parse the server data from JSON format
$serverData = Get-AutomationVariable -Name 'webservernames' | ConvertFrom-Json

# Process each server
foreach ($server in $serverData) {
    Write-Output "Processing server: $($server.servername) in subscription $($server.subsname)"
    
    # Set subscription context
    Set-AzContext -Subscription $server.subsname
    
    try {
        # Get the ARC VM details
        $arcVM = Get-AzConnectedMachine -ResourceGroupName $server.rgname -Name $server.servername
        
        # Define the SAS URL for the script file in the storage account
        $scriptUrl = "https://XXXXX.blob.core.windows.net/myscriptcontainer/Install-Arc7ZIP.ps1?sp=r&st=MYSASTOKEN"

        # Define the settings for the Custom Script Extension
        $settings = @{
            fileUris = @($scriptUrl)
            commandToExecute = "powershell -ExecutionPolicy Unrestricted -File Install-Arc7ZIP.ps1"
        }

        # Define protected settings (empty, as SAS is public)
        $protectedSettings = @{}

        # Log the script URL and command to execute
        Write-Output "Deploying Custom Script Extension to $($server.servername)"
        Write-Output "Script URL: $scriptUrl"
        Write-Output "Command: $($settings.commandToExecute)"

        # Remove existing extension if present
        try {
            Remove-AzConnectedMachineExtension ` 
                -ResourceGroupName $server.rgname ` 
                -MachineName $server.servername ` 
                -Name "CustomScriptExtension" ` 
                -NoWait
            
            Start-Sleep -Seconds 30  # Wait for removal
        } catch {
            Write-Output "No existing extension to remove or removal failed. Continuing with deployment."
        }

        # Deploy the new extension with script from the storage account
        $extensionParams = @{
            ResourceGroupName = $server.rgname
            MachineName = $server.servername
            Name = "CustomScriptExtension"
            Location = $arcVM.Location
            Publisher = "Microsoft.Compute"
            ExtensionType = "CustomScriptExtension"
            TypeHandlerVersion = "1.10"
            Settings = $settings
            ProtectedSettings = $protectedSettings
        }

        New-AzConnectedMachineExtension @extensionParams
        
        # Monitor extension status with timeout
        $timeout = (Get-Date).AddMinutes(5)
        $extensionCompleted = $false
        
        do {
            Start-Sleep -Seconds 10
            $status = Get-AzConnectedMachineExtension ` 
                -ResourceGroupName $server.rgname ` 
                -MachineName $server.servername ` 
                -Name "CustomScriptExtension"
            
            Write-Output "Extension Status for $($server.servername): $($status.ProvisioningState)"
            
            switch ($status.ProvisioningState) {
                "Succeeded" {
                    Write-Output "Script executed successfully on $($server.servername)"
                    $extensionCompleted = $true
                }
                "Failed" {
                    Write-Error "Extension deployment failed on $($server.servername)"
                    Write-Error $status.StatusMessage
                    $extensionCompleted = $true
                }
                "Creating" {
                    # Continue waiting
                }
                default {
                    Write-Warning "Unexpected status: $($status.ProvisioningState)"
                }
            }
        } while (-not $extensionCompleted -and (Get-Date) -lt $timeout)
        
        if (-not $extensionCompleted) {
            Write-Error "Extension deployment timed out for $($server.servername)"
        }
        
        # Remove the extension after completion
        Write-Output "Removing extension from $($server.servername)"
        Remove-AzConnectedMachineExtension ` 
            -ResourceGroupName $server.rgname ` 
            -MachineName $server.servername ` 
            -Name "CustomScriptExtension" ` 
            -NoWait
        
    } catch {
        Write-Error "Error processing server $($server.servername): $_"
        Write-Error $_.Exception.Message
        Write-Error $_.ScriptStackTrace
    }
}
