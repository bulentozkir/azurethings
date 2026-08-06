#Requires -Modules Az.Accounts, Az.Compute, Az.Network, Az.Resources

<#
.SYNOPSIS
Resizes an Azure VM to a compatible destination size.

.DESCRIPTION
Linux VMs are resized in place across all local temporary-disk combinations.
Windows VMs are resized in place when both sizes either have a temporary disk
or both do not. When Windows crosses that boundary Azure refuses a direct
resize, so the script deletes and recreates the VM object under the same name
and reattaches the original managed disks and network interfaces. The VM name,
disk names, NIC names, private and public IP addresses, and all data are
preserved. Backup snapshots of every managed disk are taken first and are
retained after a successful run.

DryRun is read-only. It validates region and zone availability, quotas, local
temporary-disk class, disk and NIC limits, architecture, Hyper-V generation,
disk controller, Premium disks, accelerated networking, Trusted Launch,
encryption at host, and Write Accelerator. Live capacity is guaranteed only
by an Azure Capacity Reservation.

.PARAMETER Help
Displays detailed help without accessing Azure resources.

.PARAMETER SubscriptionId
Subscription containing the VM.

.PARAMETER ResourceGroupName
Resource group containing the VM.

.PARAMETER VmName
VM name. The source size and operating system are detected automatically.

.PARAMETER DestinationVmSize
Destination Azure VM SKU, for example Standard_D4s_v5.

.PARAMETER PageFileAlreadyOnOsDisk
Skips automatic page-file relocation when no page file uses the temporary disk.
Relocation finds the temporary disk by its Azure marker file and volume label, so a
reassigned drive letter is handled and page files on persistent data disks are left
alone. Use this switch only when the relocation was already completed by hand.

.PARAMETER ReinstallExtensions
Reinstalls the VM extensions after a Windows boundary recreation. Without this
switch the script refuses to run when the VM has extensions, because extension
protected settings cannot be read back from Azure. With this switch the public
settings are restored and any protected settings must be reapplied by hand.

.PARAMETER DryRun
Performs read-only validation and reports the selected migration path.

.EXAMPLE
.\resize-azurevm.ps1 -Help

