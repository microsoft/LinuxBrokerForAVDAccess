param location string = resourceGroup().location
param tags object = {}
param keyVaultName string
@secure()
param sqlAdminPassword string
@secure()
param linuxHostSshPrivateKey string

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
  name: 'db-password'
  properties: {
    value: sqlAdminPassword
  }
}

resource linuxHostPrivateKeySecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'linux-host'
  properties: {
    value: linuxHostSshPrivateKey
  }
}

output name string = keyVault.name
output id string = keyVault.id
output vaultUri string = keyVault.properties.vaultUri
