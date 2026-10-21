param([Parameter(Mandatory = $true)][ValidateSet('List', 'Discover', 'Icons', 'Choose', 'Save', 'Open', 'Reveal', 'Trash', 'ValidateNative', 'OpenNative', 'RevealNative')][string]$Action)
$ErrorActionPreference = 'Stop'
[Console]::InputEncoding = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$root = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CipherRelay\ProxyLaunchers'
. (Join-Path $PSScriptRoot 'applications.ps1')

function Read-Launcher([string]$Id) {
    $guid = [guid]::Empty
    if (-not [guid]::TryParseExact($Id, 'D', [ref]$guid)) { throw 'Invalid launcher ID.' }
    $folder = Join-Path $root $guid.ToString('D')
    if ((Get-Item -LiteralPath $folder).Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw 'Managed launchers cannot be symbolic links.'
    }
    $item = Get-Content -LiteralPath (Join-Path $folder 'launcher.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($item.id -ne $Id -or $item.schemaVersion -ne 1) { throw 'Invalid managed launcher.' }
    # Retain the shortcut filename across edits, including display-name edits.
    if ([string]::IsNullOrWhiteSpace($item.shortcutName) -or
        $item.shortcutName -match '[<>:"/\\|?*\x00-\x1f]' -or
        [IO.Path]::GetExtension($item.shortcutName) -ine '.lnk') { throw 'Invalid launcher shortcut.' }
    $item | Add-Member -NotePropertyName launcherPath -NotePropertyValue (Join-Path $folder $item.shortcutName) -Force
    return $item
}

function Output-Json($Value) {
    [Console]::WriteLine((ConvertTo-Json -InputObject $Value -Depth 8 -Compress))
}

try {
    $inputData = [Console]::In.ReadToEnd() | ConvertFrom-Json
    switch ($Action) {
        'ValidateNative' {
            if ((Get-LauncherApplication $inputData.appPath).mode -ne 'claudeNative') {
                throw 'This Claude version does not support native proxy configuration.'
            }
            foreach ($policy in @('HKLM:\SOFTWARE\Policies\Claude', 'HKCU:\SOFTWARE\Policies\Claude')) {
                if ((Test-Path $policy) -and (Get-Item $policy).ValueCount -gt 0) {
                    throw 'Claude is managed by an organization. Local proxy settings may be overridden; no settings were changed.'
                }
            }
        }
        'OpenNative' {
            if ((Get-LauncherApplication $inputData.appPath).mode -ne 'claudeNative') { throw 'Select an installed Claude application.' }
            Start-Process -FilePath (Join-Path $env:SystemRoot 'explorer.exe') -ArgumentList ('"' + $inputData.appPath + '"')
        }
        'RevealNative' {
            Start-Process -FilePath (Join-Path $env:SystemRoot 'explorer.exe') -ArgumentList ('/select,"' + $inputData.path + '"')
        }
        'Discover' { Output-Json @(Find-LauncherApplications) }
        'Icons' {
            # The shell's large icon, as the TUN process picker shows it.
            Add-Type -AssemblyName System.Drawing
            $icons = @{}
            foreach ($path in @($inputData.paths)) {
                try {
                    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
                    $icon = [System.Drawing.Icon]::ExtractAssociatedIcon($path)
                    $bitmap = $icon.ToBitmap()
                    $stream = [IO.MemoryStream]::new()
                    try {
                        $bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
                        $icons[$path] = [Convert]::ToBase64String($stream.ToArray())
                    } finally { $stream.Dispose(); $bitmap.Dispose(); $icon.Dispose() }
                } catch { }
            }
            Output-Json $icons
        }
        'List' {
            $items = @()
            if (Test-Path -LiteralPath $root) {
                foreach ($folder in Get-ChildItem -LiteralPath $root -Directory) {
                    if ($folder.Name.StartsWith('.')) { continue }
                    $items += Read-Launcher $folder.Name
                }
            }
            Output-Json @($items | Sort-Object name)
        }
        'Choose' {
            Add-Type -AssemblyName System.Windows.Forms
            $dialog = [System.Windows.Forms.OpenFileDialog]::new()
            $dialog.Filter = 'Applications (*.exe)|*.exe'
            $dialog.InitialDirectory = [Environment]::GetFolderPath('ProgramFiles')
            try {
                if ($dialog.ShowDialog() -ne 'OK') { Output-Json $null; break }
                $path = $dialog.FileName
                Output-Json (Get-LauncherApplication $path)
            } finally { $dialog.Dispose() }
        }
        'Save' {
            $name = [string]$inputData.name
            $path = [string]$inputData.appPath
            if ([string]::IsNullOrWhiteSpace($name) -or $name.Length -gt 80 -or
                $name -match '[<>:"/\\|?*\x00-\x1f]') { throw 'Invalid launcher name.' }
            if (-not [IO.Path]::IsPathRooted($path) -or [IO.Path]::GetExtension($path) -ine '.exe' -or
                -not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'Select an installed .exe application.' }
            $port = [int]$inputData.port
            if ($port -lt 1 -or $port -gt 65535 -or $inputData.mode -notin @('chromium', 'environment')) {
                throw 'Invalid proxy port or launch mode.'
            }
            $rules = @($inputData.bypassRules | ForEach-Object { ([string]$_).Trim().ToLowerInvariant() } | Select-Object -Unique)
            if ($rules.Count -gt 200) { throw 'Use at most 200 bypass rules.' }
            foreach ($rule in $rules) {
                if ($rule -notmatch '^[a-z0-9*._\-\[\]:]+$' -or $rule.Length -gt 253 -or
                    $rule -eq '.' -or $rule.Contains('..') -or
                    ($rule.Contains(':') -and $rule -notin @('::1', '[::1]'))) { throw 'Invalid bypass host.' }
            }
            $existing = $null
            if ($inputData.id) {
                $existing = Read-Launcher $inputData.id
                $id = $existing.id
            } else { $id = [guid]::NewGuid().ToString('D') }
            $settings = [ordered]@{
                schemaVersion = 1; id = $id; name = $name; appPath = $path
                mode = $inputData.mode; port = $port; bypassRules = $rules
                shortcutName = if ($existing) { $existing.shortcutName } else { "$name.lnk" }
            }
            $identity = (Get-LauncherApplication $path).applicationId
            if ($identity) { $settings.applicationId = $identity }
            [void][IO.Directory]::CreateDirectory($root)
            $destination = Join-Path $root $id
            $stage = Join-Path $root ('.staging-' + [guid]::NewGuid())
            $backup = Join-Path $root ('.backup-' + [guid]::NewGuid())
            try {
                [void][IO.Directory]::CreateDirectory($stage)
                $settings | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $stage 'launcher.json') -Encoding UTF8
                Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'runtime.ps1') -Destination (Join-Path $stage 'runtime.ps1')
                Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'applications.ps1') -Destination (Join-Path $stage 'applications.ps1')
                $shell = New-Object -ComObject WScript.Shell
                $shortcut = $shell.CreateShortcut((Join-Path $stage $settings.shortcutName))
                $shortcut.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
                $shortcut.Arguments = '-NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "' +
                    (Join-Path $destination 'runtime.ps1') + '" -Config "' + (Join-Path $destination 'launcher.json') + '"'
                $shortcut.Description = $name
                $shortcut.IconLocation = "$path,0"
                $shortcut.WindowStyle = 7
                $shortcut.Save()
                [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut)
                [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)
                if ($existing) { [IO.Directory]::Move($destination, $backup) }
                try { [IO.Directory]::Move($stage, $destination) }
                catch {
                    if (Test-Path -LiteralPath $backup) { [IO.Directory]::Move($backup, $destination) }
                    throw
                }
                if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Recurse -Force }
            } finally {
                if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
            }
            Output-Json (Read-Launcher $id)
        }
        'Open' {
            $item = Read-Launcher $inputData.id
            # Ask the desktop shell to open the shortcut, so an elevated
            # CipherRelay window does not elevate the target application.
            Start-Process -FilePath (Join-Path $env:SystemRoot 'explorer.exe') -ArgumentList ('"' + $item.launcherPath + '"')
        }
        'Reveal' {
            $item = Read-Launcher $inputData.id
            Start-Process -FilePath (Join-Path $env:SystemRoot 'explorer.exe') -ArgumentList ('/select,"' + $item.launcherPath + '"')
        }
        'Trash' {
            $item = Read-Launcher $inputData.id
            Add-Type -AssemblyName Microsoft.VisualBasic
            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory(
                [IO.Path]::GetDirectoryName($item.launcherPath),
                [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
                [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin
            )
        }
    }
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
