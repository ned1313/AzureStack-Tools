<#
.SYNOPSIS
    Contains functions to view and download available products from the Azure Syndication
    Requires that the Azure Stack system already be registered and syndicated with Azure
#>
function Get-AzSMarketplaceItem {
[CmdletBinding(DefaultParameterSetName='MarketplaceItemName')]    

    Param(
        [Parameter(Mandatory=$false, ParameterSetName='MarketplaceItemName')]
        [ValidateNotNullorEmpty()]
        [string] $MarketplaceItemName,

        [Parameter(Mandatory=$false, ParameterSetName='MarketplaceItemID')]
        [ValidateNotNullorEmpty()]
        [string] $MarketplaceItemID,

        [Parameter(Mandatory=$false, ParameterSetName='SyncOfflineAzsMarketplaceItem')]
        [ValidateNotNullorEmpty()]
        [string] $ActivationResourceGroup = "azurestack-activation",

        [Parameter(Mandatory=$false, ParameterSetName='SyncOfflineAzsMarketplaceItem')]
        [ValidateNotNullorEmpty()]
        [string] $SubscriptionID
    )


    $MPItems = Get-AzureRmResource -ResourceId "/subscriptions/$SubscriptionID/resourceGroups/$ActivationResourceGroup/providers/Microsoft.AzureBridge.Admin/activations/default/products/"
    
    if($MarketplaceItemName){
        $MPItems = $MPItems | Where-Object{$_.Properties.displayName -eq $MarketplaceItemName}
        return $MPItems
    }elseif ($MarketplaceItemID) {
        $MPItems = $MPItems | Where-Object{$_.Properties.galleryItemIdentity -eq $MarketplaceItemID}
        return $MPItems
    }else {
        return $MPItems
    }
}

function Add-AzSMarketplaceItem {
[CmdletBinding(DefaultParameterSetName='MarketplaceItemName')]

    Param(
        [string] $MarketplaceItemName,
        [string] $MarketplaceItemID,
        [string] $SubscriptionID,
        [string] $apiVersion = "2016-01-01",
        [string] $ArmEndpoint = "https://adminmanagement.local.azurestack.external",
        [bool] $BackgroundDownload
    )

    if($MarketplaceItemName){
        $MPItem = Get-AzSMarketplaceItem -MarketPlaceItemName $MarketplaceItemName -SubscriptionID $SubscriptionID
    }elseif($MarketplaceItemID){
        $MPItem = Get-AzSMarketplaceItem -MarketPlaceItemID $MarketplaceItemID -SubscriptionID $SubscriptionID
    }else{
        throw("no marketplace item name or ID specified")
    }
    if(-not $MPItem){
        throw("no marketplace item found")
    }

    $tokens = [Microsoft.Azure.Commands.Common.Authentication.AzureSession]::Instance.TokenCache.ReadItems()

    $downloadUri = $ArmEndpoint + $MPItem.ResourceId + "/download?api-version=$apiVersion"
    Invoke-RestMethod -Method Post -Uri $downloadUri -Headers @{'Authorization'="Bearer $($tokens.AccessToken)"}

    if(-not $BackgroundDownload){
        $MPItemResourceID = "/subscriptions/$subID/resourceGroups/$ActivationResourceGroup/providers/Microsoft.AzureBridge.Admin/activations/default/downloadedproducts/" + $MPItem.Properties.publisherIdentifier + "." + $MPItem.Properties.offer + $MPItem.Properties.sku

    
        do{
            $downloadItem = Get-AzureRmResource -ResourceId $MPItemResourceID
            Write-Output "Downloading Item"
        }while($downloadItem.provisioningState -ne "Succeeded")
    }

}