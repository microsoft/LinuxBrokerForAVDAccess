param location string = resourceGroup().location
param tags object = {}

// Network Parameters
param vnetName string
param subnetName string
param vnetResourceGroup string

// VM Parameters - General
param vmNamePrefix string
param vmSize string
@minValue(1)
@maxValue(20)
param numberOfVMs int

// VM Parameters - Authentication
@allowed([
  'Password'
  'SSH'
])
param authType string
param adminUsername string
@secure()
param adminPassword string
param sshPublicKey string = ''

// VM Parameters - OS Image
@allowed([
  '7-LVM' // RHEL 7
  '8-LVM' // RHEL 8
  '9-LVM' // RHEL 9
  '24_04-lts' // Ubuntu 24.04
])
param OSVersion string

var vmNames = [for i in range(1, numberOfVMs): '${vmNamePrefix}-${padLeft(i, 2, '0')}']
var adminPass = authType == 'Password' ? adminPassword : sshPublicKey

var imageConfigs = {
  '7-LVM': {
    image: {
      publisher: 'RedHat'
      offer: 'RHEL'
      sku: '7-LVM'
      version: 'latest'
    }
    script: {
      uri: 'https://raw.githubusercontent.com/microsoft/LinuxBrokerForAVDAccess/refs/heads/main/custom_script_extensions/Configure-RHEL7-Host.sh'
      cmd: 'bash Configure-RHEL7-Host.sh'
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
      uri: 'https://raw.githubusercontent.com/microsoft/LinuxBrokerForAVDAccess/refs/heads/main/custom_script_extensions/Configure-RHEL8-Host.sh'
      cmd: 'bash Configure-RHEL8-Host.sh'
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
      uri: 'https://raw.githubusercontent.com/microsoft/LinuxBrokerForAVDAccess/refs/heads/main/custom_script_extensions/Configure-RHEL9-Host.sh'
      cmd: 'bash Configure-RHEL9-Host.sh'
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
      uri: 'https://raw.githubusercontent.com/microsoft/LinuxBrokerForAVDAccess/refs/heads/main/custom_script_extensions/Configure-Ubuntu24_desktop-Host.sh'
      cmd: 'bash Configure-Ubuntu24_desktop-Host.sh'
    }
  }
}

// Selected configuration based on OSVersion parameter
var selectedConfig = imageConfigs[OSVersion]

// Retrieve existing VNet and Subnet
resource existingVNet 'Microsoft.Network/virtualNetworks@2021-05-01' existing = {
  name: vnetName
  scope: resourceGroup(vnetResourceGroup)
}

resource existingSubnet 'Microsoft.Network/virtualNetworks/subnets@2021-05-01' existing = {
  parent: existingVNet
  name: subnetName
}

// Create Network Interfaces
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

// Create Linux VMs 
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
      osProfile: {
        computerName: vmNames[i]
        adminUsername: adminUsername
        adminPassword: adminPass
        linuxConfiguration: authType == 'SSH'
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
      }
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

// Apply Script Based on Image OS
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
