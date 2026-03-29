targetScope = 'resourceGroup'

@description('Application name used for resource naming.')
param appName string
param environmentName string
param location string = resourceGroup().location
param tags object = {}
param tenantId string
param frontendClientId string
@secure()
param frontendClientSecret string
param apiClientId string
@secure()
param apiClientSecret string
param avdHostGroupId string = ''
param linuxHostGroupId string = ''
param sqlAdminLogin string = 'brokeradmin'
@secure()
param sqlAdminPassword string
@secure()
param flaskKey string
param domainName string = ''
param nfsShare string = ''
param linuxHostAdminLoginName string = 'avdadmin'
@secure()
param hostAdminPassword string
param vmHostResourceGroup string = ''
param vmSubscriptionId string = subscription().subscriptionId
param allowedClientIp string = ''
param appServicePlanSku string = 'P1v3'
param deployLinuxHosts bool = false
param deployAvdHosts bool = false
param linuxHostVmNamePrefix string = 'lnxhost'
param linuxHostVmSize string = 'Standard_D2s_v5'
param linuxHostCount int = 0
@allowed([
  'Password'
  'SSH'
])
param linuxHostAuthType string = 'Password'
param linuxHostSshPublicKey string = ''
@allowed([
  '7-LVM'
  '8-LVM'
  '9-LVM'
  '24_04-lts'
])
param linuxHostOsVersion string = '24_04-lts'
param avdHostPoolName string = ''
param avdSessionHostCount int = 0
param avdMaxSessionLimit int = 5
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
param avdVmSize string = 'Standard_D8s_v5'

var sanitizedApp = toLower(replace(appName, '-', ''))
var sanitizedEnv = toLower(replace(environmentName, '-', ''))
var sqlLocation = location == 'eastus2' ? 'eastus' : location
var suffix = toLower(uniqueString(subscription().subscriptionId, resourceGroup().id, appName, environmentName))
var sqlSuffix = toLower(uniqueString(subscription().subscriptionId, resourceGroup().id, appName, environmentName, sqlLocation))
var storageAccountName = take('${sanitizedApp}${sanitizedEnv}${suffix}', 24)
var keyVaultName = take('kv${sanitizedApp}${sanitizedEnv}${suffix}', 24)
var containerRegistryName = take('${sanitizedApp}${sanitizedEnv}${suffix}', 50)
var sqlServerName = take('sql-${sanitizedApp}-${sanitizedEnv}-${sqlSuffix}', 63)
var sqlDatabaseName = 'LinuxBroker'
var logAnalyticsName = 'log-${appName}-${environmentName}'
var applicationInsightsName = 'appi-${appName}-${environmentName}'
var appServicePlanName = 'asp-${appName}-${environmentName}'
var frontendAppName = 'fe-${appName}-${environmentName}'
var apiAppName = 'api-${appName}-${environmentName}'
var taskAppName = 'task-${appName}-${environmentName}'
var vnetName = 'vnet-${appName}-${environmentName}'
var appSubnetName = 'snet-appsvc'
var linuxSubnetName = 'snet-linux-hosts'
var avdSubnetName = 'snet-avd-hosts'
var privateEndpointSubnetName = 'snet-private-endpoints'
var effectiveVmResourceGroup = empty(vmHostResourceGroup) ? resourceGroup().name : vmHostResourceGroup
var keyVaultSecretsUserRoleDefinitionId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6')
var acrPullRoleDefinitionId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')
var databasePasswordSecretName = 'db-admin-password'
var apiSecretName = 'api-client-secret'

module networking 'modules/core/networking.bicep' = {
  name: 'networking'
  params: {
    location: location
    tags: tags
    vnetName: vnetName
    appSubnetName: appSubnetName
    linuxSubnetName: linuxSubnetName
    avdSubnetName: avdSubnetName
    privateEndpointSubnetName: privateEndpointSubnetName
  }
}

module observability 'modules/core/observability.bicep' = {
  name: 'observability'
  params: {
    location: location
    tags: tags
    logAnalyticsWorkspaceName: logAnalyticsName
    applicationInsightsName: applicationInsightsName
  }
}

module containerRegistry 'modules/core/container-registry.bicep' = {
  name: 'containerRegistry'
  params: {
    location: location
    tags: tags
    containerRegistryName: containerRegistryName
  }
}

module storageAccount 'modules/core/storage-account.bicep' = {
  name: 'storageAccount'
  params: {
    location: location
    tags: tags
    storageAccountName: storageAccountName
  }
}

