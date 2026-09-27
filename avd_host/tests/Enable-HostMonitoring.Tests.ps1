# Pester 5 tests for deploy/Enable-HostMonitoring.ps1, which connects the Linux hosts and the AVD
# session hosts to the host monitoring, and for how deploy/Post-Provision.ps1 runs it. From the
# repository root, in Windows PowerShell:
#   Invoke-Pester -Path avd_host/tests

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $script:MonitoringScriptPath = Join-Path $script:RepoRoot 'deploy\Enable-HostMonitoring.ps1'
    . $script:MonitoringScriptPath

    # Mock can only replace a command that exists, and the machine running the tests may not have
    # the Azure CLIs.
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        function script:az { }
    }
    if (-not (Get-Command azd -ErrorAction SilentlyContinue)) {
        function script:azd { }
    }

    $script:ResourceGroup = 'rg-linuxbroker-dev'
    $script:SubscriptionId = '6d1e0f3c-2b4a-4c5d-8e9f-0a1b2c3d4e5f'
    $script:RulePrefix = "/subscriptions/$($script:SubscriptionId)/resourceGroups/$($script:ResourceGroup)/providers/Microsoft.Insights/dataCollectionRules"
    $script:LinuxRuleId = "$($script:RulePrefix)/linuxbroker-dev-linux-hosts"
    $script:AvdRuleId = "$($script:RulePrefix)/linuxbroker-dev-avd-hosts"
    $script:WindowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $script:Utf8NoBom = New-Object System.Text.UTF8Encoding -ArgumentList $false
    $script:AzureVariables = @('AZURE_ENV_NAME', 'AZURE_ENVIRONMENT_NAME', 'AZURE_SUBSCRIPTION_ID')

    function New-TestVm {
        param(
            [Parameter(Mandatory = $true)]
            [string]$Name,

            [AllowEmptyString()]
            [string]$Role = 'linux-host',

            [string]$PowerState = 'VM running',

            [switch]$NoPowerState
        )

        $vm = [ordered]@{
            id            = "/subscriptions/$($script:SubscriptionId)/resourceGroups/$($script:ResourceGroup)/providers/Microsoft.Compute/virtualMachines/$Name"
            name          = $Name
            resourceGroup = $script:ResourceGroup
            tags          = $null
        }
        if ($Role.Length -gt 0) {
            $vm['tags'] = @{ 'broker-role' = $Role }
        }
        if (-not $NoPowerState) {
            $vm['powerState'] = $PowerState
        }
        return [pscustomobject]$vm
    }

    function Set-TestVm {
        param([object[]]$Vm)

        $script:VmListJson = ConvertTo-Json -InputObject @($Vm) -Depth 5
        # As the script reads them, with the tags as properties rather than hashtable keys.
        $script:TestVms = @(ConvertFrom-Json -InputObject $script:VmListJson | ForEach-Object { $_ })
    }

    function Get-TestVmId {
        param([string]$Name)

        return "/subscriptions/$($script:SubscriptionId)/resourceGroups/$($script:ResourceGroup)/providers/Microsoft.Compute/virtualMachines/$Name"
    }

    # Queues what the listings of a VM's extensions report about the agent, one entry per listing:
    # '' for no agent, a provisioning state, @{ State; Name } for the agent under another name, or
    # @{ Error } for az failing. The last entry repeats. A VM with nothing queued has no agent
    # until an install starts, and then has it.
    function Set-AgentState {
        param(
            [Parameter(Mandatory = $true)]
            [string]$Vm,

            [object[]]$State
        )

        $queue = New-Object System.Collections.Queue
        foreach ($entry in $State) {
            $queue.Enqueue($entry)
        }
        $script:AgentStates[$Vm] = $queue
    }

    function Get-NextAgentState {
        param([string]$Vm)

        if ($script:AgentStates.ContainsKey($Vm)) {
            $queue = $script:AgentStates[$Vm]
            if ($queue.Count -gt 1) {
                return $queue.Dequeue()
            }
            return $queue.Peek()
        }
        if (@($script:Installs | Where-Object { $_.Vm -eq $Vm }).Count -gt 0) {
            return 'Succeeded'
        }
        return ''
    }

    function Get-TestAgentName {
        param([string]$Vm)

        $testVm = @($script:TestVms | Where-Object { $_.name -eq $Vm }) | Select-Object -First 1
        if ($null -ne $testVm -and (Get-VmTagValue -Vm $testVm -Name 'broker-role') -eq 'avd-host') {
            return 'AzureMonitorWindowsAgent'
        }
        return 'AzureMonitorLinuxAgent'
    }

    # The extensions az lists for a VM: the one that set the host up, and the agent unless it has
    # none, as az 2.83 lists them.
    function ConvertTo-ExtensionListJson {
        param(
            [string]$Vm,

            $Agent
        )

        $extensions = @([ordered]@{
                name               = 'host-setup'
                publisher          = 'Microsoft.Azure.Extensions'
                type               = 'Microsoft.Compute/virtualMachines/extensions'
                typePropertiesType = 'CustomScript'
                provisioningState  = 'Succeeded'
            })

        if ($Agent -is [hashtable] -or ([string]$Agent).Length -gt 0) {
            $agentName = Get-TestAgentName -Vm $Vm
            $state = [string]$Agent
            $name = $agentName
            if ($Agent -is [hashtable]) {
                $state = [string]$Agent['State']
                if ($Agent.ContainsKey('Name')) {
                    $name = $Agent['Name']
                }
            }
            $extensions += [ordered]@{
                name                   = $name
                publisher              = 'Microsoft.Azure.Monitor'
                type                   = 'Microsoft.Compute/virtualMachines/extensions'
                typePropertiesType     = $agentName
                typeHandlerVersion     = '1.33'
                enableAutomaticUpgrade = $true
                provisioningState      = $state
            }
        }

        return ConvertTo-Json -InputObject $extensions -Depth 5
    }

    function New-AzErrorRecord {
        param([string]$Message)

        return New-Object System.Management.Automation.ErrorRecord -ArgumentList @(
            (New-Object System.Exception -ArgumentList $Message),
            'NativeCommandError',
            [System.Management.Automation.ErrorCategory]::NotSpecified,
            $null)
    }

    function Get-ArgumentValue {
        param(
            [string[]]$Arguments,

            [string]$Name
        )

        $index = [array]::IndexOf($Arguments, $Name)
        if ($index -lt 0 -or $index + 1 -ge $Arguments.Count) {
            return $null
        }
        return $Arguments[$index + 1]
    }

    function Test-Utf8Bom {
        param([byte[]]$Bytes)

        return ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF)
    }

    function ConvertTo-TestLiteral {
        param([string]$Value)

        return "'" + $Value.Replace("'", "''") + "'"
    }

    function Invoke-ChildProcess {
        param(
            [Parameter(Mandatory = $true)]
            [string]$FilePath,

            [Parameter(Mandatory = $true)]
            [string]$ScriptPath
        )

        $folder = Split-Path -Parent $ScriptPath
        $stdoutPath = Join-Path $folder 'stdout.txt'
        $stderrPath = Join-Path $folder 'stderr.txt'
        $process = Start-Process -FilePath $FilePath `
            -ArgumentList @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $ScriptPath)) `
            -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -Wait -PassThru -NoNewWindow

        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            StdOut   = [System.IO.File]::ReadAllText($stdoutPath)
            StdErr   = [System.IO.File]::ReadAllText($stderrPath)
        }
    }

    function Save-AzureVariable {
        $saved = @{}
        foreach ($name in $script:AzureVariables) {
            $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
            [Environment]::SetEnvironmentVariable($name, $null, 'Process')
        }
        return $saved
    }

    function Restore-AzureVariable {
        param([hashtable]$Saved)

        foreach ($name in $Saved.Keys) {
            [Environment]::SetEnvironmentVariable($name, $Saved[$name], 'Process')
        }
    }
}

