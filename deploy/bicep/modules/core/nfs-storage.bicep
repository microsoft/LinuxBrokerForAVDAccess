@description('Name of the premium FileStorage account that hosts the NFS share.')
@minLength(3)
@maxLength(24)
param storageAccountName string
param location string = resourceGroup().location
param tags object = {}

@description('Name of the NFS share that holds user home directories.')
param shareName string = 'home'

@description('Provisioned size of the share in GiB. Premium file shares have a 100 GiB minimum.')
@minValue(100)
param shareQuotaGiB int = 100

@description('Virtual network the Linux hosts mount the share from.')
param virtualNetworkId string

@description('Subnet the storage private endpoint is placed in.')
param privateEndpointSubnetId string

var privateDnsZoneName = 'privatelink.file.${environment().suffixes.storage}'

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  tags: tags
  kind: 'FileStorage'
  sku: {
    name: 'Premium_LRS'
  }
  properties: {
    // NFS mounts do not use HTTPS. Access is limited to the private endpoint instead.
    supportsHttpsTrafficOnly: false
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Deny'
    }
  }
}

resource fileService 'Microsoft.Storage/storageAccounts/fileServices@2023-05-01' = {
  parent: storageAccount
  name: 'default'
}

resource share 'Microsoft.Storage/storageAccounts/fileServices/shares@2023-05-01' = {
  parent: fileService
  name: shareName
  properties: {
    enabledProtocols: 'NFS'
    // create-user.sh creates and chowns each home directory as root on the host.
    rootSquash: 'NoRootSquash'
    shareQuota: shareQuotaGiB
  }
}

resource privateEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: 'pe-${storageAccountName}-file'
  location: location
  tags: tags
  properties: {
    subnet: {
      id: privateEndpointSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: 'file'
        properties: {
          privateLinkServiceId: storageAccount.id
          groupIds: [
            'file'
          ]
        }
      }
    ]
  }
}

resource privateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: privateDnsZoneName
  location: 'global'
  tags: tags
}

resource privateDnsZoneLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: privateDnsZone
  name: 'link-${last(split(virtualNetworkId, '/'))}'
  location: 'global'
  tags: tags
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: virtualNetworkId
    }
  }
}

resource privateDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: privateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'file'
        properties: {
          privateDnsZoneId: privateDnsZone.id
        }
      }
    ]
  }
}

output storageAccountName string = storageAccount.name
output shareName string = share.name
output nfsSharePath string = '${storageAccount.name}.file.${environment().suffixes.storage}:/${storageAccount.name}/${share.name}'
