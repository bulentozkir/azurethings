# Get the list of Azure Arc machines in the subscriptions
$machines = Get-AzConnectedMachine | Select-Object Name, ResourceGroupName

# Loop through each machine and delete the extension if it exists
foreach ($machine in $machines) {
  # Check if the extension is installed
  $extension = Get-AzConnectedMachineExtension -MachineName $machine.Name -Name MicrosoftMonitoringAgent -ResourceGroupName $machine.ResourceGroupName
  if ($extension) {
    # Delete the extension
    Remove-AzConnectedMachineExtension -MachineName $machine.Name -Name MicrosoftMonitoringAgent -ResourceGroupName $machine.ResourceGroupName -Force
    Write-Host "Deleted AzureMonitorWindowsAgent extension from $($machine.Name)"
  }
  else {
    Write-Host "MicrosoftMonitoringAgent extension not found on $($machine.Name)"
  }
}
