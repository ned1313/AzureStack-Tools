# Copyright (c) Microsoft Corporation. All rights reserved.
# See LICENSE.txt in the project root for license information.

#requires -Version 4.0
#requires -Modules AzureRM.Profile, VpnClient, AzureRM.AzureStackAdmin


<#
    .SYNOPSIS
    Adds Azure Stack environment to use with AzureRM command-lets when targeting Azure Stack
#>

function Add-AzsEnvironment {
    param (
        [Parameter(mandatory = $true, HelpMessage = "The Admin ARM endpoint of the Azure Stack Environment")]
        [string] $ArmEndpoint,
        [parameter(mandatory = $true, HelpMessage = "Azure Stack environment name for use with AzureRM commandlets")]
        [string] $Name
    )

    Write-Warning "The function '$($MyInvocation.MyCommand)' is marked for future deprecation."

    if (!$ARMEndpoint.Contains('https://')) {
        if ($ARMEndpoint.Contains('http://')) {
            $ARMEndpoint = $ARMEndpoint.Substring(7)
            $ARMEndpoint = 'https://' + $ARMEndpoint

        }
        else {
            $ARMEndpoint = 'https://' + $ARMEndpoint
        }
    }

    $ArmEndpoint = $ArmEndpoint.TrimEnd("/")

    $Domain = ""
    try {
        $null = [System.Uri] $ArmEndpoint
        $i = $ArmEndpoint.IndexOf('.')
        $Domain = ($ArmEndpoint.Remove(0, $i + 1)).TrimEnd('/')
    }
    catch {
        Write-Error "The specified ARM endpoint was invalid"
    }

    $ResourceManagerEndpoint = $ArmEndpoint 
    $stackdomain = $Domain         

    Write-Verbose "Retrieving endpoints from the $ResourceManagerEndpoint..." -Verbose
    $endpoints = Invoke-RestMethod -Method Get -Uri "$($ResourceManagerEndpoint.ToString().TrimEnd('/'))/metadata/endpoints?api-version=2015-01-01" -ErrorAction Stop

    $AzureKeyVaultDnsSuffix = "vault.$($stackdomain)".ToLowerInvariant()
    $AzureKeyVaultServiceEndpointResourceId = $("https://vault.$stackdomain".ToLowerInvariant())
    $StorageEndpointSuffix = ($stackdomain).ToLowerInvariant()
    $aadAuthorityEndpoint = $endpoints.authentication.loginEndpoint

    $azureEnvironmentParams = @{
        Name                                     = $Name
        ActiveDirectoryEndpoint                  = $endpoints.authentication.loginEndpoint.TrimEnd('/') + "/"
        ActiveDirectoryServiceEndpointResourceId = $endpoints.authentication.audiences[0]
        ResourceManagerEndpoint                  = $ResourceManagerEndpoint
        GalleryEndpoint                          = $endpoints.galleryEndpoint
        GraphEndpoint                            = $endpoints.graphEndpoint
        GraphAudience                            = $endpoints.graphEndpoint
        StorageEndpointSuffix                    = $StorageEndpointSuffix
        AzureKeyVaultDnsSuffix                   = $AzureKeyVaultDnsSuffix
        AzureKeyVaultServiceEndpointResourceId   = $AzureKeyVaultServiceEndpointResourceId
        EnableAdfsAuthentication                 = $aadAuthorityEndpoint.TrimEnd("/").EndsWith("/adfs", [System.StringComparison]::OrdinalIgnoreCase)
    }

    $armEnv = Get-AzureRmEnvironment -Name $Name
    if ($armEnv) {
        Write-Verbose "Updating AzureRm environment $Name" -Verbose
        Remove-AzureRmEnvironment -Name $Name -Force | Out-Null
    }
    else {
        Write-Verbose "Adding AzureRm environment $Name" -Verbose
    }
            
    return Add-AzureRmEnvironment @azureEnvironmentParams
}

Export-ModuleMember -Function 'Add-AzsEnvironment'

<#
    .SYNOPSIS
    Add VPN connection to an Azure Stack instance
#>

