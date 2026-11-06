#requires -Version 5.1
<#
.SYNOPSIS
    coding-agents-installer: install or upgrade AI coding CLIs and desktop apps on Windows.
.DESCRIPTION
    CLIs : Codex, Claude Code, OpenCode, Antigravity (agy)
    Apps : Claude Desktop, Codex Desktop (ChatGPT), VS Code, Antigravity IDE,
           Cursor, T3 Code

    - Refreshes the winget source, then upgrades what is installed and installs
      what is missing. Harmless winget results count as success.
    - Claude Code installed with Anthropic's native installer is updated with
      `claude update` instead of adding a second copy from winget.
    - Node.js (for OpenCode) is installed from winget only when npm is missing;
      a Node managed by nvm-windows, fnm or Volta is left alone.
    - Orphaned npm launchers (no package behind them) are renamed aside before
      the npm install; the old `opencode-ai` package is replaced.
    - Reports which file each CLI command resolves to in a NEW terminal.

    Run from a regular (non-elevated) PowerShell window and close the apps
    being upgraded first. winget versions trail vendor releases by hours to days.

    https://github.com/ayazmirza54/coding-agents-installer
.PARAMETER Preview
    Check every package against its catalog and print the version that would be
    installed. Changes nothing. Exits 1 if a package ID no longer exists.
.PARAMETER List
    List tool keys and exit.
.PARAMETER Only
    Install only these tools: keys from -List, or the groups clis / apps.
.PARAMETER Skip
    Skip these tools (same format as -Only).
.PARAMETER SkipApps
    Same as -Skip apps.
.PARAMETER SkipClis
    Same as -Skip clis.
.PARAMETER ForceWinGetClaude
    Install Claude Code from winget even when the native install is present.
.EXAMPLE
    irm https://raw.githubusercontent.com/ayazmirza54/coding-agents-installer/main/install.ps1 | iex
