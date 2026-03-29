param location string = resourceGroup().location
param tags object = {}
param appName string
param serverFarmId string
param containerImageName string
param containerRegistryLoginServer string
param applicationInsightsConnectionString string
@secure()
param storageConnectionString string
param appSettings object = {}
param useManagedIdentityForRegistry bool = true

resource functionApp 'Microsoft.Web/sites@2023-12-01' = {
  name: appName
  location: location
  tags: tags
  kind: 'functionapp,linux,container'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: serverFarmId
    httpsOnly: true
    siteConfig: {
      acrUseManagedIdentityCreds: useManagedIdentityForRegistry
      alwaysOn: true
      appCommandLine: ''
      ftpsState: 'FtpsOnly'
      linuxFxVersion: 'DOCKER|${containerImageName}'
      minTlsVersion: '1.2'
    }
  }
}

resource functionAppSettings 'Microsoft.Web/sites/config@2023-12-01' = {
  parent: functionApp
  name: 'appsettings'
  properties: union({
    APPLICATIONINSIGHTS_CONNECTION_STRING: applicationInsightsConnectionString
    AzureWebJobsStorage: storageConnectionString
    DOCKER_REGISTRY_SERVER_URL: 'https://${containerRegistryLoginServer}'
    WEBSITE_CONTENTAZUREFILECONNECTIONSTRING: storageConnectionString
    WEBSITE_CONTENTSHARE: toLower(take('${appName}content', 63))
    WEBSITES_ENABLE_APP_SERVICE_STORAGE: 'false'
  }, appSettings)
}

output id string = functionApp.id
output name string = functionApp.name
output principalId string = functionApp.identity.principalId
output defaultHostName string = functionApp.properties.defaultHostName
