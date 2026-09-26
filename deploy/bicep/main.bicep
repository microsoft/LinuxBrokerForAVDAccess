targetScope = 'subscription'

@description('Application name used for resource naming.')
param appName string

@description('Deployment environment name.')
param environmentName string

@description('Azure region for all resources.')
param location string

@description('Tags applied to provisioned resources.')
param tags object = {}

@description('Optional explicit resource group name. When empty, a name is generated.')
param resourceGroupName string = ''

@description('Tenant ID used by the frontend and API applications.')
param tenantId string = ''

@description('Frontend Entra app client ID.')
param frontendClientId string = ''

@secure()
@description('Frontend Entra app client secret.')
param frontendClientSecret string = ''

@description('API Entra app client ID.')
param apiClientId string = ''

@secure()
@description('API Entra app client secret.')
param apiClientSecret string = ''

@secure()
@description('Linux host SSH private key stored in Key Vault for broker-managed SSH access.')
param linuxHostSshPrivateKey string = ''

@description('Azure AD group ID used for AVD host access.')
param avdHostGroupId string = ''

@description('Azure AD group ID used for Linux host access.')
param linuxHostGroupId string = ''

@description('SQL administrator login.')
param sqlAdminLogin string = 'brokeradmin'

@secure()
@description('SQL administrator password.')
param sqlAdminPassword string = ''

@description('Azure SQL Database SKU name, for example Basic, S0, S1 or GP_S_Gen5_1. Basic suits small pools; use S1 or higher when many hosts and portal users call the broker at once.')
param sqlDatabaseSkuName string = 'Basic'

@description('Temporarily let any portal user with the access_as_user scope act as FullAccess, as releases before role enforcement did. Use only while you assign the Reader, Operator and FullAccess app roles during an upgrade, then turn it off.')
param allowLegacyScopeAccess bool = false

@secure()
@description('Flask session key for the frontend app.')
param flaskKey string = ''

@description('Optional custom domain used by Linux hosts. When empty, hosts register into the private DNS zone linuxbroker.internal and the broker uses that zone.')
param domainName string = ''

@description('Optional NFS share used by Linux hosts. When empty and deployNfsShare is true, a Premium Azure Files NFS share is provisioned.')
param nfsShare string = ''

@description('Provision a Premium Azure Files NFS share for Linux home directories when nfsShare is empty and Linux hosts are deployed.')
param deployNfsShare bool = true

@description('Provisioned size of the NFS share in GiB. Premium file shares have a 100 GiB minimum.')
@minValue(100)
param nfsShareQuotaGiB int = 100

@description('Object ID of the Entra group whose members can launch the Linux Desktop RemoteApp. Leave empty to assign access manually.')
param avdUsersGroupId string = ''

@description('Admin login name used for Linux host provisioning.')
param linuxHostAdminLoginName string = 'avdadmin'

@secure()
@description('Admin password used for Linux and AVD host provisioning.')
param hostAdminPassword string = ''

@description('Optional resource group that contains managed VMs. Defaults to the deployment resource group.')
param vmHostResourceGroup string = ''

@description('Subscription ID that contains managed VMs. Defaults to the current subscription.')
param vmSubscriptionId string = subscription().subscriptionId

@description('Azure cloud the deployment targets. AzureCustom requires every custom endpoint parameter to be supplied.')
@allowed([
  'AzurePublic'
  'AzureUSGovernment'
  'AzureCustom'
])
param azureCloudName string = 'AzurePublic'

@description('Entra authority host. Leave empty to use the built-in value for the selected cloud.')
param azureAuthorityHost string = ''

@description('Microsoft Graph endpoint. Leave empty to use the built-in value for the selected cloud.')
param graphEndpoint string = ''

@description('Legacy STS issuer host used to validate v1 tokens. Leave empty to use the built-in value for the selected cloud.')
param stsIssuerHost string = ''