.EXAMPLE
.\resize-azurevm.ps1 `
    -SubscriptionId '<subscription-id>' `
    -ResourceGroupName '<resource-group>' `
    -VmName '<vm-name>' `
    -DestinationVmSize 'Standard_D4s_v5' `
    -DryRun

.EXAMPLE
.\resize-azurevm.ps1 `
    -SubscriptionId '<subscription-id>' `
    -ResourceGroupName '<resource-group>' `
    -VmName '<vm-name>' `
    -DestinationVmSize 'Standard_D4s_v5'

.LINK
https://learn.microsoft.com/azure/virtual-machines/sizes/resize-vm

.LINK
https://learn.microsoft.com/azure/virtual-machines/azure-vms-no-temp-disk
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Alias('?')][switch] $Help,
    [string] $SubscriptionId,
    [string] $ResourceGroupName,
    [string] $VmName,
    [string] $DestinationVmSize,
    [switch] $PageFileAlreadyOnOsDisk,
    [switch] $ReinstallExtensions,
    [switch] $DryRun
)

if ($Help) {
    Get-Help -Name $PSCommandPath -Detailed
    return
}

foreach ($name in 'SubscriptionId', 'ResourceGroupName', 'VmName', 'DestinationVmSize') {
    if ([string]::IsNullOrWhiteSpace([string](Get-Variable $name).Value)) {
        throw "Parameter -$name is required. Run .\resize-azurevm.ps1 -Help."
    }
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-Capability {
    param([object] $Sku, [string] $Name)
    $item = @($Sku.Capabilities | Where-Object Name -eq $Name | Select-Object -First 1)
    if ($item.Count) { return [string]$item[0].Value }
    return $null
}

function Get-IdParts {
    param([string] $Id)
    $parts = @($Id.Trim('/') -split '/')
    $index = 0..($parts.Count - 1) | Where-Object { $parts[$_] -ieq 'resourceGroups' } |
        Select-Object -First 1
    if ($null -eq $index) { throw "Cannot parse resource ID '$Id'." }
    [pscustomobject]@{ ResourceGroup = $parts[$index + 1]; Name = $parts[-1] }
}

function Get-DiskById {
    param([string] $Id)
    $parts = Get-IdParts $Id
    Get-AzDisk -ResourceGroupName $parts.ResourceGroup -DiskName $parts.Name -ErrorAction Stop
}

function Get-PowerState {
    param([object] $VmStatus)
    $property = $VmStatus.PSObject.Properties['PowerState']
    if ($null -ne $property -and $property.Value) { return [string]$property.Value }

    $status = @($VmStatus.Statuses | Where-Object Code -like 'PowerState/*' |
        Select-Object -Last 1)
    if (-not $status.Count) { throw "Azure returned no power state for '$($VmStatus.Name)'." }
    switch ([string]$status[0].Code) {
        'PowerState/running'      { 'VM running' }
        'PowerState/stopped'      { 'VM stopped' }
        'PowerState/deallocated'  { 'VM deallocated' }
        'PowerState/starting'     { 'VM starting' }
        'PowerState/stopping'     { 'VM stopping' }
        'PowerState/deallocating' { 'VM deallocating' }
        default                   { [string]$status[0].DisplayStatus }
    }
}

function Test-NotFound {
    param([System.Management.Automation.ErrorRecord] $Record)
    $Record.Exception.Message -match
        'ErrorCode:\s*ResourceNotFound|StatusCode:\s*404|was not found'
}

function Test-ResourceExists {
    param([scriptblock] $Read)
    try {
        & $Read | Out-Null
        return $true
    }
    catch {
        if (Test-NotFound $_) { return $false }
        throw
    }
}

function New-ResizeName {
    param([string] $Base, [string] $Suffix, [int] $MaximumLength = 80)
    $tail = "-$Suffix"
    $baseLength = $MaximumLength - $tail.Length
    if ($baseLength -lt 1) { throw "Suffix '$Suffix' exceeds the name limit." }
    $Base.Substring(0, [Math]::Min($Base.Length, $baseLength)) + $tail
}

function Restore-PowerState {
    param([string] $ResourceGroup, [string] $Name, [string] $OriginalState)
    $status = Get-AzVM -ResourceGroupName $ResourceGroup -Name $Name -Status -ErrorAction Stop
    $current = Get-PowerState $status
    switch ($OriginalState) {
        'VM running' {
            if ($current -ne 'VM running') {
                Start-AzVM -ResourceGroupName $ResourceGroup -Name $Name -ErrorAction Stop |
                    Out-Null
            }
        }
        'VM stopped' {
            if ($current -eq 'VM deallocated') {
                Start-AzVM -ResourceGroupName $ResourceGroup -Name $Name -ErrorAction Stop |
                    Out-Null
            }
            Stop-AzVM -ResourceGroupName $ResourceGroup -Name $Name -Force -StayProvisioned `
                -ErrorAction Stop | Out-Null
        }
        'VM deallocated' {
            if ($current -ne 'VM deallocated') {
                Stop-AzVM -ResourceGroupName $ResourceGroup -Name $Name -Force `
                    -ErrorAction Stop | Out-Null
            }
        }
        default { throw "Cannot restore power state '$OriginalState'." }
    }
}

function Assert-Quota {
    param([string] $Location, [object] $SourceSku, [object] $TargetSku,
        [switch] $CreatesReplacement)

    $sourceVcpus = [int](Get-Capability $SourceSku 'vCPUs')
    $targetVcpus = [int](Get-Capability $TargetSku 'vCPUs')
    $usage = @(Get-AzVMUsage -Location $Location -ErrorAction Stop)
    $family = @($usage | Where-Object { $_.Name.Value -ieq $TargetSku.Family } |
        Select-Object -First 1)
    $regional = @($usage | Where-Object {
            $_.Name.Value -ieq 'cores' -or
            $_.Name.LocalizedValue -ieq 'Total Regional vCPUs'
        } | Select-Object -First 1)
    $vmCount = @($usage | Where-Object {
            $_.Name.Value -ieq 'virtualMachines' -or
            $_.Name.LocalizedValue -ieq 'Virtual Machines'
        } | Select-Object -First 1)
    if (-not $family.Count -or -not $regional.Count -or -not $vmCount.Count) {
        throw 'Azure returned incomplete compute quota data.'
    }

    $familyAdd = $targetVcpus
    if (-not $CreatesReplacement -and $SourceSku.Family -ieq $TargetSku.Family) {
        $familyAdd = [Math]::Max(0, $targetVcpus - $sourceVcpus)
    }
    $regionalAdd = if ($CreatesReplacement) { $targetVcpus }
        else { [Math]::Max(0, $targetVcpus - $sourceVcpus) }
    $checks = @(
        @($family[0], $familyAdd),
        @($regional[0], $regionalAdd),
        @($vmCount[0], $(if ($CreatesReplacement) { 1 } else { 0 }))
    )
    foreach ($check in $checks) {
        $record, $additional = $check
        if ([int]$record.CurrentValue + $additional -gt [int]$record.Limit) {
            throw "Insufficient '$($record.Name.LocalizedValue)' quota."
        }
    }
}

function Wait-WindowsAgent {
    param([string] $ResourceGroup, [string] $Name, [int] $TimeoutSeconds = 600)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $status = Get-AzVM -ResourceGroupName $ResourceGroup -Name $Name -Status `
            -ErrorAction Stop
        $ready = $null -ne $status.VMAgent -and
            @($status.VMAgent.Statuses | Where-Object {
                    $_.Code -eq 'ProvisioningState/succeeded'
                }).Count -gt 0
        if ((Get-PowerState $status) -eq 'VM running' -and $ready) { return }
        Start-Sleep -Seconds 15
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Windows VM agent was not ready within $TimeoutSeconds seconds."
}

function Get-PageFileConfig {
    param([string] $ResourceGroup, [string] $Name)
    $status = Get-AzVM -ResourceGroupName $ResourceGroup -Name $Name -Status `
        -ErrorAction Stop
    if ((Get-PowerState $status) -ne 'VM running') {
        Start-AzVM -ResourceGroupName $ResourceGroup -Name $Name -ErrorAction Stop |
            Out-Null
    }
    Wait-WindowsAgent $ResourceGroup $Name
    $script = @'
$path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'
$system = Get-CimInstance Win32_ComputerSystem
$value = @{
    Automatic = [bool]$system.AutomaticManagedPagefile
    PagingFiles = @((Get-ItemProperty -Path $path).PagingFiles)
} | ConvertTo-Json -Compress
$encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($value))
Write-Output "PAGEFILE_CONFIG::$encoded"
'@
    $result = Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroup -VMName $Name `
        -CommandId RunPowerShellScript -ScriptString $script -ErrorAction Stop
    $message = $result.Value.Message -join "`n"
    $match = [regex]::Match($message, 'PAGEFILE_CONFIG::(?<value>[A-Za-z0-9+/=]+)')
    if (-not $match.Success) { throw 'Could not capture the page-file configuration.' }
    $json = [Text.Encoding]::UTF8.GetString(
        [Convert]::FromBase64String($match.Groups['value'].Value))
    $json | ConvertFrom-Json
}

function Restore-PageFileConfig {
    param([string] $ResourceGroup, [string] $Name, [object] $Configuration)
    $status = Get-AzVM -ResourceGroupName $ResourceGroup -Name $Name -Status `
        -ErrorAction Stop
    if ((Get-PowerState $status) -ne 'VM running') {
        Start-AzVM -ResourceGroupName $ResourceGroup -Name $Name -ErrorAction Stop |
            Out-Null
    }
    Wait-WindowsAgent $ResourceGroup $Name
    $json = @{
        Automatic = [bool]$Configuration.Automatic
        PagingFiles = @($Configuration.PagingFiles)
    } | ConvertTo-Json -Compress
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
    $script = @"
`$config = [Text.Encoding]::UTF8.GetString(
    [Convert]::FromBase64String('$encoded')) | ConvertFrom-Json
`$path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'
`$system = Get-CimInstance Win32_ComputerSystem
Set-CimInstance `$system -Property @{
    AutomaticManagedPagefile = [bool]`$config.Automatic
} | Out-Null
Set-ItemProperty -Path `$path -Name PagingFiles -Value ([string[]]@(`$config.PagingFiles))
Write-Output 'PAGEFILE_RESTORED'
"@
    $result = Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroup -VMName $Name `
        -CommandId RunPowerShellScript -ScriptString $script -ErrorAction Stop
    if (($result.Value.Message -join "`n") -notmatch 'PAGEFILE_RESTORED') {
        throw 'Page-file restoration failed.'
    }
    Restart-AzVM -ResourceGroupName $ResourceGroup -Name $Name -ErrorAction Stop |
        Out-Null
    Wait-WindowsAgent $ResourceGroup $Name
}