module keyVault 'modules/core/key-vault.bicep' = {
  name: 'keyVault'
  params: {
    location: location
    tags: tags
    keyVaultName: keyVaultName
    sqlAdminPassword: sqlAdminPassword
    frontendClientSecret: frontendClientSecret
    apiClientSecret: apiClientSecret
    hostAdminPassword: hostAdminPassword
  }
}

module sql 'modules/core/sql-database.bicep' = {
  name: 'sql'
  params: {
    location: sqlLocation
    tags: tags
    sqlServerName: sqlServerName
    databaseName: sqlDatabaseName
    administratorLogin: sqlAdminLogin
    administratorPassword: sqlAdminPassword
    allowedClientIp: allowedClientIp
  }
}

module appServicePlan 'modules/core/app-service-plan.bicep' = {
  name: 'appServicePlan'
  params: {
    location: location
    tags: tags
    appServicePlanName: appServicePlanName
    skuName: appServicePlanSku
  }
}

resource acrResource 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = {
  name: containerRegistryName
}

resource keyVaultResource 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: keyVaultName
}

var frontendImageName = '${containerRegistry.outputs.loginServer}/frontend:latest'
var apiImageName = '${containerRegistry.outputs.loginServer}/api:latest'
var taskImageName = '${containerRegistry.outputs.loginServer}/task:latest'
var frontendApiBaseUrl = 'https://${apiAppName}.azurewebsites.net/api'
var storageConnectionString = 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.outputs.name};AccountKey=${listKeys(resourceId('Microsoft.Storage/storageAccounts', storageAccountName), '2023-05-01').keys[0].value};EndpointSuffix=${environment().suffixes.storage}'
var frontendSettings = {
  API_CLIENT_ID: apiClientId
  API_URL: frontendApiBaseUrl
  CLIENT_ID: frontendClientId
  FLASK_KEY: flaskKey
  MICROSOFT_PROVIDER_AUTHENTICATION_SECRET: '@Microsoft.KeyVault(SecretUri=${keyVault.outputs.frontendAuthKeyUri})'
  SCM_DO_BUILD_DURING_DEPLOYMENT: 'false'
  TENANT_ID: tenantId
  WEBSITE_AUTH_AAD_ALLOWED_TENANTS: tenantId
}
var apiSettings = {
  AVD_HOST_GROUP_ID: avdHostGroupId
  CLIENT_ID: apiClientId
  DB_DATABASE: sql.outputs.databaseName
  DB_PASSWORD_NAME: databasePasswordSecretName
  DB_SERVER: sql.outputs.sqlServerFullyQualifiedDomainName
  DB_USERNAME: sqlAdminLogin
  DOMAIN_NAME: domainName
  GRAPH_API_ENDPOINT: 'https://graph.microsoft.com/.default'
  KEY_NAME: apiSecretName
  LINUX_HOST_ADMIN_LOGIN_NAME: linuxHostAdminLoginName
  LINUX_HOST_GROUP_ID: linuxHostGroupId
  MICROSOFT_PROVIDER_AUTHENTICATION_SECRET: '@Microsoft.KeyVault(SecretUri=${keyVault.outputs.apiAuthKeyUri})'
  NFS_SHARE: nfsShare
  SCM_DO_BUILD_DURING_DEPLOYMENT: 'false'
  TENANT_ID: tenantId
  VAULT_URL: keyVault.outputs.vaultUri
  VM_RESOURCE_GROUP: effectiveVmResourceGroup
  VM_SUBSCRIPTION_ID: vmSubscriptionId
}
var functionSettings = {
  API_CLIENT_ID: apiClientId
  API_URL: frontendApiBaseUrl
  AzureWebJobsStorage: storageConnectionString
  FUNCTIONS_EXTENSION_VERSION: '~4'
  FUNCTIONS_WORKER_RUNTIME: 'python'
  SCM_DO_BUILD_DURING_DEPLOYMENT: 'false'
  WEBSITE_CONTENTAZUREFILECONNECTIONSTRING: storageConnectionString
  WEBSITE_CONTENTSHARE: toLower(take('${taskAppName}content', 63))
}

module frontendApp 'modules/apps/container-web-app.bicep' = {
  name: 'frontendApp'
  params: {
    location: location
    tags: union(tags, {
      'azd-service-name': 'frontend'
    })
    appName: frontendAppName
    serverFarmId: appServicePlan.outputs.id
    containerImageName: frontendImageName
    containerRegistryLoginServer: containerRegistry.outputs.loginServer
    applicationInsightsConnectionString: observability.outputs.applicationInsightsConnectionString
    appSettings: frontendSettings
    alwaysOn: true
    useManagedIdentityForRegistry: true
  }
}

