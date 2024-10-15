# Connect to Azure (if not already connected in Cloud Shell)
Connect-AzAccount -UseDeviceAuthentication

# Get all Azure Arc-enabled Windows VMs
$arcVMs = Get-AzConnectedMachine | Where-Object {$_.OSName -like "*Windows*"}

foreach ($vm in $arcVMs) {
    Write-Host "Processing VM: $($vm.Name)"
    
    # Check if the Microsoft Monitoring Agent extension exists
    $extension = Get-AzConnectedMachineExtension -MachineName $vm.Name -ResourceGroupName $vm.ResourceGroupName |
                 Where-Object { $_.Name -eq "MicrosoftMonitoringAgent" }
    
    if ($extension) {
        Write-Host "Microsoft Monitoring Agent extension found on $($vm.Name). Attempting to remove..."
        
        try {
            Remove-AzConnectedMachineExtension -MachineName $vm.Name -Name "MicrosoftMonitoringAgent" -ResourceGroupName $vm.ResourceGroupName -Verbose -ErrorAction Stop
            Write-Host "Successfully removed Microsoft Monitoring Agent extension from $($vm.Name)."
        }
        catch {
            Write-Host "Failed to remove Microsoft Monitoring Agent extension from $($vm.Name). Error: $_"
        }
    } else {
        Write-Host "Microsoft Monitoring Agent extension not found on $($vm.Name). Skipping..."
    }
    
    Write-Host "------------------------"
}

Write-Host "Script execution completed."


# Light version of the same script
# $myVM = Get-AzConnectedMachine
# foreach($vm in $myVM)
# {
#	Remove-AzConnectedMachineExtension -MachineName $vm.Name -Name MicrosoftMonitoringAgent -ResourceGroupName $vm.ResourceGroupName -Verbose
# }
