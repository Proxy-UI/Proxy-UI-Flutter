param(
    [Parameter(Mandatory = $true)][string]$Config,
    [switch]$Check
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

function Show-LauncherMessage([string]$Text) {
    Add-Type -AssemblyName PresentationFramework
    [void][System.Windows.MessageBox]::Show($Text, 'CipherRelay', 'OK', 'Information')
}

try {
    $settings = Get-Content -LiteralPath $Config -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($settings.schemaVersion -ne 1 -or $settings.port -lt 1 -or $settings.port -gt 65535 -or
        $settings.mode -notin @('chromium', 'environment')) { throw 'Invalid launcher configuration.' }
    if ($settings.applicationId -in @('com.openai.codex', 'com.anthropic.claudefordesktop')) {
        . (Join-Path $PSScriptRoot 'applications.ps1')
        $current = @(Find-LauncherApplications | Where-Object { $_.applicationId -eq $settings.applicationId })
        if ($current.Count -gt 0) { $settings.appPath = $current[0].appPath }
    }
    if (-not [IO.Path]::IsPathRooted($settings.appPath) -or
        [IO.Path]::GetExtension($settings.appPath) -ine '.exe' -or
        -not (Test-Path -LiteralPath $settings.appPath -PathType Leaf)) {
        throw 'The target application moved. Select it again in CipherRelay.'
    }
    $proxy = "http://127.0.0.1:$($settings.port)"
    $browserRules = @('localhost', '127.0.0.1', '[::1]')
    $environmentRules = @('localhost', '127.0.0.1', '::1')
    foreach ($rule in $settings.bypassRules) {
        if ($rule -notmatch '^[a-z0-9*._\-\[\]:]+$' -or $rule.Length -gt 253 -or
            $rule -eq '.' -or $rule.Contains('..') -or
            ($rule.Contains(':') -and $rule -notin @('::1', '[::1]'))) {
            throw 'Invalid bypass rule.'
        }
        if ($rule -eq '::1') { $browserRules += '[::1]' }
        elseif ($rule.StartsWith('.')) { $browserRules += $rule.Substring(1); $browserRules += "*$rule" }
        else { $browserRules += $rule }
        if ($rule -eq '[::1]') { $environmentRules += '::1' }
        elseif ($rule -eq '*') { $environmentRules += '*' }
        elseif ($rule.StartsWith('*.') -and -not $rule.Substring(1).Contains('*')) {
            $environmentRules += $rule.Substring(1)
        }
        elseif (-not $rule.Contains('*')) { $environmentRules += $rule }
    }
    $arguments = @()
    if ($settings.mode -eq 'chromium') {
        $arguments = @("--proxy-server=$proxy", "--proxy-bypass-list=$($browserRules -join ';')")
    }
    # Environment variables only affect this launcher and the child it starts.
    # Windows environment keys are case-insensitive.
    foreach ($key in @('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY')) {
        [Environment]::SetEnvironmentVariable($key, $proxy, 'Process')
    }
    [Environment]::SetEnvironmentVariable('NO_PROXY', ($environmentRules -join ','), 'Process')

    $socket = [Net.Sockets.TcpClient]::new()
    $listening = $false
    try {
        $pending = $socket.BeginConnect('127.0.0.1', [int]$settings.port, $null, $null)
        if ($pending.AsyncWaitHandle.WaitOne(2000)) {
            $socket.EndConnect($pending)
            $listening = $true
        }
        $pending.AsyncWaitHandle.Close()
    } catch { $listening = $false } finally { $socket.Dispose() }

    $running = @(Get-CimInstance Win32_Process | Where-Object {
        $_.ExecutablePath -and $_.ExecutablePath -ieq $settings.appPath
    })
    if ($Check) {
        [ordered]@{
            proxy = $proxy; proxyListening = $listening
            launchArguments = $arguments; noProxy = $environmentRules -join ','
            runningProcessIds = @($running | ForEach-Object { $_.ProcessId })
        } | ConvertTo-Json -Depth 5
        exit 0
    }
    $zh = [Globalization.CultureInfo]::CurrentUICulture.Name.StartsWith('zh')
    if (-not $listening) {
        if ($zh) { Show-LauncherMessage "请先在 CipherRelay 中连接节点，确保 $proxy 可用。无需开启 TUN。" }
        else { Show-LauncherMessage "Connect to a node in CipherRelay first. $proxy must be listening. TUN is not required." }
        exit 0
    }
    if ($running.Count -gt 0) {
        # Even apps with matching flags can have stale backend environment.
        # Never terminate a user's running work to change launch settings.
        if ($zh) { Show-LauncherMessage '请保存工作并完全退出目标应用，再点击此启动器，以应用代理和直连规则。' }
        else { Show-LauncherMessage 'Save your work and fully quit the target app, then open this launcher again to apply proxy and bypass settings.' }
        exit 0
    }
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $settings.appPath
    $start.WorkingDirectory = [IO.Path]::GetDirectoryName($settings.appPath)
    $start.UseShellExecute = $false
    # Rules and proxy addresses are validated to exclude quotes or whitespace.
    $start.Arguments = ($arguments | ForEach-Object { '"' + $_ + '"' }) -join ' '
    [void][Diagnostics.Process]::Start($start)
} catch {
    if ($Check) { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }
    Show-LauncherMessage $_.Exception.Message
    exit 1
}
