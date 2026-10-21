# Shared by discovery and the generated launcher so updates can move an app
# between versioned installation directories without breaking its shortcut.
function Get-LauncherApplication([string]$Path) {
    $filename = [IO.Path]::GetFileName($Path).ToLowerInvariant()
    $name = [IO.Path]::GetFileNameWithoutExtension($Path)
    $id = $null
    switch ($filename) {
        'claude.exe' { $name = 'Claude'; $id = 'com.anthropic.claudefordesktop' }
        'codex.exe' { $name = 'Codex'; $id = 'com.openai.codex' }
        'chatgpt.exe' {
            $product = [Diagnostics.FileVersionInfo]::GetVersionInfo($Path).ProductName
            if ($product -match 'Codex' -or $Path -match '[\\/]OpenAI\.Codex_') {
                $name = 'Codex'; $id = 'com.openai.codex'
            }
        }
    }
    $directory = [IO.Path]::GetDirectoryName($Path)
    $chromium = $id -or ($filename -in @('chrome.exe', 'msedge.exe', 'brave.exe', 'opera.exe', 'vivaldi.exe')) -or
        (Test-Path -LiteralPath (Join-Path $directory 'chrome_elf.dll')) -or
        (Test-Path -LiteralPath (Join-Path $directory 'resources/app.asar'))
    $nativeClaude = $false
    if ($id -eq 'com.anthropic.claudefordesktop') {
        $version = [Diagnostics.FileVersionInfo]::GetVersionInfo($Path).FileVersion
        $parsed = $null
        $nativeClaude = [version]::TryParse(($version -replace '[^0-9.].*$', ''), [ref]$parsed) -and $parsed -ge [version]'1.44121.1'
    }
    return @{
        name = $name; appPath = $Path; applicationId = $id
        mode = if ($nativeClaude) { 'claudeNative' } elseif ($chromium) { 'chromium' } else { 'environment' }
    }
}

function Get-LauncherInstallations {
    $known = @(
        @{ name = 'Claude'; id = 'com.anthropic.claudefordesktop'; executables = @('Claude.exe') },
        @{ name = 'Codex'; id = 'com.openai.codex'; executables = @('Codex.exe', 'ChatGPT.exe') }
    )
    foreach ($app in $known) {
        $roots = @()
        foreach ($base in @($env:LOCALAPPDATA, $env:ProgramFiles, ${env:ProgramFiles(x86)})) {
            if (-not $base) { continue }
            $roots += Join-Path $base $app.name
            $roots += Join-Path $base ('Programs/' + $app.name)
        }
        foreach ($registry in @(
            'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
        )) {
            foreach ($entry in @(Get-ItemProperty -Path $registry -ErrorAction SilentlyContinue)) {
                if ($entry.DisplayName -match ('^' + $app.name + '( Desktop)?$') -and $entry.InstallLocation) {
                    $roots += $entry.InstallLocation
                }
            }
        }
        if (Get-Command Get-AppxPackage -ErrorAction SilentlyContinue) {
            $packages = if ($app.name -eq 'Codex') {
                @(Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction SilentlyContinue)
            } else {
                @(Get-AppxPackage -Name '*Claude*' -ErrorAction SilentlyContinue |
                    Where-Object { $_.Publisher -match 'Anthropic' })
            }
            $roots += @($packages | ForEach-Object { $_.InstallLocation })
        }
        foreach ($root in @($roots | Where-Object { $_ } | Select-Object -Unique)) {
            @{ name = $app.name; id = $app.id; executables = $app.executables; root = $root }
        }
    }
}

function Find-LauncherApplications([object[]]$Installations = @(Get-LauncherInstallations)) {
    $found = @{}
    foreach ($install in $Installations) {
        if (-not (Test-Path -LiteralPath $install.root -PathType Container)) { continue }
        $directories = @($install.root, (Join-Path $install.root 'app'))
        # Squirrel uses app-<version>; never search an entire drive recursively.
        $directories += @(Get-ChildItem -LiteralPath $install.root -Directory -Filter 'app-*' -ErrorAction SilentlyContinue |
            ForEach-Object { $_.FullName })
        foreach ($directory in $directories) {
            foreach ($exe in $install.executables) {
                $path = Join-Path $directory $exe
                if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
                $file = Get-Item -LiteralPath $path
                $version = [version]'0.0'
                $text = [string]$file.VersionInfo.FileVersion
                if ($text -match '^\d+(\.\d+){1,3}') { [void][version]::TryParse($Matches[0], [ref]$version) }
                $previous = $found[$install.id]
                if ($previous -and ($previous.version -gt $version -or
                    ($previous.version -eq $version -and $previous.modified -ge $file.LastWriteTimeUtc))) { continue }
                $found[$install.id] = @{
                    version = $version; modified = $file.LastWriteTimeUtc
                    application = @{
                        name = $install.name; applicationId = $install.id
                        appPath = $file.FullName; mode = 'chromium'
                    }
                }
            }
        }
    }
    @($found.Values | ForEach-Object { $_.application } | Sort-Object name)
}
