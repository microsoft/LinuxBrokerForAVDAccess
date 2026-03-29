param location string = resourceGroup().location
param tags object = {}
param sqlServerName string
param databaseName string
param administratorLogin string
@secure()
param administratorPassword string
param allowedClientIp string = ''

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
  sku: {
    name: 'Basic'
    tier: 'Basic'
  }
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
