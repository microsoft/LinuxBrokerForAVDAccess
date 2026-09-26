# Pester 5 tests for deploy/Update-AvdHostBrokerScript.ps1, which replaces Connect-LinuxBroker.ps1
# on the existing AVD session hosts through Run Command, and for how
# deploy/Migrate-ExistingEnvironment.ps1 runs it. From the repository root, in Windows PowerShell:
#   Invoke-Pester -Path avd_host/tests

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $script:UpdateScriptPath = Join-Path $script:RepoRoot 'deploy\Update-AvdHostBrokerScript.ps1'
    $script:BrokerScriptPath = Join-Path $script:RepoRoot 'avd_host\broker\Connect-LinuxBroker.ps1'
    . $script:UpdateScriptPath

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
    $script:ApiUrl = 'https://app-linuxbroker-api.azurewebsites.net/api'
    $script:ClientId = '0b5a9c3e-6f1d-4a2b-9c8e-7d6f5e4a3b21'
    $script:DefaultSourceUrl = 'https://raw.githubusercontent.com/microsoft/LinuxBrokerForAVDAccess/refs/heads/main/avd_host/broker/Connect-LinuxBroker.ps1'
    $script:BrokerScriptVersion = [regex]::Match([System.IO.File]::ReadAllText($script:BrokerScriptPath), '(?m)^\$ScriptVersion = ''([^'']+)''').Groups[1].Value
    $script:WindowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $script:Utf8NoBom = New-Object System.Text.UTF8Encoding -ArgumentList $false
    $script:AzureVariables = @('AZURE_ENV_NAME', 'AZURE_ENVIRONMENT_NAME', 'AZURE_SUBSCRIPTION_ID')

    function New-TestVm {
        param(
            [Parameter(Mandatory = $true)]
            [string]$Name,

            $Tags = @{ 'broker-role' = 'avd-host' },

            [string]$PowerState = 'VM running',

            [switch]$NoPowerState
        )

        $vm = [ordered]@{ name = $Name; resourceGroup = $script:ResourceGroup; tags = $Tags }
        if (-not $NoPowerState) {
            $vm['powerState'] = $PowerState
        }
        return [pscustomobject]$vm
    }

    function Set-TestVm {
        param([object[]]$Vm)

        $script:VmListJson = ConvertTo-Json -InputObject @($Vm) -Depth 5
    }

    function ConvertTo-RunCommandJson {
        param(
            [AllowEmptyString()]
            [string]$StdOut = '',

            [AllowEmptyString()]
            [string]$StdErr = ''
        )

        return ConvertTo-Json -Depth 5 -InputObject ([ordered]@{
                value = @(
                    [ordered]@{ code = 'ComponentStatus/StdOut/succeeded'; displayStatus = 'Provisioning succeeded'; level = 'Info'; message = $StdOut },
                    [ordered]@{ code = 'ComponentStatus/StdErr/succeeded'; displayStatus = 'Provisioning succeeded'; level = 'Info'; message = $StdErr }
                )
            })
    }

    # Queues what Run Command answers on a VM, one entry per call: @{ StdOut; StdErr } for a run,
    # @{ Error } for az failing, or @{ Raw } for output that is not JSON. A VM with nothing queued
    # reports a completed update.
    function Add-RunCommandOutcome {
        param(
            [Parameter(Mandatory = $true)]
            [string]$Vm,

            [Parameter(Mandatory = $true)]
            [hashtable[]]$Outcome
        )

        if (-not $script:RunCommandOutcomes.ContainsKey($Vm)) {
            $script:RunCommandOutcomes[$Vm] = New-Object System.Collections.Queue
        }
        foreach ($entry in $Outcome) {
            $script:RunCommandOutcomes[$Vm].Enqueue($entry)
        }
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

    # The value a top-level assignment in the session host's update script gives a variable.
    function Get-PayloadValue {
        param(
            [Parameter(Mandatory = $true)]
            [string]$Payload,

            [Parameter(Mandatory = $true)]
            [string]$Name
        )

        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($Payload, [ref]$null, [ref]$parseErrors)
        $assignment = $ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                $node.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
                $node.Left.VariablePath.UserPath -eq $Name
            }, $false)
        if ($null -eq $assignment) {
            return $null
        }
        return $assignment.Right.Expression.Value
    }

    function Test-Utf8Bom {
        param([byte[]]$Bytes)

        return ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF)
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

    # Runs the script Run Command would run on a session host, in Windows PowerShell as Run Command
    # does, with the destination in the test drive. The stubs keep it from registering an event
    # source on the machine running the tests and from waiting between attempts, and a failure is
    # reported on one line, as Run Command returns it.
    function Invoke-HostUpdate {
        param(
            [Parameter(Mandatory = $true)]
            [string]$SourceUrl,

            [Parameter(Mandatory = $true)]
            [string]$Destination
        )

        $folder = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $folder | Out-Null
        $payloadPath = Join-Path $folder 'payload.ps1'
        $harnessPath = Join-Path $folder 'harness.ps1'

        $payload = Get-AvdHostUpdateScript -SourceUrl $SourceUrl -ApiBaseUrl $script:ApiUrl -ApiClientId $script:ClientId -Destination $Destination
        [System.IO.File]::WriteAllText($payloadPath, $payload, $script:Utf8NoBom)
        $harness = @'
function New-EventLog { param($LogName, $Source) Write-Output "TEST: New-EventLog $LogName $Source" }
function Start-Sleep { param($Seconds) Write-Output "TEST: Start-Sleep $Seconds" }
try {
    . __PAYLOAD__
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
'@
        [System.IO.File]::WriteAllText($harnessPath, $harness.Replace('__PAYLOAD__', (ConvertTo-PowerShellLiteral -Value $payloadPath)), $script:Utf8NoBom)

        return Invoke-ChildProcess -FilePath $script:WindowsPowerShell -ScriptPath $harnessPath
    }

    function New-InstalledScript {
        param([string]$Content = "# Connect-LinuxBroker.ps1 from an earlier release`r`n")

        $destination = Join-Path $TestDrive ('{0}\Connect-LinuxBroker.ps1' -f [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Split-Path -Parent $destination) | Out-Null
        [System.IO.File]::WriteAllText($destination, $Content)
        return $destination
    }

    function Get-FolderEntry {
        param([string]$Path)

        return @(Get-ChildItem -LiteralPath (Split-Path -Parent $Path) -Force | ForEach-Object { $_.Name })
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

Describe 'ConvertTo-PowerShellLiteral' {
    It 'doubles single quotes, including the curly ones PowerShell also ends a string at' {
        ConvertTo-PowerShellLiteral -Value "it's" | Should -BeExactly "'it''s'"
        $curly = [string][char]0x2019
        ConvertTo-PowerShellLiteral -Value "it$($curly)s" | Should -BeExactly "'it$curly$($curly)s'"
        ConvertTo-PowerShellLiteral -Value '' | Should -BeExactly "''"
    }
}

Describe 'Test-SafeHttpsUrl' {
    It 'accepts <Value>' -TestCases @(
        @{ Value = 'https://app-linuxbroker-api.azurewebsites.net/api' }
        @{ Value = 'https://app-linuxbroker-api.azurewebsites.us:8443/api' }
        @{ Value = 'https://raw.githubusercontent.com/microsoft/LinuxBrokerForAVDAccess/refs/heads/main' }
        @{ Value = 'https://mirror.contoso.us/linux%20broker/~main/' }
        @{ Value = 'https://10.0.0.4' }
    ) {
        Test-SafeHttpsUrl -Value $Value | Should -BeTrue
    }

    It 'refuses a URL that <Description>' -TestCases @(
        @{ Description = 'is empty'; Value = '' }
        @{ Description = 'is not https'; Value = 'http://app/api' }
        @{ Description = 'names no host'; Value = 'https:///api' }
        @{ Description = 'holds a double quote'; Value = 'https://app/api"' }
        @{ Description = 'holds a single quote'; Value = "https://app/it's" }
        @{ Description = 'holds a typographic double quote'; Value = ('https://app/api{0}' -f [char]0x201D) }
        @{ Description = 'holds a typographic single quote'; Value = ('https://app/it{0}s' -f [char]0x2019) }
        @{ Description = 'holds a letter outside ASCII'; Value = ('https://app/{0}/api' -f [char]0x00D1) }
        @{ Description = 'holds the Kelvin sign, which a match without regard to case takes for a k'; Value = ('https://app/{0}/api' -f [char]0x212A) }
        @{ Description = 'holds a subexpression'; Value = 'https://app/$(Get-Process)/api' }
        @{ Description = 'holds a backtick'; Value = 'https://app/`api' }
        @{ Description = 'holds a space'; Value = 'https://app /api' }
        @{ Description = 'ends with a line break'; Value = "https://app/api`n" }
        @{ Description = 'has a query string'; Value = 'https://app/api?code=1' }
        @{ Description = 'has a fragment'; Value = 'https://app/api#top' }
        @{ Description = 'names a user'; Value = 'https://user@app/api' }
        @{ Description = 'has a port that is not a number'; Value = 'https://app:port/api' }
        @{ Description = 'has a port above 65535'; Value = 'https://app:99999/api' }
    ) {
        Test-SafeHttpsUrl -Value $Value | Should -BeFalse
    }
}

Describe 'Get-AzdEnvValue' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $script:AzdCalls = New-Object System.Collections.Generic.List[string]
        $script:AzdExitCode = 0
        $script:AzdOutput = @('rg-linuxbroker-dev', '')
        Mock azd {
            $script:AzdCalls.Add(($args -join ' '))
            $global:LASTEXITCODE = $script:AzdExitCode
            $script:AzdOutput
        }
    }

    It 'reads a value from the azd environment' {
        Get-AzdEnvValue -EnvironmentName 'linuxbroker-dev' -Key 'resourceGroupName' | Should -BeExactly 'rg-linuxbroker-dev'
        $script:AzdCalls | Should -Be @('env get-value resourceGroupName --environment linuxbroker-dev')
    }

    It 'answers with nothing when azd has no such value' {
        $script:AzdExitCode = 1
        $script:AzdOutput = 'ERROR: key ''apiUrl'' not found in the environment values'

        Get-AzdEnvValue -EnvironmentName 'linuxbroker-dev' -Key 'apiUrl' | Should -BeExactly ''
    }

    It 'does not ask azd without an environment' {
        Get-AzdEnvValue -EnvironmentName '' -Key 'apiUrl' | Should -BeExactly ''
        $script:AzdCalls.Count | Should -Be 0
    }
}

Describe 'Get-AvdHostUpdateScript' {
    BeforeEach {
        Set-StrictMode -Version Latest
    }

    It 'fills in <Description> exactly, as a string PowerShell 5.1 parses' -TestCases @(
        @{ Description = 'ordinary values'; Value = 'https://app-linuxbroker-api.azurewebsites.net/api' }
        @{ Description = 'a single quote'; Value = "https://example.com/it's" }
        @{ Description = 'a curly quote'; Value = ('https://example.com/it{0}s' -f [char]0x2019) }
        @{ Description = 'what a double-quoted string would expand'; Value = 'https://example.com/$(Get-Process)/`t/$env:COMPUTERNAME"' }
    ) {
        $payload = Get-AvdHostUpdateScript -SourceUrl $Value -ApiBaseUrl $Value -ApiClientId $Value -Destination $Value

        $parseErrors = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($payload, [ref]$null, [ref]$parseErrors)
        @($parseErrors).Count | Should -Be 0
        foreach ($name in 'sourceUrl', 'apiBaseUrl', 'apiClientId', 'destination') {
            Get-PayloadValue -Payload $payload -Name $name | Should -BeExactly $Value
        }
        $payload | Should -Not -Match '__(SOURCE_URL|API_BASE_URL|API_CLIENT_ID|DESTINATION)__'
    }

    It 'fills in every value in one pass, so a value that holds a token keeps it' {
        $sourceUrl = 'https://example.com/__DESTINATION__/__API_CLIENT_ID__/Connect-LinuxBroker.ps1'

        $payload = Get-AvdHostUpdateScript -SourceUrl $sourceUrl -ApiBaseUrl $script:ApiUrl -ApiClientId $script:ClientId

        Get-PayloadValue -Payload $payload -Name 'sourceUrl' | Should -BeExactly $sourceUrl
        Get-PayloadValue -Payload $payload -Name 'apiClientId' | Should -BeExactly $script:ClientId
        Get-PayloadValue -Payload $payload -Name 'destination' | Should -BeExactly 'C:\Temp\Connect-LinuxBroker.ps1'
    }

    It 'installs the script where Configure-AVD-Host.ps1 does and the RemoteApp runs it from' {
        $default = Get-PayloadValue -Payload (Get-AvdHostUpdateScript -SourceUrl $script:DefaultSourceUrl -ApiBaseUrl $script:ApiUrl -ApiClientId $script:ClientId) -Name 'destination'

        $bicep = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot 'deploy\bicep\modules\AVD\main.bicep'))
        $remoteAppPath = [regex]::Match($bicep, "commandLineArguments: '[^']*-File (\S+?)'").Groups[1].Value.Replace('\\', '\')
        $remoteAppPath | Should -BeExactly $default
        $configure = [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot 'custom_script_extensions\Configure-AVD-Host.ps1'))
        $configure | Should -Match ([regex]::Escape('$folderPath = "C:\Temp"'))
        $configure | Should -Match ([regex]::Escape('$outputPath = "$folderPath\Connect-LinuxBroker.ps1"'))
    }
}

