using './main.bicep'

/*Network Config*/
param subnetName =  'mySubnet'
param vnetName =  'myVnet'
param vnetResourceGroup =  'myResourceGroup'

/*VM Config - General*/
param vmNamePrefix = 'myLinuxVM'
param vmSize = 'Standard_D2s_v3'
param numberOfVMs = 2
param OSVersion = '24_04-lts'

/*VM Config - Auth*/
param authType = 'Password'
param adminUsername = 'myAdminUser'
param adminPassword = 'JustASecret!'
