// Gives the portal's managed identity data access to the session cache. Separate from
// redis-session-store.bicep because the portal's app settings need the cache's host name
// first, and this needs the portal's identity.

@allowed([
  'managed'
  'cache'
])
param kind string
param redisName string

@description('Object ID of the portal\'s system-assigned managed identity.')
param principalId string

// Alphanumeric, which both kinds of assignment accept. A new identity gets its own assignment
// rather than changing the old one.
var assignmentName = 'portal${uniqueString(principalId)}'

resource managedRedis 'Microsoft.Cache/redisEnterprise@2025-07-01' existing = {
  name: redisName
}

resource managedRedisDatabase 'Microsoft.Cache/redisEnterprise/databases@2025-07-01' existing = {
  parent: managedRedis
  name: 'default'
}

resource managedRedisAccess 'Microsoft.Cache/redisEnterprise/databases/accessPolicyAssignments@2025-07-01' = if (kind == 'managed') {
  parent: managedRedisDatabase
  name: assignmentName
  properties: {
    // The only policy Azure Managed Redis offers: full data access.
    accessPolicyName: 'default'
    user: {
      objectId: principalId
    }
  }
}

resource cache 'Microsoft.Cache/redis@2024-11-01' existing = {
  name: redisName
}

resource cacheAccess 'Microsoft.Cache/redis/accessPolicyAssignments@2024-11-01' = if (kind == 'cache') {
  parent: cache
  name: assignmentName
  properties: {
    accessPolicyName: 'Data Contributor'
    objectId: principalId
    // The alias is also the user name the portal signs in with, which is its object ID.
    objectIdAlias: principalId
  }
}