Describe 'Updating the session hosts through Run Command' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $global:LASTEXITCODE = 0
        $script:AzCalls = New-Object System.Collections.Generic.List[string]
        $script:RunCommands = New-Object System.Collections.Generic.List[object]
        $script:RunCommandOutcomes = @{}
        $script:AccountSetExitCode = 0
        $script:VmListExitCode = 0
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
                    return
                }
                return $script:VmListJson
            }

            if ($commandLine -like 'vm run-command invoke *') {
                $vmName = Get-ArgumentValue -Arguments $arguments -Name '--name'
                $scriptFile = (Get-ArgumentValue -Arguments $arguments -Name '--scripts').Substring(1)
                $script:RunCommands.Add([pscustomobject]@{
                        Vm            = $vmName
                        ResourceGroup = Get-ArgumentValue -Arguments $arguments -Name '--resource-group'
                        Arguments     = $arguments
                        File          = $scriptFile
                        Script        = [System.IO.File]::ReadAllText($scriptFile)
                        Bytes         = [System.IO.File]::ReadAllBytes($scriptFile)
                    })

                $outcome = @{ StdOut = "Updated Connect-LinuxBroker.ps1 on $vmName from 1.0.0 to 2.0.0." }
                if ($script:RunCommandOutcomes.ContainsKey($vmName) -and $script:RunCommandOutcomes[$vmName].Count -gt 0) {
                    $outcome = $script:RunCommandOutcomes[$vmName].Dequeue()
                }

                if ($outcome.ContainsKey('Error')) {
                    $global:LASTEXITCODE = 1
                    return (New-Object System.Management.Automation.ErrorRecord -ArgumentList @(
                            (New-Object System.Exception -ArgumentList $outcome['Error']),
                            'NativeCommandError',
                            [System.Management.Automation.ErrorCategory]::NotSpecified,
                            $null))
                }
                if ($outcome.ContainsKey('Raw')) {
                    return $outcome['Raw']
                }
                return (ConvertTo-RunCommandJson -StdOut ([string]$outcome['StdOut']) -StdErr ([string]$outcome['StdErr']))
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
        $update = @{
            ResourceGroupName = $script:ResourceGroup
            ApiBaseUrl        = $script:ApiUrl
            ApiClientId       = $script:ClientId
            SubscriptionId    = $script:SubscriptionId
        }
    }

    AfterEach {
        Restore-AzureVariable -Saved $savedVariables
    }

    Context 'Invoke-RunCommandWithRetry' {
        BeforeEach {
            $testScript = "Write-Output 'first'`r`nWrite-Output 'second'`r`n"
        }

        It 'returns what the script wrote to standard output and standard error' {
            Add-RunCommandOutcome -Vm 'avd-0' -Outcome @{ StdOut = "first`nsecond`n"; StdErr = 'WARNING: The CredentialManager module is not installed.' }

            $result = Invoke-RunCommandWithRetry -ResourceGroupName $script:ResourceGroup -VmName 'avd-0' -Script $testScript

            $result.StdOut | Should -BeExactly "first`nsecond"
            $result.StdErr | Should -BeExactly 'WARNING: The CredentialManager module is not installed.'
            $script:RunCommands.Count | Should -Be 1
            $script:Slept.Count | Should -Be 0
        }

        It 'hands az the script as a file, without a byte order mark, and deletes the file afterwards' {
            Invoke-RunCommandWithRetry -ResourceGroupName $script:ResourceGroup -VmName 'avd-0' -Script $testScript | Out-Null

            $call = $script:RunCommands[0]
            $call.Script | Should -BeExactly $testScript
            Test-Utf8Bom -Bytes $call.Bytes | Should -BeFalse
            Test-Path -LiteralPath $call.File | Should -BeFalse
            Get-ArgumentValue -Arguments $call.Arguments -Name '--command-id' | Should -BeExactly 'RunPowerShellScript'
            $call.ResourceGroup | Should -BeExactly $script:ResourceGroup
        }

        It 'retries a Run Command that fails, waiting longer each time' {
            $conflict = 'ERROR: (Conflict) Run command extension execution is in progress. Please wait for completion before invoking a run command.'
            Add-RunCommandOutcome -Vm 'avd-0' -Outcome @{ Error = $conflict }, @{ Error = $conflict }, @{ StdOut = 'done' }

            $result = Invoke-RunCommandWithRetry -ResourceGroupName $script:ResourceGroup -VmName 'avd-0' -Script $testScript

            $result.StdOut | Should -BeExactly 'done'
            $script:RunCommands.Count | Should -Be 3
            $script:Slept | Should -Be @(5, 10)
            $script:Warnings | Should -Contain "Run Command failed on 'avd-0' attempt 1 of 3. Retrying in 5 seconds."
            $script:Warnings | Should -Contain $conflict
        }

        It 'gives up after the last attempt, reporting the last error, and deletes the file' {
            Add-RunCommandOutcome -Vm 'avd-0' -Outcome @{ Error = 'ERROR: first' }, @{ Error = 'ERROR: second' }, @{ Error = 'ERROR: third' }

            { Invoke-RunCommandWithRetry -ResourceGroupName $script:ResourceGroup -VmName 'avd-0' -Script $testScript } |
                Should -Throw "Run Command failed on 'avd-0'. Last error: ERROR: third"

            $script:RunCommands.Count | Should -Be 3
            $script:Slept | Should -Be @(5, 10)
            Test-Path -LiteralPath $script:RunCommands[0].File | Should -BeFalse
        }

        It 'waits at most 30 seconds between attempts' {
            Add-RunCommandOutcome -Vm 'avd-0' -Outcome @{ Error = 'ERROR' }, @{ Error = 'ERROR' }, @{ Error = 'ERROR' }, @{ Error = 'ERROR' }, @{ StdOut = 'done' }

            Invoke-RunCommandWithRetry -ResourceGroupName $script:ResourceGroup -VmName 'avd-0' -Script $testScript -MaxAttempts 5 -InitialDelaySeconds 20 | Out-Null

            $script:Slept | Should -Be @(20, 30, 30, 30)
        }

        It 'refuses output that is not JSON' {
            Add-RunCommandOutcome -Vm 'avd-0' -Outcome @{ Raw = 'This command is in preview and under development.' }

            { Invoke-RunCommandWithRetry -ResourceGroupName $script:ResourceGroup -VmName 'avd-0' -Script $testScript } |
                Should -Throw "Run Command on 'avd-0' returned output that is not JSON*"
            $script:RunCommands.Count | Should -Be 1
        }
    }

    Context 'Invoke-AvdHostBrokerScriptUpdate' {
        It 'updates every running AVD session host in the resource group and no other VM' {
            Set-TestVm -Vm @(
                (New-TestVm -Name 'avd-0'),
                (New-TestVm -Name 'lnx-0' -Tags @{ 'broker-role' = 'linux-host' }),
                (New-TestVm -Name 'jumpbox' -Tags @{ environment = 'dev' }),
                (New-TestVm -Name 'untagged' -Tags $null),
                (New-TestVm -Name 'avd-1'),
                (New-TestVm -Name 'avd-2' -NoPowerState)
            )

            Invoke-AvdHostBrokerScriptUpdate @update

            @($script:RunCommands | ForEach-Object { $_.Vm }) | Should -Be @('avd-0', 'avd-1', 'avd-2')
            @($script:RunCommands | ForEach-Object { $_.ResourceGroup } | Select-Object -Unique) | Should -Be @($script:ResourceGroup)
            $script:AzCalls[0] | Should -BeExactly "account set --subscription $script:SubscriptionId"
            $script:AzCalls[1] | Should -BeExactly "vm list --resource-group $script:ResourceGroup --show-details --output json --only-show-errors"
            $script:HostLines | Should -Contain 'Connect-LinuxBroker.ps1 is up to date on 3 AVD session host(s).'
            $script:Warnings.Count | Should -Be 0
        }

        It 'runs the same update on every session host, filled in with this environment''s values' {
            Set-TestVm -Vm @((New-TestVm -Name 'avd-0'), (New-TestVm -Name 'avd-1'))

            Invoke-AvdHostBrokerScriptUpdate @update

            $payload = $script:RunCommands[0].Script
            $script:RunCommands[1].Script | Should -BeExactly $payload
            Get-PayloadValue -Payload $payload -Name 'sourceUrl' | Should -BeExactly $script:DefaultSourceUrl
            Get-PayloadValue -Payload $payload -Name 'apiBaseUrl' | Should -BeExactly $script:ApiUrl
            Get-PayloadValue -Payload $payload -Name 'apiClientId' | Should -BeExactly $script:ClientId
            Get-PayloadValue -Payload $payload -Name 'destination' | Should -BeExactly 'C:\Temp\Connect-LinuxBroker.ps1'
        }

        It 'downloads Connect-LinuxBroker.ps1 from ScriptSourceRoot and drops a trailing slash from the API URL' {
            Set-TestVm -Vm @(New-TestVm -Name 'avd-0')
            $update.ScriptSourceRoot = 'https://mirror.contoso.com/linuxbroker/'
            $update.ApiBaseUrl = " $script:ApiUrl/ "
            $update.ApiClientId = " $script:ClientId "

            Invoke-AvdHostBrokerScriptUpdate @update

            $payload = $script:RunCommands[0].Script
            Get-PayloadValue -Payload $payload -Name 'sourceUrl' | Should -BeExactly 'https://mirror.contoso.com/linuxbroker/avd_host/broker/Connect-LinuxBroker.ps1'
            Get-PayloadValue -Payload $payload -Name 'apiBaseUrl' | Should -BeExactly $script:ApiUrl
            Get-PayloadValue -Payload $payload -Name 'apiClientId' | Should -BeExactly $script:ClientId
        }

        It 'skips the session hosts that are not running and names them at the end' {
            Set-TestVm -Vm @(
                (New-TestVm -Name 'avd-0'),
                (New-TestVm -Name 'avd-1' -PowerState 'VM deallocated'),
                (New-TestVm -Name 'avd-2' -PowerState 'VM stopped')
            )

            Invoke-AvdHostBrokerScriptUpdate @update

            @($script:RunCommands | ForEach-Object { $_.Vm }) | Should -Be @('avd-0')
            $script:Warnings | Should -Contain "Skipping AVD session host 'avd-1' because it is not running (VM deallocated). Start it and run this script again with -AvdHostNames avd-1."
            $script:Warnings | Should -Contain 'Not updated because they are not running: avd-1, avd-2.'
            $script:HostLines | Should -Contain 'Connect-LinuxBroker.ps1 is up to date on 1 AVD session host(s).'
        }

        It 'tries every session host and then names the ones where the update failed' {
            Set-TestVm -Vm @((New-TestVm -Name 'avd-0'), (New-TestVm -Name 'avd-1'), (New-TestVm -Name 'avd-2'))
            $downloadFailure = "Could not download $script:DefaultSourceUrl after 3 attempts: The remote server returned an error: (404) Not Found."
            Add-RunCommandOutcome -Vm 'avd-0' -Outcome @{ StdOut = ''; StdErr = $downloadFailure }
            $agentFailure = 'ERROR: (VMAgentStatusCommunicationError) The VM agent is not reporting.'
            Add-RunCommandOutcome -Vm 'avd-1' -Outcome @{ Error = $agentFailure }, @{ Error = $agentFailure }, @{ Error = $agentFailure }

            { Invoke-AvdHostBrokerScriptUpdate @update } |
                Should -Throw 'The Connect-LinuxBroker.ps1 update failed on: avd-0, avd-1. Rerun with -AvdHostNames to retry them.'

            @($script:RunCommands | ForEach-Object { $_.Vm }) | Should -Be @('avd-0', 'avd-1', 'avd-1', 'avd-1', 'avd-2')
            $script:Warnings | Should -Contain "The update did not run to completion on 'avd-0'. $downloadFailure"
            $script:Warnings | Should -Contain "Run Command failed on 'avd-1'. Last error: $agentFailure"
            @($script:HostLines | Where-Object { $_ -like '*is up to date*' }).Count | Should -Be 0
        }

        It 'treats a run that did not reach its last line as failed, even without an error' {
            Set-TestVm -Vm @(New-TestVm -Name 'avd-0')
            Add-RunCommandOutcome -Vm 'avd-0' -Outcome @{ StdOut = 'WARNING: The LinuxBrokerScript event source could not be created.' }

            { Invoke-AvdHostBrokerScriptUpdate @update } | Should -Throw 'The Connect-LinuxBroker.ps1 update failed on: avd-0.*'
            $script:Warnings | Should -Contain "The update did not run to completion on 'avd-0'."
        }

        It 'reads the values it is not given from the azd environment' {
            Set-TestVm -Vm @(New-TestVm -Name 'avd-0')
            $script:AzdValues = @{
                resourceGroupName     = $script:ResourceGroup
                AZURE_SUBSCRIPTION_ID = $script:SubscriptionId
                apiUrl                = $script:ApiUrl
                apiClientId           = $script:ClientId
            }

            Invoke-AvdHostBrokerScriptUpdate -EnvironmentName 'linuxbroker-dev'

            @($script:AzdEnvironments | Select-Object -Unique) | Should -Be @('linuxbroker-dev')
            $script:AzCalls | Should -Contain "account set --subscription $script:SubscriptionId"
            $script:AzCalls | Should -Contain "vm list --resource-group $script:ResourceGroup --show-details --output json --only-show-errors"
            Get-PayloadValue -Payload $script:RunCommands[0].Script -Name 'apiBaseUrl' | Should -BeExactly $script:ApiUrl
            Get-PayloadValue -Payload $script:RunCommands[0].Script -Name 'apiClientId' | Should -BeExactly $script:ClientId
        }

        It 'uses the azd environment in <Variable> when none is given' -TestCases @(
            @{ Variable = 'AZURE_ENV_NAME' }
            @{ Variable = 'AZURE_ENVIRONMENT_NAME' }
        ) {
            Set-TestVm -Vm @(New-TestVm -Name 'avd-0')
            [Environment]::SetEnvironmentVariable($Variable, 'linuxbroker-hook', 'Process')
            $update.Remove('ResourceGroupName')
            $script:AzdValues = @{ resourceGroupName = $script:ResourceGroup }

            Invoke-AvdHostBrokerScriptUpdate @update

            @($script:AzdEnvironments | Select-Object -Unique) | Should -Be @('linuxbroker-hook')
            $script:RunCommands.Count | Should -Be 1
        }

        It 'selects the subscription in AZURE_SUBSCRIPTION_ID when azd has none' {
            Set-TestVm -Vm @(New-TestVm -Name 'avd-0')
            $update.Remove('SubscriptionId')
            $env:AZURE_SUBSCRIPTION_ID = $script:SubscriptionId

            Invoke-AvdHostBrokerScriptUpdate @update

            $script:AzCalls | Should -Contain "account set --subscription $script:SubscriptionId"
        }

        It 'keeps the current subscription when none is known' {
            Set-TestVm -Vm @(New-TestVm -Name 'avd-0')
            $update.Remove('SubscriptionId')

            Invoke-AvdHostBrokerScriptUpdate @update

            @($script:AzCalls | Where-Object { $_ -like 'account set*' }).Count | Should -Be 0
            $script:RunCommands.Count | Should -Be 1
        }

        It 'stops before it calls Azure when <Missing> is not known' -TestCases @(
            @{ Missing = 'ResourceGroupName' }
            @{ Missing = 'ApiBaseUrl' }
            @{ Missing = 'ApiClientId' }
        ) {
            $update.Remove($Missing)

            { Invoke-AvdHostBrokerScriptUpdate @update } |
                Should -Throw 'The AVD session host update needs ResourceGroupName, ApiBaseUrl and ApiClientId, as parameters or azd environment values.'
            $script:AzCalls.Count | Should -Be 0
        }

        It 'refuses an API URL that <Description>' -TestCases @(
            @{ Description = 'is not https'; Url = 'http://app-linuxbroker-api.azurewebsites.net/api' }
            @{ Description = 'holds a double quote'; Url = 'https://app/api";Remove-Item("C:\Temp");"' }
            @{ Description = 'holds a typographic double quote'; Url = ('https://app/api{0};Remove-Item("C:\Temp");{0}' -f [char]0x201D) }
            @{ Description = 'holds a letter outside ASCII'; Url = ('https://app/{0}/api' -f [char]0x00D1) }
            @{ Description = 'holds a single quote'; Url = "https://app/api'" }
            @{ Description = 'holds a subexpression'; Url = 'https://app/$(Get-Process)/api' }
            @{ Description = 'holds a backtick'; Url = 'https://app/`api' }
            @{ Description = 'holds a space'; Url = 'https://app /api' }
        ) {
            $update.ApiBaseUrl = $Url

            { Invoke-AvdHostBrokerScriptUpdate @update } | Should -Throw "ApiBaseUrl must be the broker API's https:// URL, such as https://<api-host>/api, not *"
            $script:AzCalls.Count | Should -Be 0
        }

        It 'refuses a ScriptSourceRoot that <Description>' -TestCases @(
            @{ Description = 'is not https'; Root = 'http://mirror.contoso.com/linuxbroker' }
            @{ Description = 'holds a single quote'; Root = "https://mirror.contoso.com/it's" }
            @{ Description = 'holds a typographic single quote'; Root = ('https://mirror.contoso.com/it{0}s' -f [char]0x2019) }
            @{ Description = 'holds a letter outside ASCII'; Root = ('https://mirror.contoso.com/{0}' -f [char]0x00D1) }
            @{ Description = 'is empty'; Root = '' }
        ) {
            $update.ScriptSourceRoot = $Root

            { Invoke-AvdHostBrokerScriptUpdate @update } | Should -Throw 'ScriptSourceRoot must be the https:// URL of the repository or of a mirror of it, such as https://raw.githubusercontent.com/microsoft/LinuxBrokerForAVDAccess/refs/heads/main, not *'
            $script:AzCalls.Count | Should -Be 0
        }

        It 'accepts URLs with a port, percent-encoding and a tilde' {
            Set-TestVm -Vm @(New-TestVm -Name 'avd-0')
            $update.ScriptSourceRoot = 'https://mirror.contoso.us:8443/linux%20broker/~main'
            $update.ApiBaseUrl = 'https://app-linuxbroker-api.azurewebsites.us:8443/api'

            Invoke-AvdHostBrokerScriptUpdate @update

            $payload = $script:RunCommands[0].Script
            Get-PayloadValue -Payload $payload -Name 'sourceUrl' | Should -BeExactly 'https://mirror.contoso.us:8443/linux%20broker/~main/avd_host/broker/Connect-LinuxBroker.ps1'
            Get-PayloadValue -Payload $payload -Name 'apiBaseUrl' | Should -BeExactly 'https://app-linuxbroker-api.azurewebsites.us:8443/api'
        }

        It 'refuses a client ID that is not a GUID in its usual form: <ClientId>' -TestCases @(
            @{ ClientId = 'api://0b5a9c3e-6f1d-4a2b-9c8e-7d6f5e4a3b21' }
            @{ ClientId = '{0b5a9c3e-6f1d-4a2b-9c8e-7d6f5e4a3b21}' }
            @{ ClientId = '0b5a9c3e6f1d4a2b9c8e7d6f5e4a3b21' }
            @{ ClientId = 'linuxbroker-api' }
        ) {
            $update.ApiClientId = $ClientId

            { Invoke-AvdHostBrokerScriptUpdate @update } | Should -Throw "ApiClientId must be the broker API app registration's client ID, a GUID, not *"
            $script:AzCalls.Count | Should -Be 0
        }

        It 'updates only the session hosts named with -AvdHostNames, in any case, and warns about the rest' {
            Set-TestVm -Vm @(
                (New-TestVm -Name 'avd-0'),
                (New-TestVm -Name 'avd-1'),
                (New-TestVm -Name 'lnx-0' -Tags @{ 'broker-role' = 'linux-host' })
            )

            Invoke-AvdHostBrokerScriptUpdate @update -AvdHostNames 'AVD-1', ' avd-9 ', 'lnx-0', ''

            @($script:RunCommands | ForEach-Object { $_.Vm }) | Should -Be @('avd-1')
            $script:Warnings | Should -Contain "Requested AVD session host 'avd-9' was not found in resource group '$script:ResourceGroup'."
            $script:Warnings | Should -Contain "Requested AVD session host 'lnx-0' was not found in resource group '$script:ResourceGroup'."
            $script:Warnings.Count | Should -Be 2
        }

        It 'does nothing when no session host has a requested name' {
            Set-TestVm -Vm @(New-TestVm -Name 'avd-0')

            Invoke-AvdHostBrokerScriptUpdate @update -AvdHostNames 'avd-9'

            $script:RunCommands.Count | Should -Be 0
            $script:HostLines | Should -Contain 'No AVD session hosts matched the requested update scope.'
        }

        It 'does nothing in a resource group with <Description>' -TestCases @(
            @{ Description = 'no VMs'; Linux = $false }
            @{ Description = 'only Linux hosts'; Linux = $true }
        ) {
            if ($Linux) {
                Set-TestVm -Vm @(New-TestVm -Name 'lnx-0' -Tags @{ 'broker-role' = 'linux-host' })
            }

            Invoke-AvdHostBrokerScriptUpdate @update

            $script:RunCommands.Count | Should -Be 0
            $script:HostLines | Should -Contain "No AVD session host VMs found in resource group '$script:ResourceGroup'."
        }

        It 'stops when the VMs cannot be listed' {
            $script:VmListExitCode = 1

            { Invoke-AvdHostBrokerScriptUpdate @update } | Should -Throw "Could not list the VMs in resource group '$script:ResourceGroup'."
            $script:RunCommands.Count | Should -Be 0
        }

        It 'stops when the subscription cannot be selected' {
            $script:AccountSetExitCode = 1

            { Invoke-AvdHostBrokerScriptUpdate @update } | Should -Throw "Could not select subscription '$script:SubscriptionId'."
            @($script:AzCalls | Where-Object { $_ -like 'vm *' }).Count | Should -Be 0
        }
    }
}

