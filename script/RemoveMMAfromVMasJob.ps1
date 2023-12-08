$myVM = Get-AzConnectedMachine
foreach($vm in $myVM)
{
start-job -name myjob -ScriptBlock {
	Write-Host "Deleted MicrosoftMonitoringAgent extension from $($vm.Name)"
	Remove-AzConnectedMachineExtension -MachineName $vm.Name -Name MicrosoftMonitoringAgent -ResourceGroupName $vm.ResourceGroupName -Verbose
} ; Wait-Job myjob;}
