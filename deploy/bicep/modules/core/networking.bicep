param location string = resourceGroup().location
param tags object = {}
param vnetName string
param appSubnetName string = 'snet-appsvc'
param linuxSubnetName string = 'snet-linux-hosts'
param avdSubnetName string = 'snet-avd-hosts'
param privateEndpointSubnetName string = 'snet-private-endpoints'

@description('Create a private DNS zone that every VM in the virtual network registers into automatically.')
param createHostDnsZone bool = true

@description('Name of the private DNS zone the hosts register into. The broker API connects to Linux hosts as <hostname>.<zone>.')
param hostDnsZoneName string = 'linuxbroker.internal'

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

resource hostDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = if (createHostDnsZone) {
  name: hostDnsZoneName
  location: 'global'
  tags: tags
}

resource hostDnsZoneLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = if (createHostDnsZone) {
  parent: hostDnsZone
  name: 'link-${vnetName}'
  location: 'global'
  tags: tags
  properties: {
    registrationEnabled: true
    virtualNetwork: {
      id: virtualNetwork.id
    }
  }
}

output vnetName string = virtualNetwork.name
output vnetId string = virtualNetwork.id
output hostDnsZoneName string = createHostDnsZone ? hostDnsZoneName : ''
output appSubnetName string = appSubnet.name
output appSubnetId string = appSubnet.id
output linuxSubnetName string = linuxSubnet.name
output linuxSubnetId string = linuxSubnet.id
output avdSubnetName string = avdSubnet.name
output avdSubnetId string = avdSubnet.id
output privateEndpointSubnetName string = privateEndpointSubnet.name
output privateEndpointSubnetId string = privateEndpointSubnet.id
