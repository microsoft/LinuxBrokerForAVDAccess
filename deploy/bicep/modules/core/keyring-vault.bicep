param location string = resourceGroup().location
param tags object = {}
param keyVaultName string

// Holds one secret per user, keyring-<uid>, with the key that opens that user's login keyring.
// The API creates the secrets at checkout, so the template adds none.
resource keyringVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
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

output name string = keyringVault.name
output id string = keyringVault.id
output vaultUri string = keyringVault.properties.vaultUri