function Add-AzsVpnConnection {
    param (
        [parameter(HelpMessage = "Azure Stack VPN Connection Name such as 'my-poc'")]
        [string] $ConnectionName = "azurestack",

        [parameter(mandatory = $true, HelpMessage = "External IP of the Azure Stack NAT VM such as '1.2.3.4'")]
        [string] $ServerAddress,

        [parameter(mandatory = $true, HelpMessage = "Administrator password used to deploy this Azure Stack instance")]
        [securestring] $Password
    )

    $existingConnection = Get-VpnConnection -Name $ConnectionName -ErrorAction Ignore
    if ($existingConnection) {
        Write-Verbose "Updating Azure Stack VPN connection named $ConnectionName" -Verbose
        rasdial $ConnectionName /d
        Remove-VpnConnection -name $ConnectionName -Force -ErrorAction Ignore
    }
    else {
        Write-Verbose "Creating Azure Stack VPN connection named $ConnectionName" -Verbose
    }

    $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
    $PlainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)

    $connection = Add-VpnConnection -Name $ConnectionName -ServerAddress $ServerAddress -TunnelType L2tp -EncryptionLevel Required -AuthenticationMethod MSChapv2 -L2tpPsk $PlainPassword -Force -RememberCredential -PassThru -SplitTunneling 
    
    Write-Verbose "Adding routes to Azure Stack VPN connection named $ConnectionName" -Verbose
    Add-VpnConnectionRoute -ConnectionName $ConnectionName -DestinationPrefix 192.168.102.0/27 -RouteMetric 2 -PassThru | Out-Null
    Add-VpnConnectionRoute -ConnectionName $ConnectionName -DestinationPrefix 192.168.105.0/27 -RouteMetric 2 -PassThru | Out-Null

    return $connection
}

Export-ModuleMember -Function 'Add-AzsVpnConnection'

<#
    .SYNOPSIS
    Connects to Azure Stack via VPN
#>

function Connect-AzsVpn {
    param (
        [parameter(HelpMessage = "Azure Stack VPN Connection Name such as 'my-poc'")]
        [string] $ConnectionName = "azurestack",
        [parameter(HelpMessage = "Administrator user name of this Azure Stack Instance")]
        [string] $User = "administrator",
        [parameter(mandatory = $true, HelpMessage = "Administrator password used to deploy this Azure Stack instance")]
        [securestring] $Password,
        [parameter(HelpMessage = "Indicate whether to retrieve and trust certificates from the environment after establishing a VPN connection")]
        [bool] $RetrieveCertificates = $true
    )    
    
    Write-Verbose "Connecting to Azure Stack VPN using connection named $ConnectionName..." -Verbose

    $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
    $PlainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)

    # Connecting using legacy command. Need to use domainless cred. Domain will be assumed on the other end.
    rasdial $ConnectionName $User $PlainPassword

    $azshome = "$env:USERPROFILE\Documents\$ConnectionName"

    if ($RetrieveCertificates) {
        Write-Verbose "Connection-specific files will be saved in $azshome" -Verbose

        New-Item $azshome -ItemType Directory -Force | Out-Null

        $hostIP = (Get-VpnConnection -Name $ConnectionName).ServerAddress

        $UserCred = ".\$User"
        $credential = New-Object System.Management.Automation.PSCredential -ArgumentList $UserCred, $Password

        Write-Verbose "Retrieving Azure Stack Root Authority certificate..." -Verbose
        $cert = Invoke-Command -ComputerName "$hostIP" -ScriptBlock { Get-ChildItem cert:\currentuser\root | where-object {$_.Subject -like "*AzureStackSelfSignedRootCert*"} } -Credential $credential

        if ($cert) {
            if ($cert.GetType().IsArray) {
                $cert = $cert[0] # take any that match the subject if multiple certs were deployed
            }

            $certFilePath = "$azshome\CA.cer"

            Write-Verbose "Saving Azure Stack Root certificate in $certFilePath..." -Verbose

            Export-Certificate -Cert $cert -FilePath $certFilePath -Force | Out-Null

            Write-Verbose "Installing Azure Stack Root certificate for the current user..." -Verbose
            
            Write-Progress "LOOK FOR CERT ACCEPTANCE PROMPT ON YOUR SCREEN!"

            Import-Certificate -CertStoreLocation cert:\currentuser\root -FilePath $certFilePath
        }
        else {
            Write-Error "Certificate has not been retrieved!"
        }
    }

}

Export-ModuleMember -Function 'Connect-AzsVpn'

<#
    .SYNOPSIS
    Retrieve the admin token and subscription ID needed to make REST calls directly to Azure Resource Manager
#>

