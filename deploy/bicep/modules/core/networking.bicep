param location string = resourceGroup().location
param tags object = {}
param vnetName string
param appSubnetName string = 'snet-appsvc'
param linuxSubnetName string = 'snet-linux-hosts'
param avdSubnetName string = 'snet-avd-hosts'
param privateEndpointSubnetName string = 'snet-private-endpoints'

resource virtualNetwork 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.40.0.0/16'
      ]
    }
  }
}

resource appSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' = {
  parent: virtualNetwork
  name: appSubnetName
  properties: {
    addressPrefix: '10.40.1.0/24'
    delegations: [
      {
        name: 'appservice'
        properties: {
          serviceName: 'Microsoft.Web/serverFarms'
        }
      }
    ]
  }
}

resource linuxSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' = {
  parent: virtualNetwork
  name: linuxSubnetName
  dependsOn: [
    appSubnet
  ]
  properties: {
    addressPrefix: '10.40.2.0/24'
  }
}

resource avdSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' = {
  parent: virtualNetwork
  name: avdSubnetName
  dependsOn: [
    linuxSubnet
  ]
  properties: {
    addressPrefix: '10.40.3.0/24'
  }
}

resource privateEndpointSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' = {
  parent: virtualNetwork
  name: privateEndpointSubnetName
  dependsOn: [
    avdSubnet
  ]
  properties: {
    addressPrefix: '10.40.4.0/24'
    privateEndpointNetworkPolicies: 'Disabled'
  }
}

output vnetName string = virtualNetwork.name
output vnetId string = virtualNetwork.id
output appSubnetName string = appSubnet.name
output appSubnetId string = appSubnet.id
output linuxSubnetName string = linuxSubnet.name
output linuxSubnetId string = linuxSubnet.id
output avdSubnetName string = avdSubnet.name
output avdSubnetId string = avdSubnet.id
output privateEndpointSubnetName string = privateEndpointSubnet.name
output privateEndpointSubnetId string = privateEndpointSubnet.id
