
#List all App Registrations Delegated and Application Permissions in the Entra ID Tenant

Connect-MgGraph -Scopes "User.Read.All", "Group.ReadWrite.All", "Application.Read.All", "Application.ReadWrite.All", "Directory.Read.All", "Directory.ReadWrite.All", "Directory.AccessAsUser.All"

$Apps = Get-MgApplication

$permissions = @()

foreach ($App in $Apps) {

    $sp = Get-MgServicePrincipal -Filter "DisplayName eq '$($App.DisplayName)'"

    #Get-MgServicePrincipalOauth2PermissionGrant -ServicePrincipalId $sp.Id | select ResourceId, ConsentType, PrincipalId, Scope
    $oAuth2PermGrants = Get-MgServicePrincipalOauth2PermissionGrant -ServicePrincipalId $sp.Id
    $oAuth2PermGrants | % { 
        $resourceSP = Get-MgServicePrincipal -ServicePrincipalId $_.ResourceId
        $userPrincipal = $_.ConsentType -eq "Principal" ? (Get-MgUser -UserId $_.PrincipalId) : $null
        $permissions += [PSCustomObject] @{
            "PermissionType" = "Delegated"
            "AADAppName"     = $sp.DisplayName
            #"AADAppId" = $sp.AppId
            "Resource"       = $resourceSP.DisplayName
            #"ResourceId" = $resourceSP.Id
            "Scope"          = $_.Scope
            "ConsentType"    = $_.ConsentType
            "PrincipalType"  = "User"
            "UPN"            = $userPrincipal -ne $null ? $userPrincipal.UserPrincipalName : "NA"
            "PrincipalId"    = $userPrincipal -ne $null ? $userPrincipal.Id : "NA"
        }    
    }


    $appRoles = Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $sp.Id
    $appRoles | % {
        $resourceSP = Get-MgServicePrincipal -ServicePrincipalId $_.ResourceId
        $appRoleInfo = $resourceSP.AppRoles | where Id -eq $_.AppRoleId
        $permissions += [PSCustomObject] @{
            "PermissionType" = "Application"
            "AADAppName"     = $sp.DisplayName
            #"AADAppId" = $sp.AppId
            "Resource"       = $resourceSP.DisplayName
            #"ResourceId" = $resourceSP.Id
            "Scope"          = $appRoleInfo.Value
            "ConsentType"    = "NA"
            "PrincipalType"  = $_.PrincipalType
            "UPN"            = "NA"
            "PrincipalId"    = $_.PrincipalId
        } 
    }
} 


#Show permission details
$permissions | FT -AutoSize

#Export permision details to a csv file
#$permissions | Export-Csv -Path "AppsInventory.csv" -NoTypeInformation 
