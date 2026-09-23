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
@description('Source-relative SHA256 map computed from the approved LF/UTF-8 checkout. Every downloaded bootstrap/helper is checked before execution.')
param agentFileHashes object
@description('Pinned baseline x86_64 GNU CPython archive compatible with RHEL7 glibc 2.17.')
param pythonRuntime object

@description('Disable the GNOME screen saver and screen lock on RHEL hosts. Enabled by default because a locked greeter inside an xrdp/xpra session often cannot be unlocked after a reconnect, which strands the host lease. Set to false to keep the lock screen, for example to satisfy a STIG or CIS idle-lock control. Has no effect on the Ubuntu server image, which has no desktop.')
param disableScreenLock bool = true

var normalizedScriptSourceRoot = endsWith(scriptSourceRoot, '/') ? take(scriptSourceRoot, length(scriptSourceRoot) - 1) : scriptSourceRoot
var bootstrapArgs = '"${linuxBrokerApiBaseUrl}" "${linuxBrokerApiClientId}"'
var bootstrapEnv = 'LINUXBROKER_LOCAL_AGENT_DIRECTORY="$PWD" LINUXBROKER_PYTHON_RUNTIME_CONFIG="${base64(string(pythonRuntime))}" LINUXBROKER_DISABLE_SCREEN_LOCK="${disableScreenLock ? 'true' : 'false'}" LINUXBROKER_ADMIN_USERNAME="${adminUsername}"'

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
    scriptName: 'Configure-RHEL7-Host.sh'
  }
  '8-LVM': {
    image: {
      publisher: 'RedHat'
      offer: 'RHEL'
      sku: '8-LVM'
      version: 'latest'
    }
    scriptName: 'Configure-RHEL8-Host.sh'
  }
  '9-LVM': {
    image: {
      publisher: 'RedHat'
      offer: 'RHEL'
      sku: '9-LVM'
      version: 'latest'
    }
    scriptName: 'Configure-RHEL9-Host.sh'
  }
  '24_04-lts': {
    image: {
      publisher: 'canonical'
      offer: 'ubuntu-24_04-lts'
      sku: 'server'
      version: 'latest'
    }
    scriptName: 'Configure-Ubuntu24_desktop-Host.sh'
  }
}

var selectedConfig = imageConfigs[OSVersion]
var releaseVariant = OSVersion == '24_04-lts' ? 'Ubuntu' : 'RHEL'
var artifactSources = [
  'custom_script_extensions/${selectedConfig.scriptName}'
  'custom_script_extensions/install-broker-python.py'
  'custom_script_extensions/check-broker-host-prerequisites.sh'
  'custom_script_extensions/configure-broker-xrdp-gate.py'
  'linux_host/create-user.sh'
  'linux_host/manage-lease.sh'
  'linux_host/broker-lease.py'
  'linux_host/broker-freezer.py'
  'linux_host/apply-host-settings.sh'
  'linux_host/session_release_buffer/release-session-common.sh'
  'linux_host/session_release_buffer/${releaseVariant}/release-session.sh'
  'linux_host/session_release_buffer/xrdp-who-xorg.sh'
  'linux_host/session_release_buffer/logind-session-watcher.sh'
]
var checksumLines = [for source in artifactSources: '${agentFileHashes[source]}  ${last(split(source, '/'))}']
var checksumContent = '${join(checksumLines, '\n')}\n'
var verifyCommand = 'printf %s "${base64(checksumContent)}" | base64 --decode | sha256sum --check --status'
var bootstrapCommand = '${verifyCommand} && ${bootstrapEnv} bash ${selectedConfig.scriptName} ${bootstrapArgs}'

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
        fileUris: [for source in artifactSources: '${normalizedScriptSourceRoot}/${source}']
      }
      protectedSettings: {
        commandToExecute: bootstrapCommand
      }
    }
    dependsOn: [
      vmLinuxHost[i]
    ]
  }
]