Describe 'The update on a session host' {
    BeforeAll {
        $script:SourcePath = Join-Path $TestDrive 'source\Connect-LinuxBroker.ps1'
        New-Item -ItemType Directory -Path (Split-Path -Parent $script:SourcePath) | Out-Null
        Copy-Item -LiteralPath $script:BrokerScriptPath -Destination $script:SourcePath
        $script:SourceUrl = ([Uri]$script:SourcePath).AbsoluteUri
        $script:ExpectedScript = [System.IO.File]::ReadAllText($script:BrokerScriptPath).Replace('https://your_linuxbroker_api_base_url/api', $script:ApiUrl).Replace('your_linuxbroker_api_client_id', $script:ClientId)
    }

    It 'installs the current script where there is none, with the API URL and client ID filled in' {
        $destination = Join-Path $TestDrive ('{0}\Temp\Connect-LinuxBroker.ps1' -f [guid]::NewGuid().ToString('N'))

        $result = Invoke-HostUpdate -SourceUrl $script:SourceUrl -Destination $destination

        $result.StdErr | Should -BeNullOrEmpty
        $result.ExitCode | Should -Be 0
        $script:BrokerScriptVersion | Should -Not -BeNullOrEmpty
        $result.StdOut | Should -Match ([regex]::Escape("Updated Connect-LinuxBroker.ps1 on $env:COMPUTERNAME from no script to $script:BrokerScriptVersion."))
        [System.IO.File]::ReadAllText($destination) | Should -BeExactly $script:ExpectedScript
        $script:ExpectedScript | Should -Match ([regex]::Escape("`$apiBaseUrl = `"$script:ApiUrl`""))
        $script:ExpectedScript | Should -Match ([regex]::Escape("api://$script:ClientId"))
        Test-Utf8Bom -Bytes ([System.IO.File]::ReadAllBytes($destination)) | Should -BeFalse
        Get-FolderEntry -Path $destination | Should -Be @('Connect-LinuxBroker.ps1')
    }

    It 'replaces <Description> in place' -TestCases @(
        @{ Description = 'a script from before versions'; Content = "# Connect-LinuxBroker.ps1`r`n`$apiBaseUrl = `"https://app-linuxbroker-api.azurewebsites.net/api`"`r`n"; Previous = 'a script without a version' }
        @{ Description = 'an earlier version'; Content = "`$ScriptVersion = '1.9.0'`r`n"; Previous = '1.9.0' }
    ) {
        $destination = New-InstalledScript -Content $Content

        $result = Invoke-HostUpdate -SourceUrl $script:SourceUrl -Destination $destination

        $result.StdErr | Should -BeNullOrEmpty
        $result.ExitCode | Should -Be 0
        $result.StdOut | Should -Match ([regex]::Escape("from $Previous to $script:BrokerScriptVersion."))
        [System.IO.File]::ReadAllText($destination) | Should -BeExactly $script:ExpectedScript
        Get-FolderEntry -Path $destination | Should -Be @('Connect-LinuxBroker.ps1')
    }

    It 'leaves the installed script alone when the download fails' {
        $destination = New-InstalledScript
        $before = [System.IO.File]::ReadAllText($destination)
        $missingUrl = ([Uri](Join-Path $TestDrive 'missing\Connect-LinuxBroker.ps1')).AbsoluteUri

        $result = Invoke-HostUpdate -SourceUrl $missingUrl -Destination $destination

        $result.ExitCode | Should -Be 1
        $result.StdErr | Should -Match ('Could not download ' + [regex]::Escape($missingUrl) + ' after 3 attempts')
        $result.StdOut | Should -Match 'TEST: Start-Sleep 2'
        $result.StdOut | Should -Match 'TEST: Start-Sleep 4'
        $result.StdOut | Should -Not -Match 'Updated Connect-LinuxBroker.ps1'
        [System.IO.File]::ReadAllText($destination) | Should -BeExactly $before
        Get-FolderEntry -Path $destination | Should -Be @('Connect-LinuxBroker.ps1')
    }

    It 'refuses <Description> and leaves the installed script alone' -TestCases @(
        @{
            Description = 'a file that is not a Connect-LinuxBroker.ps1'
            Content     = "Write-Output 'hello'`r`n"
            Message     = 'is not a Connect-LinuxBroker.ps1 that this update can install.'
        }
        @{
            Description = 'a script without the placeholders to fill in'
            Content     = "`$ScriptVersion = '9.9.9'`r`n`$apiBaseUrl = `"https://app-linuxbroker-api.azurewebsites.net/api`"`r`n"
            Message     = 'is not a Connect-LinuxBroker.ps1 that this update can install.'
        }
        @{
            Description = 'a script that does not parse'
            Content     = "`$ScriptVersion = '9.9.9'`r`n`$apiBaseUrl = `"https://your_linuxbroker_api_base_url/api`"`r`n`$apiAppIdUri = `"api://your_linuxbroker_api_client_id`"`r`nfunction {`r`n"
            Message     = 'Connect-LinuxBroker.ps1 9.9.9 does not parse once the API URL and client ID are filled in'
        }
        @{
            Description = 'a script with characters outside ASCII'
            Content     = "`$ScriptVersion = '9.9.9'`r`n`$apiBaseUrl = `"https://your_linuxbroker_api_base_url/api`"`r`n`$apiAppIdUri = `"api://your_linuxbroker_api_client_id`"`r`n# Caf$([char]0x00E9)`r`n"
            Message     = 'Connect-LinuxBroker.ps1 9.9.9 holds characters outside ASCII, which Windows PowerShell could misread.'
        }
    ) {
        $sourcePath = Join-Path $TestDrive ('{0}.ps1' -f [guid]::NewGuid().ToString('N'))
        [System.IO.File]::WriteAllText($sourcePath, $Content)
        $destination = New-InstalledScript
        $before = [System.IO.File]::ReadAllText($destination)

        $result = Invoke-HostUpdate -SourceUrl ([Uri]$sourcePath).AbsoluteUri -Destination $destination

        $result.ExitCode | Should -Be 1
        $result.StdErr | Should -Match ([regex]::Escape($Message))
        $result.StdOut | Should -Not -Match 'Updated Connect-LinuxBroker.ps1'
        [System.IO.File]::ReadAllText($destination) | Should -BeExactly $before
        Get-FolderEntry -Path $destination | Should -Be @('Connect-LinuxBroker.ps1')
    }
}

Describe 'Update-AvdHostBrokerScript.ps1' {
    It 'runs the update with its parameters when it is run as a script in PowerShell 7' -Skip:(-not (Get-Command pwsh -ErrorAction SilentlyContinue)) {
        $folder = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $folder | Out-Null
        $harnessPath = Join-Path $folder 'harness.ps1'
        $harness = @'
try {
    & __SCRIPT__ -ResourceGroupName 'rg-linuxbroker-dev' -ApiBaseUrl 'http://app-linuxbroker-api.azurewebsites.net/api' -ApiClientId '0b5a9c3e-6f1d-4a2b-9c8e-7d6f5e4a3b21'
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
'@
        [System.IO.File]::WriteAllText($harnessPath, $harness.Replace('__SCRIPT__', (ConvertTo-PowerShellLiteral -Value $script:UpdateScriptPath)), $script:Utf8NoBom)

        $result = Invoke-ChildProcess -FilePath (Get-Command pwsh).Source -ScriptPath $harnessPath

        $result.ExitCode | Should -Be 1
        $result.StdErr.Trim() | Should -BeExactly "ApiBaseUrl must be the broker API's https:// URL, such as https://<api-host>/api, not 'http://app-linuxbroker-api.azurewebsites.net/api'."
    }
}

Describe 'Migrate-ExistingEnvironment.ps1' {
    BeforeAll {
        $script:MigrationFolder = Join-Path $TestDrive 'deploy'
        New-Item -ItemType Directory -Path $script:MigrationFolder | Out-Null
        Copy-Item -LiteralPath (Join-Path $script:RepoRoot 'deploy\Migrate-ExistingEnvironment.ps1') -Destination $script:MigrationFolder
        $script:MigrationPath = Join-Path $script:MigrationFolder 'Migrate-ExistingEnvironment.ps1'
        $script:StepLog = Join-Path $script:MigrationFolder 'steps.log'

        # Each step records how it was run, with an array argument as a,b, and fails when
        # LINUXBROKER_TEST_FAILING_STEPS names it.
        $stub = @'
$step = [System.IO.Path]::GetFileNameWithoutExtension($MyInvocation.MyCommand.Path)
$arguments = @($args | ForEach-Object { if ($_ -is [array]) { $_ -join ',' } else { [string]$_ } })
Add-Content -LiteralPath (Join-Path $PSScriptRoot 'steps.log') -Value ('{0} {1}' -f $step, ($arguments -join ' '))
if (@([string]$env:LINUXBROKER_TEST_FAILING_STEPS -split ',') -contains $step) {
    throw "$step failed on host-1."
}
'@
        foreach ($step in 'Post-Provision', 'Migrate-LinuxHostReleaseAgent', 'Update-AvdHostBrokerScript') {
            [System.IO.File]::WriteAllText((Join-Path $script:MigrationFolder "$step.ps1"), $stub)
        }

        function Get-StepLog {
            if (-not (Test-Path -LiteralPath $script:StepLog)) {
                return @()
            }
            return @(Get-Content -LiteralPath $script:StepLog)
        }

        function Get-StepName {
            return @(Get-StepLog | ForEach-Object { ($_ -split ' ')[0] })
        }
    }

    BeforeEach {
        Remove-Item -LiteralPath $script:StepLog -ErrorAction SilentlyContinue
        # Not $script: variables: in a mock that Migrate-ExistingEnvironment.ps1 calls, $script: is
        # that script's scope. These are found through the scopes that called it.
        $hostLines = New-Object System.Collections.Generic.List[string]
        $warnings = New-Object System.Collections.Generic.List[string]
        Mock Write-Host { $hostLines.Add([string]$Object) }
        Mock Write-Warning { $warnings.Add([string]$Message) }
        Mock az { throw "Unexpected az call: $($args -join ' ')" }
        Mock azd { throw "Unexpected azd call: $($args -join ' ')" }

        $savedVariables = Save-AzureVariable
        $savedFailingSteps = $env:LINUXBROKER_TEST_FAILING_STEPS
        $env:LINUXBROKER_TEST_FAILING_STEPS = $null
        $migration = @{
            ResourceGroupName = $script:ResourceGroup
            ApiBaseUrl        = $script:ApiUrl
            ApiClientId       = $script:ClientId
        }
    }

    AfterEach {
        Restore-AzureVariable -Saved $savedVariables
        $env:LINUXBROKER_TEST_FAILING_STEPS = $savedFailingSteps
    }

    It 'updates the AVD session hosts after the Linux hosts, with the same values' {
        & $script:MigrationPath @migration -LinuxHostNames 'lnx-0' -AvdHostNames 'avd-0', 'avd-1'

        Get-StepName | Should -Be @('Post-Provision', 'Migrate-LinuxHostReleaseAgent', 'Update-AvdHostBrokerScript')
        $steps = Get-StepLog
        $steps[1] | Should -Match ([regex]::Escape('-LinuxHostNames lnx-0'))
        $steps[2] | Should -Match ([regex]::Escape("-ResourceGroupName $script:ResourceGroup -ApiBaseUrl $script:ApiUrl -ApiClientId $script:ClientId"))
        $steps[2] | Should -Match ([regex]::Escape('-ScriptSourceRoot https://raw.githubusercontent.com/microsoft/LinuxBrokerForAVDAccess/refs/heads/main'))
        $steps[2] | Should -Match ([regex]::Escape('-AvdHostNames avd-0,avd-1'))
        $hostLines | Should -Contain 'Existing environment migration completed.'
    }

    It 'still updates the AVD session hosts when the Linux host migration fails, and then fails' {
        $env:LINUXBROKER_TEST_FAILING_STEPS = 'Migrate-LinuxHostReleaseAgent'

        { & $script:MigrationPath @migration } |
            Should -Throw 'Existing environment migration failed in the Linux host migration. The warnings above name the hosts to retry.'

        Get-StepName | Should -Be @('Post-Provision', 'Migrate-LinuxHostReleaseAgent', 'Update-AvdHostBrokerScript')
        $warnings | Should -Contain 'Migrate-LinuxHostReleaseAgent failed on host-1.'
        $hostLines | Should -Not -Contain 'Existing environment migration completed.'
    }

    It 'names both host updates when both fail' {
        $env:LINUXBROKER_TEST_FAILING_STEPS = 'Migrate-LinuxHostReleaseAgent,Update-AvdHostBrokerScript'

        { & $script:MigrationPath @migration } |
            Should -Throw 'Existing environment migration failed in the Linux host migration and the AVD session host update. The warnings above name the hosts to retry.'
        $warnings | Should -Contain 'Update-AvdHostBrokerScript failed on host-1.'
    }

    It 'stops at a failed post-provision step, before it updates any host' {
        $env:LINUXBROKER_TEST_FAILING_STEPS = 'Post-Provision'

        { & $script:MigrationPath @migration } | Should -Throw 'Post-Provision failed on host-1.'
        Get-StepName | Should -Be @('Post-Provision')
    }

    It 'leaves the AVD session hosts alone with -SkipAvdHostScriptUpdate' {
        & $script:MigrationPath @migration -SkipAvdHostScriptUpdate

        Get-StepName | Should -Be @('Post-Provision', 'Migrate-LinuxHostReleaseAgent')
    }

    It 'updates only the AVD session hosts with -SkipLinuxHostReleaseAgentMigration' {
        & $script:MigrationPath @migration -SkipPostProvision -SkipLinuxHostReleaseAgentMigration

        Get-StepName | Should -Be @('Update-AvdHostBrokerScript')
    }

    It 'stops before it updates any host when <Missing> is not known' -TestCases @(
        @{ Missing = 'ResourceGroupName' }
        @{ Missing = 'ApiBaseUrl' }
        @{ Missing = 'ApiClientId' }
    ) {
        $migration.Remove($Missing)

        { & $script:MigrationPath @migration } |
            Should -Throw 'Updating the Linux hosts and the AVD session hosts requires ResourceGroupName, ApiBaseUrl, and ApiClientId.'
        Get-StepName | Should -Be @('Post-Provision')
    }

    It 'needs none of them when both host updates are skipped' {
        & $script:MigrationPath -SkipLinuxHostReleaseAgentMigration -SkipAvdHostScriptUpdate

        Get-StepName | Should -Be @('Post-Provision')
        $hostLines | Should -Contain 'Existing environment migration completed.'
    }
}
