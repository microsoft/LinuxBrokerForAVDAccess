param location string = resourceGroup().location
param tags object = {}
param appName string
param serverFarmId string
param containerImageName string
param containerRegistryLoginServer string
param applicationInsightsConnectionString string
param appSettings object = {}
param authSettings object = {}
param healthCheckPath string = ''
param alwaysOn bool = true
param useManagedIdentityForRegistry bool = true
@description('Delegated subnet for regional VNet integration. Leave empty to keep the app off the virtual network.')
param virtualNetworkSubnetId string = ''

var webSiteConfig = union({
  alwaysOn: alwaysOn
  acrUseManagedIdentityCreds: useManagedIdentityForRegistry
  linuxFxVersion: 'DOCKER|${containerImageName}'
  minTlsVersion: '1.2'
}, empty(healthCheckPath) ? {} : {
  healthCheckPath: healthCheckPath
})

resource webApp 'Microsoft.Web/sites@2023-12-01' = {
  name: appName
  location: location
  tags: tags
  kind: 'app,linux,container'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: serverFarmId
    httpsOnly: true
    // Only private (RFC 1918) traffic is routed into the VNet; SQL, Key Vault, Graph and ACR stay on the public path.
    virtualNetworkSubnetId: empty(virtualNetworkSubnetId) ? null : virtualNetworkSubnetId
    siteConfig: webSiteConfig
  }
}

resource webAppSettings 'Microsoft.Web/sites/config@2023-12-01' = {
  parent: webApp
  name: 'appsettings'
  properties: union({
    APPLICATIONINSIGHTS_CONNECTION_STRING: applicationInsightsConnectionString
    DOCKER_REGISTRY_SERVER_URL: 'https://${containerRegistryLoginServer}'
    WEBSITES_ENABLE_APP_SERVICE_STORAGE: 'false'
  }, appSettings)
}

resource webAppAuth 'Microsoft.Web/sites/config@2023-12-01' = if (!empty(authSettings)) {
  parent: webApp
  name: 'authsettingsV2'
  dependsOn: [
    webAppSettings
  ]
  properties: authSettings
}

resource webAppLogs 'Microsoft.Web/sites/config@2023-12-01' = {
  parent: webApp
  name: 'logs'
  properties: {
    applicationLogs: {
      fileSystem: {
        level: 'Information'
      }
    }
    detailedErrorMessages: {
      enabled: true
    }
    failedRequestsTracing: {
      enabled: true
    }
    httpLogs: {
      fileSystem: {
        enabled: true
        retentionInDays: 7
        retentionInMb: 35
      }
    }
  }
}

output id string = webApp.id
output name string = webApp.name
output principalId string = webApp.identity.principalId
output defaultHostName string = webApp.properties.defaultHostName