Describe 'Connecting the hosts to the host monitoring' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $global:LASTEXITCODE = 0
        $script:AzCalls = New-Object System.Collections.Generic.List[string]
        $script:Associations = New-Object System.Collections.Generic.List[object]
        $script:Installs = New-Object System.Collections.Generic.List[object]
        $script:ExtensionLists = New-Object System.Collections.Generic.List[string]
        $script:AgentStates = @{}
        $script:AssociationErrors = @{}
        $script:InstallErrors = @{}
        $script:RawExtensionJson = $null
        $script:AccountSetExitCode = 0
        $script:VmListExitCode = 0
        $script:TestVms = @()
        $script:VmListJson = '[]'
        $script:HostLines = New-Object System.Collections.Generic.List[string]
        $script:Warnings = New-Object System.Collections.Generic.List[string]
        $script:Slept = New-Object System.Collections.Generic.List[int]
        $script:AzdValues = @{}
        $script:AzdEnvironments = New-Object System.Collections.Generic.List[string]

        Mock az {
            $arguments = [string[]]@($args | ForEach-Object { [string]$_ })
            $commandLine = $arguments -join ' '
            $script:AzCalls.Add($commandLine)
            $global:LASTEXITCODE = 0

            if ($commandLine -like 'account set *') {
                $global:LASTEXITCODE = $script:AccountSetExitCode
                return
            }

            if ($commandLine -like 'vm list *') {
                $global:LASTEXITCODE = $script:VmListExitCode
                if ($script:VmListExitCode -ne 0) {
                    return (New-AzErrorRecord -Message "ERROR: (ResourceGroupNotFound) Resource group '$($script:ResourceGroup)' could not be found.")
                }
                return $script:VmListJson
            }

            if ($commandLine -like 'rest *') {
                $url = Get-ArgumentValue -Arguments $arguments -Name '--url'
                $bodyFile = (Get-ArgumentValue -Arguments $arguments -Name '--body').Substring(1)
                $vmName = ($url -split '/')[8]
                $script:Associations.Add([pscustomobject]@{
                        Vm        = $vmName
                        Url       = $url
                        Arguments = $arguments
                        File      = $bodyFile
                        Bytes     = [System.IO.File]::ReadAllBytes($bodyFile)
                        Body      = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($bodyFile))
                    })
                if ($script:AssociationErrors.ContainsKey($vmName)) {
                    $global:LASTEXITCODE = 1
                    return (New-AzErrorRecord -Message $script:AssociationErrors[$vmName])
                }
                return
            }

            if ($commandLine -like 'vm extension list *') {
                if ($null -ne $script:RawExtensionJson) {
                    return $script:RawExtensionJson
                }

                $vmName = Get-ArgumentValue -Arguments $arguments -Name '--vm-name'
                $script:ExtensionLists.Add($vmName)
                $agent = Get-NextAgentState -Vm $vmName
                if ($agent -is [hashtable] -and $agent.ContainsKey('Error')) {
                    $global:LASTEXITCODE = 1
                    return (New-AzErrorRecord -Message $agent['Error'])
                }
                return (ConvertTo-ExtensionListJson -Vm $vmName -Agent $agent)
            }

            if ($commandLine -like 'vm extension set *') {
                $vmName = Get-ArgumentValue -Arguments $arguments -Name '--vm-name'
                $script:Installs.Add([pscustomobject]@{
                        Vm           = $vmName
                        Agent        = Get-ArgumentValue -Arguments $arguments -Name '--name'
                        InstanceName = Get-ArgumentValue -Arguments $arguments -Name '--extension-instance-name'
                        Arguments    = $arguments
                    })
                if ($script:InstallErrors.ContainsKey($vmName)) {
                    $global:LASTEXITCODE = 1
                    return (New-AzErrorRecord -Message $script:InstallErrors[$vmName])
                }
                return
            }

            throw "Unexpected az call: $commandLine"
        }
        Mock azd { throw "Unexpected azd call: $($args -join ' ')" }
        Mock Get-AzdEnvValue {
            $script:AzdEnvironments.Add($EnvironmentName)
            [string]$script:AzdValues[$Key]
        }
        Mock Write-Host { $script:HostLines.Add([string]$Object) }
        Mock Write-Warning { $script:Warnings.Add([string]$Message) }
        Mock Start-Sleep { $script:Slept.Add([int]$Seconds) }

        $savedVariables = Save-AzureVariable
        $setup = @{
            ResourceGroupName             = $script:ResourceGroup
            SubscriptionId                = $script:SubscriptionId
            LinuxHostDataCollectionRuleId = $script:LinuxRuleId
            AvdHostDataCollectionRuleId   = $script:AvdRuleId
        }
    }

    AfterEach {
        Restore-AzureVariable -Saved $savedVariables
    }

    It 'connects each Linux host to the Linux rule and each AVD session host to the AVD rule, with the matching agent' {
        Set-TestVm -Vm (New-TestVm -Name 'lnx-0'), (New-TestVm -Name 'avd-0' -Role 'avd-host'), (New-TestVm -Name 'jump-0' -Role ''), (New-TestVm -Name 'sql-0' -Role 'database')

        Invoke-HostMonitoringSetup @setup

        $script:AzCalls[0] | Should -BeExactly "account set --subscription $($script:SubscriptionId)"
        $script:AzCalls[1] | Should -BeExactly "vm list --resource-group $($script:ResourceGroup) --show-details --output json --only-show-errors"

        @($script:Associations | ForEach-Object { $_.Vm }) | Should -Be @('lnx-0', 'avd-0')
        foreach ($association in $script:Associations) {
            $association.Url | Should -BeExactly "$(Get-TestVmId -Name $association.Vm)/providers/Microsoft.Insights/dataCollectionRuleAssociations/linuxbroker-host-monitoring"
            Get-ArgumentValue -Arguments $association.Arguments -Name '--method' | Should -BeExactly 'put'
            Get-ArgumentValue -Arguments $association.Arguments -Name '--url-parameters' | Should -BeExactly 'api-version=2022-06-01'
            Get-ArgumentValue -Arguments $association.Arguments -Name '--output' | Should -BeExactly 'none'
        }
        $script:Associations[0].Body.properties.dataCollectionRuleId | Should -BeExactly $script:LinuxRuleId
        $script:Associations[1].Body.properties.dataCollectionRuleId | Should -BeExactly $script:AvdRuleId

        @($script:Installs | ForEach-Object { '{0} {1}' -f $_.Vm, $_.Agent }) | Should -Be @('lnx-0 AzureMonitorLinuxAgent', 'avd-0 AzureMonitorWindowsAgent')
        foreach ($install in $script:Installs) {
            Get-ArgumentValue -Arguments $install.Arguments -Name '--resource-group' | Should -BeExactly $script:ResourceGroup
            Get-ArgumentValue -Arguments $install.Arguments -Name '--publisher' | Should -BeExactly 'Microsoft.Azure.Monitor'
            Get-ArgumentValue -Arguments $install.Arguments -Name '--enable-auto-upgrade' | Should -BeExactly 'true'
            $install.InstanceName | Should -BeExactly $install.Agent
            $install.Arguments | Should -Contain '--no-wait'
            $install.Arguments | Should -Not -Contain '--force-update'
            $install.Arguments | Should -Not -Contain '--settings'
        }

        @($script:AzCalls | Where-Object { $_ -match 'jump-0|sql-0' }).Count | Should -Be 0
        $script:Slept | Should -Be @(30)
        $script:HostLines | Should -Contain "Installing the Azure Monitor agent on Linux host 'lnx-0'..."
        $script:HostLines | Should -Contain "Linux host 'lnx-0' is connected, with the Azure Monitor agent installed."
        $script:HostLines | Should -Contain "AVD session host 'avd-0' is connected, with the Azure Monitor agent installed."
        $script:HostLines | Should -Contain 'The host monitoring is set up on 2 host(s).'
        $script:Warnings.Count | Should -Be 0
    }

    It 'writes each association to a file without a byte order mark, and deletes the file' {
        Set-TestVm -Vm (New-TestVm -Name 'lnx-0')

        Invoke-HostMonitoringSetup @setup

        $association = $script:Associations[0]
        Get-ArgumentValue -Arguments $association.Arguments -Name '--body' | Should -BeExactly "@$($association.File)"
        Test-Utf8Bom -Bytes $association.Bytes | Should -BeFalse
        $association.Body.properties.description | Should -Not -BeNullOrEmpty
        Test-Path -LiteralPath $association.File | Should -BeFalse
    }

    It 'connects a host that is not running without installing the agent, and names it to run the script again for' {
        Set-TestVm -Vm (New-TestVm -Name 'lnx-0'), (New-TestVm -Name 'lnx-1' -PowerState 'VM deallocated'), (New-TestVm -Name 'avd-0' -Role 'avd-host' -PowerState 'VM stopped')

        Invoke-HostMonitoringSetup @setup

        @($script:Associations | ForEach-Object { $_.Vm }) | Should -Be @('lnx-0', 'lnx-1', 'avd-0')
        @($script:ExtensionLists | Select-Object -Unique) | Should -Be @('lnx-0')
        @($script:Installs | ForEach-Object { $_.Vm }) | Should -Be @('lnx-0')
        $script:Warnings | Should -Contain "Linux host 'lnx-1' is connected, but it is not running (VM deallocated), so it has no Azure Monitor agent and sends no logs yet."
        $script:Warnings | Should -Contain "AVD session host 'avd-0' is connected, but it is not running (VM stopped), so it has no Azure Monitor agent and sends no logs yet."
        $script:Warnings | Should -Contain 'No Azure Monitor agent yet because they are not running: lnx-1, avd-0. Once they are running, run Enable-HostMonitoring.ps1 again with -HostNames lnx-1,avd-0.'
        $script:HostLines | Should -Contain 'The host monitoring is set up on 1 host(s).'
    }

    It 'treats a host whose power state az does not report as running' {
        Set-TestVm -Vm (New-TestVm -Name 'lnx-0' -NoPowerState)

        Invoke-HostMonitoringSetup @setup

        @($script:Installs | ForEach-Object { $_.Vm }) | Should -Be @('lnx-0')
    }

    It 'leaves the agent alone on the hosts that already have it' {
        Set-TestVm -Vm (New-TestVm -Name 'lnx-0'), (New-TestVm -Name 'avd-0' -Role 'avd-host')
        Set-AgentState -Vm 'lnx-0' -State 'Succeeded'
        Set-AgentState -Vm 'avd-0' -State 'Succeeded'

        Invoke-HostMonitoringSetup @setup

        @($script:Associations | ForEach-Object { $_.Vm }) | Should -Be @('lnx-0', 'avd-0')
        $script:Installs.Count | Should -Be 0
        $script:Slept.Count | Should -Be 0
        $script:HostLines | Should -Contain "Linux host 'lnx-0' is connected, and already has the Azure Monitor agent."
        $script:HostLines | Should -Contain "AVD session host 'avd-0' is connected, and already has the Azure Monitor agent."
        $script:HostLines | Should -Contain 'The host monitoring is set up on 2 host(s).'
    }

    It 'waits for an install that is <State> instead of starting another' -TestCases @(
        @{ State = 'Creating' }
        @{ State = 'Updating' }
    ) {
        Set-TestVm -Vm (New-TestVm -Name 'lnx-0')
        Set-AgentState -Vm 'lnx-0' -State $State, $State, 'Succeeded'

        Invoke-HostMonitoringSetup @setup

        $script:Installs.Count | Should -Be 0
        $script:Slept | Should -Be @(30, 30)
        $script:HostLines | Should -Contain "Linux host 'lnx-0' is connected, with the Azure Monitor agent installed."
    }

    It 'installs the agent again, forced, where an earlier install failed' {
        Set-TestVm -Vm (New-TestVm -Name 'lnx-0')
        Set-AgentState -Vm 'lnx-0' -State 'Failed', 'Succeeded'

        Invoke-HostMonitoringSetup @setup

        $script:Installs.Count | Should -Be 1
        $script:Installs[0].InstanceName | Should -BeExactly 'AzureMonitorLinuxAgent'
        $script:Installs[0].Arguments | Should -Contain '--force-update'
        $script:HostLines | Should -Contain 'The host monitoring is set up on 1 host(s).'
    }

    It 'recognises the agent installed under another name, and installs it again under that name' {
        Set-TestVm -Vm (New-TestVm -Name 'lnx-0'), (New-TestVm -Name 'avd-0' -Role 'avd-host')
        Set-AgentState -Vm 'lnx-0' -State @{ State = 'Succeeded'; Name = 'AMALinux' }
        Set-AgentState -Vm 'avd-0' -State @{ State = 'Failed'; Name = 'AzureMonitorWindowsAgent-policy' }, 'Succeeded'

        Invoke-HostMonitoringSetup @setup

        $script:Installs.Count | Should -Be 1
        $script:Installs[0].Vm | Should -BeExactly 'avd-0'
        $script:Installs[0].Agent | Should -BeExactly 'AzureMonitorWindowsAgent'
        $script:Installs[0].InstanceName | Should -BeExactly 'AzureMonitorWindowsAgent-policy'
        $script:Installs[0].Arguments | Should -Contain '--force-update'
        $script:HostLines | Should -Contain "Linux host 'lnx-0' is connected, and already has the Azure Monitor agent."
    }

    It 'reports a host whose agent fails to install, after it sets up the others' {
        Set-TestVm -Vm (New-TestVm -Name 'lnx-0'), (New-TestVm -Name 'lnx-1')
        Set-AgentState -Vm 'lnx-0' -State '', 'Failed'

        { Invoke-HostMonitoringSetup @setup } |
            Should -Throw 'The host monitoring could not be set up on: lnx-0. Run Enable-HostMonitoring.ps1 again with -HostNames lnx-0 to retry them.'

        $script:Warnings | Should -Contain "The Azure Monitor agent failed to install on Linux host 'lnx-0'. The AzureMonitorLinuxAgent extension's status on the VM says why."
        $script:HostLines | Should -Contain "Linux host 'lnx-1' is connected, with the Azure Monitor agent installed."
    }

    It 'stops waiting for an install at the time limit, and reports the host' {
        Set-TestVm -Vm (New-TestVm -Name 'lnx-0')
        Set-AgentState -Vm 'lnx-0' -State '', 'Creating'

        { Invoke-HostMonitoringSetup @setup -AgentTimeoutMinutes 1 } |
            Should -Throw 'The host monitoring could not be set up on: lnx-0. *'

        $script:Slept | Should -Be @(30, 30)
        $script:Warnings | Should -Contain "The Azure Monitor agent install on Linux host 'lnx-0' did not finish within 1 minute(s)."
    }

    It 'waits 20 minutes for the installs by default' {
        Set-TestVm -Vm (New-TestVm -Name 'lnx-0')
        Set-AgentState -Vm 'lnx-0' -State '', 'Creating'

        { Invoke-HostMonitoringSetup @setup } | Should -Throw

        $script:Slept.Count | Should -Be 40
        $script:Warnings | Should -Contain "The Azure Monitor agent install on Linux host 'lnx-0' did not finish within 20 minute(s)."
    }

    It 'keeps going when it cannot connect a host, and reports the host' {
        Set-TestVm -Vm (New-TestVm -Name 'lnx-0'), (New-TestVm -Name 'lnx-1')
        $script:AssociationErrors['lnx-0'] = "ERROR: (AuthorizationFailed) The client does not have authorization to perform action 'Microsoft.Insights/dataCollectionRuleAssociations/write'."

        { Invoke-HostMonitoringSetup @setup } |
            Should -Throw 'The host monitoring could not be set up on: lnx-0. Run Enable-HostMonitoring.ps1 again with -HostNames lnx-0 to retry them.'

        $script:Warnings | Should -Contain "Could not connect Linux host 'lnx-0' to the host monitoring: Could not associate the data collection rule. $($script:AssociationErrors['lnx-0'])"
        Test-Path -LiteralPath $script:Associations[0].File | Should -BeFalse
        @($script:ExtensionLists | Select-Object -Unique) | Should -Be @('lnx-1')
        $script:HostLines | Should -Contain "Linux host 'lnx-1' is connected, with the Azure Monitor agent installed."
    }

    It 'keeps going when an agent install cannot start, and reports the host' {
        Set-TestVm -Vm (New-TestVm -Name 'avd-0' -Role 'avd-host'), (New-TestVm -Name 'lnx-0')
        $script:InstallErrors['avd-0'] = "ERROR: (OperationNotAllowed) Operation 'PUT' is not allowed on VM 'avd-0' since the VM is deallocated or marked to be deallocated."

        { Invoke-HostMonitoringSetup @setup } |
            Should -Throw 'The host monitoring could not be set up on: avd-0. *'

        $script:Warnings | Should -Contain "Could not install the Azure Monitor agent on AVD session host 'avd-0': Could not start installing the Azure Monitor agent. $($script:InstallErrors['avd-0'])"
        $script:HostLines | Should -Contain "Linux host 'lnx-0' is connected, with the Azure Monitor agent installed."
    }

    It 'tries again at the next poll when it cannot read the extensions of a host it is waiting for' {
        Set-TestVm -Vm (New-TestVm -Name 'lnx-0')
        Set-AgentState -Vm 'lnx-0' -State '', @{ Error = 'ERROR: The request timed out.' }, 'Succeeded'

        Invoke-HostMonitoringSetup @setup

        $script:Slept | Should -Be @(30, 30)
        $script:HostLines | Should -Contain 'The host monitoring is set up on 1 host(s).'
    }

    It 'reports a host whose extensions it cannot read before the install' {
        Set-TestVm -Vm (New-TestVm -Name 'lnx-0')
        Set-AgentState -Vm 'lnx-0' -State @{ Error = 'ERROR: The request timed out.' }

        { Invoke-HostMonitoringSetup @setup } |
            Should -Throw 'The host monitoring could not be set up on: lnx-0. *'

        $script:Warnings | Should -Contain "Could not install the Azure Monitor agent on Linux host 'lnx-0': Could not list the extensions of 'lnx-0'. ERROR: The request timed out."
        $script:Installs.Count | Should -Be 0
    }

    It 'sets up only the hosts -HostNames names, ignoring case, and warns about the names that are not hosts' {
        Set-TestVm -Vm (New-TestVm -Name 'lnx-0'), (New-TestVm -Name 'lnx-1'), (New-TestVm -Name 'avd-0' -Role 'avd-host'), (New-TestVm -Name 'jump-0' -Role '')

        Invoke-HostMonitoringSetup @setup -HostNames 'LNX-1', 'avd-0', 'jump-0', 'lnx-9', ' '

        @($script:Associations | ForEach-Object { $_.Vm }) | Should -Be @('lnx-1', 'avd-0')
        @($script:Installs | ForEach-Object { $_.Vm }) | Should -Be @('lnx-1', 'avd-0')
        $script:Warnings | Should -Contain "Requested host 'jump-0' is not a Linux host or AVD session host in resource group '$($script:ResourceGroup)'."
        $script:Warnings | Should -Contain "Requested host 'lnx-9' is not a Linux host or AVD session host in resource group '$($script:ResourceGroup)'."
        $script:Warnings.Count | Should -Be 2
    }

    It 'says so when the resource group has no hosts to connect' {
        Set-TestVm -Vm (New-TestVm -Name 'jump-0' -Role '')

        Invoke-HostMonitoringSetup @setup

        $script:Associations.Count | Should -Be 0
        $script:HostLines | Should -Contain "No Linux hosts or AVD session hosts to connect to the host monitoring in resource group '$($script:ResourceGroup)'."
    }

    It 'changes nothing when the deployment has no host monitoring' {
        $setup.Remove('LinuxHostDataCollectionRuleId')
        $setup.Remove('AvdHostDataCollectionRuleId')
        $env:AZURE_ENV_NAME = 'dev'

        Invoke-HostMonitoringSetup @setup

        $script:AzCalls.Count | Should -Be 0
        @($script:AzdEnvironments | Select-Object -Unique) | Should -Be @('dev')
        $script:HostLines | Should -Contain 'This deployment has no host monitoring, so there is nothing to connect: deployHostMonitoring is false, or azd provision has not run since the monitoring was added.'
    }

    It 'leaves alone the hosts whose rule it does not know' {
        $setup.Remove('AvdHostDataCollectionRuleId')
        Set-TestVm -Vm (New-TestVm -Name 'lnx-0'), (New-TestVm -Name 'avd-0' -Role 'avd-host')

        Invoke-HostMonitoringSetup @setup

        @($script:Associations | ForEach-Object { $_.Vm }) | Should -Be @('lnx-0')
        @($script:AzCalls | Where-Object { $_ -match 'avd-0' }).Count | Should -Be 0
    }

    It 'refuses <Case> as the <Parameter> before it changes anything' -TestCases @(
        @{ Parameter = 'LinuxHostDataCollectionRuleId'; Case = 'a Log Analytics workspace'; Value = '/subscriptions/6d1e0f3c-2b4a-4c5d-8e9f-0a1b2c3d4e5f/resourceGroups/rg-linuxbroker-dev/providers/Microsoft.OperationalInsights/workspaces/log-linuxbroker-dev' }
        @{ Parameter = 'LinuxHostDataCollectionRuleId'; Case = 'a rule name'; Value = 'linuxbroker-dev-linux-hosts' }
        @{ Parameter = 'LinuxHostDataCollectionRuleId'; Case = 'a subscription name'; Value = '/subscriptions/dev/resourceGroups/rg-linuxbroker-dev/providers/Microsoft.Insights/dataCollectionRules/linuxbroker-dev-linux-hosts' }
        @{ Parameter = 'AvdHostDataCollectionRuleId'; Case = 'a path below a rule'; Value = '/subscriptions/6d1e0f3c-2b4a-4c5d-8e9f-0a1b2c3d4e5f/resourceGroups/rg-linuxbroker-dev/providers/Microsoft.Insights/dataCollectionRules/linuxbroker-dev-avd-hosts/associations' }
    ) {
        $setup[$Parameter] = $Value

        { Invoke-HostMonitoringSetup @setup } |
            Should -Throw "'$Value' is not the resource ID of a data collection rule, such as /subscriptions/<subscription-id>/resourceGroups/<resource-group>/providers/Microsoft.Insights/dataCollectionRules/<name>."

        $script:AzCalls.Count | Should -Be 0
    }

    It 'reads the rules, the resource group and the subscription from the azd environment that <Variable> names' -TestCases @(
        @{ Variable = 'AZURE_ENV_NAME' }
        @{ Variable = 'AZURE_ENVIRONMENT_NAME' }
    ) {
        [Environment]::SetEnvironmentVariable($Variable, 'dev', 'Process')
        $script:AzdValues = @{
            resourceGroupName             = $script:ResourceGroup
            AZURE_SUBSCRIPTION_ID         = $script:SubscriptionId
            linuxHostDataCollectionRuleId = $script:LinuxRuleId
            avdHostDataCollectionRuleId   = $script:AvdRuleId
        }
        Set-TestVm -Vm (New-TestVm -Name 'lnx-0'), (New-TestVm -Name 'avd-0' -Role 'avd-host')

        Invoke-HostMonitoringSetup

        @($script:AzdEnvironments | Select-Object -Unique) | Should -Be @('dev')
        $script:AzCalls[0] | Should -BeExactly "account set --subscription $($script:SubscriptionId)"
        $script:AzCalls[1] | Should -BeExactly "vm list --resource-group $($script:ResourceGroup) --show-details --output json --only-show-errors"
        $script:Associations[0].Body.properties.dataCollectionRuleId | Should -BeExactly $script:LinuxRuleId
        $script:Associations[1].Body.properties.dataCollectionRuleId | Should -BeExactly $script:AvdRuleId
    }

    It 'selects the subscription in AZURE_SUBSCRIPTION_ID when the azd environment has none' {
        $setup.Remove('SubscriptionId')
        $env:AZURE_SUBSCRIPTION_ID = $script:SubscriptionId

        Invoke-HostMonitoringSetup @setup

        $script:AzCalls[0] | Should -BeExactly "account set --subscription $($script:SubscriptionId)"
    }

    It 'keeps the current subscription when it does not know one' {
        $setup.Remove('SubscriptionId')

        Invoke-HostMonitoringSetup @setup

        $script:AzCalls[0] | Should -Match '^vm list '
    }

    It 'stops when it does not know the resource group' {
        $setup.Remove('ResourceGroupName')

        { Invoke-HostMonitoringSetup @setup } |
            Should -Throw 'The host monitoring setup needs ResourceGroupName, as a parameter or an azd environment value.'
        $script:AzCalls.Count | Should -Be 0
    }

    It 'stops when it cannot select the subscription' {
        $script:AccountSetExitCode = 1

        { Invoke-HostMonitoringSetup @setup } | Should -Throw "Could not select subscription '$($script:SubscriptionId)'."
        $script:AzCalls.Count | Should -Be 1
    }

    It 'stops when it cannot list the VMs' {
        $script:VmListExitCode = 1

        { Invoke-HostMonitoringSetup @setup } |
            Should -Throw "Could not list the VMs in resource group '$($script:ResourceGroup)'. ERROR: (ResourceGroupNotFound) Resource group '$($script:ResourceGroup)' could not be found."
        $script:Associations.Count | Should -Be 0
    }

    Context 'Finding the agent among the extensions az lists' {
        It 'finds the agent <Case>' -TestCases @(
            @{ Case = 'by its type, which older versions of az call virtualMachineExtensionType'; Expected = 'AMALinux Succeeded'; Json = '[{"name":"AMALinux","publisher":"Microsoft.Azure.Monitor","virtualMachineExtensionType":"AzureMonitorLinuxAgent","provisioningState":"Succeeded"}]' }
            @{ Case = 'in a nested properties object, below the resource type'; Expected = 'AMALinux Creating'; Json = '[{"name":"AMALinux","type":"Microsoft.Compute/virtualMachines/extensions","properties":{"publisher":"Microsoft.Azure.Monitor","type":"AzureMonitorLinuxAgent","provisioningState":"Creating"}}]' }
            @{ Case = 'by its name'; Expected = 'AzureMonitorLinuxAgent Failed'; Json = '[{"name":"AzureMonitorLinuxAgent","provisioningState":"Failed"}]' }
        ) {
            $script:RawExtensionJson = $Json

            $extension = Get-AgentExtension -ResourceGroupName $script:ResourceGroup -VmName 'lnx-0' -AgentName 'AzureMonitorLinuxAgent'

            '{0} {1}' -f $extension.Name, $extension.ProvisioningState | Should -BeExactly $Expected
        }

        It 'does not take <Case> for the agent' -TestCases @(
            @{ Case = 'an extension of the same type from another publisher'; Json = '[{"name":"imitation","publisher":"Contoso.Monitoring","typePropertiesType":"AzureMonitorLinuxAgent","provisioningState":"Succeeded"}]' }
            @{ Case = 'the agent for the other operating system'; Json = '[{"name":"AzureMonitorWindowsAgent","publisher":"Microsoft.Azure.Monitor","typePropertiesType":"AzureMonitorWindowsAgent","provisioningState":"Succeeded"}]' }
            @{ Case = 'an empty list'; Json = '[]' }
            @{ Case = 'no output'; Json = '' }
        ) {
            $script:RawExtensionJson = $Json

            Get-AgentExtension -ResourceGroupName $script:ResourceGroup -VmName 'lnx-0' -AgentName 'AzureMonitorLinuxAgent' | Should -BeNullOrEmpty
        }
    }
}

