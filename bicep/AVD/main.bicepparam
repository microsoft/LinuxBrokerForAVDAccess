using 'main.bicep'

/*AVD Config*/
param hostPoolName = 'myHostPool'
param sessionHostCount = 2
param maxSessionLimit = 5

/*VM Config*/
param vmNamePrefix = 'myVMName'
param vmSize = 'Standard_DS2_v2'
param adminUsername = 'myAdminUser'
param adminPassword = 'NotaPassword!'

/*Network Config*/
param subnetName = 'mySubnetName'
param vnetName = 'myVnetName'
param vnetResourceGroup = 'myVnetResourceGroup'

/*API Config*/
param linuxBrokerApiBaseUrl = 'https://your-broker.domain.com/api'
