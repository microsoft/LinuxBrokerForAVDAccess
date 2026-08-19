# Linux Broker for Azure Virtual Desktop (AVD) Access

[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

## Purpose

The **Linux Broker for AVD Access** is a solution designed to manage and broker user access to Linux hosts via Azure Virtual Desktop (AVD). It provides a scalable and efficient way to connect users to Linux virtual machines (VMs) using either Remote Desktop Protocol (RDP) for full desktop experiences or xpra (X Remote Application) for virtualized applications.

This solution leverages Azure services such as managed identities, security groups, Azure App Service, Azure Functions, and Azure SQL Database to provide secure and efficient brokering, session management, and scaling of Linux hosts.


## Architecture Description

The solution consists of the following components:

- **Azure Virtual Desktop (AVD)**: Provides the interface for users to access Linux hosts. Users can connect via the AVD web client or any supported AVD client.

- **Broker Agent (`Connect-LinuxBroker.ps1`)**: A PowerShell script running on each AVD host that acts as an agent to broker connections to Linux hosts. It connects to the Broker API using managed identity to check out a Linux VM and initiate the appropriate connection (RDP or xpra).

- **Linux Hosts Cluster**: A set of Linux VMs that users connect to. Each Linux host has managed identity enabled and runs a Session Release Agent.

- **Session Release Agent**: A host-side reconciliation service that keeps the one-minute poll as a safety net, uses XRDP/Xorg session inspection as the source of truth, and can wake early from `systemd-logind` signals to shorten disconnect detection time. It still enforces the same 20-minute reconnect window before final logoff and cleanup.

- **Broker API**: A RESTful API running on Azure App Service that handles interactions between the Broker Agent, Session Release Agent, and the Broker Database. It uses managed identities and Azure Key Vault for secure access to resources.

- **Broker Database**: An Azure SQL Database that stores information about virtual machines, scaling rules, and scaling activity. It includes the following tables:
  - `virtual_machines`: Stores information about Linux VMs, including hostname, IP address, power state, network status, VM status, connected username, AVD host, and VM ID.
  - `vm_scaling_rules`: Stores scaling rules for the Linux host cluster.
  - `vm_scaling_activity`: Logs scaling activities such as VMs being turned on or off.

- **Azure Function for Scaling Tasks**: An Azure Function that runs on a schedule to manage scaling of Linux hosts based on the scaling rules. It updates VM network statuses, turns VMs on or off, and performs health checks on the Linux hosts.

- **Service Management Portal**: A front-end web application that allows administrators to manage VMs, scaling rules, and monitor the system. It provides functionalities such as adding/deleting VMs, checking out VMs, releasing/returning VMs, modifying VM statuses, and viewing logs.

- **Azure Key Vault**: Stores sensitive information such as SSH keys and database passwords, accessed securely by the Broker API using managed identity.

- **Managed Identities and Security Groups**: Used throughout the solution to securely authenticate and authorize different components. AVD hosts and Linux hosts have managed identities and are members of respective security groups.

The architecture ensures secure, efficient, and scalable management of Linux host access via AVD.

![Architecture](images/architecture.png)

## List of Services

- **Azure Virtual Desktop (AVD)**: Provides virtual desktop infrastructure.
- **Broker Agent (`Connect-LinuxBroker.ps1`)**: PowerShell script acting as an agent on AVD hosts.
- **Linux Hosts Cluster**: The set of Linux VMs users connect to.
- **Session Release Agent**: Systemd-timer-based reconciliation service on Linux hosts, optionally accelerated by a `systemd-logind` watcher.
- **Broker API**: RESTful API for brokering connections and managing VMs.
- **Broker Database**: Azure SQL Database for storing VM and scaling data.
- **Azure Function for Scaling Tasks**: Manages scaling of Linux hosts.
- **Service Management Portal**: Front-end application for administrators.
- **Azure Key Vault**: Secure storage for SSH keys and passwords.
- **Managed Identities**: Used for secure authentication between components.
- **Security Groups**: Controls access permissions for managed identities.

## User Workflow

1. **User Logs into AVD**: The user accesses the AVD web client or any supported client.
2. **Selects Linux Host Connection**: The user selects a desktop icon for full RDP session or an application for xpra session.
3. **Broker Agent Initiates Connection**:
   - The Broker Agent script (`Connect-LinuxBroker.ps1`) connects to the Broker API using the AVD host's managed identity.
   - It checks out an available Linux VM for the user.
   - The user's ID is added to the Linux host with a unique 25-character password.
   - The user is added to appropriate user groups on the Linux host for RDP or xpra access.
4. **User Connects to Linux Host**: The user is connected to the Linux host via RDP or xpra and can work as needed.
5. **Session Management**:
   - If the user disconnects or logs off, the Session Release Agent on the Linux host reconciles the XRDP/Xorg session state immediately when possible and otherwise on the next one-minute safety-net poll.
   - A 20-minute timer is initiated to allow the user to reconnect.
   - If the user reconnects within 20 minutes, they resume their session.
   - If not, the user's account is removed from the Linux host, and the VM is made available for other users.

## Admin Workflow

1. **Access Service Management Portal**: Admins log into the front-end portal.
2. **Manage VMs**:
   - **Add VMs**: Register new Linux VMs into the system.
   - **Delete VMs**: Remove VMs from the system.
   - **Update VM Attributes**: Modify VM statuses (e.g., set to maintenance).
3. **Manage Scaling Rules**:
   - **Create/Update/Delete Scaling Rules**: Adjust scaling rules to control the minimum and maximum number of VMs, scale-up/down ratios, and increments.
4. **Monitor System**:
   - **View VM Details**: Access detailed information about VMs.
   - **View Scaling Activity Logs**: Monitor scaling activities and history.
   - **View VM History**: Track the usage and status changes of VMs.

## RBAC Permissions

The solution uses Role-Based Access Control (RBAC) to secure access:

- **Management Portal Admins**:
  - **Roles**: `User` and `FullAccess` on the Broker API.
  - **Permissions**: Access to the management portal and ability to manage VMs and scaling rules.
- **Broker Agent (AVD Hosts)**:
  - **Role**: `AVDHost` on the Broker API.
  - **Permissions**: Access to the `checkout` API endpoint.
  - **Requirements**: Must be using managed identity and be a member of the `LinuxBroker-AVDHost-VMs` security group.
- **Session Release Agent (Linux Hosts)**:
  - **Role**: `LinuxHost` on the Broker API.
  - **Permissions**: Access to release VMs and update statuses.
  - **Requirements**: Managed identity and membership in `LinuxBroker-LinuxHost-VMs` security group.
- **Azure Function (Scaling Tasks)**:
  - **Role**: `ScheduledTask` on the Broker API.
  - **Permissions**: Access to APIs for getting VMs, updating attributes, releasing VMs, and triggering scaling.
- **Broker API**:
  - **Permissions**: Has API permissions to Microsoft Graph for directory and group read access to validate managed identities and security group memberships.
- **Managed Identities**:
  - **AVD Hosts and Linux Hosts**: Each has a managed identity used for authentication.
  - **Security Groups**: Managed identities are added to respective security groups to control API access.

![RBAC](images/rbac.png)

## Database Setup

The database component is essential for storing VM information, scaling rules, and activity logs. For detailed instructions on setting up the Azure SQL Database and deploying the stored procedures, please refer to the [Database Setup Documentation](sql_queries/README.md).

## Custom Script Extension

The **Custom Script Extensions** automate the configuration of both the AVD hosts and Linux hosts, ensuring they are prepared to support user access and integration with the Linux Broker for AVD solution.

### **AVD Host Configuration**

The custom script extension for the AVD host:

- **Installs the Linux Broker Agent**: Downloads and sets up the Linux Broker Agent (`Connect-LinuxBroker.ps1`) on the AVD host.
- **Configures Required Libraries**: Installs necessary authentication libraries to enable secure communication with the Broker API using managed identity.
- **Prepares the Host for User Connection**: Configures the AVD host to support seamless user connections, allowing them to access the Linux desktop via Azure Virtual Desktop.

### **Linux Host Configuration**

The custom script extensions support the following Linux distributions:

- **Red Hat Enterprise Linux (RHEL) 7, 8, and 9**
- **Ubuntu 24 Desktop**

These scripts:

- **Install XRDP and xpra**: Set up XRDP for full desktop access (RDP) and xpra for application virtualization, enabling users to connect via AVD.
- **Configure Authentication**: Sets up authentication mechanisms for secure user access.
- **Deploy the Linux Session Release Agent**: Installs the minute-based reconciliation service plus a `systemd-logind` watcher that can trigger early reconciliations. The minute timer remains the fallback path so the system still converges even if event delivery is delayed or unavailable.

## Additional Details

### Scaling Rules

- **Minimum VMs Running**: The minimum number of Linux VMs to keep powered on.
- **Maximum VMs Running**: The maximum number of Linux VMs allowed to be powered on.
- **Scale-Up Ratio**: The ratio of used VMs to total VMs at which the system should scale up (e.g., when 80% of VMs are in use).
- **Scale-Up Increment**: The number of VMs to add when scaling up.
- **Scale-Down Ratio**: The ratio at which to scale down the number of running VMs (e.g., when usage drops below 30%).
- **Scale-Down Increment**: The number of VMs to remove when scaling down.

### Session Release Mechanism

- **Session Monitoring**: The Session Release Agent reconciles XRDP/Xorg session state on a one-minute timer and can also wake early from `systemd-logind` session signals.
- **Release State**: When a session is disconnected, the VM enters a 'released' state, allowing the user to reconnect within 20 minutes.
- **Session Termination**: If the user does not reconnect within the 20-minute window, their account is removed from the Linux host, and the VM becomes available for other users.

### Security and Authentication

- **Managed Identities**: Used for secure authentication between Azure resources without storing credentials.
- **Azure Key Vault**: Stores SSH keys and database passwords securely, accessed via managed identities.
- **API Permissions**: Specific API permissions are granted to components to restrict access based on roles.
- **Logging and Monitoring**: All activities are logged to Azure Application Insights and Log Analytics Workspace.

### AVD Host Sizing Recommendations

- [Session host virtual machine sizing guidelines for Azure Virtual Desktop and Remote Desktop Services | Microsoft Learn](https://learn.microsoft.com/en-us/windows-server/remote/remote-desktop-services/virtual-machine-recs#multi-session-recommendations)

Given that AVD acts as a pass-through in this solution, starting with **light to medium workload sizing** is recommended. This provides a good balance of performance and efficiency without overprovisioning resources. The following table outlines the suggested configurations:

| Workload Type | Maximum Users per vCPU | Minimum Configuration             | Example Azure Instances                                      | Minimum Profile Storage |
| ------------- | ---------------------- | --------------------------------- | ------------------------------------------------------------ | ----------------------- |
| Light         | 6 users per vCPU       | 8 vCPUs, 16 GB RAM, 32 GB storage | D8s_v5, D8s_v4, F8s_v2, D8as_v4, D16s_v5, D16s_v4, F16s_v2, D16as_v4 | 30 GB                   |
| Medium        | 4 users per vCPU       | 8 vCPUs, 16 GB RAM, 32 GB storage | D8s_v5, D8s_v4, F8s_v2, D8as_v4, D16s_v5, D16s_v4, F16s_v2, D16as_v4 | 30 GB                   |

#### **Key Considerations:**

1. **Start with Light Workloads**:
   - For initial deployments, use light workload sizing (6 users per vCPU). This provides a good balance, allowing up to 48 users on an 8-core VM.
   - This configuration aligns well with the pass-through nature of the solution, minimizing unnecessary overhead.
2. **Adjust for Medium Workloads if Necessary**:
   - If users experience performance degradation, consider switching to a medium workload configuration (4 users per vCPU).
   - This reduces the user density per core and provides more headroom for CPU-intensive operations.
3. **VM Sizing Recommendations**:
   - Use VMs with at least 8 vCPUs and 16 GB of RAM. This configuration avoids stability issues seen with smaller VMs and provides sufficient resources for user sessions.
   - Avoid using VMs with more than 24 vCPUs to prevent diminishing returns due to increased synchronization overhead.
4. **Optimize for Multi-Session Workloads**:
   - Use multiple smaller VMs (e.g., 8-core instances) rather than fewer large VMs. This allows for better load balancing and resource management.
   - Smaller VMs can be shut down when not in use, conserving resources and reducing costs. Use Azure autoscale to manage VM power states based on demand.

## Getting Started

The supported deployment entrypoint for this repository is in `deploy/`.

For the full deployment walkthrough, see [deploy/DEPLOYMENT.md](deploy/DEPLOYMENT.md).

That guide covers:

- prerequisites and required permissions
- azd environment values and defaults
- how `azd up` prompts for subscription and deployment region when not pre-set
- choosing between Azure commercial, Azure US Government, and custom or sovereign clouds
- Entra app and group bootstrap behavior
- SSH key reuse, prompt, and auto-generation behavior
- what `preprovision`, Bicep provisioning, and `postprovision` each do
- the separate migration path for existing deployed environments
- SQL bootstrap, Linux host SQL registration, and validation steps
- troubleshooting and rerun paths

Quick start from the repository root:

```powershell
cd .\deploy
azd env new <environment-name>
azd up
```

For existing environments that need in-place rollout instead of new-environment provisioning, use [deploy/Migrate-ExistingEnvironment.ps1](deploy/Migrate-ExistingEnvironment.ps1) from the `deploy/` directory. `azd up` remains the supported greenfield path.

The deployment targets Azure commercial by default. Set `azureCloudName` to `AzureUSGovernment` or `AzureCustom` to deploy elsewhere; commercial and Government resolve their endpoints automatically, while custom and sovereign clouds require their own authority, Graph, STS, and App Service FQDNs. Air-gapped environments should also set `scriptSourceRoot` to a reachable mirror of this repository, because the Linux hosts download their agent scripts from it during bootstrap.

The deployment defaults the App Service plan to Premium v3 `P2mv3`, which provides the minimum supported baseline of 4 vCPUs and 32 GB memory for the frontend, API, and task apps.

Before running `azd up`, review the detailed guide and set any environment-specific values you need, especially networking, host counts, VM sizes, App Service plan sizing, and SQL firewall access. The deployment scripts under `deploy/` now handle the Entra bootstrap, SSH key flow, App Service health checks on `/health`, Application Insights wiring for the frontend and API, post-provision role assignment, container image builds, SQL initialization, and Linux host SQL registration used by this solution.

## Contributing

Contributions are welcome! Please read the [CONTRIBUTING](CONTRIBUTING.md) guidelines for more information.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
