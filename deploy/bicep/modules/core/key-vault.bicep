param location string = resourceGroup().location
param tags object = {}
param keyVaultName string
@secure()
param sqlAdminPassword string
@secure()
param frontendClientSecret string
@secure()
param apiClientSecret string
@secure()
param hostAdminPassword string

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: keyVaultName
  location: location
  tags: tags
  properties: {
    tenantId: subscription().tenantId
    enableRbacAuthorization: true
    enabledForDeployment: false
    enabledForDiskEncryption: false
    enabledForTemplateDeployment: false
    publicNetworkAccess: 'Enabled'
    sku: {
      family: 'A'
      name: 'standard'
    }
    softDeleteRetentionInDays: 90
  }
}

resource sqlAdminPasswordSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'db-admin-password'
  properties: {
    value: sqlAdminPassword
  }
}

resource frontendClientSecretSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'frontend-client-secret'
  properties: {
    value: frontendClientSecret
  }
}

resource apiClientSecretSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'api-client-secret'
  properties: {
    value: apiClientSecret
  }
}

resource hostAdminPasswordSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'host-admin-password'
  properties: {
    value: hostAdminPassword
  }
}

output name string = keyVault.name
output id string = keyVault.id
output vaultUri string = keyVault.properties.vaultUri
output frontendAuthKeyUri string = frontendClientSecretSecret.properties.secretUriWithVersion
output apiAuthKeyUri string = apiClientSecretSecret.properties.secretUriWithVersion
