#client and server name
$client = Read-Host -Prompt 'Enter client name'
$role = Read-Host -Prompt 'Enter server role'

# Variables 
$resourceGroupserv = ('GRSRV'+$client.ToUpper()+$role.ToUpper())
$resourceGroupnetwork = "GRNetwork"
$resourceGroupbackup = "GRBackup"
$location = "francecentral"
$vmName = ('SRV'+$client.ToUpper()+$role.ToUpper())

# create admin account
$cred = Get-Credential -Message "Enter a username and password for the virtual machine."

# create resource group
New-AzureRMResourceGroup -Name $resourceGroupserv -Location $location
New-AzureRMResourceGroup -Name $resourceGroupnetwork -Location $location
New-AzureRMResourceGroup -Name $resourceGroupbackup -Location $location

# create storage account for bootdiag
$StorageAccountName = (''+$resourceGroupserv.ToLower()+'diag')
$SkuName = "Standard_LRS"
$StorageAccount = New-AzureRMStorageAccount -Location $location -ResourceGroupName $ResourceGroupserv `
-Type $SkuName -Name $StorageAccountName
Set-AzureRmCurrentStorageAccount -StorageAccountName $storageAccountName -ResourceGroupName $resourceGroupserv

#create save vault
$vaultname = ('Vault'+$client.ToUpper())

New-AzRecoveryServicesVault -ResourceGroupName $resourceGroupbackup -Name $vaultname -location $location

$Vault = Get-AzRecoveryServicesVault -Name $vaultname
Set-AzRecoveryServicesBackupProperty -Vault $Vault -BackupStorageRedundancy LocallyRedundant
Set-AzRecoveryServicesVaultProperty -VaultId $Vault.ID -SoftDeleteFeatureState Disable

# create subnet
$subnetConfig = New-AzureRMVirtualNetworkSubnetConfig -Name "Serveurs" -AddressPrefix 10.0.100.0/25

# create network
$vnetname = ('VNet'+$client.ToUpper())
$vnet = New-AzureRMVirtualNetwork -ResourceGroupName $resourceGroupnetwork -Location $location `
  -Name $vnetname -AddressPrefix 10.0.100.0/24 -Subnet $subnetConfig

# create public IP and dns record
$pip = New-AzureRMPublicIpAddress -ResourceGroupName $resourceGroupserv -Location $location `
  -Name "$vmName-ip" -AllocationMethod Dynamic -IdleTimeoutInMinutes 4 -DomainNameLabel $vmName.ToLower()

# Create nsg rule to allow rdp
$nsgRuleRDP = New-AzureRMNetworkSecurityRuleConfig -Name RDP  -Protocol Tcp `
  -Direction Inbound -Priority 300 -SourceAddressPrefix * -SourcePortRange * -DestinationAddressPrefix * `
  -DestinationPortRange 3389 -Access Allow
  
# create nsg 
$nsg = New-AzureRMNetworkSecurityGroup -ResourceGroupName $resourceGroupserv -Location $location `
  -Name "$vmName-nsg" -SecurityRules $nsgRuleRDP

# create network adapter
$Subnet = Get-AzVirtualNetwork -Name "VnetVPN" -ResourceGroupName $resourceGroupnetwork 
$IPconfig = New-AzNetworkInterfaceIpConfig -Name "IPConfig1" -PrivateIpAddressVersion IPv4 `
-PrivateIpAddress "10.0.100.10" -PublicIpAddressId $pip.Id -SubnetId $Subnet.Subnets[0].Id
$nic = New-AzNetworkInterface -Name "$vmName-nic" -ResourceGroupName  $resourceGroupserv -Location $location `
-IpConfiguration $IPconfig -NetworkSecurityGroupId $nsg.Id

# VM config, if SSD put set-azurermvmosdisk in commentary
$vmDiskName = (''+$vmName+'_OsDisk')
$vmDiskSize = '128'
$vmDiskaccountType = 'Standard_LRS'

$vmConfig = New-AzureRmVMConfig -VMName $vmName -VMSize "Standard_B2ms" |`
Set-AzureRmVMBootDiagnostics -ResourceGroupName $resourceGroupserv -StorageAccountName $StorageAccountName -Enable |`
Set-AzureRmVMOperatingSystem -Windows -ComputerName $vmName -Credential $cred |`
Set-AzureRmVMSourceImage -PublisherName MicrosoftWindowsServer -Offer WindowsServer -Skus 2019-Datacenter -Version latest |`
Add-AzureRmVMNetworkInterface -Id $nic.Id

Set-AzureRmVMOSDisk -CreateOption fromImage -VM $vmConfig -Name $vmDiskName -DiskSizeInGB $vmDiskSize -Caching ReadWrite -StorageAccountType $vmDiskaccountType -Windows

# Create VM
New-AzureRMVM -ResourceGroupName $resourceGroupserv -Location $location -VM $vmConfig

#antimalware extension deployment
#variables
$PublisherName = "Microsoft.Azure.Security"
$Type = "IaaSAntimalware"
$amversion = ((Get-AzVMExtensionImage -Location $location -PublisherName $PublisherName -Type $Type).Version[-1][0..2] -join '')
#COnfiguration antimalware
$amsettings = @'
{
    "AntimalwareEnabled": true,
    "RealtimeProtectionEnabled": true,
    "ScheduledScanSettings": {
        "isEnabled": false,
        "day": 7,
        "time": 120,
        "scanType": "Quick"
    },
}
'@
#Extension activation
Set-AzVMExtension -ResourceGroupName $resourceGroupserv -VMName $vmName -Name $Type -Publisher $PublisherName `
-ExtensionType $Type -SettingString $amsettings -Location $location -TypeHandlerVersion $amversion