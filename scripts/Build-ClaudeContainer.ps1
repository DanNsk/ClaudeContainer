<#
.SYNOPSIS
    Builds a Claude Code Windows container image.

.DESCRIPTION
    Builds an auth-agnostic Docker image for running Claude Code in Windows containers.
    Authentication is handled at runtime via Start-ClaudeContainer.ps1.

.PARAMETER Config
    Path to JSON config file (claude-container.json). Reads image, sdk, instructions, extensions sections.

.PARAMETER ImageName
    Docker image name. Default: claude-agent

.PARAMETER ImageTag
    Docker image tag. Default: dev

.PARAMETER DotNetVersion
    .NET SDK version channel. Default: 10.0
    Accepts: 8.0, 9.0, 10.0, LTS, STS

.PARAMETER NodeVersion
    Node.js major version. Default: 22

.PARAMETER MdFiles
    Paths or wildcards for MD files to copy. Default: ./docs/*.md, fallback ~/.claude/*.md

.PARAMETER NoDefaultMd
    Skip creating default CLAUDE.md if no MD files found.

.PARAMETER McpServers
    MCP server configurations. Format: "name:command:args" or JSON.

.PARAMETER PythonVersion
    Python version to install. Default: 3.12

.PARAMETER IncludeBuildTools
    Install Visual Studio Build Tools with MSBuild. Default: true

.PARAMETER BaseImage
    Windows Server base image. Default: auto-detect from host OS.
    Accepts: ltsc2022, ltsc2019, ltsc2016, or auto

.PARAMETER UseBun
    Install Bun JavaScript runtime.

.PARAMETER UseUv
    Install uv Python package manager.

.PARAMETER AzDoAuth
    Configure Azure DevOps authentication for git repos and NuGet feeds.
    Installs credential provider and configures git to use SYSTEM_ACCESSTOKEN.

.PARAMETER Reuse
    Skip build if image already exists.

.EXAMPLE
    .\Build-ClaudeContainer.ps1
    Builds claude-agent:dev with .NET 10 and Node.js 20.

.EXAMPLE
    .\Build-ClaudeContainer.ps1 -Config "claude-container.json"
    Builds using settings from JSON config file.

.EXAMPLE
    .\Build-ClaudeContainer.ps1 -DotNetVersion 8.0 -MdFiles "./custom/*.md"
    Builds with .NET 8 and custom MD files.

.EXAMPLE
    .\Build-ClaudeContainer.ps1 -NodeVersion 22
    Builds with Node.js 22.

.EXAMPLE
    .\Build-ClaudeContainer.ps1 -McpServers @("filesystem:npx:-y @modelcontextprotocol/server-filesystem C:\source")
    Builds with custom MCP server.
#>
param(
    [string]$Config,
    [string]$ImageName,
    [string]$ImageTag,
    [string]$DotNetVersion,
    [string]$NodeVersion,
    [string]$PythonVersion,
    [switch]$IncludeBuildTools,
    [string]$BaseImage,
    [switch]$UseBun,
    [switch]$UseUv,
    [switch]$AzDoAuth,
    [string[]]$MdFiles,
    [switch]$NoDefaultMd,
    [string[]]$McpServers,
    [switch]$Reuse,
    [switch]$InstallAsAdmin
)

$ErrorActionPreference = "Stop"

# Load config file if specified
$configData = $null
if ($Config -and (Test-Path $Config)) {
    $configData = Get-Content $Config -Raw | ConvertFrom-Json
}

# Apply defaults with config fallback
if (-not $ImageName) {
    $ImageName = if ($configData -and $configData.image.name) { $configData.image.name } else { "claude-agent" }
}
if (-not $ImageTag) {
    $ImageTag = if ($configData -and $configData.image.tag) { $configData.image.tag } else { "dev" }
}
if (-not $DotNetVersion) {
    $DotNetVersion = if ($configData -and $configData.sdk.dotNetVersion) { $configData.sdk.dotNetVersion } else { "10.0" }
}
if (-not $NodeVersion) {
    $NodeVersion = if ($configData -and $configData.sdk.nodeVersion) { $configData.sdk.nodeVersion } else { "22" }
}
if (-not $MdFiles -and $configData -and $configData.instructions.mdFiles) {
    $MdFiles = $configData.instructions.mdFiles
}
if (-not $NoDefaultMd -and $configData -and $configData.instructions.noDefaultMd) {
    $NoDefaultMd = $configData.instructions.noDefaultMd
}
if (-not $InstallAsAdmin -and $configData -and $configData.container.installAsAdmin) {
    $InstallAsAdmin = $configData.container.installAsAdmin
}
if (-not $PythonVersion) {
    $PythonVersion = if ($configData -and $configData.sdk.pythonVersion) { $configData.sdk.pythonVersion } else { "3.12" }
}
# IncludeBuildTools defaults to true
if (-not $PSBoundParameters.ContainsKey('IncludeBuildTools')) {
    $IncludeBuildTools = if ($configData -and $null -ne $configData.sdk.includeBuildTools) { $configData.sdk.includeBuildTools } else { $true }
}
if (-not $BaseImage) {
    $BaseImage = if ($configData -and $configData.image.baseImage) { $configData.image.baseImage } else { "auto" }
}
if (-not $UseBun -and $configData -and $configData.sdk.useBun) {
    $UseBun = $configData.sdk.useBun
}
if (-not $UseUv -and $configData -and $configData.sdk.useUv) {
    $UseUv = $configData.sdk.useUv
}
if (-not $AzDoAuth -and $configData -and $configData.azdo.auth) {
    $AzDoAuth = $configData.azdo.auth
}

# Detect host OS version for base image selection
if ($BaseImage -eq "auto") {
    $osVersion = [System.Environment]::OSVersion.Version
    $buildNumber = $osVersion.Build

    # Map Windows build numbers to Server versions
    # Windows Server 2022: Build 20348+
    # Windows Server 2019: Build 17763
    # Windows Server 2016: Build 14393
    if ($buildNumber -ge 20348) {
        $BaseImage = "ltsc2022"
    } elseif ($buildNumber -ge 17763) {
        $BaseImage = "ltsc2019"
    } elseif ($buildNumber -ge 14393) {
        $BaseImage = "ltsc2016"
    } else {
        Write-Warning "Unknown Windows build $buildNumber, defaulting to ltsc2022"
        $BaseImage = "ltsc2022"
    }
    Write-Host "Detected host OS build $buildNumber, using base image: $BaseImage"
}

# Set user path based on InstallAsAdmin
$containerUser = if ($InstallAsAdmin) { "ContainerAdministrator" } else { "ContainerUser" }
$userPath = "C:\Users\$containerUser"

$FullImageName = "${ImageName}:${ImageTag}"

if ($Reuse) {
    $existingImage = docker images -q $FullImageName 2>$null
    if ($existingImage) {
        Write-Host "Image $FullImageName exists, skipping build"
        exit 0
    }
}

Write-Host "Building Claude container image: $FullImageName"

# Create temp build context
$tempPath = Join-Path $env:TEMP "claude-build-$(Get-Random)"
New-Item -ItemType Directory -Path "$tempPath\.claude" -Force | Out-Null
New-Item -ItemType Directory -Path "$tempPath\azdo" -Force | Out-Null

try {
    # Resolve MD files
    $mdFilesCopied = 0
    $resolvedMdFiles = @()

    if ($MdFiles -and $MdFiles.Count -gt 0) {
        foreach ($pattern in $MdFiles) {
            $resolved = Get-ChildItem -Path $pattern -ErrorAction SilentlyContinue
            $resolvedMdFiles += $resolved
        }
    }

    # Fallback to defaults if no explicit MdFiles specified
    if ($resolvedMdFiles.Count -eq 0 -and -not $MdFiles) {
        # Try ./docs/*.md first
        $docsPath = Join-Path $PSScriptRoot "..\docs\*.md"
        $resolvedMdFiles = Get-ChildItem -Path $docsPath -ErrorAction SilentlyContinue

        # Fallback to ~/.claude/*.md
        if ($resolvedMdFiles.Count -eq 0) {
            $userClaudeDir = "$env:USERPROFILE\.claude"
            Get-ChildItem -Path $userClaudeDir -Filter "CLAUDE*.md" -ErrorAction SilentlyContinue | ForEach-Object {
                $resolvedMdFiles += $_
            }
            if (Test-Path "$userClaudeDir\AGENTS.md") {
                $resolvedMdFiles += Get-Item "$userClaudeDir\AGENTS.md"
            }
        }
    }

    # Copy resolved MD files
    foreach ($file in $resolvedMdFiles) {
        Copy-Item $file.FullName "$tempPath\.claude\$($file.Name)"
        Write-Host "  [OK] $($file.Name)" -ForegroundColor Green
        $mdFilesCopied++
    }

    # Create default CLAUDE.md if none found and not suppressed
    if ($mdFilesCopied -eq 0 -and -not $NoDefaultMd) {
        $defaultMd = @"
# Container execution mode

You are running in an automated container. There is no human to ask questions.

## Guidelines

- Complete tasks fully without asking for clarification
- If uncertain, make reasonable assumptions and document them
- Output results clearly
- Report errors with enough detail to debug
"@
        $defaultMd | Set-Content "$tempPath\.claude\CLAUDE.md"
        Write-Host "  [OK] CLAUDE.md (default)" -ForegroundColor Yellow
    }

    # Append AZDO-TOOLS.md include to CLAUDE.md if tools documentation exists
    $azdoToolsMd = "$tempPath\.claude\AZDO-TOOLS.md"
    $claudeMd = "$tempPath\.claude\CLAUDE.md"
    if ((Test-Path $azdoToolsMd) -and (Test-Path $claudeMd)) {
        Add-Content -Path $claudeMd -Value "`n@~/.claude/AZDO-TOOLS.md"
        Write-Host "  [OK] Added AZDO-TOOLS.md include to CLAUDE.md" -ForegroundColor Green
    }

    # Copy Azure DevOps scripts
    $azdoScriptsPath = Join-Path $PSScriptRoot "azdo"
    if (Test-Path $azdoScriptsPath) {
        $azdoFiles = Get-ChildItem -Path $azdoScriptsPath -Filter "*.ps1" -ErrorAction SilentlyContinue
        foreach ($file in $azdoFiles) {
            Copy-Item $file.FullName "$tempPath\azdo\$($file.Name)"
            Write-Host "  [OK] azdo/$($file.Name)" -ForegroundColor Green
        }
    }

    # Generate entrypoint-watchdog.ps1
    $entrypoint = @'
$idleTimeout = if ($env:IDLE_TIMEOUT) { [int]$env:IDLE_TIMEOUT } else { 300 }
$strictMode = if ($env:WATCHDOG_STRICT) { $env:WATCHDOG_STRICT -ne "false" } else { $true }
$lastActivity = Get-Date

$modeDesc = if ($strictMode) { "strict (prompt mode only)" } else { "non-strict (any claude)" }
Write-Host "Claude container ready. Idle timeout: $idleTimeout seconds, mode: $modeDesc"

while ($true) {
    $claudeActive = $false

    if ($strictMode) {
        # Only detect Claude processes with -p parameter (prompt mode)
        $procs = Get-CimInstance Win32_Process -Filter "Name='claude.exe'" -ErrorAction SilentlyContinue
        foreach ($proc in $procs) {
            if ($proc.CommandLine -match '\s-p\s') {
                $claudeActive = $true
                break
            }
        }
    } else {
        # Detect any Claude process
        $claudeActive = $null -ne (Get-Process -Name "claude" -ErrorAction SilentlyContinue)
    }

    if ($claudeActive) {
        $lastActivity = Get-Date
    } else {
        $idle = ((Get-Date) - $lastActivity).TotalSeconds
        if ($idle -gt $idleTimeout) {
            Write-Host "Idle timeout ($idleTimeout s) reached. Shutting down."
            exit 0
        }
    }
    Start-Sleep -Seconds 5
}
'@
    $entrypoint | Set-Content "$tempPath\entrypoint-watchdog.ps1"

    # Build MCP add commands
    # Verified syntax: claude mcp add <name> --transport stdio -s user cmd /c <command> <args>
    $mcpCommands = ""

    # Process McpServers from command line (format: name:command:args for stdio)
    if ($McpServers) {
        foreach ($server in $McpServers) {
            if ($server.StartsWith("{")) {
                # JSON format
                $mcpCommands += "    claude mcp add-json custom-$([guid]::NewGuid().ToString().Substring(0,8)) '$server'; ```n"
            } else {
                # name:command:args format (stdio transport assumed)
                $parts = $server -split ":", 3
                if ($parts.Count -ge 2) {
                    $name = $parts[0]
                    $command = $parts[1]
                    $cmdArgs = if ($parts.Count -eq 3) { $parts[2] } else { "" }
                    # Add cmd /c prefix for Node.js-based commands
                    if ($command -in @("npx", "bunx", "uvx", "node")) {
                        $mcpCommands += "    claude mcp add $name --transport stdio -s user cmd /c $command $cmdArgs; ```n"
                    } else {
                        $mcpCommands += "    claude mcp add $name --transport stdio -s user $command $cmdArgs; ```n"
                    }
                }
            }
        }
    }

    # Process MCP servers from config file
    if ($configData -and $configData.extensions.mcpServers) {
        foreach ($server in $configData.extensions.mcpServers) {
            $name = $server.name
            $transport = if ($server.transport) { $server.transport } else { "stdio" }

            if ($transport -eq "http") {
                # HTTP transport uses url
                $url = $server.url
                $mcpCommands += "    claude mcp add $name --transport http -s user $url; ```n"
            } else {
                # stdio transport uses command + args
                $command = $server.command
                $cmdArgs = $server.args -join ' '
                # Add cmd /c prefix for Node.js-based commands
                if ($command -in @("npx", "bunx", "uvx", "node")) {
                    $mcpCommands += "    claude mcp add $name --transport stdio -s user cmd /c $command $cmdArgs; ```n"
                } else {
                    $mcpCommands += "    claude mcp add $name --transport stdio -s user $command $cmdArgs; ```n"
                }
            }
        }
    }

    # Build plugin commands
    $pluginCommands = ""

    # Process marketplaces from config file
    if ($configData -and $configData.extensions.marketplaces) {
        foreach ($marketplace in $configData.extensions.marketplaces) {
            $pluginCommands += "    claude plugin marketplace add $($marketplace.url); ```n"
        }
    }

    # Process plugins from config file
    if ($configData -and $configData.extensions.plugins) {
        foreach ($plugin in $configData.extensions.plugins) {
            $pluginCommands += "    claude plugin install $plugin; ```n"
        }
    }

    # Resolve Node.js version to full version number
    $nodeFullVersion = "${NodeVersion}.0.0"
    # Use known LTS versions for common major versions
    switch ($NodeVersion) {
        "18" { $nodeFullVersion = "18.20.5" }
        "20" { $nodeFullVersion = "20.18.0" }
        "22" { $nodeFullVersion = "22.12.0" }
    }

    # Generate Dockerfile
    $dockerfile = @"
# escape=``
# Claude Code Windows Container
# Generated: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")

FROM mcr.microsoft.com/powershell:lts-windowsservercore-$BaseImage

SHELL ["powershell", "-Command", "`$ErrorActionPreference = 'Stop';"]

# Set user environment (InstallAsAdmin: $InstallAsAdmin)
ENV HOME=$userPath
ENV USERPROFILE=$userPath

# Create container user directories
RUN New-Item -ItemType Directory -Path '$userPath\.claude' -Force | Out-Null; ``
    New-Item -ItemType Directory -Path '$userPath\.local\bin' -Force | Out-Null

# Install Node.js $NodeVersion
RUN Invoke-WebRequest -Uri 'https://nodejs.org/dist/v$nodeFullVersion/node-v$nodeFullVersion-x64.msi' -OutFile node.msi; ``
    Start-Process msiexec -Wait -ArgumentList '/i node.msi /qn'; ``
    Remove-Item node.msi

# Install .NET $DotNetVersion SDK
RUN Invoke-WebRequest -Uri 'https://dot.net/v1/dotnet-install.ps1' -OutFile dotnet-install.ps1; ``
    ./dotnet-install.ps1 -Channel $DotNetVersion -InstallDir 'C:\Program Files\dotnet' | Out-Null; ``
    Remove-Item dotnet-install.ps1

# Install Git for Windows
RUN Invoke-WebRequest -Uri 'https://github.com/git-for-windows/git/releases/download/v2.47.1.windows.2/Git-2.47.1.2-64-bit.exe' -OutFile git-installer.exe; ``
    Start-Process -FilePath git-installer.exe -ArgumentList '/VERYSILENT','/NORESTART','/NOCANCEL','/SP-','/CLOSEAPPLICATIONS','/RESTARTAPPLICATIONS','/COMPONENTS=icons,ext\reg\shellhere,assoc,assoc_sh' -Wait; ``
    Remove-Item git-installer.exe

# Install Claude Code
RUN `$env:PATH = 'C:\Program Files\nodejs;C:\Program Files\Git\bin;' + `$env:PATH; ``
    Invoke-RestMethod -Uri 'https://claude.ai/install.ps1' | Invoke-Expression; ``
    if (-not (Test-Path '$userPath\.local\bin\claude.exe')) { throw 'Claude Code installation failed' }

# Install Python $PythonVersion
RUN Invoke-WebRequest -Uri 'https://www.python.org/ftp/python/$PythonVersion.0/python-$PythonVersion.0-amd64.exe' -OutFile python-installer.exe; ``
    Start-Process -FilePath python-installer.exe -ArgumentList '/quiet','InstallAllUsers=1','PrependPath=1','Include_test=0' -Wait; ``
    Remove-Item python-installer.exe

"@

    # Add Build Tools if requested
    if ($IncludeBuildTools) {
        $dockerfile += @"
# Install Visual Studio Build Tools with MSBuild
RUN Invoke-WebRequest -Uri 'https://aka.ms/vs/17/release/vs_buildtools.exe' -OutFile vs_buildtools.exe; ``
    Start-Process -FilePath vs_buildtools.exe -ArgumentList '--quiet','--wait','--norestart','--nocache','--add','Microsoft.VisualStudio.Workload.MSBuildTools','--add','Microsoft.VisualStudio.Workload.VCTools','--add','Microsoft.VisualStudio.Component.Windows11SDK.22621' -Wait; ``
    Remove-Item vs_buildtools.exe

"@
    }

    # Add Bun if requested
    if ($UseBun) {
        $dockerfile += @"
# Install Bun
RUN `$env:PATH = 'C:\Program Files\nodejs;' + `$env:PATH; ``
    Invoke-RestMethod -Uri 'https://bun.sh/install.ps1' | Invoke-Expression

"@
    }

    # Add uv if requested
    if ($UseUv) {
        $pythonPathForUv = "C:\Program Files\Python$($PythonVersion -replace '\.','');C:\Program Files\Python$($PythonVersion -replace '\.','')\Scripts"
        $dockerfile += @"
# Install uv
RUN `$env:PATH = '$pythonPathForUv;' + `$env:PATH; ``
    Invoke-RestMethod -Uri 'https://astral.sh/uv/install.ps1' | Invoke-Expression

"@
    }

    # Add Azure DevOps authentication (git + NuGet credential provider)
    if ($AzDoAuth) {
        $dockerfile += @"
# Configure Azure DevOps authentication
# Git: credential helper using SYSTEM_ACCESSTOKEN
# NuGet: Azure Artifacts Credential Provider (auto-detects feeds from nuget.config)
RUN `$env:PATH = 'C:\Program Files\Git\bin;' + `$env:PATH; ``
    git config --global credential.helper '!f() { echo username=token; echo password=`$env:SYSTEM_ACCESSTOKEN; }; f'; ``
    Invoke-WebRequest -Uri 'https://aka.ms/install-artifacts-credprovider.ps1' -OutFile install-credprovider.ps1; ``
    ./install-credprovider.ps1 -AddNetfx; ``
    Remove-Item install-credprovider.ps1

"@
    }

    # Add MCP configuration if any
    if ($mcpCommands) {
        $dockerfile += @"
# Configure MCP servers
RUN `$env:PATH = '$userPath\.local\bin;C:\Program Files\nodejs;' + `$env:PATH; ``
$mcpCommands    Write-Host 'Done'

"@
    }

    # Add plugin configuration if any
    if ($pluginCommands) {
        $dockerfile += @"
# Configure plugins
RUN `$env:PATH = '$userPath\.local\bin;C:\Program Files\nodejs;' + `$env:PATH; ``
$pluginCommands    Write-Host 'Done'

"@
    }

    # Build COPY commands for md files
    $mdCopyCommands = ""
    Get-ChildItem -Path "$tempPath\.claude" -Filter "*.md" -ErrorAction SilentlyContinue | ForEach-Object {
        $mdCopyCommands += "COPY .claude\$($_.Name) $userPath\.claude\$($_.Name)`n"
    }

    # Build COPY command for azdo scripts if any exist
    $azdoCopyCommand = ""
    $azdoFilesInTemp = Get-ChildItem -Path "$tempPath\azdo" -Filter "*.ps1" -ErrorAction SilentlyContinue
    if ($azdoFilesInTemp -and $azdoFilesInTemp.Count -gt 0) {
        $azdoCopyCommand = "COPY azdo\*.ps1 C:\scripts\azdo\`n"
    }

    # Build dynamic PATH
    $pythonPath = "C:\Program Files\Python$($PythonVersion -replace '\.','');C:\Program Files\Python$($PythonVersion -replace '\.','')\Scripts"
    $pathParts = @(
        "$userPath\.local\bin",
        "C:\Program Files\PowerShell\7",
        "C:\Program Files\Git\bin",
        "C:\Program Files\nodejs",
        "C:\Program Files\dotnet",
        $pythonPath
    )

    if ($IncludeBuildTools) {
        $pathParts += "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\MSBuild\Current\Bin"
    }
    if ($UseBun) {
        $pathParts += "$userPath\.bun\bin"
    }
    # uv installs to .local\bin which is already included

    $pathParts += @(
        "C:\Windows\System32\WindowsPowerShell\v1.0",
        "C:\Windows\System32",
        "C:\Windows"
    )

    $envPath = $pathParts -join ";"

    # Build verification commands
    $verifyCommands = @(
        'Write-Host "Claude Code: $(claude --version)"',
        'Write-Host "Git: $(git --version)"',
        'Write-Host "Node.js: $(node --version)"',
        'Write-Host "dotnet: $(dotnet --version)"',
        'Write-Host "Python: $(python --version)"'
    )
    if ($IncludeBuildTools) {
        $verifyCommands += 'Write-Host "MSBuild: $((Get-Item ''C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\MSBuild\Current\Bin\MSBuild.exe'').VersionInfo.ProductVersion)"'
    }
    if ($UseBun) {
        $verifyCommands += 'Write-Host "Bun: $(bun --version)"'
    }
    if ($UseUv) {
        $verifyCommands += 'Write-Host "uv: $(uv --version)"'
    }
    $verifyCommands += 'Write-Host "MD files: $((Get-ChildItem ''$userPath\.claude\*.md'' -ErrorAction SilentlyContinue).Count)"'

    $verifyScript = $verifyCommands -join "; "

    $dockerfile += @"
# Copy configuration files
${mdCopyCommands}${azdoCopyCommand}COPY entrypoint-watchdog.ps1 C:\entrypoint-watchdog.ps1

# Set PATH
ENV PATH="$envPath"

# Verify installation
RUN Write-Host '=== Verification ==='; $verifyScript

WORKDIR C:\source

ENTRYPOINT ["powershell", "-File", "C:\\entrypoint-watchdog.ps1"]
"@

    $dockerfile | Set-Content "$tempPath\Dockerfile"

    # Build image
    Push-Location $tempPath
    try {
        #$env:DOCKER_BUILDKIT=0

        docker build -t $FullImageName .
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Docker build failed with exit code $LASTEXITCODE"
            exit $LASTEXITCODE
        }
    } finally {
        Pop-Location
    }

    Write-Host "Build successful: $FullImageName" -ForegroundColor Green

} finally {
    if (Test-Path $tempPath) {
        Remove-Item -Recurse -Force $tempPath
    }
}
