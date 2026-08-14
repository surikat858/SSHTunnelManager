#requires -version 5.1

# ============================================================
# SSH TUNNEL MANAGER
# Version 2.0
#
# SSH implementation:
#   SSH.NET / Renci.SshNet
#
# No plink.exe required.
#
# Designed for:
#   Windows PowerShell 5.1
#   .NET Framework 4.8
#   PS2EXE
# ============================================================

Set-StrictMode -Version Latest

$ErrorActionPreference = "Stop"

# ============================================================
# GLOBAL SETTINGS
# ============================================================

$script:AppName = "SSH Tunnel Manager"
$script:AppVersion = "2.1"

# --------------------------------------------------------
# BUG FIX (crash on startup: "Cannot find property 'Path'
# for this object"):
#
# $MyInvocation.MyCommand.Path only exists when the script
# runs directly as an .ps1 file (CommandType "ExternalScript").
#
# Inside a PS2EXE-compiled -NoConsole EXE, $MyInvocation.MyCommand
# is a completely different command object that has NO "Path"
# property at all - not $null, genuinely absent. With
# Set-StrictMode -Version Latest that means the very first line
# of the script throws immediately:
#
#   "Property 'Path' cannot be found for this object.
#    Make sure that it exists."
#
# ...and since it's a -NoConsole app, PS2EXE's generated host
# shows that error in a message box titled "SSH Tunnel Manager"
# and the app never gets further than that - exactly the crash
# reported.
#
# Fix (per PS2EXE's own README, credited there to JacquesFS):
# detect whether we're an ExternalScript (.ps1) or something
# else (compiled EXE) before ever touching .Path/.Definition.
# --------------------------------------------------------

if ($MyInvocation.MyCommand.CommandType -eq "ExternalScript") {

    # Running directly as SSHTunnelManager.ps1
    $script:AppDirectory = Split-Path `
        -Parent `
        -Path $MyInvocation.MyCommand.Definition
}
else {

    # Running as the compiled SSHTunnelManager.exe
    $script:AppDirectory = Split-Path `
        -Parent `
        -Path ([Environment]::GetCommandLineArgs()[0])
}

if ([string]::IsNullOrWhiteSpace($script:AppDirectory)) {
    $script:AppDirectory = [Environment]::CurrentDirectory
}

# --------------------------------------------------------
# IMPORTANT (PATH FIX):
#
# build.ps1 embeds the DLL using PS2EXE's -embedFiles with the
# target path "%TEMP%\SSHTunnelManager\Renci.SshNet.dll".
# PS2EXE expands %TEMP% at runtime the same way cmd.exe does,
# i.e. strictly from the TEMP environment variable.
#
# [System.IO.Path]::GetTempPath() is NOT guaranteed to return
# the same folder: internally it prefers TMP over TEMP. On a
# machine where TMP and TEMP point to different folders, using
# GetTempPath() here would make the script look in the wrong
# place and report "Renci.SshNet.dll not found" even though
# PS2EXE extracted it correctly.
#
# So we resolve the base folder the same way PS2EXE does:
# TEMP first, falling back only if it is not set at all.
# --------------------------------------------------------

$script:BaseTempPath = $env:TEMP

if ([string]::IsNullOrWhiteSpace($script:BaseTempPath)) {

    $script:BaseTempPath = $env:TMP
}

if ([string]::IsNullOrWhiteSpace($script:BaseTempPath)) {

    $script:BaseTempPath = [System.IO.Path]::GetTempPath()
}

$script:TempDirectory = Join-Path `
    $script:BaseTempPath `
    "SSHTunnelManager"

$script:SshDllPath = Join-Path `
    $script:TempDirectory `
    "Renci.SshNet.dll"

# Active SSH client
$script:SshClient = $null

# Active forwarding object
$script:ForwardedPort = $null

# Current connection state
$script:IsConnected = $false

# ============================================================
# WINDOWS FORMS
# ============================================================

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::EnableVisualStyles()

# ============================================================
# HELPER: SHOW ERROR
# ============================================================

