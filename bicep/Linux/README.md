# Linux Compute Deployment

This directory contains Bicep templates to help with deploying and managing the Linux Virtual Machines that are to be used with the Linux Broker for AVD.

## Parameter Files

### `main.bicepparam`

This parameter file contains the following key parameters:

- **Network Config**:
  - `subnetName`: The name of the subnet (e.g., `mySubnet`).
  - `vnetName`: The name of the virtual network (e.g., `myVnet`).
  - `vnetResourceGroup`: The resource group containing the virtual network (e.g., `myResourceGroup`).

- **VM Config - General**:
  - `vmNamePrefix`: The prefix for the VM names (e.g., `myLinuxVM`).
  - `vmSize`: The size of the VMs (e.g., `Standard_D2s_v3`).
  - `numberOfVMs`: The number of VMs to deploy (e.g., `2`).
  - `OSVersion`: The operating system version for the VMs (e.g., `24_04-lts`).

- **VM Config - Auth**:
  - `authType`: The authentication type for the VMs (e.g., `Password` or `SSH`).
  - `adminUsername`: The administrator username for the VMs (e.g., `myAdminUser`).
  - `adminPassword`: The administrator password for the VMs (e.g., `JustASecret!`).

## Deployment Instructions

1. Ensure you have the necessary prerequisites installed, including the Azure CLI and Bicep CLI.

2. Update the parameter files (`main.bicepparam`) with values specific to your environment.

3. Deploy the infrastructure using the following command:

   ```bash
   az deployment group create --resource-group <resourceGroupName> --template-file main.bicep --parameters @main.bicepparam
   ```