function Move-PageFileToOsDisk {
    param([string] $ResourceGroup, [string] $Name)
    $status = Get-AzVM -ResourceGroupName $ResourceGroup -Name $Name -Status `
        -ErrorAction Stop
    if ((Get-PowerState $status) -ne 'VM running') {
        Start-AzVM -ResourceGroupName $ResourceGroup -Name $Name -ErrorAction Stop |
            Out-Null
    }
    Wait-WindowsAgent $ResourceGroup $Name

    # The temporary disk is not always D:. Locate it by volume identity - the Azure
    # marker file and the default label - so a reassigned drive letter is handled and
    # a page file on a persistent data disk is never touched.
    $detect = @'
$ErrorActionPreference = 'Stop'
$path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'
$systemDrive = $env:SystemDrive
$tempDrives = @(foreach ($volume in @(Get-CimInstance Win32_Volume)) {
        $drive = [string]$volume.DriveLetter
        if (-not $drive -or $drive -ieq $systemDrive) { continue }
        if (Test-Path -LiteralPath "$drive\DATALOSS_WARNING_README.txt" `
                -ErrorAction SilentlyContinue) { $drive; continue }
        if ([string]$volume.Label -ieq 'Temporary Storage') { $drive }
    })
function Test-OnTempDrive {
    param([string] $Entry, [string[]] $Drives)
    foreach ($drive in $Drives) {
        if ($Entry -match "^$([regex]::Escape($drive))\\") { return $true }
    }
    return $false
}
'@

    $configure = $detect + @'

$configured = @((Get-ItemProperty -Path $path).PagingFiles | Where-Object { $_ })
$offSystem = @($configured | Where-Object {
        $_ -match '^[A-Za-z]:\\' -and
        $_ -notmatch "^$([regex]::Escape($systemDrive))\\"
    })
if (-not $tempDrives.Count -and $offSystem.Count) {
    throw ("The temporary disk could not be identified in the guest, and these page " +
        "files are not on ${systemDrive}: $($offSystem -join ' | '). Move them to " +
        "${systemDrive} by hand, reboot, then re-run with -PageFileAlreadyOnOsDisk.")
}
$keep = @($configured | Where-Object { -not (Test-OnTempDrive $_ $tempDrives) })
if (-not @($keep | Where-Object {
        $_ -match "^$([regex]::Escape($systemDrive))\\pagefile\.sys(?:\s|$)"
    }).Count) {
    $keep += "$systemDrive\pagefile.sys 0 0"
}
Set-CimInstance (Get-CimInstance Win32_ComputerSystem) -Property @{
    AutomaticManagedPagefile = $false
} | Out-Null
Set-ItemProperty -Path $path -Name PagingFiles -Value ([string[]]$keep)
Write-Output "PAGEFILE_TEMP_DRIVES::$($tempDrives -join ',')"
Write-Output 'PAGEFILE_CONFIGURED'
'@
    $result = Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroup -VMName $Name `
        -CommandId RunPowerShellScript -ScriptString $configure -ErrorAction Stop
    $message = $result.Value.Message -join "`n"
    if ($message -notmatch 'PAGEFILE_CONFIGURED') {
        throw "Page-file configuration did not complete: $message"
    }
    $match = [regex]::Match($message, 'PAGEFILE_TEMP_DRIVES::(?<value>[^\r\n]*)')
    $tempDrives = @()
    if ($match.Success) {
        $tempDrives = @($match.Groups['value'].Value -split ',' | Where-Object { $_ })
    }
    if (@($tempDrives | Where-Object { $_ -ine 'D:' }).Count) {
        Write-Warning ('The temporary disk uses a non-default drive letter ' +
            "($($tempDrives -join ', ')); its page files were moved to the OS disk.")
    }
    else {
        Write-Verbose "Temporary disk drives detected: $($tempDrives -join ', ')"
    }

    Restart-AzVM -ResourceGroupName $ResourceGroup -Name $Name -ErrorAction Stop |
        Out-Null
    Wait-WindowsAgent $ResourceGroup $Name

    # Re-detect after the reboot so the check covers the letters as they are now.
    $verify = $detect + @'

$configured = @((Get-ItemProperty -Path $path).PagingFiles | Where-Object { $_ })
$active = @(Get-CimInstance Win32_PageFileUsage)
foreach ($drive in $tempDrives) {
    if (@($configured | Where-Object { Test-OnTempDrive $_ @($drive) }).Count) {
        throw "A page file is still configured on the temporary disk $drive."
    }
    if (@($active | Where-Object { Test-OnTempDrive ([string]$_.Name) @($drive) }).Count) {
        throw "A page file is still active on the temporary disk $drive."
    }
}
if (-not @($configured | Where-Object {
        $_ -match "^$([regex]::Escape($systemDrive))\\pagefile\.sys(?:\s|$)"
    }).Count) {
    throw "No page file is configured on ${systemDrive}."
}
if (-not @($active | Where-Object {
        [string]$_.Name -ieq "$systemDrive\pagefile.sys"
    }).Count) {
    throw "The ${systemDrive} page file is not active."
}
Write-Output 'PAGEFILE_READY'
'@
    $result = Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroup -VMName $Name `
        -CommandId RunPowerShellScript -ScriptString $verify -ErrorAction Stop
    $message = $result.Value.Message -join "`n"
    if ($message -notmatch 'PAGEFILE_READY') {
        throw "Page-file verification failed: $message"
    }
}

function Get-DriveLetterMap {
    param([string] $ResourceGroup, [string] $Name)
    $script = @'
$ErrorActionPreference = 'Stop'
$volumes = @(Get-CimInstance Win32_Volume | Where-Object { $_.DriveLetter } |
    ForEach-Object {
        [pscustomobject]@{
            Id = [string]$_.DeviceID
            Letter = [string]$_.DriveLetter
            Label = [string]$_.Label
        }
    })
$json = ConvertTo-Json -InputObject $volumes -Compress -Depth 4
$encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
Write-Output "DRIVELETTERS::$encoded"
'@
    $result = Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroup -VMName $Name `
        -CommandId RunPowerShellScript -ScriptString $script -ErrorAction Stop
    $message = $result.Value.Message -join "`n"
    $match = [regex]::Match($message, 'DRIVELETTERS::(?<value>[A-Za-z0-9+/=]+)')
    if (-not $match.Success) {
        throw "The guest drive letters could not be read: $message"
    }
    @([Text.Encoding]::UTF8.GetString(
            [Convert]::FromBase64String($match.Groups['value'].Value)) | ConvertFrom-Json)
}

