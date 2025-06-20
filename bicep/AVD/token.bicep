param location string = resourceGroup().location
param tags object = {}
param hostPoolName string
param friendlyName string
param hostPoolType string
param loadBalancerType string
param preferredAppGroupType string
param maxSessionLimit int
param startVMOnConnect bool
param validationEnvironment bool
param agentUpdate object

@description('Token validity duration in ISO 8601 format')
param tokenValidityLength string = 'PT8H' // 8 hours by default
@description('Generated. Do not provide a value! This date value is used to generate a registration token.')
param baseTime string = utcNow('u')

resource hostPoolTokenUpdate 'Microsoft.DesktopVirtualization/hostPools@2024-04-03' = {
  name: hostPoolName
  location: location
  tags: tags
  properties: {
    friendlyName: friendlyName
    hostPoolType: hostPoolType
    loadBalancerType: loadBalancerType
    preferredAppGroupType: preferredAppGroupType
    maxSessionLimit: maxSessionLimit
    startVMOnConnect: startVMOnConnect
    validationEnvironment: validationEnvironment
    agentUpdate: agentUpdate
    // Update the registration info with a new token
    registrationInfo: {
      expirationTime: dateTimeAdd(baseTime, tokenValidityLength)
      registrationTokenOperation: 'Update'
    }
  }
}

@secure()
output registrationToken string = first(hostPoolTokenUpdate.listRegistrationTokens().value)!.token
