#Connect to Azure subscription
Connect-AzAccount

## Enable Windows hybrid benefit for all VMs in a subscription
$nonehbvm = Get-AzVM -Status | where{$_.StorageProfile.OsDisk.OsType -eq "Windows" -and ($_.LicenseType -eq "None" -or $_.LicenseType -eq "") -and $_.Tags["AHUB"] -eq "true"} | Select-Object Name,ResourceGroupName,Licensetype

foreach($i in $nonehbvm)
{
    $vm = Get-AzVM -ResourceGroup $($i.ResourceGroupName) -Name $($i.Name) 
    Write-Verbose "Setting hybrid benefit on VM $($i.Name) "
    $vm.LicenseType = "Windows_Server"
    Update-AzVM -ResourceGroupName $($i.ResourceGroupName) -VM $vm
} 


## Enable SUSE Linux hybrid benefit for all VMs in a subscription
$nonehbvm = Get-AzVM -Status | where{$_.StorageProfile.OsDisk.OsType -eq "Linux" -and $_.StorageProfile.ImageReference.Publisher -eq "SUSE" -and ($_.LicenseType -eq "None" -or $_.LicenseType -eq "") -and $_.Tags["AHUB"] -eq "true"} | Select-Object Name,ResourceGroupName,Licensetype

foreach($i in $nonehbvm)
{
    $vm = Get-AzVM -ResourceGroup $($i.ResourceGroupName) -Name $($i.Name) 
    Write-Verbose "Setting hybrid benefit on VM $($i.Name) "
    $vm.LicenseType = "SLES_BYOS"
    Update-AzVM -ResourceGroupName $($i.ResourceGroupName) -VM $vm
} 


## Enable RedHat Linux hybrid benefit for all VMs in a subscription
$nonehbvm = Get-AzVM -Status | where{$_.StorageProfile.OsDisk.OsType -eq "Linux" -and $_.StorageProfile.ImageReference.Publisher -eq "RedHat" -and ($_.LicenseType -eq "None" -or $_.LicenseType -eq "") -and $_.Tags["AHUB"] -eq "true"} | Select-Object Name,ResourceGroupName,Licensetype

foreach($i in $nonehbvm)
{
    $vm = Get-AzVM -ResourceGroup $($i.ResourceGroupName) -Name $($i.Name) 
    Write-Verbose "Setting hybrid benefit on VM $($i.Name) "
    $vm.LicenseType = "RHEL_BYOS"
    Update-AzVM -ResourceGroupName $($i.ResourceGroupName) -VM $vm
}
