# Script to report on Enterprise Applications in Entra ID (Azure AD) with complete permission details
# Enhanced version with permission name resolution

# Ensure required modules are installed
#$requiredModules = @("Microsoft.Graph", "ImportExcel")
#foreach ($module in $requiredModules) {
#    if (-not (Get-Module -ListAvailable -Name $module)) {
#        Write-Host "Installing required module: $module"
#        Install-Module -Name $module -Force -AllowClobber
#    }
#}


# Import the modules we need
try {
    Import-Module ImportExcel
    Import-Module Microsoft.Graph
} catch {
    Write-Host "Error loading required Microsoft Graph modules. Please ensure they are installed."
    exit
}


# Use a try/catch block for loading directory management cmdlets
try {
    # Try to get the directory role cmdlet
    $null = Get-Command Get-MgDirectoryRole -ErrorAction Stop
} catch {
    try {
        # If the cmdlet isn't available, try to import the module
        Import-Module Microsoft.Graph.Identity.DirectoryManagement -DisableNameChecking -ErrorAction Stop
    } catch {
        # If that fails with assembly error, we'll use a workaround with a different session
        Write-Host "Using workaround for Microsoft.Graph.Identity.DirectoryManagement module loading issue..." -ForegroundColor Yellow
    }
}
# Connect to Microsoft Graph with all required permissions
Connect-MgGraph -Scopes "Directory.Read.All", "Application.Read.All", "DelegatedPermissionGrant.Read.All", 
                "AppRoleAssignment.ReadWrite.All", "RoleManagement.Read.All", "User.Read.All", "Group.Read.All"

# Set the number of apps to process (0 = all)
$NumberToProcess = 0

# Get all Enterprise Applications (service principals)
Write-Host "Fetching Enterprise Applications from Entra ID..."
$EnterpriseApps = Get-MgServicePrincipal -Filter "servicePrincipalType eq 'Application'" -All

# Get Microsoft Graph and common API service principals for permission lookup
Write-Host "Fetching common API service principals for permission mapping..."
$CommonAPIs = @(
    "Microsoft Graph",
    "Office 365 Exchange Online",
    "Office 365 SharePoint Online",
    "Windows Azure Active Directory",
    "Office 365 Management APIs",
    "Microsoft Teams",
    "Azure Key Vault"
)

# Build permission lookup tables for quicker resolution
$PermissionLookup = @{}
Write-Host "Building permission lookup tables for faster resolution..."

foreach ($apiName in $CommonAPIs) {
    try {
        $ApiSP = Get-MgServicePrincipal -Filter "displayName eq '$apiName'" -Top 1
        if ($ApiSP) {
            # Add AppRoles to lookup table
            foreach ($appRole in $ApiSP.AppRoles) {
                $key = "$($ApiSP.AppId)|$($appRole.Id)"
                $PermissionLookup[$key] = @{
                    Value = $appRole.Value
                    DisplayName = $appRole.DisplayName
                    Description = $appRole.Description
                    Type = "Application"
                }
            }
            
            # Add OAuth2PermissionScopes to lookup table
            foreach ($permission in $ApiSP.OAuth2PermissionScopes) {
                $key = "$($ApiSP.AppId)|$($permission.Id)"
                $PermissionLookup[$key] = @{
                    Value = $permission.Value
                    DisplayName = $permission.AdminConsentDisplayName
                    Description = $permission.AdminConsentDescription
                    Type = "Delegated"
                }
            }
            Write-Host "Added permissions for $apiName"
        }
    }
    catch {
        Write-Warning "Error fetching permissions for $apiName`: $_"
    }
}

# Get all directory roles for later use - with fallback for assembly loading issues
Write-Host "Fetching directory roles..."
try {
    $DirectoryRoles = Get-MgDirectoryRole -All
}
catch {
    Write-Host "Error fetching directory roles using Get-MgDirectoryRole: $_" -ForegroundColor Yellow
    Write-Host "Using alternate method to fetch directory roles..." -ForegroundColor Yellow
    
    # Fallback approach using Microsoft Graph API directly
    try {
        $GraphUrl = "https://graph.microsoft.com/v1.0/directoryRoles"
        $DirectoryRoles = Invoke-MgGraphRequest -Uri $GraphUrl -Method GET | Select-Object -ExpandProperty value
    }
    catch {
        Write-Host "Error fetching directory roles via direct Graph call: $_" -ForegroundColor Red
        $DirectoryRoles = @()
    }
}