function New-DiskPlan {
    param([object] $Disk, [string] $Role)
    [pscustomobject]@{
        Source = $Disk
        SnapshotName = New-ResizeName $Disk.Name "resize-$Role-$snapshotStamp"
    }
}

function New-DiskSnapshot {
    param([object] $Plan, [string] $Location)
    $source = $Plan.Source
    $snapshotArgs = @{
        SourceUri = $source.Id; Location = $Location; CreateOption = 'Copy'
    }
    if ($null -ne $source.Encryption -and $source.Encryption.Type) {
        $snapshotArgs.EncryptionType = [string]$source.Encryption.Type
        if ($source.Encryption.DiskEncryptionSetId) {
            $snapshotArgs.DiskEncryptionSetId = $source.Encryption.DiskEncryptionSetId
        }
    }
    New-AzSnapshot -ResourceGroupName $ResourceGroupName `
        -SnapshotName $Plan.SnapshotName `
        -Snapshot (New-AzSnapshotConfig @snapshotArgs) -ErrorAction Stop
}

function Set-AttachedResourcesToDetach {
    param([string] $ResourceGroup, [string] $Name)
    $target = Get-AzVM -ResourceGroupName $ResourceGroup -Name $Name -ErrorAction Stop
    $target.StorageProfile.OsDisk.DeleteOption = 'Detach'
    foreach ($item in @($target.StorageProfile.DataDisks)) {
        $item.DeleteOption = 'Detach'
    }
    foreach ($item in @($target.NetworkProfile.NetworkInterfaces)) {
        $item.DeleteOption = 'Detach'
    }
    Update-AzVM -ResourceGroupName $ResourceGroup -VM $target -ErrorAction Stop |
        Out-Null

    $check = Get-AzVM -ResourceGroupName $ResourceGroup -Name $Name -ErrorAction Stop
    $options = @([string]$check.StorageProfile.OsDisk.DeleteOption)
    $options += @($check.StorageProfile.DataDisks |
        ForEach-Object { [string]$_.DeleteOption })
    $options += @($check.NetworkProfile.NetworkInterfaces |
        ForEach-Object { [string]$_.DeleteOption })
    if (@($options | Where-Object { $_ -ne 'Detach' }).Count) {
        throw 'Azure did not accept Detach on every disk and network interface.'
    }
}

