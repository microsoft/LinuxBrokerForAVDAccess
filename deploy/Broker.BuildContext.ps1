. "$PSScriptRoot\Broker.Deployment.Common.ps1"

function Test-BrokerContainerSourcePath {
    param([Parameter(Mandatory)][string]$RelativePath)
    $path = $RelativePath.Replace('\', '/')
    if ($path -eq '.dockerignore') { return $true }
    if ($path -notmatch '^(api|front_end|task)/' -or $path -match '(^|/)\.\.(/|$)') { return $false }
    if ($path -match '(^|/)(\.azure|\.venv|__pycache__|\.pytest_cache|node_modules|flask_session|bin|obj|\.artifacts|artifacts)(/|$)' -or
        $path -match '(^|/)(\.env[^/]*|local\.settings\.json)$' -or
        $path -match '\.(pyc|pyo|log|db)$' -or $path.StartsWith('front_end/static/dist/')) {
        return $false
    }
    return $true
}

function New-BrokerContainerBuildContext {
    param([Parameter(Mandatory)][string]$SourceRoot, [Parameter(Mandatory)][string]$Destination)
    $SourceRoot = (Resolve-Path -LiteralPath $SourceRoot).Path
    if (Test-Path -LiteralPath $Destination) { throw 'Build context staging directory must be new.' }
    $files = & git -C $SourceRoot -c core.quotepath=false ls-files --cached --others --exclude-standard -- api front_end task .dockerignore 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'Cannot enumerate the current tracked/unignored application build inputs.' }
    $null = New-Item -ItemType Directory -Path $Destination
    foreach ($relative in $files | Select-Object -Unique) {
        if (-not (Test-BrokerContainerSourcePath $relative)) { continue }
        $relative = $relative.Replace('/', '\')
        $source = Join-Path $SourceRoot $relative
        if (-not (Test-Path -LiteralPath $source)) { continue } # Honor tracked working-tree deletions.
        $item = Get-Item -LiteralPath $source -Force
        if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'Application build inputs must be regular files, not submodules or reparse points.'
        }
        $parent = $item.Directory
        while ($parent -and $parent.FullName -ne $SourceRoot) {
            if ($parent.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'A build-input parent is a reparse point.' }
            $parent = $parent.Parent
        }
        $target = Join-Path $Destination $relative
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force
        Copy-Item -LiteralPath $source -Destination $target
    }
    foreach ($directory in @('api', 'front_end', 'task')) {
        if (-not (Test-Path -LiteralPath (Join-Path $Destination "$directory\Dockerfile") -PathType Leaf)) {
            throw "The reviewed build context is missing '$directory\Dockerfile'."
        }
    }
}
