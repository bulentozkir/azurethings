# PowerShell script that enumerates all blobs in an Azure Storage account and retrieves information for blobs where anonymous access is allowed:

# Authenticate to Microsoft Azure platform
Connect-AzAccount

# Select the appropriate Azure subscription
$SubscriptionName = 'devtest'
Select-AzSubscription -SubscriptionName $SubscriptionName

# Specify your storage account details
$StorageAccountName = 'haliterenrgperfdiag549'

# $StorageAccount = Get-AzStorageAccount -ResourceGroupName 'haliteren-rg' -Name $StorageAccountName
$StorageKey = (Get-AzStorageAccountKey -ResourceGroupName 'haliteren-rg' -Name $StorageAccountName).Value[0]
$Context = New-AzStorageContext -StorageAccountName $StorageAccountName -StorageAccountKey $StorageKey

# Rest of the script remains unchanged

# Rest of the script remains unchanged
# ...

# List all containers in the storage account
$Containers = Get-AzStorageContainer -Context $Context

# Iterate through each container
foreach ($Container in $Containers) {
    Write-Host "Container: $($Container.Name)"

    try {
        # Retrieve a list of blobs in the container
        $Blobs = Get-AzStorageBlob -Context $Context -Container $Container.Name
    }
    catch {
        Write-Host "Error retrieving blobs in the container. $($Container.Name)"
        continue
    }

    # Check if each blob allows anonymous access
    foreach ($Blob in $Blobs) {
        $BlobName = $Blob.Name
        $BlobUrl = $Blob.ICloudBlob.Uri.AbsoluteUri

        # Create an anonymous context for the blob
        $AnonContext = New-AzStorageContext -StorageAccountName $StorageAccountName -Anonymous

        # Attempt to retrieve blob properties anonymously
        try {
            $BlobProperties = Get-AzStorageBlob -Context $AnonContext -Container $Container.Name -Blob $BlobName
            Write-Host "  Blob: $BlobName (Anonymous Access Allowed)"
            Write-Host "    URL: $BlobUrl"
            Write-Host "    Content Type: $($BlobProperties.Properties.ContentType)"
            # Add any other relevant properties you want to display
        }
        catch {
            # If anonymous access is not allowed, catch the exception
            Write-Host "  Blob: $BlobName (No Anonymous Access)"
        }
    }
}