# Determine how many to process
$TotalApps = $EnterpriseApps.Count
If ($NumberToProcess -gt 0 -and $NumberToProcess -lt $TotalApps) {
    $AppsToProcess = $NumberToProcess
} else {
    $AppsToProcess = $TotalApps
}

Write-Host ("Processing {0} Enterprise Applications..." -f $AppsToProcess)

# Initialize report collections
$Report = [System.Collections.Generic.List[Object]]::new()
$UsersAndGroupsReport = [System.Collections.Generic.List[Object]]::new()
$AdminConsentReport = [System.Collections.Generic.List[Object]]::new()
$UserConsentReport = [System.Collections.Generic.List[Object]]::new()
$AppCount = 0

# Helper function to resolve permission name

# Add a special case for common Microsoft APIs with known permission GUIDs
$knownPermissions = @{
    # Microsoft Graph common permissions
    # "6918b873-d17a-4dc1-b314-35f528134491" = @{ Value = "Contacts.ReadWrite"; DisplayName = "Read and write contacts in all mailboxes"; Type = "Application" }
}


$graphSp = Get-MgServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'"

$knownPermissions = @{}

# Process Application permissions
foreach ($appRole in $graphSp.AppRoles) {
    $knownPermissions[$appRole.Id] = @{
        Value       = $appRole.Value
        DisplayName = $appRole.DisplayName
        Description = $appRole.Description
        Type        = "Application"
    }
}

# Process Delegated permissions
foreach ($scope in $graphSp.Oauth2PermissionScopes) {
    $knownPermissions[$scope.Id] = @{
        Value       = $scope.Value
        DisplayName = $scope.AdminConsentDisplayName
        Description = $scope.AdminConsentDescription
        Type        = "Delegated"
    }
}


function Get-PermissionDetails {
    param (
        [string]$ResourceAppId,
        [string]$PermissionId,
        [string]$DefaultName = ""
    )
    
    $key = "$ResourceAppId|$PermissionId"
    if ($PermissionLookup.ContainsKey($key)) {
        return $PermissionLookup[$key]
    }
    
    # If not in cache, try to get from service principal
    try {
        $ResourceSP = $EnterpriseApps | Where-Object { $_.AppId -eq $ResourceAppId }
        if ($ResourceSP) {
            # Check AppRoles
            $AppRole = $ResourceSP.AppRoles | Where-Object { $_.Id -eq $PermissionId }
            if ($AppRole) {
                $permInfo = @{
                    Value = $AppRole.Value
                    DisplayName = $AppRole.DisplayName
                    Description = $AppRole.Description
                    Type = "Application"
                }
                $PermissionLookup[$key] = $permInfo
                return $permInfo
            }
            
            # Check OAuth2PermissionScopes
            $Permission = $ResourceSP.OAuth2PermissionScopes | Where-Object { $_.Id -eq $PermissionId }
            if ($Permission) {
                $permInfo = @{
                    Value = $Permission.Value
                    DisplayName = $Permission.AdminConsentDisplayName
                    Description = $Permission.AdminConsentDescription
                    Type = "Delegated"
                }
                $PermissionLookup[$key] = $permInfo
                return $permInfo
            }
        }
    }
    catch {
        # Just continue if we can't resolve
    }
    
    
    # Check if this is a known permission GUID
    if ($knownPermissions.ContainsKey($PermissionId)) {
        $permInfo = $knownPermissions[$PermissionId]
        return $permInfo
    }

    # Return default if not found
    return @{
        Value = if ($DefaultName -ne "") { $DefaultName } else { $PermissionId }
        DisplayName = if ($DefaultName -ne "") { $DefaultName } else { "Unknown Permission" }
        Description = "Permission details not found"
        Type = "Unknown"
    }
}


