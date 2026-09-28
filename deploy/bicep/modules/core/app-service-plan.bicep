param location string = resourceGroup().location
param tags object = {}
param appServicePlanName string
param skuName string = 'P2mv3'

@description('Instances the plan runs. The portal, the API and the task function all run on every instance.')
@minValue(1)
@maxValue(30)
param capacity int = 1

resource appServicePlan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: appServicePlanName
  location: location
  tags: tags
  sku: {
    name: skuName
    tier: 'PremiumV3'
    size: skuName
    capacity: capacity
  }
  kind: 'linux'
  properties: {
    reserved: true
  }
}

output id string = appServicePlan.id
output name string = appServicePlan.name
