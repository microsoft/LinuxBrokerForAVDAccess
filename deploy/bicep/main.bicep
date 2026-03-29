targetScope = 'subscription'

@description('Application name used for resource naming.')
param appName string

@description('Deployment environment name.')
param environmentName string

@description('Azure region for all resources.')
param location string = deployment().location

@description('Tags applied to provisioned resources.')
param tags object = {}

@description('Optional explicit resource group name. When empty, a name is generated.')
param resourceGroupName string = ''

@description('Tenant ID used by the frontend and API applications.')
param tenantId string

@description('Frontend Entra app client ID.')
param frontendClientId string

@secure()
@description('Frontend Entra app client secret.')
param frontendClientSecret string

@description('API Entra app client ID.')
param apiClientId string

@secure()
@description('API Entra app client secret.')
param apiClientSecret string

@description('Azure AD group ID used for AVD host access.')
param avdHostGroupId string = ''

@description('Azure AD group ID used for Linux host access.')
param linuxHostGroupId string = ''

@description('SQL administrator login.')
param sqlAdminLogin string = 'brokeradmin'

@secure()
@description('SQL administrator password.')
param sqlAdminPassword string

@secure()
@description('Flask session key for the frontend app.')
param flaskKey string

@description('Optional custom domain used by Linux hosts.')
param domainName string = ''

@description('Optional NFS share used by Linux hosts.')
param nfsShare string = ''

@description('Admin login name used for Linux host provisioning.')
param linuxHostAdminLoginName string = 'avdadmin'

@secure()
@description('Admin password used for Linux and AVD host provisioning.')
param hostAdminPassword string

@description('Optional resource group that contains managed VMs. Defaults to the deployment resource group.')
param vmHostResourceGroup string = ''

@description('Subscription ID that contains managed VMs. Defaults to the current subscription.')
param vmSubscriptionId string = subscription().subscriptionId

@description('Optional IPv4 address allowed through the SQL firewall.')
param allowedClientIp string = ''

@description('App Service plan SKU name.')
param appServicePlanSku string = 'P1v3'

@description('Deploy Linux broker host VMs.')
param deployLinuxHosts bool = false

@description('Deploy Azure Virtual Desktop session hosts.')
param deployAvdHosts bool = false

@description('Linux host VM name prefix.')
param linuxHostVmNamePrefix string = 'lnxhost'

@description('Linux host VM size.')
param linuxHostVmSize string = 'Standard_D2s_v5'

@description('Number of Linux host VMs to deploy.')
param linuxHostCount int = 0

@allowed([
  'Password'
  'SSH'
])
@description('Authentication mode for Linux host VMs.')
param linuxHostAuthType string = 'Password'

@description('SSH public key used when Linux host auth type is SSH.')
param linuxHostSshPublicKey string = ''

@allowed([
  '7-LVM'
  '8-LVM'
  '9-LVM'
  '24_04-lts'
])
@description('Linux host OS image SKU.')
param linuxHostOsVersion string = '24_04-lts'

@description('AVD host pool name.')
param avdHostPoolName string = ''

@description('Number of AVD session hosts to deploy.')
param avdSessionHostCount int = 0

@description('Maximum number of sessions per AVD session host.')
param avdMaxSessionLimit int = 5

@description('AVD session host VM name prefix.')
param avdVmNamePrefix string = 'avdhost'

@allowed([
  'Standard_DS2_v2'
  'Standard_D8s_v5'
  'Standard_D8s_v4'
  'Standard_F8s_v2'
  'Standard_D8as_v4'
  'Standard_D16s_v5'
  'Standard_D16s_v4'
  'Standard_F16s_v2'
  'Standard_D16as_v4'
])
@description('AVD session host VM size.')
param avdVmSize string = 'Standard_D8s_v5'

@description('Resource group used for deployment.')
var effectiveResourceGroupName = empty(resourceGroupName) ? 'rg-${appName}-${environmentName}' : resourceGroupName

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: effectiveResourceGroupName
  location: location
  tags: tags
}

module resources 'main.resources.bicep' = {
  name: 'resources'
  scope: rg
  params: {
    appName: appName
    environmentName: environmentName
    location: location
    tags: tags
    tenantId: tenantId
    frontendClientId: frontendClientId
    frontendClientSecret: frontendClientSecret
    apiClientId: apiClientId
    apiClientSecret: apiClientSecret
    avdHostGroupId: avdHostGroupId
    linuxHostGroupId: linuxHostGroupId
    sqlAdminLogin: sqlAdminLogin
    sqlAdminPassword: sqlAdminPassword
    flaskKey: flaskKey
    domainName: domainName
    nfsShare: nfsShare
    linuxHostAdminLoginName: linuxHostAdminLoginName
    hostAdminPassword: hostAdminPassword
    vmHostResourceGroup: vmHostResourceGroup
    vmSubscriptionId: vmSubscriptionId
    allowedClientIp: allowedClientIp
    appServicePlanSku: appServicePlanSku
    deployLinuxHosts: deployLinuxHosts
    deployAvdHosts: deployAvdHosts
    linuxHostVmNamePrefix: linuxHostVmNamePrefix
    linuxHostVmSize: linuxHostVmSize
    linuxHostCount: linuxHostCount
    linuxHostAuthType: linuxHostAuthType
    linuxHostSshPublicKey: linuxHostSshPublicKey
    linuxHostOsVersion: linuxHostOsVersion
    avdHostPoolName: avdHostPoolName
    avdSessionHostCount: avdSessionHostCount
    avdMaxSessionLimit: avdMaxSessionLimit
    avdVmNamePrefix: avdVmNamePrefix
    avdVmSize: avdVmSize
  }
}

output resourceGroupName string = rg.name
output frontendAppName string = resources.outputs.frontendAppName
output frontendUrl string = resources.outputs.frontendUrl
output apiAppName string = resources.outputs.apiAppName
output apiUrl string = resources.outputs.apiUrl
output taskAppName string = resources.outputs.taskAppName
output keyVaultName string = resources.outputs.keyVaultName
output containerRegistryName string = resources.outputs.containerRegistryName
output sqlServerName string = resources.outputs.sqlServerName
output sqlDatabaseName string = resources.outputs.sqlDatabaseName
output virtualNetworkName string = resources.outputs.virtualNetworkName
