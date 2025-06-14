# Azure Virtual Desktop (AVD) Bicep Deployment

This directory contains Bicep templates to help with deploying and managing Azure Virtual Desktop (AVD) infrastructure to be used with the Linux Broker for AVD.

## Parameter Files

### `main.bicepparam`

This parameter file contains the following key parameters:

- **AVD Config**:
  - `hostPoolName`: The name of the AVD host pool (e.g., `hp-test-01`).
  - `sessionHostCount`: The number of session host VMs to deploy (e.g., `2`).
  - `maxSessionLimit`: The maximum number of sessions per host (e.g., `5`).

- **VM Config**:
  - `vmNamePrefix`: The prefix for the session host VM names (e.g., `hptest`).
  - `vmSize`: The size of the session host VMs (e.g., `Standard_DS2_v2`).
  - `adminUsername`: The administrator username for the VMs (e.g., `avdadmin`).
  - `adminPassword`: The administrator password for the VMs (e.g., `NotaPassword!`).

- **Network Config**:
  - `subnetName`: The name of the subnet (e.g., `sn00`).
  - `vnetName`: The name of the virtual network (e.g., `vnet-avd-01`).
  - `vnetResourceGroup`: The resource group containing the virtual network (e.g., `rg-avd-bicep-01`).

- **API Config**:
  - `linuxBrokerApiBaseUrl`: The base URL for the AVD Linux Broker API (e.g., `https://your-broker.domain.com/api`).

## Deployment Instructions

1. Ensure you have the necessary prerequisites installed, including the Azure CLI and Bicep CLI.

2. Update the parameter files (`main.bicepparam`) with values specific to your environment.

3. Deploy the infrastructure using the following command:

   ```bash
   az deployment group create --resource-group <resourceGroupName> --template-file main.bicep --parameters @main.bicepparam
   ```

