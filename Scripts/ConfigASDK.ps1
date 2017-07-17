
<#

.SYNOPSYS

    The purpose of this script is to automate as much as possible post deployment tasks in Azure Stack Development Kit
    This include :
        - Tools installation (git, azstools, Azure Stack PS module)
        - Registration with Azure
        - Windows Server 2016 and Ubuntu 14.04.4-LTS images installation
        - MySQL Resource Provider Installation
        - Deployment of a MySQL 5.7 hosting Server on Windows Server 2016 Core
        - SQL Resource Provider Installation
        - AppService Resource Provider sources download

.VERSION

    0.1: Initial version

.AUTHOR

    Alain VETIER 

    Blog: http://aka.ms/alainv  

.PARAMETERS

	-AAD (if you used AAD deployment) -Register (If you want to register your ASDK with Azure to enable market place Syndication)

.EXAMPLE

	ConfigASDK.ps1 -AAD -Register

#>



[CmdletBinding()]
Param (

# if AAD deployment
[switch]$AAD,

# if you want to enable market place syndication
[switch]$Register

)

$ISOPath = "PATH_TO WIN2016_ISO"                             # path to your windows 2016 evaluation ISO
$rppassword = "ADMINPASSWORD_FOR_RP_INSTALLATION"            # the password that you want to set for Resource Providers administrator account
$Azscredential = Get-Credential                              # your service administrator (azure Stack) credentials
$azureSubscriptionId = "YOUR_SUBSCRIPTION_ID"                # your Azure subscription ID
$azureDirectoryTenantName = "YOUR_AAD_TENANT_NAME"           # your Azure Tenant Directory Name
$azureAccountId = "YOUR_AZURE_SERVICE_ADMIN"                 # your Azure Global Administrator account ID

# set password expiration to 180 days
Set-ADDefaultDomainPasswordPolicy -MaxPasswordAge 180.00:00:00 -Identity azurestack.local
Get-ADDefaultDomainPasswordPolicy

# Install Azure Stack PS module
Set-PSRepository -Name "PSGallery" -InstallationPolicy Trusted
Get-Module -ListAvailable | where-Object {$_.Name -like “Azure*”} | Uninstall-Module
Install-Module -Name AzureRm.BootStrapper
Use-AzureRmProfile -Profile 2017-03-09-profile -Force
Install-Module -Name AzureStack -RequiredVersion 1.2.10
Get-Module -ListAvailable | where-Object {$_.Name -like “Azure*”}

# Download git
invoke-webrequest https://github.com/git-for-windows/git/releases/download/v2.13.3.windows.1/Git-2.13.3-64-bit.exe -OutFile "c:\temp\Git-2.13.3-64-bit.exe"
$scriptblock = {C:\Temp\Git-2.13.3-64-bit.exe /SILENT /COMPONENTS="icons,ext\reg\shellhere,assoc,assoc_sh" }
icm -ScriptBlock $scriptblock | Out-Null

#Download AZSTools
$s = New-PSSession
$scriptblock = {
cd \
git clone https://github.com/Azure/AzureStack-Tools.git --recursive | Out-Null
}
icm -ScriptBlock $scriptblock -Session $s | Out-Null

# Register with azure - this will prompt for your Azure Credential
if ($Register) {
invoke-webrequest https://raw.githubusercontent.com/Azure/AzureStack-Tools/master/Registration/RegisterWithAzure.ps1 -OutFile "c:\temp\RegisterWithAzure.ps1"
C:\Temp\RegisterWithAzure.ps1 -azureSubscriptionId $azureSubscriptionId -azureDirectoryTenantName $azureDirectoryTenantName -azureAccountId $azureAccountId
}

# Create Windows Server 2016 Images
ipmo C:\AzureStack-Tools\Connect\AzureStack.Connect.psm1
ipmo C:\AzureStack-Tools\ComputeAdmin\AzureStack.ComputeAdmin.psm1
Add-AzureRMEnvironment -Name "AzureStackAdmin" -ArmEndpoint "https://adminmanagement.local.azurestack.external" 
if ($AAD) {
$TenantID = Get-AzsDirectoryTenantId -AADTenantName  $azureDirectoryTenantName -EnvironmentName AzureStackAdmin 
set-AzureRmEnvironment -Name AzureStackAdmin -GraphAudience https://graph.windows.net/
}
else {
$TenantID = Get-AzsDirectoryTenantId -ADFS -EnvironmentName AzureStackAdmin
Set-AzureRmEnvironment AzureStackAdmin -GraphAudience https://graph.local.azurestack.external -EnableAdfsAuthentication:$true
}
Login-AzureRmAccount -EnvironmentName "AzureStackAdmin" -TenantId $TenantID -Credential $Azscredential
New-AzsServer2016VMImage -ISOPath $ISOPath -Version Both -IncludeLatestCU -Net35 $true -CreateGalleryItem $true