@description('App Service public hostname suffix. Leave empty to use the built-in value for the selected cloud.')
param appServiceDomain string = ''

@description('Root URL the Linux host bootstrap scripts are downloaded from. Point this at a reachable mirror for sovereign or air-gapped clouds.')
param scriptSourceRoot string = 'https://raw.githubusercontent.com/microsoft/LinuxBrokerForAVDAccess/refs/heads/main'

@description('Optional IPv4 address allowed through the SQL firewall.')
param allowedClientIp string = ''

@description('App Service plan SKU name.')
param appServicePlanSku string = 'P2mv3'

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
param linuxHostAuthType string = 'SSH'

@description('SSH public key used when Linux host auth type is SSH.')
param linuxHostSshPublicKey string = ''

@allowed([
  '8-LVM'
  '9-LVM'
  'rocky-9'
  'alma-9'
  '24_04-lts'
])
@description('Linux host image: 8-LVM (RHEL 8), 9-LVM (RHEL 9), rocky-9 (Rocky Linux 9), alma-9 (AlmaLinux 9) or 24_04-lts (Ubuntu 24.04). Rocky Linux 9 is a Marketplace image: the subscription must accept its terms once and be allowed to buy Marketplace images, even though it costs nothing.')
param linuxHostOsVersion string = '9-LVM'

@description('Disable the screen saver and screen lock on the Linux hosts, whichever desktop they run. Enabled by default because a locked GNOME greeter inside an xrdp session often cannot be unlocked after a reconnect, which strands the host lease. Set to false to keep the lock screen, for example to satisfy a STIG or CIS idle-lock control.')
param linuxHostDisableScreenLock bool = true

@allowed([
  'gnome'
  'xfce'
  'mate'
])
@description('Desktop the Linux hosts run in xrdp sessions: gnome (the RHEL Server with GUI group, or the Ubuntu desktop), xfce or mate. Changing it on existing hosts runs their bootstrap again at the next provision, so drain them first.')
param linuxHostDesktop string = 'gnome'

@description('AVD host pool name.')
param avdHostPoolName string = ''

@description('Number of AVD session hosts to deploy.')
param avdSessionHostCount int = 0

@description('Maximum number of sessions per AVD session host.')
param avdMaxSessionLimit int = 5

@description('Opens the Linux desktop full screen. False opens it in a window on one monitor. Turn it off only once every AVD session host runs Connect-LinuxBroker.ps1 2.0.0 or later (deploy/Update-AvdHostBrokerScript.ps1): older scripts refuse the argument and the Linux Desktop app fails to open.')
param avdLinuxDesktopFullScreen bool = true

@description('Spreads a full-screen Linux desktop across every monitor. False keeps it on one monitor. Turn it off only once every AVD session host runs Connect-LinuxBroker.ps1 2.0.0 or later.')
param avdLinuxDesktopMultiMonitor bool = true

@description('Starts and stops the AVD session hosts on a schedule through an Azure Virtual Desktop scaling plan. The plan is always deployed with the session hosts; false leaves it assigned to no host pool, so the hosts stay as they are and you can assign a plan of your own instead. Azure refuses to assign the plan unless the Azure Virtual Desktop service principal holds Desktop Virtualization Power On Off Contributor on the subscription.')
param avdScalingPlanEnabled bool = true

@description('Starts a deallocated AVD session host when a user opens the Linux Desktop app and no running session host can take the session. Needs the same role as the scaling plan.')
param avdStartVmOnConnect bool = true

@description('Windows time zone ID the scaling plan\'s times are in, such as UTC or Eastern Standard Time. It is separate from the broker\'s own scaling time zone, which the portal sets.')
param avdScalingPlanTimeZone string = 'UTC'

@description('Start of ramp-up, as HH:mm in avdScalingPlanTimeZone. The weekday and weekend schedules use the same times.')
param avdScalingPlanRampUpStart string = '07:00'