.EXAMPLE
    & ([scriptblock]::Create((irm https://raw.githubusercontent.com/ayazmirza54/coding-agents-installer/main/install.ps1))) -Only codex,claude
.EXAMPLE
    .\install.ps1 -Preview
.NOTES
    With `irm | iex` there are no parameters; set CAI_ONLY, CAI_SKIP,
    CAI_PREVIEW=1, CAI_SKIP_APPS=1, CAI_SKIP_CLIS=1 or CAI_FORCE_WINGET_CLAUDE=1
    in the environment instead.
#>
[CmdletBinding()]
param(
    [switch]$Preview,
    [switch]$List,
    [string[]]$Only,
    [string[]]$Skip,
    [switch]$SkipApps,
    [switch]$SkipClis,
    [switch]$ForceWinGetClaude
)

# Everything runs in a child scope so preferences and helper functions do not
# leak into the caller's session when the script is piped into Invoke-Expression.
$caiResult = 1
try {
$caiResult = & {
    $ErrorActionPreference = 'Stop'
    $PSNativeCommandUseErrorActionPreference = $false
    $caiVersion = '1.0.0'

    function Test-Truthy([string]$Value) { $Value -and ($Value.ToLowerInvariant() -in '1', 'true', 'yes', 'on') }
    function Split-Keys($Value) {
        @($Value | ForEach-Object { "$_" -split '[,;\s]+' } | Where-Object { $_ } | ForEach-Object { $_.ToLowerInvariant() })
    }

    # Parameters win; environment variables cover `irm | iex`, which takes none.
    $optPreview = $Preview -or (Test-Truthy $env:CAI_PREVIEW)
    $optForceClaude = $ForceWinGetClaude -or (Test-Truthy $env:CAI_FORCE_WINGET_CLAUDE)
    $optOnly = if ($Only) { Split-Keys $Only } else { Split-Keys $env:CAI_ONLY }
    $optSkip = if ($Skip) { Split-Keys $Skip } else { Split-Keys $env:CAI_SKIP }
    if ($SkipApps -or (Test-Truthy $env:CAI_SKIP_APPS)) { $optSkip += 'apps' }
    if ($SkipClis -or (Test-Truthy $env:CAI_SKIP_CLIS)) { $optSkip += 'clis' }

    # Scope 'user' keeps winget from matching a second, machine-wide install of the same ID.
    $catalog = @(
        [pscustomobject]@{ Key = 'codex';           Group = 'cli'; Name = 'Codex CLI';               Kind = 'winget'; Package = 'OpenAI.Codex';               Scope = $null;  Command = 'codex' }
        [pscustomobject]@{ Key = 'claude';          Group = 'cli'; Name = 'Claude Code CLI';         Kind = 'claude'; Package = 'Anthropic.ClaudeCode';       Scope = $null;  Command = 'claude' }
        [pscustomobject]@{ Key = 'opencode';        Group = 'cli'; Name = 'OpenCode CLI';            Kind = 'npm';    Package = '@opencode/cli';              Scope = $null;  Command = 'opencode' }
        [pscustomobject]@{ Key = 'agy';             Group = 'cli'; Name = 'Antigravity CLI (agy)';   Kind = 'winget'; Package = 'Google.AntigravityCLI';      Scope = $null;  Command = 'agy' }
        [pscustomobject]@{ Key = 'claude-desktop';  Group = 'app'; Name = 'Claude Desktop';          Kind = 'winget'; Package = 'Anthropic.Claude';           Scope = $null;  Command = $null }
        # The Codex desktop app ships as "ChatGPT".
        [pscustomobject]@{ Key = 'codex-desktop';   Group = 'app'; Name = 'Codex Desktop (ChatGPT)'; Kind = 'winget'; Package = 'OpenAI.ChatGPT';             Scope = $null;  Command = $null }
        [pscustomobject]@{ Key = 'vscode';          Group = 'app'; Name = 'VS Code';                 Kind = 'winget'; Package = 'Microsoft.VisualStudioCode'; Scope = 'user'; Command = $null }
        [pscustomobject]@{ Key = 'antigravity-ide'; Group = 'app'; Name = 'Antigravity IDE';         Kind = 'winget'; Package = 'Google.AntigravityIDE';      Scope = 'user'; Command = $null }
        [pscustomobject]@{ Key = 'cursor';          Group = 'app'; Name = 'Cursor';                  Kind = 'winget'; Package = 'Anysphere.Cursor';           Scope = 'user'; Command = $null }
        [pscustomobject]@{ Key = 't3code';          Group = 'app'; Name = 'T3 Code Desktop';         Kind = 'winget'; Package = 'T3Tools.T3Code';             Scope = $null;  Command = $null }
    )
    $nodePackage = 'OpenJS.NodeJS.LTS'

    $known = @($catalog.Key) + 'clis', 'apps'
    foreach ($k in @($optOnly) + @($optSkip)) {
        if ($k -notin $known) { $host.UI.WriteErrorLine("Unknown tool key '$k'. Run with -List to see keys."); return 2 }
    }

    if ($List) {
        $catalog | Format-Table Key, Group, Name, Kind, Package -AutoSize | Out-Host
        Write-Host 'Groups: clis, apps'
        return 0
    }

    if (($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) -or $env:OS -ne 'Windows_NT') {
        Write-Warning 'This script is for Windows. On Linux, macOS or WSL2 use install.sh.'
        return 1
    }

    $selected = @($catalog | Where-Object {
        ((-not $optOnly) -or ($_.Key -in $optOnly) -or (($_.Group + 's') -in $optOnly)) -and
        ($_.Key -notin $optSkip) -and (($_.Group + 's') -notin $optSkip)
    })
    if (-not $selected) { Write-Warning 'Nothing selected. Check -Only / -Skip (see -List).'; return 2 }

    # winget results that are not failures. Keys are 8-digit hex exit codes.
    $okCodes = @{
        '00000000' = 'OK'
        '8A15002B' = 'Up to date'                  # UPDATE_NOT_APPLICABLE
        '8A150061' = 'Already installed'           # PACKAGE_ALREADY_INSTALLED
        '8A150109' = 'OK (restart to finish)'      # INSTALL_REBOOT_REQUIRED_TO_FINISH
    }
    $inUseCodes = '8A150101', '8A15010B'

    $nativeClaude = Join-Path $env:USERPROFILE '.local\bin\claude.exe'
    $useNativeClaude = (Test-Path -LiteralPath $nativeClaude) -and -not $optForceClaude
    $needsNode = [bool]($selected | Where-Object Kind -eq 'npm')
    $needsWinget = [bool]($selected | Where-Object { $_.Kind -eq 'winget' -or ($_.Kind -eq 'claude' -and -not $useNativeClaude) })

    $wingetCmd = Get-Command winget.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $wg = if ($wingetCmd) { $wingetCmd.Source } else { $null }

    function Get-Hex([int]$Code) { $Code.ToString('X8') }

    function Invoke-WinGet([string[]]$Arguments) {
        & $wg @Arguments | Out-Host
        return $LASTEXITCODE
    }

    function Test-WinGetInstalled([string]$Package, [string]$Scope, [switch]$Quiet) {
        $a = @('list', '--id', $Package, '--exact', '--disable-interactivity', '--accept-source-agreements')
        if ($Scope) { $a += @('--scope', $Scope) }
        $out = & $wg @a 2>&1 | Out-String
        $installed = ($LASTEXITCODE -eq 0)
        # Warn-only: winget truncates long IDs in narrow consoles, so this count can miss.
        $rows = ([regex]::Matches($out, '(?m)\s' + [regex]::Escape($Package) + '\s')).Count
        if ($rows -gt 1 -and -not $Quiet) {
            $where = if ($Scope) { " in $Scope scope" } else { '' }
            Write-Warning "$Package has $rows installs$where. winget may refuse or pick one; uninstall the stale copy."
        }
        return $installed
    }

    function Update-WinGetPackage([string]$Package, [string]$Scope) {
        $common = @('--id', $Package, '--exact', '--source', 'winget', '--silent',
                    '--disable-interactivity', '--accept-package-agreements', '--accept-source-agreements')
        if ($Scope) { $common += @('--scope', $Scope) }
        if (Test-WinGetInstalled $Package $Scope) {
            $code = Invoke-WinGet (@('upgrade') + $common + '--include-unknown')
        } else {
            $code = Invoke-WinGet (@('install') + $common)
        }
        $hex = Get-Hex $code
        if ($okCodes.ContainsKey($hex)) { return $okCodes[$hex] }
        $hint = if ($hex -in $inUseCodes) { ' Installer is in use: close the app and rerun.' } else { '' }
        throw ("winget exit 0x{0} ({1}).{2} See output above." -f $hex, $code, $hint)
    }

    function Get-WinGetVersion([string]$Package) {
        $out = & $wg show --id $Package --exact --source winget --disable-interactivity --accept-source-agreements 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) { return $null }
        ([regex]::Match($out, '(?m)^Version:\s*(.+)$')).Groups[1].Value.Trim()
    }

    function Get-NpmLatest([string]$Package) {
        try { (Invoke-RestMethod "https://registry.npmjs.org/-/package/$Package/dist-tags" -UseBasicParsing).latest }
        catch { $null }
    }

    # PATH directories as a new terminal sees them: Machine, then User.
    function Get-RegistryPath {
        foreach ($scope in 'Machine', 'User') {
            $raw = [Environment]::GetEnvironmentVariable('Path', $scope)
            if ($raw) { [Environment]::ExpandEnvironmentVariables($raw) -split ';' | Where-Object { $_ } }
        }
    }

    function Update-SessionPath {
        $fresh = @(Get-RegistryPath)
        $extra = @($env:Path -split ';' | Where-Object { $_ -and $_ -notin $fresh })
        $env:Path = ($fresh + $extra) -join ';'
    }

    function Resolve-Cli([string]$Name) {
        $hits = foreach ($d in Get-RegistryPath) {
            foreach ($ext in '.exe', '.cmd', '.bat', '.ps1') {
                $p = Join-Path $d "$Name$ext"
                if (Test-Path -LiteralPath $p -PathType Leaf) { $p; break }
            }
        }
        @($hits | Select-Object -Unique)
    }

    function Get-Npm { Get-Command npm.cmd -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1 }

    # npm launchers whose package is gone shadow real installs and make
    # `npm install -g` fail with EEXIST. Rename them (reversible), never delete.
    function Repair-OrphanNpmShim([string]$Prefix, [string]$Name) {
        $cmdShim = Join-Path $Prefix "$Name.cmd"
        if (-not (Test-Path -LiteralPath $cmdShim)) { return }
        $m = [regex]::Match((Get-Content -LiteralPath $cmdShim -Raw), 'node_modules[\\/][^"%\r\n]+')
        if (-not $m.Success) { return }
        if (Test-Path -LiteralPath (Join-Path $Prefix $m.Value)) { return }
        $stamp = Get-Date -Format 'yyyyMMddHHmmss'
        foreach ($f in $Name, "$Name.cmd", "$Name.ps1") {
            $p = Join-Path $Prefix $f
            if (Test-Path -LiteralPath $p) { Rename-Item -LiteralPath $p -NewName "$f.orphan-$stamp" }
        }
        Write-Host "Moved orphaned npm launcher '$Name' aside (*.orphan-$stamp in $Prefix)."
    }

    function Install-NodeIfNeeded {
        $npm = Get-Npm
        if ($npm -and -not (Test-WinGetInstalled $nodePackage $null -Quiet)) {
            # nvm-windows, fnm, Volta, ...: leave the user's Node manager in charge.
            $v = (& node --version 2>$null | Out-String).Trim()
            return "Existing $v (not managed here)"
        }
        if (-not $wg) { throw 'npm is missing and winget is unavailable to install Node.js.' }
        $s = Update-WinGetPackage $nodePackage $null
        Update-SessionPath
        if (-not (Get-Npm)) { throw 'npm.cmd not found after Node.js setup. Open a new PowerShell window and rerun.' }
        return $s
    }

    function Update-NpmPackage([string]$Package, [string]$Command) {
        $npm = Get-Npm
        if (-not $npm) { throw 'npm unavailable (Node.js step failed).' }
        $prefix = (& $npm.Source config get prefix | Out-String).Trim()
        if ($Package -eq '@opencode/cli' -and (Test-Path (Join-Path $prefix 'node_modules\opencode-ai'))) {
            Write-Host 'Removing old opencode-ai package (replaced by @opencode/cli)...'
            & $npm.Source uninstall --global opencode-ai | Out-Host
        }
        Repair-OrphanNpmShim $prefix $Command
        Repair-OrphanNpmShim $prefix 'codex'   # a stale npm codex launcher would shadow the winget Codex CLI
        & $npm.Source install --global "$Package@latest" | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "npm exit $LASTEXITCODE. See output above." }
        return "OK ($(Get-NpmLatest $Package))"
    }

    function Update-ClaudeCode([pscustomobject]$Tool) {
        if ($useNativeClaude) {
            Write-Host "Native install found at $nativeClaude; running 'claude update'."
            & $nativeClaude update | Out-Host
            if ($LASTEXITCODE -ne 0) { throw "claude update exit $LASTEXITCODE. See output above." }
            return 'OK (native self-update)'
        }
        Update-WinGetPackage $Tool.Package $Tool.Scope
    }

    # ------------------------------------------------------------ preview
    if ($optPreview) {
        Write-Host "coding-agents-installer $caiVersion (preview)"
        if ($needsWinget -and -not $wg) { Write-Warning 'winget not found. Install App Installer from https://aka.ms/getwinget.' }
        $drift = 0
        $rows = foreach ($t in $selected) {
            $v = switch ($t.Kind) {
                'npm' { Get-NpmLatest $t.Package }
                'claude' {
                    if ($useNativeClaude) { 'native install: will run claude update' }
                    elseif ($wg) { Get-WinGetVersion $t.Package }
                }
                default { if ($wg) { Get-WinGetVersion $t.Package } }
            }
            if (-not $v) { $v = if ($wg -or $t.Kind -eq 'npm') { 'NOT FOUND' } else { 'winget unavailable' }; $drift++ }
            [pscustomobject]@{ Key = $t.Key; Name = $t.Name; Source = $t.Kind; Package = $t.Package; Version = $v }
        }
        $rows | Format-Table -AutoSize | Out-Host
        if ($drift) { Write-Warning "$drift package(s) could not be resolved."; return 1 }
        return 0
    }

    # ------------------------------------------------------------ install
    if ($needsWinget -and -not $wg) {
        Write-Warning 'winget not found. Install or update App Installer from https://aka.ms/getwinget and reopen PowerShell.'
        return 1
    }

    $log = Join-Path ([IO.Path]::GetTempPath()) ("coding-agents-{0:yyyyMMdd-HHmmss}-{1}.log" -f (Get-Date), $PID)
    Start-Transcript -Path $log | Out-Null
    $failed = 0
    try {
        Write-Host "coding-agents-installer $caiVersion"
        if ($wg) {
            Write-Host 'Refreshing winget source...'
            [void](Invoke-WinGet @('source', 'update', '--name', 'winget', '--disable-interactivity'))
        }
        $results = New-Object System.Collections.Generic.List[object]

        if ($needsNode) {
            Write-Host "`n[Node.js] prerequisite for npm-based CLIs"
            try { $s = Install-NodeIfNeeded }
            catch { $s = 'Failed'; Write-Warning "Node.js: $($_.Exception.Message)" }
            $results.Add([pscustomobject]@{ Tool = 'Node.js (prereq)'; Result = $s })
        }

        foreach ($tool in $selected) {
            Write-Host "`n[$($tool.Name)] $($tool.Package)"
            try {
                $status = switch ($tool.Kind) {
                    'npm'    { Update-NpmPackage $tool.Package $tool.Command }
                    'claude' { Update-ClaudeCode $tool }
                    default  { Update-WinGetPackage $tool.Package $tool.Scope }
                }
            } catch {
                $status = 'Failed'
                Write-Warning ("{0}: {1}" -f $tool.Name, $_.Exception.Message)
            }
            $results.Add([pscustomobject]@{ Tool = $tool.Name; Result = $status })
        }
        $results | Format-Table -AutoSize | Out-Host

        $clis = @($selected | Where-Object Command)
        if ($clis) {
            Write-Host 'Command resolution in a new terminal:'
            $resolution = foreach ($tool in $clis) {
                $hits = @(Resolve-Cli $tool.Command)
                $first = if ($hits.Count) { $hits[0] } else { 'NOT ON PATH' }
                [pscustomobject]@{ Command = $tool.Command; Runs = $first; Shadowed = (($hits | Select-Object -Skip 1) -join '; ') }
            }
            $resolution | Format-Table -AutoSize -Wrap | Out-Host
            foreach ($r in $resolution | Where-Object Shadowed) {
                Write-Warning "'$($r.Command)' has more than one copy. '$($r.Runs)' wins; uninstall the others or reorder PATH."
            }
        }

        $failed = @($results | Where-Object Result -eq 'Failed').Count
        Write-Host "Log: $log"
        Write-Host 'Open a new terminal to use the installed CLIs.'
        if ($failed) { Write-Warning "$failed item(s) failed. Check the log, fix the issue and rerun." }
    } finally {
        Stop-Transcript | Out-Null
    }
    if ($failed) { return 1 }
    return 0
}
} catch {
    # An unexpected error must never be reported as success.
    $host.UI.WriteErrorLine("coding-agents-installer: $($_.Exception.Message)")
    $caiResult = 1
}

# The last value the block returned is the exit code; anything before it is stray output.
$caiExitCode = [int](@($caiResult)[-1])
# `exit` would close the caller's window under `irm | iex` or a script block.
if ($PSCommandPath) { exit $caiExitCode } else { $global:LASTEXITCODE = $caiExitCode }
