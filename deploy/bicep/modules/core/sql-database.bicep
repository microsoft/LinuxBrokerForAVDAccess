param location string = resourceGroup().location
param tags object = {}
param sqlServerName string
param databaseName string
param administratorLogin string
@secure()
param administratorPassword string
param allowedClientIp string = ''

@description('SKU name, for example Basic, S0, S1 or GP_S_Gen5_1. The tier is derived from the name.')
param skuName string = 'Basic'

// DTU SKU names map to a tier; vCore names such as GP_S_Gen5_1 carry it in the name.
var dtuTiers = {
  Basic: 'Basic'
  S0: 'Standard'
  S1: 'Standard'
  S2: 'Standard'
  S3: 'Standard'
  S4: 'Standard'
  S6: 'Standard'
  S7: 'Standard'
  S9: 'Standard'
  S12: 'Standard'
  P1: 'Premium'
  P2: 'Premium'
  P4: 'Premium'
  P6: 'Premium'
  P11: 'Premium'
  P15: 'Premium'
}
var databaseSku = contains(dtuTiers, skuName) ? {
  name: skuName
  tier: dtuTiers[skuName]
} : {
  name: skuName
}

resource sqlServer 'Microsoft.Sql/servers@2023-08-01-preview' = {
  name: sqlServerName
  location: location
  tags: tags
  properties: {
    administratorLogin: administratorLogin
    administratorLoginPassword: administratorPassword
    minimalTlsVersion: '1.2'
    publicNetworkAccess: 'Enabled'
  }
}

resource database 'Microsoft.Sql/servers/databases@2023-08-01-preview' = {
  parent: sqlServer
  name: databaseName
  location: location
  sku: databaseSku
  properties: {
    collation: 'SQL_Latin1_General_CP1_CI_AS'
  }
}

resource allowAzureServices 'Microsoft.Sql/servers/firewallRules@2023-08-01-preview' = {
  parent: sqlServer
  name: 'AllowAzureServices'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
}

resource allowClientIp 'Microsoft.Sql/servers/firewallRules@2023-08-01-preview' = if (!empty(allowedClientIp)) {
  parent: sqlServer
  name: 'AllowClientIp'
  properties: {
    startIpAddress: allowedClientIp
    endIpAddress: allowedClientIp
  }
}

output sqlServerName string = sqlServer.name
output sqlServerFullyQualifiedDomainName string = sqlServer.properties.fullyQualifiedDomainName
output databaseName string = database.name
