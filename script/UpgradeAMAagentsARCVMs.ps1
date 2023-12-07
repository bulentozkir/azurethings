# Get the list of Azure Arc machines in the subscriptions
$machines = Get-AzConnectedMachine | Select-Object Name, ResourceGroupName

# Loop through each machine and upgrade the extension if it exists
foreach ($machine in $machines) {
  # Check if the extension is installed
  $extension = Get-AzConnectedMachineExtension -MachineName $machine.Name -Name AzureMonitorWindowsAgent -ResourceGroupName $machine.ResourceGroupName

  $target = @{"Microsoft.Azure.Monitor.AzureMonitorWindowsAgent" = @{"targetVersion"=1.21.0.0}}
  
  if ($extension) {
    # Upgrade the extension
    Update-AzConnectedExtension -ResourceGroupName $machine.ResourceGroupName -MachineName $machine.Name  -ExtensionTarget $target
    Write-Host "Upgraded AzureMonitorWindowsAgent extension on $($machine.Name)"
  }
  else {
    Write-Host "AzureMonitorWindowsAgent extension not found on $($machine.Name)"
  }
}