function New-SameNameVm {
    param([string] $Size)
    $configArgs = @{ VMName = $VmName; VMSize = $Size; Tags = @{} }
    if ($null -ne $vm.Tags) {
        foreach ($tag in $vm.Tags.Keys) { $configArgs.Tags[$tag] = $vm.Tags[$tag] }
    }
    if ($zones.Count) { $configArgs.Zone = $zones }
    if ($vm.LicenseType) { $configArgs.LicenseType = $vm.LicenseType }
    if ($vm.StorageProfile.DiskControllerType) {
        $configArgs.DiskControllerType = $vm.StorageProfile.DiskControllerType
    }
    if ($securityType) {
        $configArgs.SecurityType = $securityType
        if ($null -ne $vm.SecurityProfile.UefiSettings) {
            $configArgs.EnableVtpm = [bool]$vm.SecurityProfile.UefiSettings.VTpmEnabled
            $configArgs.EnableSecureBoot =
                [bool]$vm.SecurityProfile.UefiSettings.SecureBootEnabled
        }
    }
    if ($null -ne $vm.SecurityProfile -and $vm.SecurityProfile.EncryptionAtHost) {
        $configArgs.EncryptionAtHost = $true
    }
    $sourceIdentityType =
        if ($null -ne $vm.Identity) { [string]$vm.Identity.Type } else { '' }
    if ($sourceIdentityType -and $sourceIdentityType -ne 'None') {
        $configArgs.IdentityType = $sourceIdentityType
        if ($null -ne $vm.Identity.UserAssignedIdentities -and
            $vm.Identity.UserAssignedIdentities.Count) {
            $configArgs.IdentityId = @($vm.Identity.UserAssignedIdentities.Keys)
        }
    }
    if ($null -ne $vm.AdditionalCapabilities) {
        if ($vm.AdditionalCapabilities.UltraSSDEnabled) {
            $configArgs.EnableUltraSSD = $true
        }
        if ($vm.AdditionalCapabilities.HibernationEnabled) {
            $configArgs.HibernationEnabled = $true
        }
    }
    if ($null -ne $vm.ProximityPlacementGroup -and $vm.ProximityPlacementGroup.Id) {
        $configArgs.ProximityPlacementGroupId = $vm.ProximityPlacementGroup.Id
    }
    if ($null -ne $vm.Host -and $vm.Host.Id) { $configArgs.HostId = $vm.Host.Id }
    if ($null -ne $vm.CapacityReservation -and
        $null -ne $vm.CapacityReservation.CapacityReservationGroup -and
        $vm.CapacityReservation.CapacityReservationGroup.Id) {
        $configArgs.CapacityReservationGroupId =
            $vm.CapacityReservation.CapacityReservationGroup.Id
    }
    if ($null -ne $vm.VirtualMachineScaleSet -and $vm.VirtualMachineScaleSet.Id) {
        $configArgs.VmssId = $vm.VirtualMachineScaleSet.Id
        if ($null -ne $vm.PlatformFaultDomain) {
            $configArgs.PlatformFaultDomain = [int]$vm.PlatformFaultDomain
        }
    }
    if ($vm.UserData) { $configArgs.UserData = $vm.UserData }
    $config = New-AzVMConfig @configArgs
    if ($vm.Plan) {
        $planArgs = @{
            VM = $config; Publisher = $vm.Plan.Publisher; Product = $vm.Plan.Product
            Name = $vm.Plan.Name
        }
        if ($vm.Plan.PromotionCode) { $planArgs.PromotionCode = $vm.Plan.PromotionCode }
        $config = Set-AzVMPlan @planArgs
    }

    $osArgs = @{
        VM = $config; ManagedDiskId = $osDisk.Id; CreateOption = 'Attach'
        Windows = $true; Caching = $vm.StorageProfile.OsDisk.Caching
        DeleteOption = 'Detach'
    }
    if ($vm.StorageProfile.OsDisk.WriteAcceleratorEnabled) {
        $osArgs.WriteAccelerator = $true
    }
    $config = Set-AzVMOSDisk @osArgs
    for ($index = 0; $index -lt $dataAttachments.Count; $index++) {
        $attachment = $dataAttachments[$index]
        $diskArgs = @{
            VM = $config; Name = $dataDisks[$index].Name
            ManagedDiskId = $dataDisks[$index].Id; CreateOption = 'Attach'
            Lun = $attachment.Lun; Caching = $attachment.Caching; DeleteOption = 'Detach'
        }
        if ($attachment.WriteAcceleratorEnabled) { $diskArgs.WriteAccelerator = $true }
        $config = Add-AzVMDataDisk @diskArgs
    }
    foreach ($reference in $nicReferences) {
        $nicArgs = @{ VM = $config; Id = $reference.Id; DeleteOption = 'Detach' }
        if ($nicReferences.Count -eq 1 -or $reference.Primary) {
            $nicArgs.Primary = $true
        }
        $config = Add-AzVMNetworkInterface @nicArgs
    }
    if ($null -ne $vm.DiagnosticsProfile -and
        $null -ne $vm.DiagnosticsProfile.BootDiagnostics -and
        $vm.DiagnosticsProfile.BootDiagnostics.Enabled) {
        $bootArgs = @{ VM = $config; Enable = $true }
        if ($vm.DiagnosticsProfile.BootDiagnostics.StorageUri) {
            $bootArgs.ResourceGroupName = $ResourceGroupName
            $bootArgs.StorageAccountName =
                ([uri]$vm.DiagnosticsProfile.BootDiagnostics.StorageUri).Host.Split('.')[0]
        }
        $config = Set-AzVMBootDiagnostic @bootArgs
    }
    New-AzVM -ResourceGroupName $ResourceGroupName -Location $vm.Location -VM $config `
        -DisableBginfoExtension -ErrorAction Stop | Out-Null

    if ($sourceIdentityType -and $sourceIdentityType -ne 'None') {
        $created = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VmName `
            -ErrorAction Stop
        $identityArgs = @{
            ResourceGroupName = $ResourceGroupName; VM = $created
            IdentityType = $sourceIdentityType
        }
        if ($null -ne $vm.Identity.UserAssignedIdentities -and
            $vm.Identity.UserAssignedIdentities.Count) {
            $identityArgs.IdentityId = @($vm.Identity.UserAssignedIdentities.Keys)
        }
        Update-AzVM @identityArgs -ErrorAction Stop | Out-Null
        $verified = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VmName `
            -ErrorAction Stop
        $verifiedType =
            if ($null -ne $verified.Identity) { [string]$verified.Identity.Type } else { '' }
        if (-not $verifiedType -or $verifiedType -eq 'None') {
            throw "The managed identity could not be restored on '$VmName'."
        }
    }
}

function Restore-VmExtension {
    param([object] $Extension)
    $extensionArgs = @{
        ResourceGroupName = $ResourceGroupName; VMName = $VmName
        Name = [string]$Extension.Name
        Publisher = [string]$Extension.Publisher
        ExtensionType = [string]$Extension.VirtualMachineExtensionType
        TypeHandlerVersion = [string]$Extension.TypeHandlerVersion
        Location = $vm.Location
    }
    if ($null -ne $Extension.Settings) {
        $extensionArgs.SettingString =
            $Extension.Settings | ConvertTo-Json -Depth 20 -Compress
    }
    if ($null -ne $Extension.AutoUpgradeMinorVersion -and
        -not $Extension.AutoUpgradeMinorVersion) {
        $extensionArgs.DisableAutoUpgradeMinorVersion = $true
    }
    if ($Extension.EnableAutomaticUpgrade) {
        $extensionArgs.EnableAutomaticUpgrade = $true
    }
    Set-AzVMExtension @extensionArgs -ErrorAction Stop | Out-Null
}

Set-AzContext -Subscription $SubscriptionId -WhatIf:$false -ErrorAction Stop |
    Out-Null
$vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VmName -ErrorAction Stop
$status = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VmName -Status `
    -ErrorAction Stop
$initialState = Get-PowerState $status
if ($initialState -notin 'VM running', 'VM stopped', 'VM deallocated') {
    throw "VM state '$initialState' is transitional. Retry when stable."
}

$sourceSize = [string]$vm.HardwareProfile.VmSize
$targetSize = $DestinationVmSize
if ($sourceSize -eq $targetSize) {
    Write-Output "VM '$VmName' already uses $targetSize."
    return
}
$osType = [string]$vm.StorageProfile.OsDisk.OsType
if ($osType -notin 'Linux', 'Windows') { throw "Unsupported OS type '$osType'." }
if ($null -ne $vm.StorageProfile.OsDisk.DiffDiskSettings -and
    $vm.StorageProfile.OsDisk.DiffDiskSettings.Option -eq 'Local') {
    throw 'Ephemeral OS disks are not supported.'
}
if ($null -eq $vm.StorageProfile.OsDisk.ManagedDisk -or
    -not $vm.StorageProfile.OsDisk.ManagedDisk.Id) {
    throw 'A managed OS disk is required.'
}

$skus = @(Get-AzComputeResourceSku -Location $vm.Location -ErrorAction Stop |
    Where-Object ResourceType -eq 'virtualMachines')
$sourceSku = @($skus | Where-Object Name -eq $sourceSize)
$targetSku = @($skus | Where-Object Name -eq $targetSize)
if (-not $sourceSku.Count) { throw "Source size '$sourceSize' was not returned." }
if (-not $targetSku.Count) { throw "$targetSize is unavailable in '$($vm.Location)'." }
if (@($targetSku[0].Restrictions | Where-Object Type -eq 'Location').Count) {
    throw "$targetSize is restricted in '$($vm.Location)'."
}
$zones = @($vm.Zones | Where-Object { $_ })
if ($zones.Count) {
    $offeredZones = @($targetSku[0].LocationInfo |
        Where-Object { $_.Location -ieq $vm.Location } |
        ForEach-Object Zones)
    if (@($zones | Where-Object { $_ -notin $offeredZones }).Count) {
        throw "$targetSize is not offered in zone '$($zones -join ',')'."
    }
    $restricted = @($targetSku[0].Restrictions | Where-Object Type -eq 'Zone' |
        ForEach-Object { $_.RestrictionInfo.Zones })
    if (@($zones | Where-Object { $_ -in $restricted }).Count) {
        throw "$targetSize is restricted in zone '$($zones -join ',')'."
    }
}

$sourceTemp = [int64](Get-Capability $sourceSku[0] 'MaxResourceVolumeMB') -gt 0
$targetTemp = [int64](Get-Capability $targetSku[0] 'MaxResourceVolumeMB') -gt 0
$crossesTempBoundary = $sourceTemp -ne $targetTemp
$replacementRequired = $osType -eq 'Windows' -and $crossesTempBoundary
$pageFileMoveRequired = $replacementRequired -and $sourceTemp -and -not $targetTemp `
    -and -not $PageFileAlreadyOnOsDisk

$dataAttachments = @($vm.StorageProfile.DataDisks)
$nicReferences = @($vm.NetworkProfile.NetworkInterfaces)
$maxDisks = [int](Get-Capability $targetSku[0] 'MaxDataDiskCount')
$maxNics = [int](Get-Capability $targetSku[0] 'MaxNetworkInterfaces')
if ($dataAttachments.Count -gt $maxDisks) {
    throw "$targetSize supports $maxDisks data disks; this VM has $($dataAttachments.Count)."
}
if ($nicReferences.Count -gt $maxNics) {
    throw "$targetSize supports $maxNics NICs; this VM has $($nicReferences.Count)."
}

$nics = @(foreach ($reference in $nicReferences) {
        $parts = Get-IdParts $reference.Id
        Get-AzNetworkInterface -ResourceGroupName $parts.ResourceGroup -Name $parts.Name `
            -ErrorAction Stop
    })