# Process each enterprise application
ForEach ($App in $EnterpriseApps) {

    # #### REMOVE THIS SEGMENT FOR PRODUCTION ####
    # # Skip if the app is not starting witj adv 
    # If ($App.AppDisplayName -notlike "adv*") {
    #     continue
    # }
    # #### REMOVE THIS SEGMENT FOR PRODUCTION ####

    $AppCount++
    
    # Stop if we've processed the requested number
    If ($AppCount -gt $AppsToProcess) {
        break
    }
    
    Write-Host ("Processing app {0}/{1}: {2}" -f $AppCount, $AppsToProcess, $App.DisplayName)
    
    # Get app owners
    $Owners = @()
    try {
        $AppOwners = Get-MgServicePrincipalOwner -ServicePrincipalId $App.Id -All
        foreach ($Owner in $AppOwners) {
            try {
                if ($Owner.AdditionalProperties.ContainsKey('@odata.type')) {
                    if ($Owner.AdditionalProperties['@odata.type'] -eq '#microsoft.graph.user') {
                        $User = Get-MgUser -UserId $Owner.Id
                        $Owners += $User.DisplayName
                    } elseif ($Owner.AdditionalProperties['@odata.type'] -eq '#microsoft.graph.servicePrincipal') {
                        $SP = Get-MgServicePrincipal -ServicePrincipalId $Owner.Id
                        $Owners += "$($SP.DisplayName) (Service Principal)"
                    }
                }
            } catch {
                Write-Warning "Error retrieving owner details for $($Owner.Id): $_"
            }
        }
    } catch {
        Write-Warning "Error retrieving owners for $($App.DisplayName): $_"
    }
    
    # Get administrative roles assigned to the app
    $AdminRoles = @()
    try {
        foreach ($Role in $DirectoryRoles) {
            try {
                # Handle both object types (direct cmd or Graph API response)
                $RoleId = if ($Role.PSObject.Properties.Name -contains "Id") { $Role.Id } else { $Role.id }
                $RoleName = if ($Role.PSObject.Properties.Name -contains "DisplayName") { $Role.DisplayName } else { $Role.displayName }
                
                # Try to get role members
                try {
                    $RoleMembers = Get-MgDirectoryRoleMember -DirectoryRoleId $RoleId -ErrorAction Stop
                }
                catch {
                    # Fallback to direct Graph API call
                    $GraphUrl = "https://graph.microsoft.com/v1.0/directoryRoles/$RoleId/members"
                    $RoleMembers = (Invoke-MgGraphRequest -Uri $GraphUrl -Method GET).value
                }
                
                foreach ($Member in $RoleMembers) {
                    $MemberId = if ($Member.PSObject.Properties.Name -contains "Id") { $Member.Id } else { $Member.id }
                    if ($MemberId -eq $App.Id) {
                        $AdminRoles += $RoleName
                        break
                    }
                }
            }
            catch {
                Write-Verbose "Error checking role $($RoleName): $_"
                continue
            }
        }
    } catch {
        Write-Warning "Error retrieving admin roles for $($App.DisplayName): $_"
    }
    
    # Get assigned users and groups
    $AssignedUsers = @()
    $AssignedGroups = @()
    
    # Get all app role assignments (user and group assignments)
    $AppRoleAssignments = Get-MgServicePrincipalAppRoleAssignedTo -ServicePrincipalId $App.Id -All
    
    foreach ($Assignment in $AppRoleAssignments) {
        try {
            if ($Assignment.PrincipalType -eq "User") {
                $User = Get-MgUser -UserId $Assignment.PrincipalId
                $AssignedUsers += $User
                
                # Add to the Users and Groups report
                $UserLine = [PSCustomObject]@{
                    ApplicationName = $App.DisplayName
                    ApplicationId = $App.Id
                    AssignmentType = "User"
                    ObjectId = $User.Id
                    DisplayName = $User.DisplayName -Replace('"', '')
                    PrincipalName = $User.UserPrincipalName
                    AssignmentId = $Assignment.Id
                }
                $UsersAndGroupsReport.Add($UserLine)
                
            } elseif ($Assignment.PrincipalType -eq "Group") {
                $Group = Get-MgGroup -GroupId $Assignment.PrincipalId
                $AssignedGroups += $Group
                
                # Add to the Users and Groups report
                $GroupLine = [PSCustomObject]@{
                    ApplicationName = $App.DisplayName
                    ApplicationId = $App.Id
                    AssignmentType = "Group"
                    ObjectId = $Group.Id
                    DisplayName = $Group.DisplayName
                    PrincipalName = $Group.Mail
                    AssignmentId = $Assignment.Id
                }
                $UsersAndGroupsReport.Add($GroupLine)
            }
        } catch {
            Write-Warning "Error retrieving assignment details for $($Assignment.PrincipalId): $_"
        }
    }
    
    # Get delegated permissions granted to the app (user consent permissions)
    $DelegatedPermissions = @()
    try {
        $Oauth2PermissionGrants = Get-MgOauth2PermissionGrant -Filter "clientId eq '$($App.Id)'" -All
        foreach ($Grant in $Oauth2PermissionGrants) {
            $ResourceApp = $EnterpriseApps | Where-Object { $_.AppId -eq $Grant.ResourceId }
            $ResourceName = if ($ResourceApp) { $ResourceApp.DisplayName } else { $Grant.ResourceId }
            
            $ScopesArray = $Grant.Scope -split ' '
            foreach ($Scope in $ScopesArray) {
                # First try to find the permission details in the resource app
                $PermissionDetails = $null
                if ($ResourceApp) {
                    $PermissionDetails = $ResourceApp.OAuth2PermissionScopes | Where-Object { $_.Value -eq $Scope }
                }
                
                $PermissionName = if ($PermissionDetails) { $PermissionDetails.Value } else { $Scope }
                $PermissionDisplayName = if ($PermissionDetails) { $PermissionDetails.AdminConsentDisplayName } else { "Unknown" }
                
                $Permission = [PSCustomObject]@{
                    ResourceName = $ResourceName
                    Permission = $PermissionName
                    PermissionDisplayName = $PermissionDisplayName
                    ConsentType = $Grant.ConsentType
                }
                $DelegatedPermissions += $Permission
                
                # Add to the appropriate consent report
                if ($Grant.ConsentType -eq "AllPrincipals") {
                    $AdminConsentLine = [PSCustomObject]@{
                        ApplicationName = $App.DisplayName
                        ApplicationId = $App.Id
                        ResourceName = $ResourceName
                        ResourceId = $Grant.ResourceId
                        Permission = $PermissionName
                        PermissionDisplayName = $PermissionDisplayName
                        PermissionType = "Delegated"
                        ConsentId = $Grant.Id
                        GrantedOn = $Grant.StartTime
                    }
                    $AdminConsentReport.Add($AdminConsentLine)
                } else {
                    # This is a user consent
                    $Principal = ""
                    try {
                        if ($Grant.PrincipalId) {
                            $User = Get-MgUser -UserId $Grant.PrincipalId
                            $Principal = $User.DisplayName
                        }
                    } catch {
                        $Principal = $Grant.PrincipalId
                    }
                    
                    $UserConsentLine = [PSCustomObject]@{
                        ApplicationName = $App.DisplayName
                        ApplicationId = $App.Id
                        ResourceName = $ResourceName
                        ResourceId = $Grant.ResourceId
                        Permission = $PermissionName
                        PermissionDisplayName = $PermissionDisplayName
                        ConsentedBy = $Principal
                        ConsentId = $Grant.Id
                        GrantedOn = $Grant.StartTime
                    }
                    $UserConsentReport.Add($UserConsentLine)
                }
            }
        }
    } catch {
        Write-Warning "Error retrieving delegated permissions for $($App.DisplayName): $_"
    }
    
    # Get app role assignments granted to the app (admin consent permissions)
    $AppRolePermissions = @()
    try {
        $AppRoleAssignments = Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $App.Id -All
        foreach ($Assignment in $AppRoleAssignments) {
            $ResourceApp = $EnterpriseApps | Where-Object { $_.AppId -eq $Assignment.ResourceAppId }
            $ResourceName = if ($ResourceApp) { $ResourceApp.DisplayName } else { $Assignment.ResourceAppId }
            
            # Get proper permission details
            $PermissionDetails = Get-PermissionDetails -ResourceAppId $Assignment.ResourceAppId -PermissionId $Assignment.AppRoleId
            $RoleName = $PermissionDetails.Value
            $RoleDisplayName = $PermissionDetails.DisplayName
            
            $Permission = [PSCustomObject]@{
                ResourceName = $ResourceName
                Permission = $RoleName
                PermissionDisplayName = $RoleDisplayName
                PrincipalDisplayName = $App.DisplayName
            }
            $AppRolePermissions += $Permission
            
            # Add to the Admin Consent report
            $AdminRoleConsentLine = [PSCustomObject]@{
                ApplicationName = $App.DisplayName
                ApplicationId = $App.Id
                ResourceName = $ResourceName
                ResourceId = $Assignment.ResourceAppId
                Permission = $RoleName
                PermissionDisplayName = $RoleDisplayName
                PermissionDescription = $PermissionDetails.Description
                PermissionType = "Application"
                PermissionId = $Assignment.AppRoleId
                AssignmentId = $Assignment.Id
                CreatedDate = $Assignment.CreatedDateTime
            }
            $AdminConsentReport.Add($AdminRoleConsentLine)
        }
    } catch {
        Write-Warning "Error retrieving app role permissions for $($App.DisplayName): $_"
    }
    
    # Create report entry
    $ReportLine = [PSCustomObject]@{
        ApplicationName        = $App.DisplayName
        ApplicationId          = $App.Id
        AppId                  = $App.AppId
        Publisher              = $App.PublisherName
        SignInAudience         = $App.SignInAudience
        Homepage               = $App.Homepage
        Owners                 = ($Owners -join ", ")
        OwnersCount            = $Owners.Count
        AdminRoles             = ($AdminRoles -join ", ")
        AdminRolesCount        = $AdminRoles.Count
        AssignedUsersCount     = $AssignedUsers.Count
        AssignedGroupsCount    = $AssignedGroups.Count
        DelegatedPermCount     = $DelegatedPermissions.Count
        AppRolePermCount       = $AppRolePermissions.Count
        CreatedDate            = $App.AdditionalProperties.createdDateTime
    }
    
    $Report.Add($ReportLine)
}

