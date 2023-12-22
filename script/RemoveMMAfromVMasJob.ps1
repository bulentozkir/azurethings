# Get the list of Azure VM in the subscriptions
$machines = Get-AzVM | Select-Object Name, ResourceGroupName
 
# Loop through each machine and delete the extension if it exists
foreach ($machine in $machines) {
start-job -name myjob -ScriptBlock {
  # Check if the extension is installed
  $extension = Get-AzVMExtension -VMName $machine.Name -Name MicrosoftMonitoringAgent -ResourceGroupName $machine.ResourceGroupName
  if ($extension) {
    # Delete the extension
    Remove-AzVMExtension -ResourceGroupName $machine.ResourceGroupName  -Name MicrosoftMonitoringAgent -VMName $machine.Name -Force
    Write-Host "Deleted MicrosoftMonitoringAgent extension from $($machine.Name)"
  }
  else {
    Write-Host "MicrosoftMonitoringAgent extension not found on $($machine.Name)"
  }
} ; Wait-Job myjob;}


foreach ($machine in $machines) {
start-job -name myjob -ScriptBlock {
  # Check if the extension is installed
  $extension = Get-AzVMExtension -VMName $machine.Name -Name OmsAgentForLinux -ResourceGroupName $machine.ResourceGroupName
  if ($extension) {
    # Delete the extension
    Remove-AzVMExtension -ResourceGroupName $machine.ResourceGroupName  -Name OmsAgentForLinux -VMName $machine.Name -Force
    Write-Host "Deleted OmsAgentForLinux extension from $($machine.Name)"
  }
  else {
    Write-Host "OmsAgentForLinux extension not found on $($machine.Name)"
  }
} ; Wait-Job myjob;}


foreach ($machine in $machines) {
start-job -name myjob -ScriptBlock {
  # Check if the extension is installed
  $extension = Get-AzVMExtension -VMName $machine.Name -Name DependencyAgent -ResourceGroupName $machine.ResourceGroupName
  if ($extension) {
    # Delete the extension
    Remove-AzVMExtension -ResourceGroupName $machine.ResourceGroupName  -Name DependencyAgent -VMName $machine.Name -Force
    Write-Host "Deleted DependencyAgent extension from $($machine.Name)"
  }
  else {
    Write-Host "DependencyAgent extension not found on $($machine.Name)"
  }
} ; Wait-Job myjob;}