$accelerated = @($nics | Where-Object EnableAcceleratedNetworking).Count -gt 0
if ($accelerated -and
    (Get-Capability $targetSku[0] 'AcceleratedNetworkingEnabled') -ne 'True') {
    throw "$targetSize does not support accelerated networking."
}

$osDisk = Get-DiskById $vm.StorageProfile.OsDisk.ManagedDisk.Id
$dataDisks = @(foreach ($attachment in $dataAttachments) {
        if ($null -eq $attachment.ManagedDisk -or -not $attachment.ManagedDisk.Id) {
            throw "Data disk '$($attachment.Name)' is unmanaged."
        }
        Get-DiskById $attachment.ManagedDisk.Id
    })
$diskSkus = @([string]$osDisk.Sku.Name) +
    @($dataDisks | ForEach-Object { [string]$_.Sku.Name })
if (@($diskSkus | Where-Object { $_ -match '^Premium' }).Count -and
    (Get-Capability $targetSku[0] 'PremiumIO') -ne 'True') {
    throw "$targetSize does not support attached Premium disks."
}

$sourceArch = Get-Capability $sourceSku[0] 'CpuArchitectureType'
$targetArch = Get-Capability $targetSku[0] 'CpuArchitectureType'
if ($sourceArch -and $targetArch -and $sourceArch -ne $targetArch) {
    throw "CPU architecture cannot change from $sourceArch to $targetArch."
}
$controller = [string]$vm.StorageProfile.DiskControllerType
$controllers = [string](Get-Capability $targetSku[0] 'DiskControllerTypes')
if ($controller -and $controllers -and $controller -notin @($controllers -split ',\s*')) {
    throw "$targetSize does not support the $controller disk controller."
}
$generations = [string](Get-Capability $targetSku[0] 'HyperVGenerations')
if ($osDisk.HyperVGeneration -and $generations -and
    [string]$osDisk.HyperVGeneration -notin @($generations -split ',\s*')) {
    throw "$targetSize does not support OS generation '$($osDisk.HyperVGeneration)'."
}

$securityType = if ($null -ne $vm.SecurityProfile) {
    [string]$vm.SecurityProfile.SecurityType
}
if ($null -ne $vm.SecurityProfile -and $vm.SecurityProfile.EncryptionAtHost -and
    (Get-Capability $targetSku[0] 'EncryptionAtHostSupported') -ne 'True') {
    throw "$targetSize does not support encryption at host."
}
if ($securityType -eq 'TrustedLaunch' -and
    (Get-Capability $targetSku[0] 'TrustedLaunchDisabled') -eq 'True') {
    throw "$targetSize does not support Trusted Launch."
}
if ($securityType -like 'ConfidentialVM*' -and
    -not (Get-Capability $targetSku[0] 'ConfidentialComputingType')) {
    throw "$targetSize does not support Confidential VMs."
}
if ($replacementRequired -and $securityType -like 'ConfidentialVM*') {
    throw 'Windows boundary recreation does not support Confidential VMs.'
}

$writeAcceleratorCount = @(@($vm.StorageProfile.OsDisk) + $dataAttachments |
        Where-Object WriteAcceleratorEnabled).Count
$maxWriteAccelerator = Get-Capability $targetSku[0] 'MaxWriteAcceleratorDisksAllowed'
if ($writeAcceleratorCount -and
    ($null -eq $maxWriteAccelerator -or
    $writeAcceleratorCount -gt [int]$maxWriteAccelerator)) {
    throw "$targetSize does not support this VM's write-accelerated disks."
}

$spot = [string]$vm.Priority -eq 'Spot'
if ($replacementRequired -and $spot) {
    throw 'Windows boundary recreation does not support Spot VMs.'
}
if (-not $spot) {
    Assert-Quota $vm.Location $sourceSku[0] $targetSku[0]
}