function Get-AzsAdminSubTokenHeader {
    param (
        [parameter(mandatory = $true, HelpMessage = "Name of the Azure Stack Environment")]
        [string] $EnvironmentName,

        [parameter(mandatory = $true, HelpMessage = "TenantID of Identity Tenant")]
        [string] $tenantID,

        [parameter(HelpMessage = "Credentials to retrieve token header for")]
        [System.Management.Automation.PSCredential] $azureStackCredentials,

        [parameter(HelpMessage = "Name of the Administrator subscription")]
        [string] $subscriptionName = "Default Provider Subscription"
    )
    
    $azureStackEnvironment = Get-AzureRmEnvironment -Name $EnvironmentName -ErrorAction SilentlyContinue
    if ($azureStackEnvironment) {
        $ARMEndpoint = $azureStackEnvironment.ResourceManagerUrl
    }
    else {
        Write-Error "The Azure Stack Admin environment with the name $EnvironmentName does not exist. Create one with Add-AzsEnvironment." -ErrorAction Stop
    }

    if (-not $azureStackCredentials) {
        $azureStackCredentials = Get-Credential
    }

    try {
        Invoke-RestMethod -Method Get -Uri "$($ARMEndpoint.ToString().TrimEnd('/'))/metadata/endpoints?api-version=2015-01-01" -ErrorAction Stop | Out-Null
    }
    catch {
        Write-Error "The specified ARM endpoint: $ArmEndpoint is not valid for this environment. Please make sure you are using the correct administrator ARM endpoint for this environment." -ErrorAction Stop
    }

    $authority = $azureStackEnvironment.ActiveDirectoryAuthority
    $activeDirectoryServiceEndpointResourceId = $azureStackEnvironment.ActiveDirectoryServiceEndpointResourceId

    Login-AzureRmAccount -EnvironmentName $EnvironmentName -TenantId $tenantID -Credential $azureStackCredentials | Out-Null

    try {
        $subscription = Get-AzureRmSubscription -SubscriptionName $subscriptionName 
    }
    catch {
        Write-Error "Verify that the login credentials are for the administrator and that the specified ARM endpoint: $ArmEndpoint is the valid administrator ARM endpoint for this environment." -ErrorAction Stop
    }

    $subscription | Select-AzureRmSubscription | Out-Null

    $powershellClientId = "0a7bdc5c-7b57-40be-9939-d4c5fc7cd417"

    $savedWarningPreference = $WarningPreference
    $WarningPreference = 'SilentlyContinue' 

    $adminToken = Get-AzureStackToken `
        -Authority $authority `
        -Resource $activeDirectoryServiceEndpointResourceId `
        -AadTenantId $tenantID `
        -ClientId $powershellClientId `
        -Credential $azureStackCredentials 

    $WarningPreference = $savedWarningPreference

    $headers = @{ Authorization = ("Bearer $adminToken") }
    
    return $subscription.SubscriptionId, $headers
}

Export-ModuleMember -Function 'Get-AzsAdminSubTokenHeader'

<#
    .SYNOPSIS
    Connecting to your environment requires that you obtain the value of your Directory Tenant ID. 
    For **Azure Active Directory** environments provide your directory tenant name.
#>

function Get-AzsDirectoryTenantId () {
    [CmdletBinding(DefaultParameterSetName = 'AzureActiveDirectory')]
    param(
        [Parameter(Mandatory = $true, ParameterSetName = 'ADFS')]
        [switch] $ADFS,

        [parameter(mandatory = $true, ParameterSetName = 'AzureActiveDirectory', HelpMessage = "AAD Directory Tenant <myaadtenant.onmicrosoft.com>")]
        [string] $AADTenantName,

        [Parameter(Mandatory = $true, ParameterSetName = 'ADFS')]
        [Parameter(Mandatory = $true, ParameterSetName = 'AzureActiveDirectory')]
        [string] $EnvironmentName
    )
    
    $ADauth = (Get-AzureRmEnvironment -Name $EnvironmentName).ActiveDirectoryAuthority
    if ($ADFS -eq $true) {
        if (-not (Get-AzureRmEnvironment -Name $EnvironmentName).EnableAdfsAuthentication) {
            Write-Error "This environment is not configured to do ADFS authentication." -ErrorAction Stop
        }
        return $(Invoke-RestMethod $("{0}/.well-known/openid-configuration" -f $ADauth.TrimEnd('/'))).issuer.TrimEnd('/').Split('/')[-1]
    }
    else {
        $endpt = "{0}{1}/.well-known/openid-configuration" -f $ADauth, $AADTenantName
        $OauthMetadata = (Invoke-WebRequest -UseBasicParsing $endpt).Content | ConvertFrom-Json
        $AADid = $OauthMetadata.Issuer.Split('/')[3]
        $AADid
    }
} 

Export-ModuleMember Get-AzsDirectoryTenantId