@description('Start of peak hours, as HH:mm. Must come after ramp-up.')
param avdScalingPlanPeakStart string = '09:00'

@description('Start of ramp-down, as HH:mm. Must come after peak.')
param avdScalingPlanRampDownStart string = '18:00'

@description('Start of off-peak hours, as HH:mm. Must come after ramp-down.')
param avdScalingPlanOffPeakStart string = '20:00'

@description('Share of the AVD session hosts kept running from ramp-up until ramp-down on weekdays, rounded up to whole hosts.')
@minValue(0)
@maxValue(100)
param avdScalingPlanRampUpMinimumHostsPct int = 20

@description('Share of the running session hosts\' capacity in use that makes autoscale start another one during ramp-up and peak hours.')
@minValue(1)
@maxValue(100)
param avdScalingPlanRampUpCapacityThresholdPct int = 60

@description('Share of the AVD session hosts kept running from ramp-down until the next ramp-up on weekdays, rounded up to whole hosts.')
@minValue(0)
@maxValue(100)
param avdScalingPlanRampDownMinimumHostsPct int = 10

@description('Share of the running session hosts\' capacity in use that makes autoscale start another one during ramp-down and off-peak hours.')
@minValue(1)
@maxValue(100)
param avdScalingPlanRampDownCapacityThresholdPct int = 90

@description('Share of the AVD session hosts kept running on Saturday and Sunday. 0 lets them all stop, and Start VM on Connect starts one for the first user.')
@minValue(0)
@maxValue(100)
param avdScalingPlanWeekendMinimumHostsPct int = 0

@description('Generated by the preprovision hook: lowercase AVD session host names mapped to the value of the excludeFromScaling tag each carries, so the deployment writes the tag back.')
param avdScalingExclusions object = {}

@description('Generated by the preprovision hook: the Linux hosts and AVD session hosts that are not running, whose VM extensions this deployment leaves out because Azure refuses to change an extension on a VM that is not running.')
param hostNamesNotRunning array = []

@description('Object ID of the Azure Virtual Desktop service principal (app ID 9cdead84-a844-4324-93f2-b2e6bb768d07) in this tenant. The preprovision hook finds it. Without it, the role below is not assigned.')
param avdServicePrincipalObjectId string = ''

@description('Assigns Desktop Virtualization Power On Off Contributor on the subscription to the Azure Virtual Desktop service principal, for the scaling plan and Start VM on Connect. The preprovision hook passes false when the role is already assigned, or when the signed-in account cannot assign roles on the subscription.')
param assignAvdAutoscaleRole bool = true

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
var deployAvdSessionHosts = deployAvdHosts && avdSessionHostCount > 0 && !empty(avdHostPoolName)
// Desktop Virtualization Power On Off Contributor.
var avdPowerOnOffContributorRoleGuid = '40c5ff49-9181-41f8-ae61-143b0e78555e'

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
    linuxHostSshPrivateKey: linuxHostSshPrivateKey
    avdHostGroupId: avdHostGroupId
    linuxHostGroupId: linuxHostGroupId
    sqlAdminLogin: sqlAdminLogin
    sqlAdminPassword: sqlAdminPassword
    sqlDatabaseSkuName: sqlDatabaseSkuName
    allowLegacyScopeAccess: allowLegacyScopeAccess
    flaskKey: flaskKey
    domainName: domainName
    nfsShare: nfsShare
    deployNfsShare: deployNfsShare
    nfsShareQuotaGiB: nfsShareQuotaGiB
    avdUsersGroupId: avdUsersGroupId
    linuxHostAdminLoginName: linuxHostAdminLoginName
    hostAdminPassword: hostAdminPassword
    vmHostResourceGroup: vmHostResourceGroup
    vmSubscriptionId: vmSubscriptionId
    azureCloudName: azureCloudName
    azureAuthorityHost: azureAuthorityHost
    graphEndpoint: graphEndpoint
    stsIssuerHost: stsIssuerHost
    appServiceDomain: appServiceDomain
    scriptSourceRoot: scriptSourceRoot
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
    linuxHostDisableScreenLock: linuxHostDisableScreenLock
    linuxHostDesktop: linuxHostDesktop
    avdHostPoolName: avdHostPoolName
    avdSessionHostCount: avdSessionHostCount
    avdMaxSessionLimit: avdMaxSessionLimit
    avdLinuxDesktopFullScreen: avdLinuxDesktopFullScreen
    avdLinuxDesktopMultiMonitor: avdLinuxDesktopMultiMonitor
    avdStartVmOnConnect: avdStartVmOnConnect
    avdScalingExclusions: avdScalingExclusions
    hostNamesNotRunning: hostNamesNotRunning
    avdVmNamePrefix: avdVmNamePrefix
    avdVmSize: avdVmSize
  }
}