# Create Ubuntu 14.04.3-LTS image
invoke-webrequest https://partner-images.canonical.com/azure/azure_stack/ubuntu-14.04-LTS-microsoft_azure_stack-20170225-10.vhd.zip -OutFile "C:\Temp\Ubuntu.zip"
cd C:\Temp
expand-archive ubuntu.zip -DestinationPath . -Force
Add-AzsVMimage -publisher "Canonical" -offer "UbuntuServer" -sku "14.04.3-LTS" -version "1.0.0" -osType Linux -osDiskLocal 'C:\Temp\trusty-server-cloudimg-amd64-disk1.vhd'
del ubuntu.zip -Force
del trusty-server-cloudimg-amd64-disk1.vhd -Force

# Register resources providers
foreach($s in (Get-AzureRmSubscription)) {
        Select-AzureRmSubscription -SubscriptionId $s.SubscriptionId | Out-Null
        Write-Progress $($s.SubscriptionId + " : " + $s.SubscriptionName)
Get-AzureRmResourceProvider -ListAvailable | Register-AzureRmResourceProvider -Force
    } 

# Install MySQL Resource Provider
Login-AzureRmAccount -EnvironmentName "AzureStackAdmin" -TenantId $TenantID -Credential $Azscredential
Invoke-WebRequest https://aka.ms/azurestackmysqlrp -OutFile "c:\temp\MySql.zip"
cd C:\Temp
expand-archive c:\temp\MySql.zip -DestinationPath .\MySQL -Force
cd C:\Temp\MySQL
$vmLocalAdminPass = ConvertTo-SecureString "$rppassword" -AsPlainText -Force
$vmLocalAdminCreds = New-Object System.Management.Automation.PSCredential ("mysqlrpadmin", $vmLocalAdminPass)
$PfxPass = ConvertTo-SecureString "$rppassword" -AsPlainText -Force
.\DeployMySQLProvider.ps1 -DirectoryTenantID $TenantID -AzCredential $AzsCredential -VMLocalCredential $vmLocalAdminCreds -ResourceGroupName "MySqlRG" -VmName "MySQLRPVM" -ArmEndpoint "https://adminmanagement.local.azurestack.external" -TenantArmEndpoint "https://management.local.azurestack.external" -DefaultSSLCertificatePassword $PfxPass

# Deploy a mysql VM for hosting tenant db
New-AzureRmResourceGroup -Name MySQL-Host -Location local
New-AzureRmResourceGroupDeployment -Name MySQLHost -ResourceGroupName MySQL-Host -TemplateUri https://raw.githubusercontent.com/Azure/AzureStack-QuickStart-Templates/master/mysql-standalone-server-windows/azuredeploy.json -vmName "mySQLHost1" -adminUsername "mysqlrpadmin" -adminPassword $vmlocaladminpass -vmSize Standard_A1 -windowsOSVersion '2016-Datacenter' -mode Incremental -Verbose
# To be added / create SKU and add host server to mysql RP

# Install SQL Resource Provider
Login-AzureRmAccount -EnvironmentName "AzureStackAdmin" -TenantId $TenantID -Credential $Azscredential
cd C:\Temp
Invoke-WebRequest https://aka.ms/azurestacksqlrp -OutFile "c:\Temp\sql.zip"
expand-archive c:\temp\Sql.zip -DestinationPath .\SQL -Force
cd C:\Temp\SQL
$vmLocalAdminPass = ConvertTo-SecureString "$rppassword" -AsPlainText -Force
$vmLocalAdminCreds = New-Object System.Management.Automation.PSCredential ("sqlrpadmin", $vmLocalAdminPass)
$PfxPass = ConvertTo-SecureString "$rppassword" -AsPlainText -Force
.\DeploySQLProvider.ps1 -DirectoryTenantID $TenandID -AzCredential $AzsCredential -VMLocalCredential $vmLocalAdminCreds -ResourceGroupName "SqlRPRG" -VmName "SqlRPVM" -ArmEndpoint "https://adminmanagement.local.azurestack.external" -TenantArmEndpoint "https://management.local.azurestack.external" -DefaultSSLCertificatePassword $PfxPass

# install App Service To be added
cd C:\Temp
Invoke-WebRequest http://aka.ms/appsvconmasrc1helper -OutFile "c:\temp\appservicehelper.zip"
Expand-Archive C:\Temp\appservicehelper.zip -DestinationPath .\AppService -Force
Invoke-WebRequest http://aka.ms/appsvconmasrc1installer -OutFile "c:\temp\AppService\appservice.exe"










