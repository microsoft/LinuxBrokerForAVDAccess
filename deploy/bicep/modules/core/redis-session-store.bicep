@description('Azure Managed Redis (managed), or Azure Cache for Redis (cache) where Azure Managed Redis is not available, as in Azure Government.')
@allowed([
  'managed'
  'cache'
])
param kind string

@description('Name of the cache. It becomes part of a public DNS name, so it must be unique.')
@minLength(1)
@maxLength(60)
param name string
param location string = resourceGroup().location
param tags object = {}

@description('Leave empty for the default size: Balanced_B0 for Azure Managed Redis, Standard_C1 for Azure Cache for Redis. Azure Cache for Redis sizes are written <tier>_<family><capacity>, such as Standard_C2 or Premium_P1.')
param skuName string = ''

@description('Virtual network the portal reaches the cache from.')
param virtualNetworkId string

@description('Subnet the cache private endpoint is placed in.')
param privateEndpointSubnetId string

@description('Private DNS zone of the cache private endpoint: privatelink.redis.azure.net for Azure Managed Redis, privatelink.redis.cache.<cloud suffix> for Azure Cache for Redis.')
param privateDnsZoneName string

var managed = kind == 'managed'
// Microsoft recommends C1 or larger outside dev/test, because C0 shares a CPU core.
var effectiveSku = empty(skuName) ? (managed ? 'Balanced_B0' : 'Standard_C1') : skuName
// Standard_C1 is tier Standard, family C, capacity 1.
var cacheSkuParts = split(effectiveSku, '_')
var managedPort = 10000

// Sessions are the only data, and the portal reads and writes them with the managed identity.
// Access keys are off, and so is public network access: the portal reaches the cache through
// its virtual network integration.
resource managedRedis 'Microsoft.Cache/redisEnterprise@2025-07-01' = if (managed) {
  name: name
  location: location
  tags: tags
  sku: {
    name: effectiveSku
  }
  properties: {
    minimumTlsVersion: '1.2'
    publicNetworkAccess: 'Disabled'
  }
}

resource managedRedisDatabase 'Microsoft.Cache/redisEnterprise/databases@2025-07-01' = if (managed) {
  parent: managedRedis
  name: 'default'
  properties: {
    clientProtocol: 'Encrypted'
    port: managedPort
    // One endpoint for clients that do not speak the cluster protocol, as the portal's does not.
    clusteringPolicy: 'EnterpriseCluster'
    // Every session expires, so under memory pressure the least recently used go first.
    evictionPolicy: 'VolatileLRU'
    accessKeysAuthentication: 'Disabled'
  }
}

resource cache 'Microsoft.Cache/redis@2024-11-01' = if (!managed) {
  name: name
  location: location
  tags: tags
  properties: {
    sku: {
      name: cacheSkuParts[0]
      family: first(cacheSkuParts[1])
      capacity: int(skip(cacheSkuParts[1], 1))
    }
    enableNonSslPort: false
    minimumTlsVersion: '1.2'
    publicNetworkAccess: 'Disabled'
    disableAccessKeyAuthentication: true
    redisConfiguration: {
      'aad-enabled': 'true'
      'maxmemory-policy': 'volatile-lru'
    }
  }
}

resource privateEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: 'pe-${name}'
  location: location
  tags: tags
  properties: {
    subnet: {
      id: privateEndpointSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: 'redis'
        properties: {
          privateLinkServiceId: managed ? managedRedis.id : cache.id
          groupIds: [
            managed ? 'redisEnterprise' : 'redisCache'
          ]
        }
      }
    ]
  }
  dependsOn: [
    managedRedisDatabase
  ]
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
        name: 'redis'
        properties: {
          privateDnsZoneId: privateDnsZone.id
        }
      }
    ]
  }
}

output name string = name
output hostName string = managed ? managedRedis!.properties.hostName : cache!.properties.hostName
output port int = managed ? managedPort : cache!.properties.sslPort