module apiApp 'modules/apps/container-web-app.bicep' = {
  name: 'apiApp'
  params: {
    location: location
    tags: union(tags, {
      'azd-service-name': 'api'
    })
    appName: apiAppName
    serverFarmId: appServicePlan.outputs.id
    containerImageName: apiImageName
    containerRegistryLoginServer: containerRegistry.outputs.loginServer
    applicationInsightsConnectionString: observability.outputs.applicationInsightsConnectionString
    appSettings: apiSettings
    alwaysOn: true
    useManagedIdentityForRegistry: true
  }
}

module taskApp 'modules/apps/container-function-app.bicep' = {
  name: 'taskApp'
  params: {
    location: location
    tags: union(tags, {
      'azd-service-name': 'task'
    })
    appName: taskAppName
    serverFarmId: appServicePlan.outputs.id
    containerImageName: taskImageName
    containerRegistryLoginServer: containerRegistry.outputs.loginServer
    applicationInsightsConnectionString: observability.outputs.applicationInsightsConnectionString
    storageConnectionString: functionSettings.AzureWebJobsStorage
    appSettings: functionSettings
    useManagedIdentityForRegistry: true
  }
}

resource frontendAcrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acrResource.id, frontendAppName, 'frontend-acr-pull')
  scope: acrResource
  properties: {
    principalId: frontendApp.outputs.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: acrPullRoleDefinitionId
  }
}

resource apiAcrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acrResource.id, apiAppName, 'api-acr-pull')
  scope: acrResource
  properties: {
    principalId: apiApp.outputs.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: acrPullRoleDefinitionId
  }
}

resource taskAcrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acrResource.id, taskAppName, 'task-acr-pull')
  scope: acrResource
  properties: {
    principalId: taskApp.outputs.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: acrPullRoleDefinitionId
  }
}

resource apiKeyVaultSecretsUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVaultResource.id, apiAppName, 'api-keyvault-secrets-user')
  scope: keyVaultResource
  properties: {
    principalId: apiApp.outputs.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: keyVaultSecretsUserRoleDefinitionId
  }
}

module linuxHosts 'modules/Linux/main.bicep' = if (deployLinuxHosts && linuxHostCount > 0) {
  name: 'linuxHosts'
  params: {
    location: location
    tags: union(tags, {
      'broker-role': 'linux-host'
    })
    vnetName: networking.outputs.vnetName
    subnetName: networking.outputs.linuxSubnetName
    vnetResourceGroup: resourceGroup().name
    vmNamePrefix: linuxHostVmNamePrefix
    vmSize: linuxHostVmSize
    numberOfVMs: linuxHostCount
    authType: linuxHostAuthType
    adminUsername: linuxHostAdminLoginName
    adminPassword: hostAdminPassword
    sshPublicKey: linuxHostSshPublicKey
    OSVersion: linuxHostOsVersion
  }
}

module avdHosts 'modules/AVD/main.bicep' = if (deployAvdHosts && avdSessionHostCount > 0 && !empty(avdHostPoolName)) {
  name: 'avdHosts'
  params: {
    location: location
    tags: union(tags, {
      'broker-role': 'avd-host'
    })
    vnetName: networking.outputs.vnetName
    subnetName: networking.outputs.avdSubnetName
    vnetResourceGroup: resourceGroup().name
    hostPoolName: avdHostPoolName
    sessionHostCount: avdSessionHostCount
    maxSessionLimit: avdMaxSessionLimit
    vmNamePrefix: avdVmNamePrefix
    vmSize: avdVmSize
    adminUsername: linuxHostAdminLoginName
    adminPassword: hostAdminPassword
    linuxBrokerApiBaseUrl: frontendApiBaseUrl
  }
}

output frontendAppName string = frontendAppName
output frontendUrl string = 'https://${frontendAppName}.azurewebsites.net'
output apiAppName string = apiAppName
output apiUrl string = 'https://${apiAppName}.azurewebsites.net/api'
output taskAppName string = taskAppName
output keyVaultName string = keyVaultName
output containerRegistryName string = containerRegistryName
output sqlServerName string = sql.outputs.sqlServerName
output sqlDatabaseName string = sql.outputs.databaseName
output virtualNetworkName string = networking.outputs.vnetName
