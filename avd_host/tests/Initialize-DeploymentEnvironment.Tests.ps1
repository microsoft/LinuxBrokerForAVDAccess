# Pester 5 tests for how deploy/Initialize-DeploymentEnvironment.ps1 sets up the AVD scaling plan
# and its role, and leaves out the VM extensions of hosts that are not running, and for the Bicep
# those settings feed. From the repository root, in Windows PowerShell:
#   Invoke-Pester -Path avd_host/tests

BeforeAll {
    $script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    $script:InitializeScriptPath = Join-Path $script:RepoRoot 'deploy\Initialize-DeploymentEnvironment.ps1'

    # Running the script would bootstrap an azd environment, so only its functions are loaded.
    $parseErrors = $null
    $script:InitializeAst = [System.Management.Automation.Language.Parser]::ParseFile($script:InitializeScriptPath, [ref]$null, [ref]$parseErrors)
    if (@($parseErrors).Count -gt 0) {
        throw "Initialize-DeploymentEnvironment.ps1 does not parse: $($parseErrors[0].Message)"
    }

    $script:FunctionDefinitions = @{}
    foreach ($definition in $script:InitializeAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
        $script:FunctionDefinitions[$definition.Name] = $definition
    }

    foreach ($name in @(
            'Get-AzdEnvValue', 'Get-FirstNonEmptyValue', 'ConvertTo-IntParameterValue', 'Get-PropertyValue', 'Get-VmTagValue',
            'ConvertTo-TimeOfDayParameterValue', 'ConvertTo-PercentParameterValue', 'Assert-AvdScalingPlanTimeOrder',
            'Resolve-WindowsTimeZoneId', 'Get-HostPowerStateSnapshot', 'Resolve-AvdServicePrincipalObjectId',
            'Invoke-ArmGetRequest', 'Get-AvdAutoscaleRoleState', 'Test-ActionPermitted', 'Test-CanAssignSubscriptionRole',
            'Resolve-AvdAutoscaleRolePlan')) {
        if (-not $script:FunctionDefinitions.ContainsKey($name)) {
            throw "Initialize-DeploymentEnvironment.ps1 has no function $name."
        }
        . ([scriptblock]::Create($script:FunctionDefinitions[$name].Extent.Text))
    }

    # Mock can only replace a command that exists, and the machine running the tests may not have
    # the Azure CLI.
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        function script:az { }
    }

    $script:SubscriptionId = '6d1e0f3c-2b4a-4c5d-8e9f-0a1b2c3d4e5f'
    $script:ResourceGroup = 'rg-linuxbroker-dev'
    $script:AvdAppId = '9cdead84-a844-4324-93f2-b2e6bb768d07'
    $script:AvdObjectId = '3f2a1b0c-9d8e-4f7a-8b6c-5d4e3f2a1b0c'
    $script:RoleId = '40c5ff49-9181-41f8-ae61-143b0e78555e'
    $script:SubscriptionScope = "/subscriptions/$script:SubscriptionId"

    # What az answers to a command line that matches Pattern, first match first: its output, the
    # lines it writes to stderr and its exit code.
    function Add-AzResponse {
        param(
            [Parameter(Mandatory = $true)][string]$Pattern,
            $Output = $null,
            [string[]]$StdErr = @(),
            [int]$ExitCode = 0
        )

        $script:AzResponses.Add(@{ Pattern = $Pattern; Output = $Output; StdErr = $StdErr; ExitCode = $ExitCode })
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

    function New-TestVm {
        param(
            [Parameter(Mandatory = $true)][string]$Name,
            [hashtable]$Tags = @{ 'broker-role' = 'avd-host' },
            [string]$PowerState = 'VM running',
            [switch]$NoPowerState
        )

        $vm = [ordered]@{ name = $Name; resourceGroup = $script:ResourceGroup; tags = [pscustomobject]$Tags }
        if (-not $NoPowerState) {
            $vm['powerState'] = $PowerState
        }
        return [pscustomobject]$vm
    }

    function New-RoleAssignment {
        param(
            [string]$PrincipalId = $script:AvdObjectId,
            [string]$PrincipalType = 'ServicePrincipal',
            [string]$RoleDefinitionId = "$script:SubscriptionScope/providers/Microsoft.Authorization/roleDefinitions/$script:RoleId",
            [string]$Scope = $script:SubscriptionScope,
            [switch]$Flattened
        )

        $properties = [ordered]@{
            principalId = $PrincipalId
            principalType = $PrincipalType
            roleDefinitionId = $RoleDefinitionId
            scope = $Scope
        }
        if ($Flattened) {
            return $properties
        }
        return [ordered]@{
            id = "$Scope/providers/Microsoft.Authorization/roleAssignments/$([guid]::NewGuid())"
            name = [guid]::NewGuid().ToString()
            properties = $properties
        }
    }

    function ConvertTo-ListJson {
        param(
            [AllowEmptyCollection()][object[]]$Value = @(),
            [string]$NextLink = ''
        )

        $body = [ordered]@{ value = @($Value) }
        if ($NextLink) {
            $body['nextLink'] = $NextLink
        }
        return ConvertTo-Json -InputObject $body -Depth 8
    }

    $script:OwnerPermission = [ordered]@{ actions = @('*'); notActions = @(); dataActions = @(); notDataActions = @() }
    $script:ContributorPermission = [ordered]@{
        actions = @('*')
        notActions = @('Microsoft.Authorization/*/Delete', 'Microsoft.Authorization/*/Write', 'Microsoft.Authorization/elevateAccess/Action', 'Microsoft.Blueprint/blueprintAssignments/write')
        dataActions = @()
        notDataActions = @()
    }
    $script:UserAccessAdministratorPermission = [ordered]@{ actions = @('*/read', 'Microsoft.Authorization/*', 'Microsoft.Support/*'); notActions = @() }
    $script:ReaderPermission = [ordered]@{ actions = @('*/read'); notActions = @() }
    $script:ConditionalPermission = [ordered]@{
        actions = @('Microsoft.Authorization/roleAssignments/write', 'Microsoft.Authorization/roleAssignments/delete', '*/read')
        notActions = @()
        condition = "((!(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})) OR (@Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {b24988ac-6180-42a0-ab88-20f7382dd24c}))"
        conditionVersion = '2.0'
    }

    # What az answers while deciding on the role: whether the tenant has the Azure Virtual Desktop
    # service principal, whether it holds the role, and whether the signed-in account can assign it.
    function Set-RoleCheck {
        param(
            [ValidateSet('Assigned', 'NotAssigned', 'Unknown')][string]$RoleState = 'NotAssigned',
            [ValidateSet('Yes', 'No', 'Unknown')][string]$CanAssign = 'Yes',
            [switch]$ServicePrincipalMissing
        )

        if ($ServicePrincipalMissing) {
            Add-AzResponse -Pattern 'ad sp list *' -Output '[]'
            Add-AzResponse -Pattern 'ad sp create *' -ExitCode 1
        }
        else {
            Add-AzResponse -Pattern 'ad sp list *' -Output (ConvertTo-Json -InputObject @($script:AvdObjectId))
        }

        switch ($RoleState) {
            'Assigned' { Add-AzResponse -Pattern 'rest *roleAssignments*' -Output (ConvertTo-ListJson -Value @((New-RoleAssignment))) }
            'NotAssigned' { Add-AzResponse -Pattern 'rest *roleAssignments*' -Output (ConvertTo-ListJson) }
            'Unknown' { Add-AzResponse -Pattern 'rest *roleAssignments*' -StdErr @('ERROR: Bad Request') -ExitCode 1 }
        }

        switch ($CanAssign) {
            'Yes' { Add-AzResponse -Pattern 'rest *permissions*' -Output (ConvertTo-ListJson -Value @($script:OwnerPermission)) }
            'No' { Add-AzResponse -Pattern 'rest *permissions*' -Output (ConvertTo-ListJson -Value @($script:ContributorPermission)) }
            'Unknown' { Add-AzResponse -Pattern 'rest *permissions*' -StdErr @('ERROR: Bad Request') -ExitCode 1 }
        }
    }
}

