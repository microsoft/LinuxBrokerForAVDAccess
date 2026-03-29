[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$ApiClientId
)

$ErrorActionPreference = 'Stop'

$virtualMachines = az vm list --resource-group $ResourceGroupName --output json | ConvertFrom-Json
if (-not $virtualMachines) {
    Write-Host "No virtual machines found in resource group '$ResourceGroupName'."
    exit 0
}

$roleMappings = @(
    @{ Tag = 'linux-host'; RoleValue = 'LinuxHost' }
    @{ Tag = 'avd-host'; RoleValue = 'AvdHost' }
)

foreach ($mapping in $roleMappings) {
    $matchingVms = $virtualMachines | Where-Object { $_.tags.'broker-role' -eq $mapping.Tag }
    foreach ($virtualMachine in $matchingVms) {
        $principalId = az vm show --resource-group $ResourceGroupName --name $virtualMachine.name --query identity.principalId --output tsv
        if ([string]::IsNullOrWhiteSpace($principalId)) {
            Write-Warning "Skipping VM '$($virtualMachine.name)' because no managed identity principal id was found."
            continue
        }

        & "$PSScriptRoot/Assign-ServicePrincipalApiRole.ps1" `
            -PrincipalId $principalId `
            -ApiClientId $ApiClientId `
            -RoleValue $mapping.RoleValue
    }
}
