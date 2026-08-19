param location string = resourceGroup().location
param tags object = {}

param vnetName string
param subnetName string
param vnetResourceGroup string

param vmNamePrefix string
param vmSize string
@minValue(1)
@maxValue(20)
param numberOfVMs int
param linuxBrokerApiBaseUrl string
param linuxBrokerApiClientId string

@allowed([
  'Password'
  'SSH'
])
param authType string
param adminUsername string
@secure()
param adminPassword string
param sshPublicKey string = ''

@allowed([
  '7-LVM'
  '8-LVM'
  '9-LVM'
  '24_04-lts'
])
param OSVersion string

@description('Root URL the host bootstrap scripts are downloaded from. Point this at a reachable mirror for sovereign or air-gapped clouds.')
param scriptSourceRoot string = 'https://raw.githubusercontent.com/microsoft/LinuxBrokerForAVDAccess/refs/heads/main'

var normalizedScriptSourceRoot = endsWith(scriptSourceRoot, '/') ? take(scriptSourceRoot, length(scriptSourceRoot) - 1) : scriptSourceRoot
var bootstrapArgs = '"${linuxBrokerApiBaseUrl}" "${linuxBrokerApiClientId}"'
var bootstrapEnv = 'LINUXBROKER_SCRIPT_SOURCE_ROOT="${normalizedScriptSourceRoot}"'

var vmNames = [for i in range(1, numberOfVMs): '${vmNamePrefix}-${padLeft(i, 2, '0')}']
var adminCredentials = authType == 'Password' ? {
  adminPassword: adminPassword
} : {}
var linuxConfiguration = authType == 'SSH'
  ? {
      disablePasswordAuthentication: true
      ssh: {
        publicKeys: [
          {
            path: '/home/${adminUsername}/.ssh/authorized_keys'
            keyData: sshPublicKey
          }
        ]
      }
    }
  : {
      disablePasswordAuthentication: false
    }

var imageConfigs = {
  '7-LVM': {
    image: {
      publisher: 'RedHat'
      offer: 'RHEL'
      sku: '7-LVM'
      version: 'latest'
    }
    script: {
      uri: '${normalizedScriptSourceRoot}/custom_script_extensions/Configure-RHEL7-Host.sh'
      cmd: '${bootstrapEnv} bash Configure-RHEL7-Host.sh ${bootstrapArgs}'
    }
  }
  '8-LVM': {
    image: {
      publisher: 'RedHat'
      offer: 'RHEL'
      sku: '8-LVM'
      version: 'latest'
    }
    script: {
      uri: '${normalizedScriptSourceRoot}/custom_script_extensions/Configure-RHEL8-Host.sh'
      cmd: '${bootstrapEnv} bash Configure-RHEL8-Host.sh ${bootstrapArgs}'
    }
  }
  '9-LVM': {
    image: {
      publisher: 'RedHat'
      offer: 'RHEL'
      sku: '9-LVM'
      version: 'latest'
    }
    script: {
      uri: '${normalizedScriptSourceRoot}/custom_script_extensions/Configure-RHEL9-Host.sh'
      cmd: '${bootstrapEnv} bash Configure-RHEL9-Host.sh ${bootstrapArgs}'
    }
  }
  '24_04-lts': {
    image: {
      publisher: 'canonical'
      offer: 'ubuntu-24_04-lts'
      sku: 'server'
      version: 'latest'
    }
    script: {
      uri: '${normalizedScriptSourceRoot}/custom_script_extensions/Configure-Ubuntu24_desktop-Host.sh'
      cmd: '${bootstrapEnv} bash Configure-Ubuntu24_desktop-Host.sh ${bootstrapArgs}'
    }
  }
}

var selectedConfig = imageConfigs[OSVersion]

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

resource vmLinuxHost 'Microsoft.Compute/virtualMachines@2022-03-01' = [
  for (name, i) in vmNames: {
    name: name
    location: location
    tags: tags
    identity: {
      type: 'SystemAssigned'
    }
    properties: {
      hardwareProfile: {
        vmSize: vmSize
      }
      osProfile: union({
        computerName: vmNames[i]
        adminUsername: adminUsername
        linuxConfiguration: linuxConfiguration
      }, adminCredentials)
      networkProfile: {
        networkInterfaces: [
          {
            id: nic[i].id
          }
        ]
      }
      storageProfile: {
        imageReference: selectedConfig.image
        osDisk: {
          createOption: 'FromImage'
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
      existingVNet
      existingSubnet
      nic[i]
    ]
  }
]

resource linuxCustomScriptExtension 'Microsoft.Compute/virtualMachines/extensions@2022-03-01' = [
  for (name, i) in vmNames: {
    name: '${name}/customScript'
    location: location
    properties: {
      publisher: 'Microsoft.Azure.Extensions'
      type: 'CustomScript'
      typeHandlerVersion: '2.1'
      autoUpgradeMinorVersion: true
      settings: {
        fileUris: [
          selectedConfig.script.uri
        ]
      }
      protectedSettings: {
        commandToExecute: selectedConfig.script.cmd
      }
    }
    dependsOn: [
      vmLinuxHost[i]
    ]
  }
]