function Show-Error {
    param(
        [string]$Message,
        [string]$Title = $script:AppName
    )

    try {

        [System.Windows.Forms.MessageBox]::Show(
            $Message,
            $Title,
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null

    }
    catch {
        Write-Host $Message
    }
}

# ============================================================
# HELPER: SHOW INFO
# ============================================================

function Show-Info {
    param(
        [string]$Message,
        [string]$Title = $script:AppName
    )

    try {

        [System.Windows.Forms.MessageBox]::Show(
            $Message,
            $Title,
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null

    }
    catch {
        Write-Host $Message
    }
}

# ============================================================
# LOAD SSH.NET
#
# IMPORTANT:
# We DO NOT use:
#   GetManifestResourceNames()
#   GetManifestResourceStream()
#
# PS2EXE -embedFiles extracts the DLL before the script starts.
# ============================================================

function Initialize-SshNet {

    try {

        # ----------------------------------------------------
        # Already loaded?
        # ----------------------------------------------------

        $loadedAssembly = [AppDomain]::CurrentDomain.GetAssemblies() |
            Where-Object {
                $_.GetName().Name -eq "Renci.SshNet"
            } |
            Select-Object -First 1

        if ($null -ne $loadedAssembly) {

            return $true
        }

        # ----------------------------------------------------
        # Expected embedded DLL location
        # ----------------------------------------------------

        if (Test-Path -LiteralPath $script:SshDllPath) {

            Add-Type `
                -Path $script:SshDllPath

            return $true
        }

        # ----------------------------------------------------
        # Fallback: [System.IO.Path]::GetTempPath() location
        #
        # Covers the rare case where %TMP% and %TEMP% point to
        # different folders on this machine.
        # ----------------------------------------------------

        $altTempDllPath = Join-Path `
            (Join-Path ([System.IO.Path]::GetTempPath()) "SSHTunnelManager") `
            "Renci.SshNet.dll"

        if (Test-Path -LiteralPath $altTempDllPath) {

            Add-Type `
                -Path $altTempDllPath

            return $true
        }

        # ----------------------------------------------------
        # Direct PS1 development mode
        #
        # Allows:
        # C:\SSHTunnelManager\Renci.SshNet.dll
        # ----------------------------------------------------

        $localDll = Join-Path `
            $script:AppDirectory `
            "Renci.SshNet.dll"

        if (Test-Path -LiteralPath $localDll) {

            Add-Type `
                -Path $localDll

            return $true
        }

        # ----------------------------------------------------
        # DLL not found
        # ----------------------------------------------------

        throw @"
Не найден Renci.SshNet.dll.

Проверено:

$($script:SshDllPath)

$altTempDllPath

$localDll

Если это EXE, пересобери программу через build.ps1
с поддержкой PS2EXE -embedFiles.
"@
    }
    catch {

        Show-Error `
            "Не удалось загрузить встроенный SSH.NET.`r`n`r`n$($_.Exception.Message)"

        return $false
    }
}

# ============================================================
# LOGGING
# ============================================================

$script:LogBox = $null

function Write-Log {

    param(
        [string]$Message
    )

    $timestamp = Get-Date -Format "HH:mm:ss"

    $line = "[$timestamp] $Message"

    try {

        if ($null -ne $script:LogBox) {

            $script:LogBox.AppendText(
                $line + [Environment]::NewLine
            )

            $script:LogBox.SelectionStart =
                $script:LogBox.TextLength

            $script:LogBox.ScrollToCaret()
        }

    }
    catch {
    }
}

# ============================================================
# PASSWORD PROTECTION (DPAPI)
#
# Uses Windows Data Protection API via ConvertTo/From-SecureString
# (no -Key given, so it defaults to DPAPI). The encrypted blob can
# only be decrypted by the SAME Windows user account on the SAME
# machine - it is not portable, and nothing but this Windows
# profile can ever read it back. This is the same mechanism
# Windows itself uses for things like saved Wi-Fi/RDP passwords.
# ============================================================

function Protect-SshPassword {

    param(
        [string]$PlainPassword
    )

    $secureString = ConvertTo-SecureString `
        -String $PlainPassword `
        -AsPlainText `
        -Force

    return ConvertFrom-SecureString `
        -SecureString $secureString
}

function Unprotect-SshPassword {

    param(
        [string]$EncryptedPassword
    )

    $secureString = ConvertTo-SecureString `
        -String $EncryptedPassword

    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR(
        $secureString
    )

    try {

        return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR(
            $bstr
        )
    }
    finally {

        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

# ============================================================
# SAVE / LOAD CONFIGURATION
# ============================================================

$script:ConfigDirectory = Join-Path `
    ([Environment]::GetFolderPath("ApplicationData")) `
    "SSHTunnelManager"

$script:ConfigFile = Join-Path `
    $script:ConfigDirectory `
    "config.json"

function Save-Config {

    param(
        [string]$HostName,
        [int]$SshPort,
        [string]$UserName,
        [int]$LocalPort,
        [string]$RemoteHost,
        [int]$RemotePort,
        [string]$Password,
        [bool]$RememberPassword
    )

    try {

        if (-not (Test-Path -LiteralPath $script:ConfigDirectory)) {

            New-Item `
                -Path $script:ConfigDirectory `
                -ItemType Directory `
                -Force |
                Out-Null
        }

        $config = [ordered]@{

            HostName   = $HostName
            SshPort    = $SshPort
            UserName   = $UserName
            LocalPort  = $LocalPort
            RemoteHost = $RemoteHost
            RemotePort = $RemotePort
        }

        # ------------------------------------------------------
        # Only ever store a password if the user explicitly
        # checked "Запомнить". Unchecking it and reconnecting
        # removes any previously saved password from the file.
        # ------------------------------------------------------

        if ($RememberPassword -and `
            -not [string]::IsNullOrEmpty($Password)) {

            try {

                $config.PasswordEncrypted =
                    Protect-SshPassword -PlainPassword $Password
            }
            catch {

                Write-Log `
                    "Не удалось сохранить пароль: $($_.Exception.Message)"
            }
        }

        $json = $config |
            ConvertTo-Json `
                -Depth 5

        [System.IO.File]::WriteAllText(
            $script:ConfigFile,
            $json,
            [System.Text.Encoding]::UTF8
        )

    }
    catch {

        Write-Log `
            "Не удалось сохранить настройки: $($_.Exception.Message)"
    }
}