Describe 'Initialize-DeploymentEnvironment.ps1' {
    BeforeEach {
        Set-StrictMode -Version Latest
        $global:LASTEXITCODE = 0
        $script:AzdValues = @{}
        $script:AzCalls = New-Object System.Collections.Generic.List[object]
        $script:AzResponses = New-Object System.Collections.Generic.List[hashtable]
        $script:Warnings = New-Object System.Collections.Generic.List[string]

        Mock Get-AzdEnvValue { [string]$script:AzdValues[$Key] }
        Mock Write-Warning { $script:Warnings.Add([string]$Message) }
        Mock az {
            # Like az's stderr, the lines go to the error stream, which the script discards with
            # 2>$null or merges into the output with 2>&1, and they never stop the script.
            $ErrorActionPreference = 'Continue'
            # A native command gets each item of an array argument as an argument of its own.
            $arguments = [string[]]@($args | ForEach-Object { $_ } | ForEach-Object { [string]$_ })
            $commandLine = $arguments -join ' '
            $script:AzCalls.Add([pscustomobject]@{ CommandLine = $commandLine; Arguments = $arguments })
            foreach ($response in $script:AzResponses) {
                if ($commandLine -like $response.Pattern) {
                    $global:LASTEXITCODE = $response.ExitCode
                    foreach ($line in $response.StdErr) {
                        Write-Error -Message $line -Category NotSpecified -ErrorId 'NativeCommandError'
                    }
                    return $response.Output
                }
            }
            throw "Unexpected az call: $commandLine"
        }
    }

    Context 'Reading the scaling plan settings' {
        It 'reads a time of day as HH:mm, from <Value>' -TestCases @(
            @{ Value = '07:00'; Expected = '07:00' }
            @{ Value = '7:05'; Expected = '07:05' }
            @{ Value = ' 18:30 '; Expected = '18:30' }
            @{ Value = '0:00'; Expected = '00:00' }
            @{ Value = '23:59'; Expected = '23:59' }
        ) {
            $script:AzdValues['avdScalingPlanPeakStart'] = $Value

            ConvertTo-TimeOfDayParameterValue -Key 'avdScalingPlanPeakStart' -DefaultValue '09:00' | Should -BeExactly $Expected
        }

        It 'uses the default time when the value is not set' {
            ConvertTo-TimeOfDayParameterValue -Key 'avdScalingPlanPeakStart' -DefaultValue '09:00' | Should -BeExactly '09:00'
        }

        It 'refuses the time <Value>' -TestCases @(
            @{ Value = '24:00' }
            @{ Value = '07:60' }
            @{ Value = '7' }
            @{ Value = '7:5' }
            @{ Value = '07:00:00' }
            @{ Value = '7am' }
            @{ Value = "07:00`n" + '08:00' }
            @{ Value = ('{0}{1}:00' -f [char]0xFF10, [char]0xFF17) }
        ) {
            $script:AzdValues['avdScalingPlanPeakStart'] = $Value

            { ConvertTo-TimeOfDayParameterValue -Key 'avdScalingPlanPeakStart' -DefaultValue '09:00' } |
                Should -Throw -ExpectedMessage "*'avdScalingPlanPeakStart'*HH:mm*"
        }

        It 'reads a percentage from <Minimum> to 100' -TestCases @(
            @{ Value = '0'; Minimum = 0; Expected = 0 }
            @{ Value = '100'; Minimum = 0; Expected = 100 }
            @{ Value = '1'; Minimum = 1; Expected = 1 }
            @{ Value = ''; Minimum = 1; Expected = 60 }
        ) {
            $script:AzdValues['avdScalingPlanRampUpCapacityThresholdPct'] = $Value

            ConvertTo-PercentParameterValue -Key 'avdScalingPlanRampUpCapacityThresholdPct' -DefaultValue 60 -Minimum $Minimum | Should -Be $Expected
        }

        It 'refuses the percentage <Value> when the minimum is <Minimum>' -TestCases @(
            @{ Value = '101'; Minimum = 0; Message = "*'avdScalingPlanRampUpCapacityThresholdPct'*from 0 to 100*" }
            @{ Value = '-1'; Minimum = 0; Message = '*from 0 to 100*' }
            @{ Value = '0'; Minimum = 1; Message = '*from 1 to 100*' }
            @{ Value = 'sixty'; Minimum = 0; Message = '*must be an integer*' }
        ) {
            $script:AzdValues['avdScalingPlanRampUpCapacityThresholdPct'] = $Value

            { ConvertTo-PercentParameterValue -Key 'avdScalingPlanRampUpCapacityThresholdPct' -DefaultValue 60 -Minimum $Minimum } |
                Should -Throw -ExpectedMessage $Message
        }

        It 'accepts phase times that come in order within one day' {
            $times = [ordered]@{ avdScalingPlanRampUpStart = '07:00'; avdScalingPlanPeakStart = '09:00'; avdScalingPlanRampDownStart = '18:00'; avdScalingPlanOffPeakStart = '20:00' }

            { Assert-AvdScalingPlanTimeOrder -Times $times } | Should -Not -Throw
        }

        It 'refuses a phase that starts <Description>' -TestCases @(
            @{ Description = 'with the one before it'; PeakStart = '07:00' }
            @{ Description = 'before the one before it'; PeakStart = '06:59' }
        ) {
            $times = [ordered]@{ avdScalingPlanRampUpStart = '07:00'; avdScalingPlanPeakStart = $PeakStart; avdScalingPlanRampDownStart = '18:00'; avdScalingPlanOffPeakStart = '20:00' }

            { Assert-AvdScalingPlanTimeOrder -Times $times } |
                Should -Throw -ExpectedMessage "*'avdScalingPlanPeakStart' ($PeakStart) must be later than 'avdScalingPlanRampUpStart' (07:00)*"
        }

        It 'refuses an off-peak time that wraps past midnight' {
            $times = [ordered]@{ avdScalingPlanRampUpStart = '07:00'; avdScalingPlanPeakStart = '09:00'; avdScalingPlanRampDownStart = '18:00'; avdScalingPlanOffPeakStart = '01:00' }

            { Assert-AvdScalingPlanTimeOrder -Times $times } | Should -Throw -ExpectedMessage "*'avdScalingPlanOffPeakStart'*"
        }

        It 'finds the Windows time zone <Value> as <Expected>' -TestCases @(
            @{ Value = 'UTC'; Expected = 'UTC' }
            @{ Value = 'utc'; Expected = 'UTC' }
            @{ Value = ' eastern standard time '; Expected = 'Eastern Standard Time' }
        ) {
            Resolve-WindowsTimeZoneId -TimeZoneId $Value | Should -BeExactly $Expected
        }

        It 'does not take the IANA name <Value> for a Windows time zone' -TestCases @(
            @{ Value = 'America/New_York' }
            @{ Value = 'Etc/UTC' }
            @{ Value = 'Not A Zone' }
        ) {
            Resolve-WindowsTimeZoneId -TimeZoneId $Value | Should -BeExactly ''
        }
    }

    Context 'Listing the hosts that are not running' {
        It 'lists nothing, and does not warn, when the resource group does not exist yet' {
            Add-AzResponse -Pattern 'group exists *' -Output 'false'

            $snapshot = Get-HostPowerStateSnapshot -SubscriptionId $script:SubscriptionId -ResourceGroupName $script:ResourceGroup

            $snapshot.Listed | Should -BeTrue
            @($snapshot.NotRunning).Count | Should -Be 0
            $snapshot.AvdScalingExclusions.Count | Should -Be 0
            $script:AzCalls.Count | Should -Be 1
            Get-ArgumentValue -Arguments $script:AzCalls[0].Arguments -Name '--name' | Should -BeExactly $script:ResourceGroup
            Get-ArgumentValue -Arguments $script:AzCalls[0].Arguments -Name '--subscription' | Should -BeExactly $script:SubscriptionId
            $script:Warnings.Count | Should -Be 0
        }

        It 'lists the broker hosts that are not running, and the exclusion tags on the session hosts' {
            $vms = @(
                (New-TestVm -Name 'lnxhost-0' -Tags @{ 'broker-role' = 'linux-host' }),
                (New-TestVm -Name 'LNXHOST-1' -Tags @{ 'broker-role' = 'linux-host' } -PowerState 'VM deallocated'),
                (New-TestVm -Name 'avdhost-0' -PowerState 'VM stopped'),
                (New-TestVm -Name 'avdhost-1' -Tags @{ 'broker-role' = 'avd-host'; excludeFromScaling = '' }),
                (New-TestVm -Name 'AvdHost-2' -Tags @{ 'broker-role' = 'avd-host'; ExcludeFromScaling = 'maintenance' } -PowerState 'VM deallocated'),
                (New-TestVm -Name 'avdhost-3' -NoPowerState),
                (New-TestVm -Name 'avdhost-4' -PowerState 'VM starting'),
                (New-TestVm -Name 'lnxhost-2' -Tags @{ 'broker-role' = 'linux-host'; excludeFromScaling = 'true' }),
                (New-TestVm -Name 'jumpbox' -Tags @{ role = 'jump' } -PowerState 'VM deallocated'),
                (New-TestVm -Name 'build-agent' -Tags @{ 'broker-role' = 'build' } -PowerState 'VM deallocated')
            )
            Add-AzResponse -Pattern 'group exists *' -Output 'true'
            Add-AzResponse -Pattern 'vm list *' -Output (ConvertTo-Json -InputObject $vms -Depth 5)

            $snapshot = Get-HostPowerStateSnapshot -SubscriptionId $script:SubscriptionId -ResourceGroupName $script:ResourceGroup

            $snapshot.Listed | Should -BeTrue
            $snapshot.NotRunning | Should -Be @('lnxhost-1', 'avdhost-0', 'avdhost-2', 'avdhost-4')
            $snapshot.NotRunningDisplay | Should -Be @('LNXHOST-1 (VM deallocated)', 'avdhost-0 (VM stopped)', 'AvdHost-2 (VM deallocated)', 'avdhost-4 (VM starting)')
            @($snapshot.AvdScalingExclusions.Keys) | Should -Be @('avdhost-1', 'avdhost-2')
            $snapshot.AvdScalingExclusions['avdhost-1'] | Should -BeExactly ''
            $snapshot.AvdScalingExclusions['avdhost-2'] | Should -BeExactly 'maintenance'
            $script:Warnings.Count | Should -Be 0

            $list = $script:AzCalls[1].Arguments
            Get-ArgumentValue -Arguments $list -Name '--resource-group' | Should -BeExactly $script:ResourceGroup
            Get-ArgumentValue -Arguments $list -Name '--subscription' | Should -BeExactly $script:SubscriptionId
            $list | Should -Contain '--show-details'
        }

        It 'lists one host that is not running as a list' {
            Add-AzResponse -Pattern 'group exists *' -Output 'true'
            Add-AzResponse -Pattern 'vm list *' -Output (ConvertTo-Json -InputObject @((New-TestVm -Name 'lnxhost-0' -Tags @{ 'broker-role' = 'linux-host' } -PowerState 'VM deallocated')) -Depth 5)

            $snapshot = Get-HostPowerStateSnapshot -SubscriptionId $script:SubscriptionId -ResourceGroupName $script:ResourceGroup

            , $snapshot.NotRunning | Should -BeOfType [string[]]
            $snapshot.NotRunning | Should -Be @('lnxhost-0')
        }

        It 'warns, and lists nothing, when <Description>' -TestCases @(
            @{ Description = 'it cannot tell whether the resource group exists'; GroupExitCode = 1; ListExitCode = 0; ListOutput = '[]'; Message = "*Could not check whether resource group 'rg-linuxbroker-dev' exists*Cannot modify extensions*" }
            @{ Description = 'it cannot list the VMs'; GroupExitCode = 0; ListExitCode = 1; ListOutput = ''; Message = "*Could not list the VMs in resource group 'rg-linuxbroker-dev'*run azd provision again*" }
            @{ Description = 'the VM list is not JSON'; GroupExitCode = 0; ListExitCode = 0; ListOutput = 'Traceback (most recent call last):'; Message = '*Could not list the VMs*' }
        ) {
            Add-AzResponse -Pattern 'group exists *' -Output 'true' -StdErr @('ERROR: something went wrong') -ExitCode $GroupExitCode
            Add-AzResponse -Pattern 'vm list *' -Output $ListOutput -ExitCode $ListExitCode

            $snapshot = Get-HostPowerStateSnapshot -SubscriptionId $script:SubscriptionId -ResourceGroupName $script:ResourceGroup

            $snapshot.Listed | Should -BeFalse
            @($snapshot.NotRunning).Count | Should -Be 0
            $snapshot.AvdScalingExclusions.Count | Should -Be 0
            $script:Warnings.Count | Should -Be 1
            $script:Warnings[0] | Should -BeLike $Message
        }
    }

    Context 'Finding the Azure Virtual Desktop service principal' {
        It 'uses the configured object ID without looking it up' {
            Resolve-AvdServicePrincipalObjectId -ConfiguredObjectId ' 3F2A1B0C-9D8E-4F7A-8B6C-5D4E3F2A1B0C ' -AppId $script:AvdAppId | Should -BeExactly $script:AvdObjectId
            $script:AzCalls.Count | Should -Be 0
        }

        It 'refuses a configured object ID that is not a GUID' {
            { Resolve-AvdServicePrincipalObjectId -ConfiguredObjectId 'Azure Virtual Desktop' -AppId $script:AvdAppId } |
                Should -Throw -ExpectedMessage "*'avdServicePrincipalObjectId'*GUID*"
        }

        It 'refuses an app ID that is not a GUID, and never searches by name' {
            { Resolve-AvdServicePrincipalObjectId -AppId "Azure Virtual Desktop' or displayName eq 'x" } |
                Should -Throw -ExpectedMessage "*'avdServicePrincipalAppId'*GUID*"
            $script:AzCalls.Count | Should -Be 0
        }

        It 'finds the service principal by app ID' {
            Add-AzResponse -Pattern 'ad sp list *' -Output (ConvertTo-Json -InputObject @($script:AvdObjectId))

            Resolve-AvdServicePrincipalObjectId -AppId $script:AvdAppId | Should -BeExactly $script:AvdObjectId

            $script:AzCalls.Count | Should -Be 1
            Get-ArgumentValue -Arguments $script:AzCalls[0].Arguments -Name '--filter' | Should -BeExactly "appId eq '$script:AvdAppId'"
        }

        It 'creates the service principal when the tenant has none' {
            Add-AzResponse -Pattern 'ad sp list *' -Output '[]'
            Add-AzResponse -Pattern 'ad sp create *' -Output $script:AvdObjectId

            Resolve-AvdServicePrincipalObjectId -AppId $script:AvdAppId | Should -BeExactly $script:AvdObjectId

            Get-ArgumentValue -Arguments $script:AzCalls[1].Arguments -Name '--id' | Should -BeExactly $script:AvdAppId
        }

        It 'does not create the service principal with SkipCreate' {
            Add-AzResponse -Pattern 'ad sp list *' -Output '[]'

            Resolve-AvdServicePrincipalObjectId -AppId $script:AvdAppId -SkipCreate | Should -BeExactly ''
            $script:AzCalls.Count | Should -Be 1
        }

        It 'answers with nothing when <Description>' -TestCases @(
            @{ Description = 'neither the lookup nor the creation works'; ListOutput = ''; ListExitCode = 1; CreateOutput = ''; CreateExitCode = 1 }
            @{ Description = 'the lookup and the creation answer with something other than a GUID'; ListOutput = '["not-a-guid"]'; ListExitCode = 0; CreateOutput = 'Insufficient privileges'; CreateExitCode = 0 }
            @{ Description = 'the lookup answers with something other than JSON'; ListOutput = 'oops'; ListExitCode = 0; CreateOutput = ''; CreateExitCode = 1 }
        ) {
            Add-AzResponse -Pattern 'ad sp list *' -Output $ListOutput -ExitCode $ListExitCode
            Add-AzResponse -Pattern 'ad sp create *' -Output $CreateOutput -ExitCode $CreateExitCode

            Resolve-AvdServicePrincipalObjectId -AppId $script:AvdAppId | Should -BeExactly ''
        }
    }

    Context 'Reading Azure Resource Manager through az rest' {
        It 'passes the query string as URL parameters, not in the URL' {
            Add-AzResponse -Pattern 'rest *' -Output '{"value":[]}'

            $result = Invoke-ArmGetRequest -Path "$script:SubscriptionScope/providers/Microsoft.Authorization/roleAssignments" -QueryParameters @('api-version=2022-04-01', "`$filter=atScope() and assignedTo('x')")

            $result.Succeeded | Should -BeTrue
            @($result.Response.value).Count | Should -Be 0
            $arguments = $script:AzCalls[0].Arguments
            Get-ArgumentValue -Arguments $arguments -Name '--method' | Should -BeExactly 'get'
            Get-ArgumentValue -Arguments $arguments -Name '--url' | Should -BeExactly "$script:SubscriptionScope/providers/Microsoft.Authorization/roleAssignments"
            $index = [array]::IndexOf($arguments, '--url-parameters')
            $arguments[$index + 1] | Should -BeExactly 'api-version=2022-04-01'
            $arguments[$index + 2] | Should -BeExactly "`$filter=atScope() and assignedTo('x')"
        }

        It 'reports what az wrote to stderr when the request fails' {
            Add-AzResponse -Pattern 'rest *' -StdErr @('ERROR: (AuthorizationFailed) The client does not have authorization.', 'Code: AuthorizationFailed') -ExitCode 1

            $result = Invoke-ArmGetRequest -Path "$script:SubscriptionScope/providers/Microsoft.Authorization/permissions" -QueryParameters @('api-version=2022-04-01')

            $result.Succeeded | Should -BeFalse
            $result.ErrorText | Should -BeLike '*(AuthorizationFailed)*Code: AuthorizationFailed'
        }

        It 'treats an answer that is not a JSON object as a failure' {
            Add-AzResponse -Pattern 'rest *' -Output 'null'

            (Invoke-ArmGetRequest -Path "$script:SubscriptionScope/providers/Microsoft.Authorization/permissions" -QueryParameters @('api-version=2022-04-01')).Succeeded | Should -BeFalse
        }
    }

    Context 'Checking whether the service principal holds the role' {
        It 'asks for the assignments at and above the subscription that apply to the service principal' {
            Add-AzResponse -Pattern 'rest *roleAssignments*' -Output (ConvertTo-ListJson)

            Get-AvdAutoscaleRoleState -PrincipalObjectId $script:AvdObjectId -SubscriptionId $script:SubscriptionId | Should -BeExactly 'NotAssigned'

            $arguments = $script:AzCalls[0].Arguments
            $index = [array]::IndexOf($arguments, '--url-parameters')
            $arguments[$index + 1] | Should -BeExactly 'api-version=2022-04-01'
            $arguments[$index + 2] | Should -BeExactly "`$filter=atScope() and assignedTo('$script:AvdObjectId')"
        }

        It 'answers Assigned for the role on <Description>' -TestCases @(
            @{ Description = 'the subscription'; Scope = '/subscriptions/6d1e0f3c-2b4a-4c5d-8e9f-0a1b2c3d4e5f' }
            @{ Description = 'the subscription, in other letter case'; Scope = '/Subscriptions/6D1E0F3C-2B4A-4C5D-8E9F-0A1B2C3D4E5F' }
            @{ Description = 'a management group'; Scope = '/providers/Microsoft.Management/managementGroups/contoso' }
            @{ Description = 'the root scope'; Scope = '/' }
        ) {
            Add-AzResponse -Pattern 'rest *roleAssignments*' -Output (ConvertTo-ListJson -Value @((New-RoleAssignment -Scope $Scope)))

            Get-AvdAutoscaleRoleState -PrincipalObjectId $script:AvdObjectId -SubscriptionId $script:SubscriptionId | Should -BeExactly 'Assigned'
        }

        It 'answers Assigned for the role given to a group the service principal belongs to' {
            $groupAssignment = New-RoleAssignment -PrincipalId ([guid]::NewGuid().ToString()) -PrincipalType 'Group'
            Add-AzResponse -Pattern 'rest *roleAssignments*' -Output (ConvertTo-ListJson -Value @($groupAssignment))

            Get-AvdAutoscaleRoleState -PrincipalObjectId $script:AvdObjectId -SubscriptionId $script:SubscriptionId | Should -BeExactly 'Assigned'
        }

        It 'answers Assigned for an assignment whose properties are not nested' {
            Add-AzResponse -Pattern 'rest *roleAssignments*' -Output (ConvertTo-ListJson -Value @((New-RoleAssignment -Flattened)))

            Get-AvdAutoscaleRoleState -PrincipalObjectId $script:AvdObjectId -SubscriptionId $script:SubscriptionId | Should -BeExactly 'Assigned'
        }

        It 'answers NotAssigned when the only assignment is <Description>' -TestCases @(
            @{ Description = 'on a resource group, which autoscale does not accept'; Assignment = @{ Scope = '/subscriptions/6d1e0f3c-2b4a-4c5d-8e9f-0a1b2c3d4e5f/resourceGroups/rg-linuxbroker-dev' } }
            @{ Description = 'on another subscription'; Assignment = @{ Scope = '/subscriptions/00000000-1111-2222-3333-444444444444' } }
            @{ Description = 'of another role'; Assignment = @{ RoleDefinitionId = '/subscriptions/6d1e0f3c-2b4a-4c5d-8e9f-0a1b2c3d4e5f/providers/Microsoft.Authorization/roleDefinitions/b24988ac-6180-42a0-ab88-20f7382dd24c' } }
            @{ Description = 'of a role whose ID only ends like it'; Assignment = @{ RoleDefinitionId = '/providers/Microsoft.Authorization/roleDefinitions/x40c5ff49-9181-41f8-ae61-143b0e78555e' } }
            @{ Description = 'for another service principal'; Assignment = @{ PrincipalId = '11111111-2222-3333-4444-555555555555' } }
        ) {
            Add-AzResponse -Pattern 'rest *roleAssignments*' -Output (ConvertTo-ListJson -Value @((New-RoleAssignment @Assignment)))

            Get-AvdAutoscaleRoleState -PrincipalObjectId $script:AvdObjectId -SubscriptionId $script:SubscriptionId | Should -BeExactly 'NotAssigned'
        }

        It 'answers Unknown when <Description>' -TestCases @(
            @{ Description = 'the request fails'; Output = $null; ExitCode = 1 }
            @{ Description = 'more pages might hold the role'; Output = 'next-page'; ExitCode = 0 }
        ) {
            $body = $null
            if ($Output -eq 'next-page') {
                $body = ConvertTo-ListJson -Value @((New-RoleAssignment -Scope '/subscriptions/6d1e0f3c-2b4a-4c5d-8e9f-0a1b2c3d4e5f/resourceGroups/rg')) -NextLink 'https://management.azure.com/next'
            }
            Add-AzResponse -Pattern 'rest *roleAssignments*' -Output $body -StdErr @('ERROR: Bad Request') -ExitCode $ExitCode

            Get-AvdAutoscaleRoleState -PrincipalObjectId $script:AvdObjectId -SubscriptionId $script:SubscriptionId | Should -BeExactly 'Unknown'
        }

        It 'still answers Assigned when more pages follow a match' {
            Add-AzResponse -Pattern 'rest *roleAssignments*' -Output (ConvertTo-ListJson -Value @((New-RoleAssignment)) -NextLink 'https://management.azure.com/next')

            Get-AvdAutoscaleRoleState -PrincipalObjectId $script:AvdObjectId -SubscriptionId $script:SubscriptionId | Should -BeExactly 'Assigned'
        }
    }

    Context 'Checking whether the signed-in account can assign roles' {
        It 'matches the action <Action> against <Patterns> as <Expected>' -TestCases @(
            @{ Action = 'Microsoft.Authorization/roleAssignments/write'; Patterns = @('*'); Expected = $true }
            @{ Action = 'Microsoft.Authorization/roleAssignments/write'; Patterns = @('Microsoft.Authorization/*'); Expected = $true }
            @{ Action = 'Microsoft.Authorization/roleAssignments/write'; Patterns = @('Microsoft.Authorization/*/Write'); Expected = $true }
            @{ Action = 'Microsoft.Authorization/roleAssignments/write'; Patterns = @('microsoft.authorization/roleassignments/WRITE'); Expected = $true }
            @{ Action = 'Microsoft.Authorization/roleAssignments/write'; Patterns = @('*/read', 'Microsoft.Support/*'); Expected = $false }
            @{ Action = 'Microsoft.Authorization/roleAssignments/write'; Patterns = @('Microsoft.Authorization/roleAssignments/writ.'); Expected = $false }
            @{ Action = 'Microsoft.Authorization/roleAssignments/write'; Patterns = @('Microsoft.Authorization/roleAssignments/write/extra'); Expected = $false }
            @{ Action = 'Microsoft.Authorization/roleAssignments/write'; Patterns = @($null, '', ' '); Expected = $false }
            @{ Action = 'Microsoft.Authorization/roleAssignments/write'; Patterns = @(); Expected = $false }
        ) {
            Test-ActionPermitted -Action $Action -Patterns $Patterns | Should -Be $Expected
        }

        It 'answers <Expected> for an account that is <Description>' -TestCases @(
            @{ Description = 'an Owner'; Permissions = @('Owner'); Expected = 'Yes' }
            @{ Description = 'a User Access Administrator'; Permissions = @('UserAccessAdministrator'); Expected = 'Yes' }
            @{ Description = 'a Contributor and a User Access Administrator'; Permissions = @('Contributor', 'UserAccessAdministrator'); Expected = 'Yes' }
            @{ Description = 'a Contributor'; Permissions = @('Contributor'); Expected = 'No' }
            @{ Description = 'a Reader'; Permissions = @('Reader'); Expected = 'No' }
            @{ Description = 'a Role Based Access Control Administrator limited by a condition'; Permissions = @('Conditional'); Expected = 'Unknown' }
            @{ Description = 'limited by a condition, and an Owner as well'; Permissions = @('Conditional', 'Owner'); Expected = 'Yes' }
        ) {
            $lookup = @{
                Owner = $script:OwnerPermission
                UserAccessAdministrator = $script:UserAccessAdministratorPermission
                Contributor = $script:ContributorPermission
                Reader = $script:ReaderPermission
                Conditional = $script:ConditionalPermission
            }
            $values = @($Permissions | ForEach-Object { $lookup[$_] })
            Add-AzResponse -Pattern 'rest *permissions*' -Output (ConvertTo-ListJson -Value $values)

            Test-CanAssignSubscriptionRole -SubscriptionId $script:SubscriptionId | Should -BeExactly $Expected

            Get-ArgumentValue -Arguments $script:AzCalls[0].Arguments -Name '--url' | Should -BeExactly "$script:SubscriptionScope/providers/Microsoft.Authorization/permissions"
        }

        It 'answers No when the account may not even read its permissions' {
            Add-AzResponse -Pattern 'rest *permissions*' -StdErr @("ERROR: (AuthorizationFailed) The client 'user@contoso.com' does not have authorization to perform action 'Microsoft.Authorization/permissions/read'.") -ExitCode 1

            Test-CanAssignSubscriptionRole -SubscriptionId $script:SubscriptionId | Should -BeExactly 'No'
        }

        It 'answers Unknown when <Description>' -TestCases @(
            @{ Description = 'the request fails for another reason'; Output = $null; StdErr = @('ERROR: HTTPSConnectionPool: Max retries exceeded'); ExitCode = 1 }
            @{ Description = 'more pages might grant it'; Output = 'next-page'; StdErr = @(); ExitCode = 0 }
        ) {
            $body = $null
            if ($Output -eq 'next-page') {
                $body = ConvertTo-ListJson -Value @($script:ReaderPermission) -NextLink 'https://management.azure.com/next'
            }
            Add-AzResponse -Pattern 'rest *permissions*' -Output $body -StdErr $StdErr -ExitCode $ExitCode

            Test-CanAssignSubscriptionRole -SubscriptionId $script:SubscriptionId | Should -BeExactly 'Unknown'
        }
    }

    Context 'Deciding whether the deployment assigns the role and the scaling plan' {
        BeforeEach {
            $plan = @{
                AvdSessionHostsDeployed = $true
                ScalingPlanRequested = $true
                StartVmOnConnect = $true
                AssignRoleRequested = $true
                ConfiguredObjectId = ''
                AppId = $script:AvdAppId
                SubscriptionId = $script:SubscriptionId
            }
            $ownerCommand = "az role assignment create --assignee-object-id $script:AvdObjectId --assignee-principal-type ServicePrincipal --role $script:RoleId --scope /subscriptions/$script:SubscriptionId"
        }

        It 'checks nothing when <Description>' -TestCases @(
            @{ Description = 'no AVD session hosts are deployed'; Settings = @{ AvdSessionHostsDeployed = $false } }
            @{ Description = 'neither the scaling plan nor Start VM on Connect is on'; Settings = @{ ScalingPlanRequested = $false; StartVmOnConnect = $false } }
        ) {
            foreach ($key in $Settings.Keys) {
                $plan[$key] = $Settings[$key]
            }

            $result = Resolve-AvdAutoscaleRolePlan @plan

            $result.AssignRole | Should -BeFalse
            $result.ServicePrincipalObjectId | Should -BeExactly ''
            $result.ScalingPlanEnabled | Should -Be $plan.ScalingPlanRequested
            $script:AzCalls.Count | Should -Be 0
            $script:Warnings.Count | Should -Be 0
        }

        It 'assigns the role, quietly, when it is missing and the account can assign it' {
            Set-RoleCheck -RoleState 'NotAssigned' -CanAssign 'Yes'

            $result = Resolve-AvdAutoscaleRolePlan @plan

            $result.AssignRole | Should -BeTrue
            $result.ScalingPlanEnabled | Should -BeTrue
            $result.ServicePrincipalObjectId | Should -BeExactly $script:AvdObjectId
            $result.Summary | Should -BeLike '*gives the Azure Virtual Desktop service principal Desktop Virtualization Power On Off Contributor*'
            $script:Warnings.Count | Should -Be 0
        }

        It 'leaves out the role assignment, and keeps the plan, when the role is already assigned' {
            Set-RoleCheck -RoleState 'Assigned'

            $result = Resolve-AvdAutoscaleRolePlan @plan

            $result.AssignRole | Should -BeFalse
            $result.ScalingPlanEnabled | Should -BeTrue
            $result.ServicePrincipalObjectId | Should -BeExactly $script:AvdObjectId
            @($script:AzCalls | Where-Object { $_.CommandLine -like 'rest *permissions*' }).Count | Should -Be 0
            $script:Warnings.Count | Should -Be 0
        }

        It 'leaves out the role and the plan assignment, with the command an Owner can run, when the account cannot assign roles' {
            Set-RoleCheck -RoleState 'NotAssigned' -CanAssign 'No'

            $result = Resolve-AvdAutoscaleRolePlan @plan

            $result.AssignRole | Should -BeFalse
            $result.ScalingPlanEnabled | Should -BeFalse
            $script:Warnings.Count | Should -Be 1
            $script:Warnings[0] | Should -BeLike "*cannot assign roles on subscription '$script:SubscriptionId'*scaling plan is deployed but assigned to no host pool*Start VM on Connect cannot start session hosts*run azd provision again*assignAvdAutoscaleRole to false*"
            $script:Warnings[0] | Should -BeLike "*Command: $ownerCommand"
        }

        It 'names only <Description> when the account cannot assign roles' -TestCases @(
            @{ Description = 'Start VM on Connect'; ScalingPlanRequested = $false; StartVmOnConnect = $true; Present = '*Start VM on Connect cannot start session hosts*'; Absent = '*scaling plan is deployed*' }
            @{ Description = 'the scaling plan'; ScalingPlanRequested = $true; StartVmOnConnect = $false; Present = '*scaling plan is deployed but assigned to no host pool*'; Absent = '*Start VM on Connect*' }
        ) {
            $plan.ScalingPlanRequested = $ScalingPlanRequested
            $plan.StartVmOnConnect = $StartVmOnConnect
            Set-RoleCheck -RoleState 'NotAssigned' -CanAssign 'No'

            $result = Resolve-AvdAutoscaleRolePlan @plan

            $result.AssignRole | Should -BeFalse
            $result.ScalingPlanEnabled | Should -BeFalse
            $script:Warnings[0] | Should -BeLike $Present
            $script:Warnings[0] | Should -Not -BeLike $Absent
        }

        It 'assigns the role, and says how to recover, when <Description>' -TestCases @(
            @{ Description = 'it cannot tell whether the role is assigned'; RoleState = 'Unknown'; CanAssign = 'Yes' }
            @{ Description = 'it cannot tell whether the account can assign it'; RoleState = 'NotAssigned'; CanAssign = 'Unknown' }
            @{ Description = 'it can tell neither'; RoleState = 'Unknown'; CanAssign = 'Unknown' }
        ) {
            Set-RoleCheck -RoleState $RoleState -CanAssign $CanAssign

            $result = Resolve-AvdAutoscaleRolePlan @plan

            $result.AssignRole | Should -BeTrue
            $result.ScalingPlanEnabled | Should -BeTrue
            $script:Warnings.Count | Should -Be 1
            $script:Warnings[0] | Should -BeLike '*RoleAssignmentExists*set assignAvdAutoscaleRole to false*AuthorizationFailed*'
            $script:Warnings[0] | Should -BeLike "*Command: $ownerCommand"
        }

        It 'leaves out the role and the plan assignment when the service principal cannot be found or created' {
            Set-RoleCheck -ServicePrincipalMissing

            $result = Resolve-AvdAutoscaleRolePlan @plan

            $result.AssignRole | Should -BeFalse
            $result.ScalingPlanEnabled | Should -BeFalse
            $result.ServicePrincipalObjectId | Should -BeExactly ''
            $script:Warnings.Count | Should -Be 1
            $script:Warnings[0] | Should -BeLike "*app ID $script:AvdAppId*Set avdServicePrincipalObjectId*assignAvdAutoscaleRole to false*"
            @($script:AzCalls | Where-Object { $_.CommandLine -like 'rest *' }).Count | Should -Be 0
        }

        It 'uses the configured object ID' {
            $plan.ConfiguredObjectId = $script:AvdObjectId
            Add-AzResponse -Pattern 'rest *roleAssignments*' -Output (ConvertTo-ListJson -Value @((New-RoleAssignment)))

            $result = Resolve-AvdAutoscaleRolePlan @plan

            $result.ServicePrincipalObjectId | Should -BeExactly $script:AvdObjectId
            @($script:AzCalls | Where-Object { $_.CommandLine -like 'ad *' }).Count | Should -Be 0
        }

        Context 'with assignAvdAutoscaleRole set to false' {
            BeforeEach {
                $plan.AssignRoleRequested = $false
            }

            It 'keeps the plan and warns when the role is missing' {
                Set-RoleCheck -RoleState 'NotAssigned'

                $result = Resolve-AvdAutoscaleRolePlan @plan

                $result.AssignRole | Should -BeFalse
                $result.ScalingPlanEnabled | Should -BeTrue
                $result.ServicePrincipalObjectId | Should -BeExactly $script:AvdObjectId
                $result.Summary | Should -BeLike '*assignAvdAutoscaleRole is false*'
                $script:Warnings.Count | Should -Be 1
                $script:Warnings[0] | Should -BeLike '*Azure refuses to assign the scaling plan to the host pool, which fails the deployment*Start VM on Connect cannot start session hosts*'
                $script:Warnings[0] | Should -BeLike "*command: $ownerCommand"
                @($script:AzCalls | Where-Object { $_.CommandLine -like 'rest *permissions*' }).Count | Should -Be 0
            }

            It 'does not warn when the role is assigned, or when it cannot tell' -TestCases @(
                @{ RoleState = 'Assigned' }
                @{ RoleState = 'Unknown' }
            ) {
                Set-RoleCheck -RoleState $RoleState

                $result = Resolve-AvdAutoscaleRolePlan @plan

                $result.AssignRole | Should -BeFalse
                $result.ScalingPlanEnabled | Should -BeTrue
                $script:Warnings.Count | Should -Be 0
            }

            It 'neither creates the service principal nor warns when the tenant has none' {
                Set-RoleCheck -ServicePrincipalMissing

                $result = Resolve-AvdAutoscaleRolePlan @plan

                $result.AssignRole | Should -BeFalse
                $result.ScalingPlanEnabled | Should -BeTrue
                $result.ServicePrincipalObjectId | Should -BeExactly ''
                @($script:AzCalls | Where-Object { $_.CommandLine -like 'ad sp create *' }).Count | Should -Be 0
                $script:Warnings.Count | Should -Be 0
            }
        }
    }
}