Describe 'The deployment outputs the script reads' {
    It 'finds both rule IDs among the outputs of main.bicep, under the names it reads them by' {
        $scriptText = [System.IO.File]::ReadAllText($script:MonitoringScriptPath)
        $main = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot 'deploy\bicep\main.bicep'))
        $resources = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot 'deploy\bicep\main.resources.bicep'))

        foreach ($name in 'linuxHostDataCollectionRuleId', 'avdHostDataCollectionRuleId') {
            $scriptText | Should -Match ([regex]::Escape("-Key '$name'"))
            $main | Should -Match ('(?m)^output {0} string = resources\.outputs\.{0}\s*$' -f $name)
            $resources | Should -Match ('(?m)^output {0} string = deployHostMonitoring \? hostMonitoring!\.outputs\.{0} : ''''\s*$' -f $name)
        }
    }
}

Describe 'Enable-HostMonitoring.ps1 in a PowerShell process of its own' {
    BeforeAll {
        # Stand-ins for az and azd, found first on PATH. The az one records each call and answers
        # as az does for one running Linux host that has no agent until the install starts.
        $script:FakeAz = @'
@echo off
>>"%~dp0calls.log" echo %*
if "%1"=="fail" (
  echo ERROR: The client does not have authorization to perform this action. 1>&2
  exit /b 1
)
if "%1"=="warn" (
  echo WARNING: This command is in preview. 1>&2
  echo {"ok": true}
  exit /b 0
)
if "%1 %2"=="account set" exit /b 0
if "%1 %2"=="vm list" (
  type "%~dp0vms.json"
  exit /b 0
)
if "%1"=="rest" exit /b 0
if "%1 %2 %3"=="vm extension set" (
  type nul > "%~dp0installed.flag"
  exit /b 0
)
if "%1 %2 %3"=="vm extension list" (
  if exist "%~dp0installed.flag" (
    type "%~dp0extensions.json"
  ) else (
    echo []
  )
  exit /b 0
)
echo ERROR: unexpected az call 1>&2
exit /b 1
'@
        $script:FakeAzd = @'
@echo off
if "%3"=="missing" (
  echo ERROR: key 'missing' not found in the environment values 1>&2
  exit /b 1
)
echo rg-linuxbroker-dev
exit /b 0
'@

        function New-FakeCliFolder {
            $folder = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $folder | Out-Null
            # cmd.exe reads batch files with CRLF line endings.
            [System.IO.File]::WriteAllText((Join-Path $folder 'az.cmd'), ($script:FakeAz -replace "`r?`n", "`r`n"))
            [System.IO.File]::WriteAllText((Join-Path $folder 'azd.cmd'), ($script:FakeAzd -replace "`r?`n", "`r`n"))
            [System.IO.File]::WriteAllText((Join-Path $folder 'vms.json'), (ConvertTo-Json -InputObject @(New-TestVm -Name 'lnx-0') -Depth 5), $script:Utf8NoBom)
            [System.IO.File]::WriteAllText((Join-Path $folder 'extensions.json'), '[{"name":"AzureMonitorLinuxAgent","publisher":"Microsoft.Azure.Monitor","type":"Microsoft.Compute/virtualMachines/extensions","typePropertiesType":"AzureMonitorLinuxAgent","provisioningState":"Succeeded"}]', $script:Utf8NoBom)
            return $folder
        }

        function Get-ShellPath {
            param([string]$Shell)

            if ($Shell -eq 'Windows PowerShell') {
                return $script:WindowsPowerShell
            }
            $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
            if ($pwsh) {
                return $pwsh.Source
            }
            return $null
        }
    }

    It 'keeps what az and azd write to stderr from stopping it, in <Shell>' -TestCases @(
        @{ Shell = 'Windows PowerShell' }
        @{ Shell = 'PowerShell 7' }
    ) {
        $shellPath = Get-ShellPath -Shell $Shell
        if (-not $shellPath) {
            Set-ItResult -Skipped -Because 'PowerShell 7 is not installed.'
            return
        }
        $folder = New-FakeCliFolder
        $harnessPath = Join-Path $folder 'harness.ps1'
        $harness = @'
$env:PATH = __FOLDER__ + ';' + $env:PATH
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. __SCRIPT__
$failed = Invoke-AzCommand -Arguments @('fail')
$warned = Invoke-AzCommand -Arguments @('warn')
Write-Output ('failed={0}|{1}|{2}' -f $failed.ExitCode, $failed.Output, $failed.Error)
Write-Output ('warned={0}|{1}|{2}' -f $warned.ExitCode, $warned.Output, $warned.Error)
Write-Output ('missing=[{0}]' -f (Get-AzdEnvValue -EnvironmentName 'dev' -Key 'missing'))
Write-Output ('present=[{0}]' -f (Get-AzdEnvValue -EnvironmentName 'dev' -Key 'resourceGroupName'))
'@
        $harness = $harness.Replace('__FOLDER__', (ConvertTo-TestLiteral -Value $folder)).Replace('__SCRIPT__', (ConvertTo-TestLiteral -Value $script:MonitoringScriptPath))
        [System.IO.File]::WriteAllText($harnessPath, $harness, $script:Utf8NoBom)

        $result = Invoke-ChildProcess -FilePath $shellPath -ScriptPath $harnessPath

        $result.StdErr | Should -BeNullOrEmpty
        $result.ExitCode | Should -Be 0
        @($result.StdOut.Trim() -split "`r?`n") | Should -Be @(
            'failed=1||ERROR: The client does not have authorization to perform this action.',
            'warned=0|{"ok": true}|WARNING: This command is in preview.',
            'missing=[]',
            'present=[rg-linuxbroker-dev]')
    }

    It 'connects a host and installs its agent when it is run as a script in <Shell>' -TestCases @(
        @{ Shell = 'Windows PowerShell' }
        @{ Shell = 'PowerShell 7' }
    ) {
        $shellPath = Get-ShellPath -Shell $Shell
        if (-not $shellPath) {
            Set-ItResult -Skipped -Because 'PowerShell 7 is not installed.'
            return
        }
        $folder = New-FakeCliFolder
        $harnessPath = Join-Path $folder 'harness.ps1'
        $harness = @'
$env:PATH = __FOLDER__ + ';' + $env:PATH
foreach ($name in 'AZURE_ENV_NAME', 'AZURE_ENVIRONMENT_NAME', 'AZURE_SUBSCRIPTION_ID') {
    [Environment]::SetEnvironmentVariable($name, $null, 'Process')
}
function Start-Sleep { param([int]$Seconds) Write-Output "TEST: Start-Sleep $Seconds" }
try {
    & __SCRIPT__ -ResourceGroupName __RESOURCE_GROUP__ -SubscriptionId __SUBSCRIPTION__ -LinuxHostDataCollectionRuleId __LINUX_RULE__ -AvdHostDataCollectionRuleId __AVD_RULE__
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
'@
        $harness = $harness.Replace('__FOLDER__', (ConvertTo-TestLiteral -Value $folder)).
            Replace('__SCRIPT__', (ConvertTo-TestLiteral -Value $script:MonitoringScriptPath)).
            Replace('__RESOURCE_GROUP__', (ConvertTo-TestLiteral -Value $script:ResourceGroup)).
            Replace('__SUBSCRIPTION__', (ConvertTo-TestLiteral -Value $script:SubscriptionId)).
            Replace('__LINUX_RULE__', (ConvertTo-TestLiteral -Value $script:LinuxRuleId)).
            Replace('__AVD_RULE__', (ConvertTo-TestLiteral -Value $script:AvdRuleId))
        [System.IO.File]::WriteAllText($harnessPath, $harness, $script:Utf8NoBom)

        $result = Invoke-ChildProcess -FilePath $shellPath -ScriptPath $harnessPath

        $result.StdErr | Should -BeNullOrEmpty
        $result.ExitCode | Should -Be 0
        $result.StdOut | Should -Match ([regex]::Escape('TEST: Start-Sleep 30'))
        $result.StdOut | Should -Match ([regex]::Escape('The host monitoring is set up on 1 host(s).'))

        $calls = @(Get-Content -LiteralPath (Join-Path $folder 'calls.log') | ForEach-Object { $_.Trim() })
        $calls.Count | Should -Be 6
        $calls[0] | Should -BeExactly "account set --subscription $($script:SubscriptionId)"
        $calls[1] | Should -BeExactly "vm list --resource-group $($script:ResourceGroup) --show-details --output json --only-show-errors"
        $association = [regex]::Match($calls[2], '^rest --method put --url (\S+) --url-parameters api-version=2022-06-01 --body "?@([^"]+?)"? --output none --only-show-errors$')
        $association.Success | Should -BeTrue
        $association.Groups[1].Value | Should -BeExactly "$(Get-TestVmId -Name 'lnx-0')/providers/Microsoft.Insights/dataCollectionRuleAssociations/linuxbroker-host-monitoring"
        Test-Path -LiteralPath $association.Groups[2].Value | Should -BeFalse
        $calls[3] | Should -BeExactly "vm extension list --resource-group $($script:ResourceGroup) --vm-name lnx-0 --output json --only-show-errors"
        $calls[4] | Should -BeExactly "vm extension set --resource-group $($script:ResourceGroup) --vm-name lnx-0 --name AzureMonitorLinuxAgent --publisher Microsoft.Azure.Monitor --extension-instance-name AzureMonitorLinuxAgent --enable-auto-upgrade true --no-wait --output none --only-show-errors"
        $calls[5] | Should -BeExactly $calls[3]
    }
}

Describe 'Post-Provision.ps1' {
    BeforeAll {
        $script:ProvisionFolder = Join-Path $TestDrive 'deploy'
        New-Item -ItemType Directory -Path $script:ProvisionFolder | Out-Null
        Copy-Item -LiteralPath (Join-Path $script:RepoRoot 'deploy\Post-Provision.ps1') -Destination $script:ProvisionFolder
        $script:ProvisionPath = Join-Path $script:ProvisionFolder 'Post-Provision.ps1'
        $script:StepLog = Join-Path $script:ProvisionFolder 'steps.log'

        # Each step records how it was run, and fails when LINUXBROKER_TEST_FAILING_STEPS names it.
        $stub = @'
$step = [System.IO.Path]::GetFileNameWithoutExtension($MyInvocation.MyCommand.Path)
$arguments = @($args | ForEach-Object { [string]$_ })
Add-Content -LiteralPath (Join-Path $PSScriptRoot 'steps.log') -Value ('{0} {1}' -f $step, ($arguments -join ' '))
if (@([string]$env:LINUXBROKER_TEST_FAILING_STEPS -split ',') -contains $step) {
    throw "$step failed on lnx-0."
}
'@
        $script:ProvisionSteps = @('Assign-FunctionAppApiRole', 'Initialize-Database', 'Build-ContainerImages', 'Assign-VmApiRoles', 'Register-LinuxHostSqlRecords', 'Enable-HostMonitoring')
        foreach ($step in $script:ProvisionSteps) {
            [System.IO.File]::WriteAllText((Join-Path $script:ProvisionFolder "$step.ps1"), $stub)
        }

        function Get-StepLog {
            if (-not (Test-Path -LiteralPath $script:StepLog)) {
                return @()
            }
            return @(Get-Content -LiteralPath $script:StepLog)
        }
    }

    BeforeEach {
        Remove-Item -LiteralPath $script:StepLog -ErrorAction SilentlyContinue
        # Not $script: variables: in a mock that Post-Provision.ps1 calls, $script: is that
        # script's scope. These are found through the scopes that called it.
        $warnings = New-Object System.Collections.Generic.List[string]
        Mock Write-Warning { $warnings.Add([string]$Message) }
        Mock az {
            if (($args -join ' ') -notlike 'account set *') {
                throw "Unexpected az call: $($args -join ' ')"
            }
            $global:LASTEXITCODE = 0
        }
        # The azd environment has no graphEndpoint.
        Mock azd { $global:LASTEXITCODE = 1 }

        $savedVariables = Save-AzureVariable
        $savedFailingSteps = $env:LINUXBROKER_TEST_FAILING_STEPS
        $env:LINUXBROKER_TEST_FAILING_STEPS = $null
        $provision = @{
            ResourceGroupName = $script:ResourceGroup
            SubscriptionId    = $script:SubscriptionId
            EnvironmentName   = 'dev'
            TaskAppName       = 'func-linuxbroker-dev-task'
            ApiClientId       = '0b5a9c3e-6f1d-4a2b-9c8e-7d6f5e4a3b21'
            SqlServerFqdn     = 'sql-linuxbroker-dev.database.windows.net'
            DatabaseName      = 'linuxbroker'
            SqlAdminLogin     = 'sqladmin'
            SqlAdminPassword  = 'not-a-real-password'
            AvdHostGroupId    = '3f2c1b0a-9e8d-4c7b-a6f5-e4d3c2b1a098'
            LinuxHostGroupId  = '7a6b5c4d-3e2f-4a1b-9c8d-7e6f5a4b3c21'
        }
    }

    AfterEach {
        Restore-AzureVariable -Saved $savedVariables
        $env:LINUXBROKER_TEST_FAILING_STEPS = $savedFailingSteps
    }

    It 'connects the hosts to the host monitoring last, in the resource group, subscription and environment it provisioned' {
        & $script:ProvisionPath @provision

        $steps = Get-StepLog
        @($steps | ForEach-Object { ($_ -split ' ')[0] }) | Should -Be $script:ProvisionSteps
        $steps[-1] | Should -BeExactly "Enable-HostMonitoring -ResourceGroupName $($script:ResourceGroup) -SubscriptionId $($script:SubscriptionId) -EnvironmentName dev"
        $warnings.Count | Should -Be 0
    }

    It 'warns, rather than failing the deployment, when the host monitoring cannot be fully set up' {
        $env:LINUXBROKER_TEST_FAILING_STEPS = 'Enable-HostMonitoring'

        { & $script:ProvisionPath @provision } | Should -Not -Throw

        $warnings | Should -Contain 'The deployment is in place, but the host monitoring is not fully set up. Enable-HostMonitoring failed on lnx-0.'
    }

    It 'still stops at a step that fails before the host monitoring' {
        $env:LINUXBROKER_TEST_FAILING_STEPS = 'Register-LinuxHostSqlRecords'

        { & $script:ProvisionPath @provision } | Should -Throw 'Register-LinuxHostSqlRecords failed on lnx-0.'

        @(Get-StepLog | ForEach-Object { ($_ -split ' ')[0] }) | Should -Not -Contain 'Enable-HostMonitoring'
    }
}
