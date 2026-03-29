param location string = resourceGroup().location
param tags object = {}
param appServicePlanName string
param skuName string = 'P1v3'

resource appServicePlan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: appServicePlanName
  location: location
  tags: tags
  sku: {
    name: skuName
    tier: 'PremiumV3'
    size: skuName
    capacity: 1
  }
  kind: 'linux'
  properties: {
    reserved: true
  }
}

output id string = appServicePlan.id
output name string = appServicePlan.name