# Output the report to Excel
Write-Host "Creating Excel report with multiple worksheets..."

# Define Excel file path
$ExcelPath = ".\EntraIDAppPermissionsReport.xlsx"

# Remove existing file if it exists to avoid conflicts
if (Test-Path $ExcelPath) {
    Remove-Item -Path $ExcelPath -Force
}

# Create the main report
Write-Host "Creating Enterprise Apps worksheet..."
$Report | Export-Excel -Path $ExcelPath -WorksheetName "Enterprise Apps" -AutoSize

# Add Users and Groups worksheet - without creating a table to avoid conflicts
Write-Host "Adding Users and Groups worksheet..."
if ($UsersAndGroupsReport.Count -gt 0) {
    $UsersAndGroupsReport
    $UsersAndGroupsReport | Export-Excel -Path $ExcelPath -WorksheetName "Users and Groups" -AutoSize -Append
} else {
    # Create a dummy entry to ensure worksheet is created
    [PSCustomObject]@{Note = "No users or groups assigned to applications"} | 
        Export-Excel -Path $ExcelPath -WorksheetName "Users and Groups" -AutoSize -Append
}

# Add Admin Consent worksheet - without creating a table to avoid conflicts
Write-Host "Adding Admin Consent worksheet..."
if ($AdminConsentReport.Count -gt 0) {
    $AdminConsentReport | Export-Excel -Path $ExcelPath -WorksheetName "Admin Consent" -AutoSize -Append
} else {
    # Create a dummy entry to ensure worksheet is created
    [PSCustomObject]@{Note = "No admin consents found"} | 
        Export-Excel -Path $ExcelPath -WorksheetName "Admin Consent" -AutoSize -Append
}

# Add User Consent worksheet - without creating a table to avoid conflicts
Write-Host "Adding User Consent worksheet..."
if ($UserConsentReport.Count -gt 0) {
    $UserConsentReport | Export-Excel -Path $ExcelPath -WorksheetName "User Consent" -AutoSize -Append
} else {
    # Create a dummy entry to ensure worksheet is created
    [PSCustomObject]@{Note = "No user consents found"} | 
        Export-Excel -Path $ExcelPath -WorksheetName "User Consent" -AutoSize -Append
}

# Open the Excel file
Write-Host "Opening the Excel report..."
Invoke-Item $ExcelPath

Write-Host "Report complete. The Excel file has been created: $ExcelPath"