// Autoscale only works with the role on the whole subscription, and Start VM on Connect is
// covered by it too.
resource avdAutoscaleRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployAvdSessionHosts && (avdScalingPlanEnabled || avdStartVmOnConnect) && assignAvdAutoscaleRole && !empty(avdServicePrincipalObjectId)) {
  name: guid(subscription().id, avdServicePrincipalObjectId, avdPowerOnOffContributorRoleGuid)
  properties: {
    principalId: avdServicePrincipalObjectId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', avdPowerOnOffContributorRoleGuid)
    description: 'Lets Azure Virtual Desktop start and stop the Linux Broker AVD session hosts, for the scaling plan and Start VM on Connect.'
  }
}

// Deployed last, so that a role assigned above has had the rest of the deployment to take effect
// before Azure checks it while assigning the plan to the host pool.
module avdScalingPlan 'modules/AVD/scaling-plan.bicep' = if (deployAvdSessionHosts) {
  name: 'avdScalingPlan'
  scope: rg
  params: {
    location: location
    tags: union(tags, {
      'broker-role': 'avd-host'
    })
    name: take('${avdHostPoolName}-scaling-plan', 64)
    hostPoolName: avdHostPoolName
    enabled: avdScalingPlanEnabled
    timeZone: avdScalingPlanTimeZone
    rampUpStartTime: avdScalingPlanRampUpStart
    peakStartTime: avdScalingPlanPeakStart
    rampDownStartTime: avdScalingPlanRampDownStart
    offPeakStartTime: avdScalingPlanOffPeakStart
    rampUpMinimumHostsPct: avdScalingPlanRampUpMinimumHostsPct
    rampUpCapacityThresholdPct: avdScalingPlanRampUpCapacityThresholdPct
    rampDownMinimumHostsPct: avdScalingPlanRampDownMinimumHostsPct
    rampDownCapacityThresholdPct: avdScalingPlanRampDownCapacityThresholdPct
    weekendMinimumHostsPct: avdScalingPlanWeekendMinimumHostsPct
  }
  dependsOn: [
    resources
    avdAutoscaleRole
  ]
}

output resourceGroupName string = rg.name
output frontendAppName string = resources.outputs.frontendAppName
output frontendUrl string = resources.outputs.frontendUrl
output apiAppName string = resources.outputs.apiAppName
output apiUrl string = resources.outputs.apiUrl
output taskAppName string = resources.outputs.taskAppName
output keyVaultName string = resources.outputs.keyVaultName
output keyringVaultName string = resources.outputs.keyringVaultName
output containerRegistryName string = resources.outputs.containerRegistryName
output sqlServerName string = resources.outputs.sqlServerName
output sqlDatabaseName string = resources.outputs.sqlDatabaseName
output virtualNetworkName string = resources.outputs.virtualNetworkName
output linuxHostDomainName string = resources.outputs.linuxHostDomainName
output nfsSharePath string = resources.outputs.nfsSharePath