if (-not $replacementRequired) {
    if ($null -ne $vm.AvailabilitySetReference -and $vm.AvailabilitySetReference.Id) {
        $available = @(Get-AzVMSize -ResourceGroupName $ResourceGroupName -VMName $VmName `
            -ErrorAction Stop | Select-Object -ExpandProperty Name)
        if ($targetSize -notin $available) {
            throw "$targetSize requires coordinated availability-set deallocation."
        }
    }
    if ($DryRun) {
        [pscustomobject]@{
            DryRun = $true; OperatingSystem = $osType
            SourceVm = $VmName; SourceSize = $sourceSize; DestinationSize = $targetSize
            SourceTempDisk = $sourceTemp; TargetTempDisk = $targetTemp
            MigrationType = 'In-place resize'; OsDiskAction = 'Retain'
            DataDiskCount = $dataAttachments.Count; DataDiskAction = 'Retain'
            Validation = 'Passed'; ValidationScope = 'Local Azure capability and quota checks'
            Capacity = 'Not guaranteed without a Capacity Reservation'
        }
        return
    }
    if (-not $PSCmdlet.ShouldProcess("$ResourceGroupName/$VmName",
        "Deallocate and resize from $sourceSize to $targetSize")) { return }

    try {
        if ($initialState -ne 'VM deallocated') {
            Stop-AzVM -ResourceGroupName $ResourceGroupName -Name $VmName -Force `
                -ErrorAction Stop | Out-Null
        }
        $updated = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VmName `
            -ErrorAction Stop
        $updated.HardwareProfile.VmSize = $targetSize
        Update-AzVM -ResourceGroupName $ResourceGroupName -VM $updated -ErrorAction Stop |
            Out-Null
        Restore-PowerState $ResourceGroupName $VmName $initialState
    }
    catch {
        $failure = $_
        try {
            $rollback = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VmName `
                -ErrorAction Stop
            if ($rollback.HardwareProfile.VmSize -ne $sourceSize) {
                $rollback.HardwareProfile.VmSize = $sourceSize
                Update-AzVM -ResourceGroupName $ResourceGroupName -VM $rollback `
                    -ErrorAction Stop | Out-Null
            }
            Restore-PowerState $ResourceGroupName $VmName $initialState
        }
        catch {
            throw "Resize failed: $($failure.Exception.Message). Rollback failed: $($_.Exception.Message)"
        }
        throw "Resize failed and was rolled back: $($failure.Exception.Message)"
    }
    $result = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VmName -Status `
        -ErrorAction Stop
    [pscustomobject]@{
        OperatingSystem = $osType; VmName = $VmName; Size = $targetSize
        PowerState = Get-PowerState $result; MigrationType = 'In-place resize'
    }
    return
}

if ($null -ne $vm.AvailabilitySetReference -and $vm.AvailabilitySetReference.Id) {
    throw 'Windows boundary recreation does not support availability sets.'
}
if ($diskSkus | Where-Object { $_ -in 'UltraSSD_LRS', 'PremiumV2_LRS' }) {
    throw 'Windows boundary recreation cannot snapshot Ultra or Premium SSD v2 disks.'
}

$blockers = [System.Collections.Generic.List[string]]::new()
$extensions = if ($null -ne $vm.Extensions) { @($vm.Extensions) } else { @() }
$persistentExtensions = @($extensions | Where-Object {
        [string]$_.VirtualMachineExtensionType -notin
            'RunCommandWindows', 'RunCommandLinux'
    })
if ($persistentExtensions.Count -and -not $ReinstallExtensions) {
    $extensionNames = @($persistentExtensions | ForEach-Object Name) -join ', '
    [void]$blockers.Add("VM extensions would be lost: $extensionNames. Re-run with " +
        '-ReinstallExtensions to restore their public settings, then reapply any ' +
        'protected settings by hand.')
}
if ($null -ne $vm.HostGroup -and $vm.HostGroup.Id) {
    [void]$blockers.Add('Dedicated host group membership cannot be reproduced.')
}
if ($null -ne $vm.ApplicationProfile) {
    [void]$blockers.Add('Assigned VM Applications cannot be reproduced.')
}
try {
    $locks = @(Get-AzResourceLock -ResourceGroupName $ResourceGroupName -ErrorAction Stop |
        Where-Object { [string]$_.Properties.level -in 'CanNotDelete', 'ReadOnly' })
    if ($locks.Count) {
        [void]$blockers.Add(('Resource locks would block deleting the VM: {0}' -f
            (@($locks | ForEach-Object Name) -join ', ')))
    }
}
catch {
    Write-Warning "Resource locks could not be read: $($_.Exception.Message)"
}
if ($blockers.Count) {
    throw ("Resizing '$VmName' across the Windows temporary-disk boundary requires " +
        "recreating the VM, which would change its configuration:`n  - " +
        ($blockers -join "`n  - "))
}
if ($null -ne $vm.Identity -and [string]$vm.Identity.Type -match 'SystemAssigned' -and
    $vm.Identity.PrincipalId) {
    try {
        $assignments = @(Get-AzRoleAssignment -ObjectId $vm.Identity.PrincipalId `
            -ErrorAction Stop)
        if ($assignments.Count) {
            Write-Warning ("The system-assigned identity holds $($assignments.Count) " +
                'role assignment(s) that must be re-granted to the new principal ID.')
        }
    }
    catch {
        Write-Warning 'Role assignments of the system-assigned identity could not be read.'
    }
}
foreach ($disk in $dataDisks) {
    $property = $disk.PSObject.Properties['ManagedByExtended']
    $owners = if ($null -ne $property) { @($property.Value) } else { @() }
    if (@($owners | Where-Object { $_ -and $_ -ine $vm.Id }).Count) {
        throw "Shared disk '$($disk.Name)' is attached to another VM."
    }
}

$snapshotStamp = Get-Date -Format 'yyyyMMddHHmmss'
$plans = [System.Collections.Generic.List[object]]::new()
[void]$plans.Add((New-DiskPlan $osDisk os))
for ($index = 0; $index -lt $dataDisks.Count; $index++) {
    [void]$plans.Add((New-DiskPlan $dataDisks[$index] "data$index"))
}
foreach ($plan in $plans) {
    if (Test-ResourceExists {
            Get-AzSnapshot -ResourceGroupName $ResourceGroupName `
                -SnapshotName $plan.SnapshotName -ErrorAction Stop
        }) {
        throw "Backup snapshot '$($plan.SnapshotName)' already exists."
    }
}
$agent = if ($initialState -eq 'VM running') {
        if ($null -ne $status.VMAgent -and
            @($status.VMAgent.Statuses | Where-Object {
                    $_.Code -eq 'ProvisioningState/succeeded'
                }).Count) { 'Ready' } else { 'Not ready' }
    }
    else { 'Deferred until execution starts the VM' }

Write-Warning 'The VM object is deleted and recreated under the same name.'
Write-Warning 'Disks, NICs, private and public IP addresses are retained and reattached.'
if ($persistentExtensions.Count) {
    Write-Warning ('These extensions are reinstalled from their public settings; ' +
        "reapply any protected settings by hand: $(@($persistentExtensions | ForEach-Object Name) -join ', ')")
}
if ($null -ne $vm.Identity -and [string]$vm.Identity.Type -match 'SystemAssigned') {
    Write-Warning 'A new system-assigned identity object ID is issued; re-grant roles.'
}
Write-Warning 'Backup snapshots are kept after success; delete them when not needed.'

if ($DryRun) {
    if ($agent -eq 'Not ready') {
        throw 'The source Windows VM agent is not ready.'
    }
    [pscustomobject]@{
        DryRun = $true; OperatingSystem = 'Windows'
        VmName = $VmName; SourceSize = $sourceSize; DestinationSize = $targetSize
        SourceTempDisk = $sourceTemp; TargetTempDisk = $targetTemp
        MigrationType = 'In-place recreation with retained disks and NICs'
        NameChanges = 'None; the VM, disks, NICs and IP addresses keep their names'
        PageFileAction = if ($pageFileMoveRequired) {
                'Detect the temporary disk, move its page files to the OS disk, verify'
            } else { 'Not required' }
        SourceAgent = $agent
        DiskAction = 'Back up with a snapshot, detach, then reattach unchanged'
        DataDiskCount = $dataDisks.Count
        NicAction = 'Detach and reattach the existing NICs and IP addresses'
        Extensions = if ($persistentExtensions.Count) {
                @($persistentExtensions | ForEach-Object Name)
            } else { 'None' }
        ExtensionAction = if ($persistentExtensions.Count) {
                'Reinstall public settings; protected settings need manual reapply'
            } else { 'Not required' }
        BackupSnapshots = @($plans | ForEach-Object SnapshotName)
        Validation = 'Passed'; ValidationScope = 'Local Azure capability and quota checks'
        Capacity = 'Not guaranteed without a Capacity Reservation'
    }
    return
}

if (-not $PSCmdlet.ShouldProcess("$ResourceGroupName/$VmName",
    "Recreate in place at size $targetSize, retaining disks and NICs")) { return }

$pageFileBackup = $null
$letterMap = $null
$letterChanges = @()
$vmRemoved = $false
$result = $null
$snapshots = [System.Collections.Generic.List[object]]::new()
try {
    if ($pageFileMoveRequired) {
        $pageFileBackup = Get-PageFileConfig $ResourceGroupName $VmName
        Move-PageFileToOsDisk $ResourceGroupName $VmName
    }

    $current = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VmName -Status `
        -ErrorAction Stop
    # Record the guest drive letters so any change can be reported afterwards. This is
    # best effort: a VM without a usable agent must still be allowed to resize.
    if ((Get-PowerState $current) -eq 'VM running') {
        try { $letterMap = Get-DriveLetterMap $ResourceGroupName $VmName }
        catch {
            Write-Warning "Guest drive letters were not recorded: $($_.Exception.Message)"
        }
    }
    if ((Get-PowerState $current) -ne 'VM deallocated') {
        Stop-AzVM -ResourceGroupName $ResourceGroupName -Name $VmName -Force `
            -ErrorAction Stop | Out-Null
    }

    Set-AttachedResourcesToDetach $ResourceGroupName $VmName

    foreach ($plan in $plans) {
        [void]$snapshots.Add((New-DiskSnapshot $plan $vm.Location))
    }

    Remove-AzVM -ResourceGroupName $ResourceGroupName -Name $VmName -Force `
        -ErrorAction Stop | Out-Null
    $vmRemoved = $true

    $lost = [System.Collections.Generic.List[string]]::new()
    foreach ($retained in @($osDisk.Name) + @($dataDisks | ForEach-Object Name)) {
        $diskName = $retained
        if (-not (Test-ResourceExists {
                    Get-AzDisk -ResourceGroupName $ResourceGroupName `
                        -DiskName $diskName -ErrorAction Stop
                })) {
            [void]$lost.Add($diskName)
        }
    }
    if ($lost.Count) {
        throw "Azure removed retained disks: $($lost -join ', ')."
    }

    New-SameNameVm $targetSize
    Wait-WindowsAgent $ResourceGroupName $VmName
    foreach ($extension in $persistentExtensions) {
        Restore-VmExtension $extension
    }

    # Drive letters live in the retained OS disk, and the data disks come back on the
    # same LUNs, so they normally survive. Confirm it rather than assume it.
    if ($null -ne $letterMap) {
        try {
            $afterMap = Get-DriveLetterMap $ResourceGroupName $VmName
            $letterChanges = @(foreach ($volume in $letterMap) {
                    $nowVolume = $afterMap | Where-Object { $_.Id -eq $volume.Id } |
                        Select-Object -First 1
                    if ($null -ne $nowVolume -and $nowVolume.Letter -ne $volume.Letter) {
                        "$($volume.Label) $($volume.Letter) -> $($nowVolume.Letter)"
                    }
                })
            if ($letterChanges.Count) {
                Write-Warning ('Guest drive letters changed: ' +
                    ($letterChanges -join '; ') + '. Reassign them in the guest.')
            }
        }
        catch {
            Write-Warning "Guest drive letters were not verified: $($_.Exception.Message)"
        }
    }

    if ($initialState -ne 'VM running') {
        Restore-PowerState $ResourceGroupName $VmName $initialState
    }
    $result = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VmName -Status `
        -ErrorAction Stop
}
catch {
    $failure = $_
    if (-not $vmRemoved) {
        try {
            if ($null -ne $pageFileBackup) {
                Restore-PageFileConfig $ResourceGroupName $VmName $pageFileBackup
            }
            Restore-PowerState $ResourceGroupName $VmName $initialState
        }
        catch { Write-Warning "Source restoration incomplete: $($_.Exception.Message)" }
        throw "Resize failed before the VM was deleted; nothing changed: $($failure.Exception.Message)"
    }

    $existing = $null
    try {
        $existing = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VmName `
            -ErrorAction Stop
    }
    catch {
        if (-not (Test-NotFound $_)) {
            throw "Resize failed: $($failure.Exception.Message). The state of '$VmName' could not be read: $($_.Exception.Message)"
        }
    }
    if ($null -ne $existing) {
        throw "Resize failed after '$VmName' was recreated at $([string]$existing.HardwareProfile.VmSize). Review the VM manually. Error: $($failure.Exception.Message)"
    }

    try {
        New-SameNameVm $sourceSize
    }
    catch {
        $backups = @($plans | ForEach-Object SnapshotName) -join ', '
        throw "Resize failed and '$VmName' could not be recreated. Disks and NICs were retained and backup snapshots exist ($backups). Original failure: $($failure.Exception.Message). Recreation failure: $($_.Exception.Message)"
    }
    try {
        if ($null -ne $pageFileBackup) {
            Restore-PageFileConfig $ResourceGroupName $VmName $pageFileBackup
        }
        Restore-PowerState $ResourceGroupName $VmName $initialState
    }
    catch { Write-Warning "Source restoration incomplete: $($_.Exception.Message)" }
    throw "Resize failed; '$VmName' was recreated at $sourceSize with its original disks and NICs: $($failure.Exception.Message)"
}

[pscustomobject]@{
    OperatingSystem = 'Windows'; VmName = $VmName; Size = $targetSize
    PowerState = Get-PowerState $result
    MigrationType = 'In-place recreation with retained disks and NICs'
    OsDisk = $osDisk.Name
    DataDisks = @($dataDisks | ForEach-Object Name)
    NetworkInterfaces = @($nics | ForEach-Object Name)
    DriveLetters = if ($null -eq $letterMap) { 'Not checked' }
        elseif ($letterChanges.Count) { $letterChanges }
        else { 'Retained' }
    BackupSnapshots = @($snapshots | ForEach-Object Name)
}