function Load-Config {

    if (-not (Test-Path -LiteralPath $script:ConfigFile)) {

        return $null
    }

    try {

        $json = [System.IO.File]::ReadAllText(
            $script:ConfigFile,
            [System.Text.Encoding]::UTF8
        )

        if ([string]::IsNullOrWhiteSpace($json)) {

            return $null
        }

        return $json |
            ConvertFrom-Json
    }
    catch {

        Write-Log `
            "Не удалось загрузить настройки: $($_.Exception.Message)"

        return $null
    }
}

# ============================================================
# VALIDATE PORT
# ============================================================

function Test-PortNumber {

    param(
        [string]$Value,
        [string]$Name
    )

    $number = 0

    if (-not [int]::TryParse($Value, [ref]$number)) {

        throw "$Name должен быть числом."
    }

    if ($number -lt 1 -or $number -gt 65535) {

        throw "$Name должен быть от 1 до 65535."
    }

    return $number
}

# ============================================================
# VALIDATE HOST
# ============================================================

function Test-HostName {

    param(
        [string]$Value,
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {

        throw "$Name не указан."
    }

    return $Value.Trim()
}

# ============================================================
# CREATE SSH CLIENT
# ============================================================

function New-SshClient {

    param(
        [string]$HostName,
        [int]$Port,
        [string]$UserName,
        [string]$Password
    )

    if ([string]::IsNullOrWhiteSpace($HostName)) {
        throw "SSH Host не указан."
    }

    if ([string]::IsNullOrWhiteSpace($UserName)) {
        throw "SSH User не указан."
    }

    # --------------------------------------------------------
    # Password authentication
    # --------------------------------------------------------

    $connectionInfo = New-Object `
        Renci.SshNet.PasswordConnectionInfo(
            $HostName,
            $Port,
            $UserName,
            $Password
        )

    # --------------------------------------------------------
    # Timeout for the initial connection/handshake.
    #
    # 30 seconds matches SSH.NET's own internal default - long
    # enough for a slow network or a server that's briefly busy,
    # while still failing in reasonable time if the host/port is
    # genuinely wrong or unreachable.
    # --------------------------------------------------------

    $connectionInfo.Timeout = `
        New-TimeSpan -Seconds 30

    $client = New-Object `
        Renci.SshNet.SshClient(
            $connectionInfo
        )

    # --------------------------------------------------------
    # Automatically accept host key.
    #
    # This makes the manager convenient, but it is less secure
    # than verifying a known host fingerprint.
    # --------------------------------------------------------

    # ----------------------------------------------------------
    # BUG FIX #2 ("There is no Runspace available to run scripts
    # in this thread"):
    #
    # SSH.NET raises HostKeyReceived from its OWN internal
    # background thread (the session's packet-reader thread)
    # while Connect() is negotiating the key exchange - not from
    # the thread that called Connect().
    #
    # A PowerShell scriptblock attached via add_HostKeyReceived()
    # works fine for WinForms events (Add_Click, Add_FormClosing
    # below) because those always fire on the UI thread, which
    # owns a runspace. SSH.NET's background thread owns none, so
    # PowerShell throws the instant it tries to run the
    # scriptblock there.
    #
    # Register-ObjectEvent does NOT fix this: its -Action runs
    # asynchronously off an internal queue. SSH.NET reads
    # e.CanTrust synchronously right after raising the event, so
    # by the time a queued action would set it, SSH.NET has
    # already rejected the key using its untouched default value.
    #
    # The reliable fix is to hand SSH.NET a real compiled .NET
    # delegate instead of PowerShell script, so nothing
    # PowerShell-specific ever has to run on that thread.
    # ----------------------------------------------------------

    if (-not ("SSHTunnelManager.TrustAllHostKeys" -as [type])) {

        $sshNetAssembly = [AppDomain]::CurrentDomain.GetAssemblies() |
            Where-Object {
                $_.GetName().Name -eq "Renci.SshNet"
            } |
            Select-Object -First 1

        if ($null -eq $sshNetAssembly) {

            throw "Сборка Renci.SshNet не загружена."
        }

        Add-Type `
            -Language CSharp `
            -ReferencedAssemblies $sshNetAssembly.Location `
            -TypeDefinition @"
using Renci.SshNet.Common;

namespace SSHTunnelManager
{
    public static class TrustAllHostKeys
    {
        public static void Handler(object sender, HostKeyEventArgs e)
        {
            e.CanTrust = true;
        }
    }
}
"@
    }

    $trustMethodInfo = [SSHTunnelManager.TrustAllHostKeys].GetMethod("Handler")

    $trustDelegate = [Delegate]::CreateDelegate(
        [System.EventHandler[Renci.SshNet.Common.HostKeyEventArgs]],
        $trustMethodInfo
    )

    $client.add_HostKeyReceived($trustDelegate)

    return $client
}

# ============================================================
# STOP TUNNEL
# ============================================================

function Stop-SshTunnel {

    Write-Log "Остановка SSH-туннеля..."

    $script:IsConnected = $false

    # --------------------------------------------------------
    # Stop forwarding
    # --------------------------------------------------------

    if ($null -ne $script:ForwardedPort) {

        try {

            if ($script:ForwardedPort.IsStarted) {

                $script:ForwardedPort.Stop()
            }

        }
        catch {

            Write-Log `
                "Ошибка остановки forwarding: $($_.Exception.Message)"
        }

        try {

            $script:ForwardedPort.Dispose()

        }
        catch {
        }

        $script:ForwardedPort = $null
    }

    # --------------------------------------------------------
    # Disconnect SSH
    # --------------------------------------------------------

    if ($null -ne $script:SshClient) {

        try {

            if ($script:SshClient.IsConnected) {

                $script:SshClient.Disconnect()
            }

        }
        catch {

            Write-Log `
                "Ошибка отключения SSH: $($_.Exception.Message)"
        }

        try {

            $script:SshClient.Dispose()

        }
        catch {
        }

        $script:SshClient = $null
    }

    Write-Log "SSH-туннель остановлен."

    if ($null -ne $script:StatusLabel) {

        $script:StatusLabel.Text = "Статус: Отключен"
        $script:StatusLabel.ForeColor =
            [System.Drawing.Color]::Firebrick
    }

    if ($null -ne $script:StartButton) {

        $script:StartButton.Enabled = $true
    }

    if ($null -ne $script:StopButton) {

        $script:StopButton.Enabled = $false
    }
}

# ============================================================
# START TUNNEL
# ============================================================

function Start-SshTunnel {

    try {

        # ----------------------------------------------------
        # Check SSH.NET
        # ----------------------------------------------------

        if (-not (Initialize-SshNet)) {

            return
        }

        # ----------------------------------------------------
        # Read GUI values
        # ----------------------------------------------------

        $hostName = Test-HostName `
            $script:HostBox.Text `
            "SSH Host"

        $userName = Test-HostName `
            $script:UserBox.Text `
            "SSH User"

        $password = $script:PasswordBox.Text

        if ([string]::IsNullOrEmpty($password)) {

            throw "SSH Password не указан."
        }

        $sshPort = Test-PortNumber `
            $script:SshPortBox.Text `
            "SSH Port"

        $localPort = Test-PortNumber `
            $script:LocalPortBox.Text `
            "Local Port"

        $remotePort = Test-PortNumber `
            $script:RemotePortBox.Text `
            "Remote Port"

        $remoteHost = Test-HostName `
            $script:RemoteHostBox.Text `
            "Remote Host"

        # ----------------------------------------------------
        # Check local port
        # ----------------------------------------------------

        $listener = $null

        try {

            $listener = New-Object `
                System.Net.Sockets.TcpListener(
                    [System.Net.IPAddress]::Loopback,
                    $localPort
                )

            $listener.Start()

        }
        catch {

            throw "Локальный порт $localPort уже занят или недоступен."
        }
        finally {

            if ($null -ne $listener) {

                try {
                    $listener.Stop()
                }
                catch {
                }
            }
        }

        # ----------------------------------------------------
        # Save configuration
        # ----------------------------------------------------

        Save-Config `
            -HostName $hostName `
            -SshPort $sshPort `
            -UserName $userName `
            -LocalPort $localPort `
            -RemoteHost $remoteHost `
            -RemotePort $remotePort `
            -Password $password `
            -RememberPassword $script:RememberPasswordCheckBox.Checked

        # ----------------------------------------------------
        # Stop old connection if any
        # ----------------------------------------------------

        if ($script:IsConnected) {

            Stop-SshTunnel
        }

        Write-Log "Подключение к $hostName`:$sshPort..."

        # ----------------------------------------------------
        # Create SSH client
        # ----------------------------------------------------

        $client = New-SshClient `
            -HostName $hostName `
            -Port $sshPort `
            -UserName $userName `
            -Password $password

        $script:SshClient = $client

        # ----------------------------------------------------
        # Connect
        # ----------------------------------------------------

        $client.Connect()

        if (-not $client.IsConnected) {

            throw "SSH.NET не установил соединение."
        }

        Write-Log "SSH подключение установлено."

        # ----------------------------------------------------
        # Create local port forwarding
        #
        # localhost:LocalPort
        #
        #       ↓ SSH
        #
        # RemoteHost:RemotePort
        # ----------------------------------------------------

        $forwardedPort = New-Object `
            Renci.SshNet.ForwardedPortLocal(
                "127.0.0.1",
                [uint32]$localPort,
                $remoteHost,
                [uint32]$remotePort
            )

        $script:ForwardedPort = $forwardedPort

        # ----------------------------------------------------
        # Add forwarding
        # ----------------------------------------------------

        $client.AddForwardedPort(
            $forwardedPort
        )

        # ----------------------------------------------------
        # Start forwarding
        # ----------------------------------------------------

        $forwardedPort.Start()

        $script:IsConnected = $true

        Write-Log `
            "SSH-туннель запущен: 127.0.0.1:$localPort -> $remoteHost`:$remotePort"

        # ----------------------------------------------------
        # GUI state
        # ----------------------------------------------------

        if ($null -ne $script:StatusLabel) {

            $script:StatusLabel.Text =
                "Статус: ПОДКЛЮЧЕН"

            $script:StatusLabel.ForeColor =
                [System.Drawing.Color]::ForestGreen
        }

        if ($null -ne $script:StartButton) {

            $script:StartButton.Enabled = $false
        }

        if ($null -ne $script:StopButton) {

            $script:StopButton.Enabled = $true
        }

    }
    catch {

        Write-Log `
            "ОШИБКА: $($_.Exception.Message)"

        # Cleanup failed connection

        try {

            if ($null -ne $script:ForwardedPort) {

                $script:ForwardedPort.Stop()
                $script:ForwardedPort.Dispose()
                $script:ForwardedPort = $null
            }

        }
        catch {
        }

        try {

            if ($null -ne $script:SshClient) {

                if ($script:SshClient.IsConnected) {

                    $script:SshClient.Disconnect()
                }

                $script:SshClient.Dispose()
                $script:SshClient = $null
            }

        }
        catch {
        }

        $script:IsConnected = $false

        if ($null -ne $script:StatusLabel) {

            $script:StatusLabel.Text =
                "Статус: Ошибка"

            $script:StatusLabel.ForeColor =
                [System.Drawing.Color]::Firebrick
        }

        if ($null -ne $script:StartButton) {

            $script:StartButton.Enabled = $true
        }

        if ($null -ne $script:StopButton) {

            $script:StopButton.Enabled = $false
        }

        $errorMessage = $_.Exception.Message

        if ($errorMessage -match "timed out") {

            $errorMessage += `
                [Environment]::NewLine + `
                [Environment]::NewLine + `
                "Сервер не ответил вовремя. Проверьте: правильность Host/Port, доступность сервера по сети (файрвол, VPN), и что SSH-сервер на нём действительно запущен."
        }

        Show-Error `
            $errorMessage
    }
}

# ============================================================
# MAIN FORM
# ============================================================

$form = New-Object `
    System.Windows.Forms.Form

$form.Text =
    "$($script:AppName) $($script:AppVersion)"

$form.StartPosition =
    "CenterScreen"

$form.Size =
    New-Object System.Drawing.Size(260, 270)

$form.MinimumSize =
    New-Object System.Drawing.Size(260, 270)

$form.MaximizeBox =
    $false

$form.FormBorderStyle =
    [System.Windows.Forms.FormBorderStyle]::FixedSingle

$form.Font =
    New-Object System.Drawing.Font(
        "Segoe UI",
        9
    )

# ------------------------------------------------------------
# Compact layout note:
#
# 260x270 by default (~half the area of the previous 400x360
# version) - dropped the GroupBox chrome in favour of a flat
# field list, and moved the example hint into a tooltip on the
# Remote Host box instead of an always-visible line.
#
# The log panel now expands SIDEWAYS: clicking the toggle grows
# the window's WIDTH (260 -> 500) to reveal a panel on the
# right, height never changes. Toggle logic sits right after
# $script:LogGroup / $script:LogToggleButton are created below.
# ------------------------------------------------------------

# ============================================================
# HOST + SSH PORT (same row)
# ============================================================

$label = New-Object `
    System.Windows.Forms.Label

$label.Text = "Host:"

$label.Location =
    New-Object System.Drawing.Point(8, 10)

$label.Size =
    New-Object System.Drawing.Size(34, 16)

$form.Controls.Add($label)

$script:HostBox = New-Object `
    System.Windows.Forms.TextBox

$script:HostBox.Location =
    New-Object System.Drawing.Point(44, 8)

$script:HostBox.Size =
    New-Object System.Drawing.Size(140, 20)

$form.Controls.Add($script:HostBox)

$label = New-Object `
    System.Windows.Forms.Label

$label.Text = "Port:"

$label.Location =
    New-Object System.Drawing.Point(188, 10)

$label.Size =
    New-Object System.Drawing.Size(30, 16)

$form.Controls.Add($label)

$script:SshPortBox = New-Object `
    System.Windows.Forms.TextBox

$script:SshPortBox.Location =
    New-Object System.Drawing.Point(220, 8)

$script:SshPortBox.Size =
    New-Object System.Drawing.Size(32, 20)

$script:SshPortBox.Text = "22"

$form.Controls.Add($script:SshPortBox)

# ============================================================
# USER
# ============================================================

$label = New-Object `
    System.Windows.Forms.Label

$label.Text = "User:"

$label.Location =
    New-Object System.Drawing.Point(8, 34)

$label.Size =
    New-Object System.Drawing.Size(34, 16)

$form.Controls.Add($label)

$script:UserBox = New-Object `
    System.Windows.Forms.TextBox

$script:UserBox.Location =
    New-Object System.Drawing.Point(44, 32)

$script:UserBox.Size =
    New-Object System.Drawing.Size(208, 20)

$form.Controls.Add($script:UserBox)

# ============================================================
# PASSWORD
# ============================================================

$label = New-Object `
    System.Windows.Forms.Label

$label.Text = "Password:"

$label.Location =
    New-Object System.Drawing.Point(8, 58)

$label.Size =
    New-Object System.Drawing.Size(62, 16)

$form.Controls.Add($label)

$script:PasswordBox = New-Object `
    System.Windows.Forms.TextBox

$script:PasswordBox.Location =
    New-Object System.Drawing.Point(72, 56)

$script:PasswordBox.Size =
    New-Object System.Drawing.Size(180, 20)

$script:PasswordBox.UseSystemPasswordChar =
    $true

$form.Controls.Add($script:PasswordBox)

# ============================================================
# REMEMBER PASSWORD (its own thin row, indented under the box)
# ============================================================

$script:RememberPasswordCheckBox = New-Object `
    System.Windows.Forms.CheckBox

$script:RememberPasswordCheckBox.Text =
    "Запомнить пароль"

$script:RememberPasswordCheckBox.AutoSize =
    $false

$script:RememberPasswordCheckBox.Location =
    New-Object System.Drawing.Point(72, 79)

$script:RememberPasswordCheckBox.Size =
    New-Object System.Drawing.Size(170, 16)

$script:RememberPasswordCheckBox.Font =
    New-Object System.Drawing.Font(
        "Segoe UI",
        8
    )

$form.Controls.Add($script:RememberPasswordCheckBox)

# ============================================================
# LOCAL PORT + REMOTE PORT (same row)
# ============================================================

$label = New-Object `
    System.Windows.Forms.Label

$label.Text = "L.Port:"

$label.Location =
    New-Object System.Drawing.Point(8, 102)

$label.Size =
    New-Object System.Drawing.Size(44, 16)

$form.Controls.Add($label)

$script:LocalPortBox = New-Object `
    System.Windows.Forms.TextBox

$script:LocalPortBox.Location =
    New-Object System.Drawing.Point(54, 100)

$script:LocalPortBox.Size =
    New-Object System.Drawing.Size(50, 20)

$script:LocalPortBox.Text = "8080"

$form.Controls.Add($script:LocalPortBox)

$label = New-Object `
    System.Windows.Forms.Label

$label.Text = "R.Port:"

$label.Location =
    New-Object System.Drawing.Point(114, 102)

$label.Size =
    New-Object System.Drawing.Size(44, 16)

$form.Controls.Add($label)

$script:RemotePortBox = New-Object `
    System.Windows.Forms.TextBox

$script:RemotePortBox.Location =
    New-Object System.Drawing.Point(160, 100)

$script:RemotePortBox.Size =
    New-Object System.Drawing.Size(92, 20)

$script:RemotePortBox.Text = "3389"

$form.Controls.Add($script:RemotePortBox)

# ============================================================
# REMOTE HOST
# ============================================================

$label = New-Object `
    System.Windows.Forms.Label

$label.Text = "Remote:"

$label.Location =
    New-Object System.Drawing.Point(8, 126)

$label.Size =
    New-Object System.Drawing.Size(48, 16)

$form.Controls.Add($label)

$script:RemoteHostBox = New-Object `
    System.Windows.Forms.TextBox

$script:RemoteHostBox.Location =
    New-Object System.Drawing.Point(58, 124)

$script:RemoteHostBox.Size =
    New-Object System.Drawing.Size(194, 20)

$script:RemoteHostBox.Text = "127.0.0.1"

$form.Controls.Add($script:RemoteHostBox)

# ------------------------------------------------------------
# The old always-visible "Пример: ..." line got dropped for
# space - it now lives as a tooltip on the Remote Host field
# and the Remember-password checkbox instead.
# ------------------------------------------------------------

$script:HintTip = New-Object `
    System.Windows.Forms.ToolTip

$script:HintTip.SetToolTip(
    $script:RemoteHostBox,
    "Пример: localhost:8080 -> через SSH -> 127.0.0.1:3389"
)

$script:HintTip.SetToolTip(
    $script:RememberPasswordCheckBox,
    "Пароль хранится зашифрованным (DPAPI) только для этого пользователя Windows"
)

# ============================================================
# BUTTONS
# ============================================================

$script:StartButton = New-Object `
    System.Windows.Forms.Button

$script:StartButton.Text =
    "Запустить"

$script:StartButton.Location =
    New-Object System.Drawing.Point(8, 152)

$script:StartButton.Size =
    New-Object System.Drawing.Size(120, 26)

$script:StartButton.Font =
    New-Object System.Drawing.Font(
        "Segoe UI Semibold",
        9
    )

$form.Controls.Add($script:StartButton)

$script:StopButton = New-Object `
    System.Windows.Forms.Button

$script:StopButton.Text =
    "Стоп"

$script:StopButton.Location =
    New-Object System.Drawing.Point(132, 152)

$script:StopButton.Size =
    New-Object System.Drawing.Size(120, 26)

$script:StopButton.Enabled =
    $false

$form.Controls.Add($script:StopButton)

# ============================================================
# STATUS
# ============================================================

$script:StatusLabel = New-Object `
    System.Windows.Forms.Label

$script:StatusLabel.Text =
    "Статус: Отключен"

$script:StatusLabel.Location =
    New-Object System.Drawing.Point(8, 182)

$script:StatusLabel.Size =
    New-Object System.Drawing.Size(244, 20)

$script:StatusLabel.TextAlign =
    [System.Drawing.ContentAlignment]::MiddleCenter

$script:StatusLabel.Font =
    New-Object System.Drawing.Font(
        "Segoe UI Semibold",
        9
    )

$script:StatusLabel.ForeColor =
    [System.Drawing.Color]::Firebrick

$form.Controls.Add($script:StatusLabel)

# ============================================================
# LOG TOGGLE
# ============================================================

$script:LogToggleButton = New-Object `
    System.Windows.Forms.Button

$script:LogToggleButton.Text =
    "Журнал >>"

$script:LogToggleButton.Location =
    New-Object System.Drawing.Point(8, 206)

$script:LogToggleButton.Size =
    New-Object System.Drawing.Size(244, 22)

$script:LogToggleButton.FlatStyle =
    [System.Windows.Forms.FlatStyle]::Flat

$form.Controls.Add($script:LogToggleButton)

# ============================================================
# LOG GROUP - opens to the RIGHT of the main panel, collapsed
# (hidden) by default
# ============================================================

$script:LogGroup = New-Object `
    System.Windows.Forms.GroupBox

$script:LogGroup.Text =
    "Журнал"

$script:LogGroup.Location =
    New-Object System.Drawing.Point(268, 8)

$script:LogGroup.Size =
    New-Object System.Drawing.Size(220, 220)

$script:LogGroup.Visible =
    $false

$form.Controls.Add($script:LogGroup)

$script:LogBox = New-Object `
    System.Windows.Forms.TextBox

$script:LogBox.Location =
    New-Object System.Drawing.Point(10, 20)

$script:LogBox.Size =
    New-Object System.Drawing.Size(200, 190)

$script:LogBox.Multiline =
    $true

$script:LogBox.ReadOnly =
    $true

$script:LogBox.ScrollBars =
    [System.Windows.Forms.ScrollBars]::Vertical

$script:LogBox.BackColor =
    [System.Drawing.Color]::White

$script:LogGroup.Controls.Add($script:LogBox)

# ------------------------------------------------------------
# Toggle behaviour: expand grows the window's WIDTH to reveal
# the log panel on the right; height never changes. MinimumSize
# above was set to the collapsed (narrow) size, which only
# constrains shrinking, not growing, so both directions work
# without touching it again.
# ------------------------------------------------------------

$script:LogExpanded = $false

$script:LogToggleButton.Add_Click({

    $script:LogExpanded = -not $script:LogExpanded

    if ($script:LogExpanded) {

        $script:LogGroup.Visible = $true

        $form.Size = New-Object System.Drawing.Size(500, 270)

        $script:LogToggleButton.Text = "<< Скрыть"
    }
    else {

        $script:LogGroup.Visible = $false

        $form.Size = New-Object System.Drawing.Size(260, 270)

        $script:LogToggleButton.Text = "Журнал >>"
    }
})

# ============================================================
# BUTTON EVENTS
# ============================================================

$script:StartButton.Add_Click({

    Start-SshTunnel
})

$script:StopButton.Add_Click({

    Stop-SshTunnel
})

# ============================================================
# FORM CLOSE
# ============================================================

$form.Add_FormClosing({

    try {

        Stop-SshTunnel

    }
    catch {
    }
})

# ============================================================
# LOAD CONFIGURATION
# ============================================================

$config = Load-Config

if ($null -ne $config) {

    try {

        if ($null -ne $config.HostName) {

            $script:HostBox.Text =
                [string]$config.HostName
        }

        if ($null -ne $config.SshPort) {

            $script:SshPortBox.Text =
                [string]$config.SshPort
        }

        if ($null -ne $config.UserName) {

            $script:UserBox.Text =
                [string]$config.UserName
        }

        if ($null -ne $config.LocalPort) {

            $script:LocalPortBox.Text =
                [string]$config.LocalPort
        }

        if ($null -ne $config.RemoteHost) {

            $script:RemoteHostBox.Text =
                [string]$config.RemoteHost
        }

        if ($null -ne $config.RemotePort) {

            $script:RemotePortBox.Text =
                [string]$config.RemotePort
        }

        if (-not [string]::IsNullOrEmpty($config.PasswordEncrypted)) {

            try {

                $script:PasswordBox.Text =
                    Unprotect-SshPassword `
                        -EncryptedPassword $config.PasswordEncrypted

                $script:RememberPasswordCheckBox.Checked =
                    $true
            }
            catch {

                # Most likely the config file was copied from a
                # different Windows user/machine - DPAPI can only
                # decrypt on the original account, so just leave
                # the password field empty instead of crashing.

                Write-Log `
                    "Не удалось расшифровать сохранённый пароль (скопирован с другого ПК/учётки?)."
            }
        }

    }
    catch {
    }
}

# ============================================================
# STARTUP LOG
# ============================================================

Write-Log "SSH Tunnel Manager $($script:AppVersion)"
Write-Log "SSH.NET используется вместо plink.exe."
Write-Log "Таймаут подключения: 30 сек."

if (Test-Path -LiteralPath $script:SshDllPath) {

    Write-Log "SSH.NET DLL найдена: $($script:SshDllPath)"
}
else {

    $localDll = Join-Path `
        $script:AppDirectory `
        "Renci.SshNet.dll"

    if (Test-Path -LiteralPath $localDll) {

        Write-Log "Режим разработки: найдена локальная SSH.NET DLL."
    }
    else {

        Write-Log "SSH.NET DLL будет ожидаться от PS2EXE -embedFiles."
    }
}

# ============================================================
# SHOW FORM
# ============================================================

[void]$form.ShowDialog()

# ============================================================
# FINAL CLEANUP
# ============================================================

try {

    Stop-SshTunnel

}
catch {
}

# ============================================================
# END
# ============================================================