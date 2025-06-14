param location string = resourceGroup().location
param tags object = {}

// Network Parameters
param vnetName string
param subnetName string
param vnetResourceGroup string

// AVD Parameters
param hostPoolName string
param friendlyName string = hostPoolName
param loadBalancerType string = 'BreadthFirst'
param preferredAppGroupType string = 'Desktop'
param sessionHostCount int
param maxSessionLimit int
@description('Token validity duration in ISO 8601 format')
param tokenValidityLength string = 'PT8H' // 8 hours by default
@description('Generated. Do not provide a value! This date value is used to generate a registration token.')
param baseTime string = utcNow('u')
@description('Agent update configuration')
param agentUpdate object = {
  type: 'Scheduled'
  useSessionHostLocalTime: true
  maintenanceWindowTimeZone: 'UTC'
  maintenanceWindows: [
    {
      dayOfWeek: 'Saturday'
      hour: 2
      duration: '02:00'
    }
  ]
}

// Session Host VM Parameters
@maxLength(10)
param vmNamePrefix string
@description('The size of the session host VMs')
@allowed([
  'Standard_DS2_v2'
  'Standard_D8s_v5'
  'Standard_D8s_v4'
  'Standard_F8s_v2'
  'Standard_D8as_v4'
  'Standard_D16s_v5'
  'Standard_D16s_v4'
  'Standard_F16s_v2'
  'Standard_D16as_v4'
])
param vmSize string
param adminUsername string
@secure()
param adminPassword string

// Linux Broker API Base URL
@description('Base URL for the AVD Linux Broker API')
param linuxBrokerApiBaseUrl string
// Linux Broker Configuration Script URI
@description('URI for the AVD Linux Broker configuration script')
// TODO update this to the latest version of the script
param linuxBrokerConfigScriptUri string = 'https://raw.githubusercontent.com/cocallaw/LinuxBrokerForAVDAccess/refs/heads/AVD-PS-Updates/custom_script_extensions/Configure-AVD-Host.ps1'

// Multisession image without Office
var osImage = 'microsoftwindowsdesktop:Windows-11:win11-24h2-avd:latest'
var vmNames = [for i in range(1, sessionHostCount): '${vmNamePrefix}-${padLeft(i, 2, '0')}']
// URL to the AVD artifacts location
var storageAccountName = 'wvdportalstorageblob'
var containerName = 'galleryartifacts'
var blobName01 = 'Configuration_1.0.02990.697.zip'
var AVDartifactsLocation = 'https://${storageAccountName}.blob.${environment().suffixes.storage}/${containerName}/${blobName01}'
var intune = false
var aadJoin = true
var aadJoinPreview = false

// Create AVD Host Pool
resource hostPool 'Microsoft.DesktopVirtualization/hostPools@2024-04-03' = {
  name: hostPoolName
  location: location
  tags: tags
  properties: {
    friendlyName: friendlyName
    hostPoolType: 'Pooled'
    preferredAppGroupType: preferredAppGroupType
    loadBalancerType: loadBalancerType
    maxSessionLimit: maxSessionLimit
    startVMOnConnect: false
    validationEnvironment: false
    agentUpdate: agentUpdate
    registrationInfo: {
      expirationTime: dateTimeAdd(baseTime, tokenValidityLength)
      registrationTokenOperation: 'Update'
    }
  }
}

// Create Desktop Application Group
resource desktopAppGroup 'Microsoft.DesktopVirtualization/applicationGroups@2024-04-03' = {
  name: '${hostPoolName}-desktopAppGroup'
  location: location
  tags: tags
  properties: {
    applicationGroupType: 'Desktop'
    hostPoolArmPath: resourceId('Microsoft.DesktopVirtualization/hostpools', hostPool.name)
  }
}

// Create Workspace
resource workspace 'Microsoft.DesktopVirtualization/workspaces@2024-11-01-preview' = {
  name: '${hostPoolName}-workspace'
  location: location
  tags: tags
  properties: {
    friendlyName: '${friendlyName} Workspace'
    applicationGroupReferences: [
      resourceId('Microsoft.DesktopVirtualization/applicationGroups', desktopAppGroup.name)
    ]
  }
}

module hostPoolRegistrationToken 'token.bicep' = {
  name: 'hostPoolRegistrationToken'
  params: {
    hostPoolName: hostPoolName
    tags: hostPool.tags
    location: hostPool.location
    hostPoolType: hostPool.properties.hostPoolType
    friendlyName: hostPool.properties.friendlyName
    loadBalancerType: hostPool.properties.loadBalancerType
    preferredAppGroupType: hostPool.properties.preferredAppGroupType
    maxSessionLimit: hostPool.properties.maxSessionLimit
    startVMOnConnect: hostPool.properties.startVMOnConnect
    validationEnvironment: hostPool.properties.validationEnvironment
    agentUpdate: hostPool.properties.agentUpdate
  }
  dependsOn: [
    desktopAppGroup
    workspace
  ]
}