Describe 'The deployment settings and the Bicep they feed' {
    BeforeAll {
        # Git can check the files out with CRLF line endings, which $ in a multiline pattern does
        # not match before.
        function Read-RepositoryText {
            param([Parameter(Mandatory = $true)][string]$RelativePath)

            return [System.IO.File]::ReadAllText((Join-Path $script:RepoRoot $RelativePath)).Replace("`r`n", "`n")
        }

        $script:ScriptText = Read-RepositoryText -RelativePath 'deploy\Initialize-DeploymentEnvironment.ps1'
        $script:MainBicep = Read-RepositoryText -RelativePath 'deploy\bicep\main.bicep'
        $script:ResourcesBicep = Read-RepositoryText -RelativePath 'deploy\bicep\main.resources.bicep'
        $script:AvdBicep = Read-RepositoryText -RelativePath 'deploy\bicep\modules\AVD\main.bicep'
        $script:LinuxBicep = Read-RepositoryText -RelativePath 'deploy\bicep\modules\Linux\main.bicep'
        $script:ScalingPlanBicep = Read-RepositoryText -RelativePath 'deploy\bicep\modules\AVD\scaling-plan.bicep'
        $script:MainBicepParameters = @([regex]::Matches($script:MainBicep, '(?m)^param\s+(\w+)\s') | ForEach-Object { $_.Groups[1].Value })
        $script:ScriptParameters = @([regex]::Matches($script:ScriptText, "-ParameterName '(\w+)'") | ForEach-Object { $_.Groups[1].Value })
    }

    It 'writes only parameters main.bicep declares, each once' {
        $script:ScriptParameters.Count | Should -BeGreaterThan 40
        foreach ($name in $script:ScriptParameters) {
            $script:MainBicepParameters | Should -Contain $name
        }
        @($script:ScriptParameters | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name }) | Should -Be @()
    }

    It 'writes every autoscale parameter' {
        foreach ($name in @(
                'avdScalingPlanEnabled', 'avdStartVmOnConnect', 'avdScalingPlanTimeZone', 'avdScalingPlanRampUpStart', 'avdScalingPlanPeakStart',
                'avdScalingPlanRampDownStart', 'avdScalingPlanOffPeakStart', 'avdScalingPlanRampUpMinimumHostsPct',
                'avdScalingPlanRampUpCapacityThresholdPct', 'avdScalingPlanRampDownMinimumHostsPct', 'avdScalingPlanRampDownCapacityThresholdPct',
                'avdScalingPlanWeekendMinimumHostsPct', 'avdScalingExclusions', 'hostNamesNotRunning', 'avdServicePrincipalObjectId',
                'assignAvdAutoscaleRole')) {
            $script:ScriptParameters | Should -Contain $name
            $script:MainBicepParameters | Should -Contain $name
        }
    }

    It 'lists in the example parameters file only parameters main.bicep declares' {
        $example = ConvertFrom-Json -InputObject (Read-RepositoryText -RelativePath 'deploy\bicep\main.parameters.example.json')
        $names = @($example.parameters.PSObject.Properties | ForEach-Object { $_.Name })
        $names | Should -Contain 'avdScalingPlanEnabled'
        $names | Should -Contain 'hostNamesNotRunning'
        foreach ($name in $names) {
            $script:MainBicepParameters | Should -Contain $name
        }
    }

    It 'leaves out every VM extension of a host that is not running, in the <Module> module' -TestCases @(
        @{ Module = 'AVD'; Expected = 3 }
        @{ Module = 'Linux'; Expected = 1 }
    ) {
        $text = $script:AvdBicep
        if ($Module -eq 'Linux') {
            $text = $script:LinuxBicep
        }

        $text | Should -Match ([regex]::Escape('var skipExtensionVmNamesLower = [for vmName in skipExtensionVmNames: toLower(vmName)]'))
        $lines = $text -split "`r?`n"
        $extensions = 0
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match "^resource\s+\w+\s+'Microsoft\.Compute/virtualMachines/extensions@") {
                $extensions++
                $lines[$i + 1] | Should -Match ([regex]::Escape('for (name, i) in vmNames: if (!contains(skipExtensionVmNamesLower, toLower(name))) {'))
            }
        }
        $extensions | Should -Be $Expected
    }

    It 'passes the hosts that are not running and the exclusion tags to the host modules' {
        $script:MainBicep | Should -Match '(?m)^\s+hostNamesNotRunning: hostNamesNotRunning$'
        $script:MainBicep | Should -Match '(?m)^\s+avdScalingExclusions: avdScalingExclusions$'
        $script:MainBicep | Should -Match '(?m)^\s+avdStartVmOnConnect: avdStartVmOnConnect$'
        [regex]::Matches($script:ResourcesBicep, '(?m)^\s+skipExtensionVmNames: hostNamesNotRunning$').Count | Should -Be 2
        $script:ResourcesBicep | Should -Match '(?m)^\s+scalingExclusions: avdScalingExclusions$'
        $script:ResourcesBicep | Should -Match '(?m)^\s+startVmOnConnect: avdStartVmOnConnect$'
    }

    It 'writes back the tag the scaling plan excludes session hosts by' {
        $script:ScalingPlanBicep | Should -Match "(?m)^param exclusionTag string = 'excludeFromScaling'$"
        $script:AvdBicep | Should -Match ([regex]::Escape('tags: contains(scalingExclusions, toLower(name))'))
        $script:AvdBicep | Should -Match ([regex]::Escape('excludeFromScaling: scalingExclusions[toLower(name)]'))
        $script:FunctionDefinitions['Get-HostPowerStateSnapshot'].Extent.Text | Should -Match ([regex]::Escape("-Name 'excludeFromScaling'"))
    }

    It 'turns Start VM on Connect on or off in both places that write the host pool' {
        $script:AvdBicep | Should -Match '(?m)^\s+startVMOnConnect: startVmOnConnect$'
        [regex]::Matches($script:AvdBicep, '(?m)^\s+startVMOnConnect: startVmOnConnect$').Count | Should -Be 2
        $tokenBicep = Read-RepositoryText -RelativePath 'deploy\bicep\modules\AVD\token.bicep'
        $tokenBicep | Should -Match '(?m)^\s+startVMOnConnect: startVMOnConnect$'
    }

    It 'assigns the scaling plan only after the role and the host pool' {
        $match = [regex]::Match($script:MainBicep, "(?s)module avdScalingPlan 'modules/AVD/scaling-plan\.bicep'.*?dependsOn:\s*\[(?<deps>[^\]]*)\]")
        $match.Success | Should -BeTrue
        $dependencies = @($match.Groups['deps'].Value -split '\s+' | Where-Object { $_ })
        $dependencies | Should -Contain 'resources'
        $dependencies | Should -Contain 'avdAutoscaleRole'
    }

    It 'checks for the same role main.bicep assigns, for the same service principal' {
        $bicepRole = [regex]::Match($script:MainBicep, "var avdPowerOnOffContributorRoleGuid = '([0-9a-f-]{36})'").Groups[1].Value
        $bicepRole | Should -BeExactly $script:RoleId
        $script:ScriptText | Should -Match ([regex]::Escape("`$avdAutoscaleRoleDefinitionId = '$bicepRole'"))
        foreach ($name in @('Get-AvdAutoscaleRoleState', 'Resolve-AvdAutoscaleRolePlan')) {
            $parameter = $script:FunctionDefinitions[$name].Body.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'RoleDefinitionId' }
            $parameter.DefaultValue.Value | Should -BeExactly $bicepRole
        }

        $script:ScriptText | Should -Match ([regex]::Escape("`$avdServicePrincipalAppId = '$script:AvdAppId'"))
        $script:MainBicep | Should -Match ([regex]::Escape("app ID $script:AvdAppId"))
    }
}
