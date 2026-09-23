param location string = resourceGroup().location
param tags object = {}

param vnetName string
param subnetName string
param vnetResourceGroup string

param hostPoolName string
param friendlyName string = hostPoolName
param loadBalancerType string = 'BreadthFirst'
@description('App group type the host pool prefers. Users who are assigned to both app groups only see this type.')
param preferredAppGroupType string = 'RailApplications'
@description('RDP properties for the host pool. The defaults enable Microsoft Entra single sign-on to the Entra joined session hosts.')
param customRdpProperty string = 'enablerdsaadauth:i:1;enablecredsspsupport:i:1;redirectclipboard:i:1;audiomode:i:0;redirectwebauthn:i:1;'
param sessionHostCount int
param maxSessionLimit int
@description('Token validity duration in ISO 8601 format')
param tokenValidityLength string = 'PT8H'
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

@description('Base URL for the AVD Linux Broker API')
param linuxBrokerApiBaseUrl string
@description('Client ID of the Linux Broker API app registration. Session hosts request tokens for api://<client-id>.')
param linuxBrokerApiClientId string
@description('Root URL the AVD host configuration scripts are downloaded from. The repository layout must be preserved.')
param scriptSourceRoot string = 'https://raw.githubusercontent.com/microsoft/LinuxBrokerForAVDAccess/refs/heads/main'
@description('Object ID of the Entra group whose members can launch the Linux Desktop RemoteApp. Leave empty to assign access manually.')
param avdUsersGroupId string = ''
@description('Display name of the RemoteApp that connects users to a Linux host.')
param remoteAppFriendlyName string = 'Linux Desktop'

var normalizedScriptSourceRoot = endsWith(scriptSourceRoot, '/') ? take(scriptSourceRoot, length(scriptSourceRoot) - 1) : scriptSourceRoot
var linuxBrokerConfigScriptUri = '${normalizedScriptSourceRoot}/custom_script_extensions/Configure-AVD-Host.ps1'
var desktopVirtualizationUserRoleId = '1d18fff3-a72a-46b5-b4a9-0b38a3cd7e63'
var virtualMachineUserLoginRoleId = 'fb879df8-f326-4884-b1cf-06f3ad86be52'

var osImage = 'microsoftwindowsdesktop:Windows-11:win11-24h2-avd:latest'
var vmNames = [for i in range(1, sessionHostCount): '${vmNamePrefix}-${padLeft(i, 2, '0')}']
var storageAccountName = 'wvdportalstorageblob'
var containerName = 'galleryartifacts'
var blobName01 = 'Configuration_1.0.02990.697.zip'
var AVDartifactsLocation = 'https://${storageAccountName}.blob.${environment().suffixes.storage}/${containerName}/${blobName01}'
var intune = false
var aadJoin = true
var aadJoinPreview = false

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
    customRdpProperty: customRdpProperty
    startVMOnConnect: false
    validationEnvironment: false
    agentUpdate: agentUpdate
    registrationInfo: {
      expirationTime: dateTimeAdd(baseTime, tokenValidityLength)
      registrationTokenOperation: 'Update'
    }
  }
}

resource desktopAppGroup 'Microsoft.DesktopVirtualization/applicationGroups@2024-04-03' = {
  name: '${hostPoolName}-desktopAppGroup'
  location: location
  tags: tags
  properties: {
    applicationGroupType: 'Desktop'
    hostPoolArmPath: resourceId('Microsoft.DesktopVirtualization/hostpools', hostPool.name)
  }
}

// Users launch the broker connection as a RemoteApp. The full desktop app group stays
// available for troubleshooting but is not assigned to anyone by the deployment.
resource remoteAppGroup 'Microsoft.DesktopVirtualization/applicationGroups@2024-04-03' = {
  name: '${hostPoolName}-remoteAppGroup'
  location: location
  tags: tags
  properties: {
    applicationGroupType: 'RemoteApp'
    friendlyName: remoteAppFriendlyName
    hostPoolArmPath: hostPool.id
  }
}

resource workspace 'Microsoft.DesktopVirtualization/workspaces@2024-11-01-preview' = {
  name: '${hostPoolName}-workspace'
  location: location
  tags: tags
  properties: {
    friendlyName: '${friendlyName} Workspace'
    applicationGroupReferences: [
      resourceId('Microsoft.DesktopVirtualization/applicationGroups', desktopAppGroup.name)
      remoteAppGroup.id
    ]
  }
}

resource remoteAppGroupUsers 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(avdUsersGroupId)) {
  name: guid(remoteAppGroup.id, avdUsersGroupId, desktopVirtualizationUserRoleId)
  scope: remoteAppGroup
  properties: {
    principalId: avdUsersGroupId
    principalType: 'Group'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', desktopVirtualizationUserRoleId)
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
    customRdpProperty: customRdpProperty
    startVMOnConnect: hostPool.properties.startVMOnConnect
    validationEnvironment: hostPool.properties.validationEnvironment
    agentUpdate: hostPool.properties.agentUpdate
  }
  dependsOn: [
    desktopAppGroup
    remoteAppGroup
    workspace
  ]
}

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
    tags: tags
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
    // The broker-role tag is how the post-provision hook finds the session hosts to add to the AVD host group.
    tags: tags
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
        commandToExecute: 'powershell -ExecutionPolicy Unrestricted -File Configure-AVD-Host.ps1 -LinuxBrokerApiBaseUrl "${linuxBrokerApiBaseUrl}" -LinuxBrokerApiClientId "${linuxBrokerApiClientId}" -ScriptSourceRoot "${normalizedScriptSourceRoot}"'
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

// Entra joined session hosts only admit users who hold a VM sign-in role on the VM itself.
resource sessionHostUserLogin 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for (name, i) in vmNames: if (!empty(avdUsersGroupId)) {
    name: guid(vmSessionHost[i].id, avdUsersGroupId, virtualMachineUserLoginRoleId)
    scope: vmSessionHost[i]
    properties: {
      principalId: avdUsersGroupId
      principalType: 'Group'
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', virtualMachineUserLoginRoleId)
    }
  }
]

// Connect-LinuxBroker.ps1 is staged at C:\Temp by Configure-AVD-Host.ps1, so the application
// is published only after the configuration extension has run on every session host.
resource linuxDesktopApp 'Microsoft.DesktopVirtualization/applicationGroups/applications@2024-04-03' = {
  parent: remoteAppGroup
  name: 'LinuxDesktop'
  properties: {
    friendlyName: remoteAppFriendlyName
    description: 'Checks out a Linux host from the Linux Broker and opens a remote desktop session to it.'
    applicationType: 'InBuilt'
    filePath: 'C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe'
    commandLineSetting: 'Require'
    commandLineArguments: '-ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File C:\\Temp\\Connect-LinuxBroker.ps1'
    iconPath: 'C:\\Windows\\System32\\mstsc.exe'
    iconIndex: 0
    showInPortal: true
  }
  dependsOn: [
    linuxBrokerConfig
  ]
}

output hostPoolName string = hostPool.name
output workspaceName string = workspace.name
output remoteAppGroupName string = remoteAppGroup.name
output desktopAppGroupName string = desktopAppGroup.name