// Retrieve the existing VNet and Subnet
resource existingVNet 'Microsoft.Network/virtualNetworks@2021-05-01' existing = {
  name: vnetName
  scope: resourceGroup(vnetResourceGroup)
}

resource existingSubnet 'Microsoft.Network/virtualNetworks/subnets@2021-05-01' existing = {
  parent: existingVNet
  name: subnetName
}

resource nic 'Microsoft.Network/networkInterfaces@2024-05-01' = [
  for (name, i) in vmNames: {
    name: '${name}-nic'
    location: location
    properties: {
      ipConfigurations: [
        {
          name: 'ipconfig1'
          properties: {
            subnet: {
              id: existingSubnet.id
            }
            privateIPAllocationMethod: 'Dynamic'
          }
        }
      ]
    }
    dependsOn: [
      existingVNet
      existingSubnet
    ]
  }
]

resource vmSessionHost 'Microsoft.Compute/virtualMachines@2024-11-01' = [
  for (name, i) in vmNames: {
    name: name
    location: location
    identity: {
      type: 'SystemAssigned'
    }
    properties: {
      hardwareProfile: {
        vmSize: vmSize
      }
      osProfile: {
        computerName: vmNames[i]
        adminUsername: adminUsername
        adminPassword: adminPassword
      }
      storageProfile: {
        imageReference: {
          publisher: split(osImage, ':')[0]
          offer: split(osImage, ':')[1]
          sku: split(osImage, ':')[2]
          version: split(osImage, ':')[3]
        }
        osDisk: {
          createOption: 'FromImage'
          managedDisk: {
            storageAccountType: 'Premium_LRS'
          }
        }
      }
      networkProfile: {
        networkInterfaces: [
          {
            id: nic[i].id
          }
        ]
      }
      diagnosticsProfile: {
        bootDiagnostics: {
          enabled: true
          storageUri: ''
        }
      }
      securityProfile: {
        securityType: 'TrustedLaunch'
        uefiSettings: {
          secureBootEnabled: true
          vTpmEnabled: true
        }
      }
    }
    dependsOn: [
      nic[i]
      hostPoolRegistrationToken
    ]
  }
]

// EntraLoginForWindows Extension
resource entraloginExtension 'Microsoft.Compute/virtualMachines/extensions@2024-11-01' = [
  for (name, i) in vmNames: {
    name: '${name}/AADLoginForWindows'
    location: resourceGroup().location
    properties: {
      publisher: 'Microsoft.Azure.ActiveDirectory'
      type: 'AADLoginForWindows'
      typeHandlerVersion: '2.0'
      autoUpgradeMinorVersion: true
      settings: (intune
        ? {
            mdmId: '0000000a-0000-0000-c000-000000000000'
          }
        : null)
    }
    dependsOn: [
      vmSessionHost[i]
      nic[i]
    ]
  }
]

// AVD DSC Configuration
resource avdDscExtension 'Microsoft.Compute/virtualMachines/extensions@2024-11-01' = [
  for (name, i) in vmNames: {
    name: '${name}/Microsoft.PowerShell.DSC'
    location: resourceGroup().location
    properties: {
      publisher: 'Microsoft.Powershell'
      type: 'DSC'
      typeHandlerVersion: '2.83'
      autoUpgradeMinorVersion: true
      settings: {
        modulesUrl: AVDartifactsLocation
        configurationFunction: 'Configuration.ps1\\AddSessionHost'
        properties: {
          hostPoolName: hostPool.name
          registrationInfoTokenCredential: {
            UserName: 'PLACEHOLDER_DO_NOT_USE'
            Password: 'PrivateSettingsRef:RegistrationInfoToken'
          }
          aadJoin: aadJoin
          UseAgentDownloadEndpoint: true
          aadJoinPreview: aadJoinPreview
          mdmId: (intune ? '0000000a-0000-0000-c000-000000000000' : '')
          sessionHostConfigurationLastUpdateTime: ''
        }
      }
      protectedSettings: {
        Items: {
          RegistrationInfoToken: hostPoolRegistrationToken.outputs.registrationToken
        }
      }
    }
    dependsOn: [
      vmSessionHost[i]
      entraloginExtension[i]
    ]
  }
]

resource linuxBrokerConfig 'Microsoft.Compute/virtualMachines/extensions@2024-11-01' = [
  for (name, i) in vmNames: {
    name: '${name}/CustomScriptExtension'
    location: location
    properties: {
      publisher: 'Microsoft.Compute'
      type: 'CustomScriptExtension'
      typeHandlerVersion: '1.10'
      autoUpgradeMinorVersion: true
      settings: {
        fileUris: array(linuxBrokerConfigScriptUri)
      }
      protectedSettings: {
        commandToExecute: 'powershell -ExecutionPolicy Unrestricted -File Configure-AVD-Host.ps1 -LinuxBrokerApiBaseUrl "${linuxBrokerApiBaseUrl}"'
      }
    }
    dependsOn: [
      hostPoolRegistrationToken
      vmSessionHost[i]
      entraloginExtension[i]
      avdDscExtension[i]
    ]
  }
]
