$ErrorActionPreference = "Stop"

# ============================================================
# SSH TUNNEL MANAGER BUILD
# ============================================================

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path

$Source = Join-Path `
    $Root `
    "SSHTunnelManager.ps1"

$Output = Join-Path `
    $Root `
    "SSHTunnelManager.exe"

$BuildDirectory = Join-Path `
    $Root `
    "_build"

$PackageFile = Join-Path `
    $BuildDirectory `
    "SSH.NET.nupkg"

$ExtractDirectory = Join-Path `
    $BuildDirectory `
    "SSH.NET"

$SshDll = Join-Path `
    $BuildDirectory `
    "Renci.SshNet.dll"

$NugetUrl = `
    "https://www.nuget.org/api/v2/package/SSH.NET/2020.0.2"

Write-Host ""
Write-Host "========================================"
Write-Host " SSH Tunnel Manager"
Write-Host " BUILD"
Write-Host "========================================"
Write-Host ""

# ============================================================
# FORCE TLS 1.2
#
# PowerShell Gallery and nuget.org require TLS 1.2. On some
# Windows PowerShell 5.1 setups the .NET Framework default
# SecurityProtocol does not include it, which makes
# Install-Module / Invoke-WebRequest fail with a vague
# "underlying connection was closed" error. This is harmless
# to set even if TLS 1.2 is already enabled.
# ============================================================

try {

    [Net.ServicePointManager]::SecurityProtocol = `
        [Net.ServicePointManager]::SecurityProtocol -bor `
        [Net.SecurityProtocolType]::Tls12
}
catch {
}

# ============================================================
# CHECK SOURCE
# ============================================================

if (-not (Test-Path -LiteralPath $Source)) {

    throw "Не найден файл: $Source"
}

Write-Host "PS1:"
Write-Host $Source
Write-Host ""

# ------------------------------------------------------------
# FINGERPRINT (so you can verify which file is really being
# compiled, independent of how it was downloaded/renamed):
# ------------------------------------------------------------

$sourceInfo = Get-Item -LiteralPath $Source

Write-Host "Изменён:  $($sourceInfo.LastWriteTime)"
Write-Host "Размер:   $($sourceInfo.Length) байт"
Write-Host ""
Write-Host "^ Если это не та версия, которую ты ожидал -"
Write-Host "  проверь, нет ли рядом ДРУГОГО SSHTunnelManager.ps1"
Write-Host "  (например, в Downloads с суффиксом (1), (2) и т.д.),"
Write-Host "  и что рядом с build.ps1 лежит именно нужный файл."
Write-Host ""

# ============================================================
# STOP OLD APPLICATION
# ============================================================

$oldProcesses = Get-Process `
    -Name "SSHTunnelManager" `
    -ErrorAction SilentlyContinue

if ($null -ne $oldProcesses) {

    Write-Host "Останавливаем старый SSHTunnelManager.exe..."

    foreach ($process in $oldProcesses) {

        try {

            Stop-Process `
                -Id $process.Id `
                -Force `
                -ErrorAction Stop

        }
        catch {

            throw "Не удалось остановить SSHTunnelManager.exe PID $($process.Id)"
        }
    }

    Start-Sleep -Milliseconds 700
}

# ============================================================
# LOAD PS2EXE
# ============================================================

Remove-Module ps2exe -ErrorAction SilentlyContinue

# ------------------------------------------------------------
# PATH FIX (part 1):
#
# Install-Module -Scope CurrentUser installs into the current
# user's "Documents\WindowsPowerShell\Modules" folder. If that
# folder was just created (first module ever installed for
# this user) or Documents is redirected (e.g. by OneDrive),
# $env:PSModulePath for THIS already-running session may not
# contain it yet, so Get-Module -ListAvailable silently returns
# nothing even right after a successful install. We add it
# explicitly instead of relying on it already being there.
# ------------------------------------------------------------

$userModulePath = Join-Path `
    ([Environment]::GetFolderPath("MyDocuments")) `
    "WindowsPowerShell\Modules"

if ($env:PSModulePath -notlike "*$userModulePath*") {

    $env:PSModulePath = `
        $userModulePath + ";" + $env:PSModulePath
}

$ps2exeModule = Get-Module `
    -ListAvailable `
    -Name ps2exe |
    Sort-Object Version -Descending |
    Select-Object -First 1

if ($null -eq $ps2exeModule) {

    Write-Host "PS2EXE не найден."
    Write-Host "Устанавливаем последнюю версию..."
    Write-Host ""

    # --------------------------------------------------------
    # PATH FIX (part 2):
    #
    # Install-Module needs the NuGet provider and, ideally, a
    # trusted PSGallery. On a "clean" machine the first call
    # can otherwise fail or hang waiting for a confirmation
    # prompt instead of just installing.
    # --------------------------------------------------------

    $nugetProvider = Get-PackageProvider `
        -Name NuGet `
        -ListAvailable `
        -ErrorAction SilentlyContinue

    if ($null -eq $nugetProvider) {

        Write-Host "Устанавливаем провайдер NuGet..."

        Install-PackageProvider `
            -Name NuGet `
            -MinimumVersion 2.8.5.201 `
            -Scope CurrentUser `
            -Force |
            Out-Null
    }

    try {

        $psGallery = Get-PSRepository `
            -Name PSGallery `
            -ErrorAction SilentlyContinue

        if (($null -ne $psGallery) -and `
            ($psGallery.InstallationPolicy -ne "Trusted")) {

            Set-PSRepository `
                -Name PSGallery `
                -InstallationPolicy Trusted
        }
    }
    catch {
    }

    Install-Module `
        -Name ps2exe `
        -Scope CurrentUser `
        -Force `
        -AllowClobber

    $ps2exeModule = Get-Module `
        -ListAvailable `
        -Name ps2exe |
        Sort-Object Version -Descending |
        Select-Object -First 1

    if ($null -eq $ps2exeModule) {

        throw @"
PS2EXE был установлен, но не найден в этой сессии PowerShell.

Проверенный путь:

$userModulePath

Закрой это окно PowerShell, открой новое и снова запусти build.ps1.
"@
    }
}

Write-Host "PS2EXE:"
Write-Host "Version: $($ps2exeModule.Version)"
Write-Host "Path:    $($ps2exeModule.Path)"
Write-Host ""

Import-Module `
    $ps2exeModule.Path `
    -Force

# ============================================================
# CHECK EMBEDFILES
# ============================================================

$invokeCommand = Get-Command `
    Invoke-ps2exe `
    -ErrorAction Stop

if (-not $invokeCommand.Parameters.ContainsKey("embedFiles")) {

    throw @"
Текущая версия PS2EXE не поддерживает -embedFiles.

Установлена версия:

$($ps2exeModule.Version)

Закрой PowerShell, открой новый PowerShell
и выполни:

Install-Module ps2exe -Scope CurrentUser -Force -AllowClobber

Затем снова запусти build.ps1.
"@
}

Write-Host "Поддержка embedFiles: OK"
Write-Host ""

# ============================================================
# CLEAN BUILD DIRECTORY
# ============================================================

if (Test-Path $BuildDirectory) {

    Remove-Item `
        $BuildDirectory `
        -Recurse `
        -Force
}

New-Item `
    -Path $BuildDirectory `
    -ItemType Directory `
    -Force |
    Out-Null

# ============================================================
# DOWNLOAD SSH.NET
# ============================================================

Write-Host "Загрузка SSH.NET..."
Write-Host ""

Invoke-WebRequest `
    -Uri $NugetUrl `
    -OutFile $PackageFile `
    -UseBasicParsing

if (-not (Test-Path $PackageFile)) {

    throw "Не удалось скачать SSH.NET."
}

Write-Host "SSH.NET скачан."
Write-Host ""

# ============================================================
# EXTRACT PACKAGE
# ============================================================

Write-Host "Распаковка SSH.NET..."

Add-Type `
    -AssemblyName System.IO.Compression.FileSystem

if (Test-Path $ExtractDirectory) {

    Remove-Item `
        $ExtractDirectory `
        -Recurse `
        -Force
}

[System.IO.Compression.ZipFile]::ExtractToDirectory(
    $PackageFile,
    $ExtractDirectory
)

# ============================================================
# FIND DLL
#
# IMPORTANT (PATH FIX):
#
# The SSH.NET package embeds SEVERAL copies of a file called
# "Renci.SshNet.dll" - one per target framework, e.g.:
#
#   lib\net35\Renci.SshNet.dll
#   lib\net40\Renci.SshNet.dll
#   lib\netstandard1.3\Renci.SshNet.dll
#   lib\netstandard2.0\Renci.SshNet.dll
#
# The old code did:
#
#   Get-ChildItem -Recurse -Filter "Renci.SshNet.dll" |
#       Select-Object -First 1
#
# "First" here depends on file system / enumeration order, NOT
# on which build is correct - it can just as easily grab the
# netstandard2.0 copy as the net40 one.
#
# That matters a lot:
#   - The net35/net40 builds are fully self-contained ("No
#     dependencies"), which is exactly what a single embedded
#     DLL needs.
#   - The netstandard1.3/2.0 builds additionally require a
#     separate SshNet.Security.Cryptography.dll assembly, which
#     this script never downloads or embeds. Even if Add-Type
#     manages to load that copy under .NET Framework, the app
#     will crash the moment it actually tries to connect, with
#     something like "Could not load file or assembly
#     'SshNet.Security.Cryptography'".
#
# So we explicitly pick the .NET Framework 4.0 build, falling
# back to 3.5 only if 4.0 is somehow missing.
# ============================================================

$dllCandidates = Get-ChildItem `
    -Path $ExtractDirectory `
    -Recurse `
    -Filter "Renci.SshNet.dll"

if ($null -eq $dllCandidates -or $dllCandidates.Count -eq 0) {

    throw "Renci.SshNet.dll не найдена в скачанном пакете."
}

$dllCandidate = $dllCandidates |
    Where-Object { $_.FullName -match '\\lib\\net40\\' } |
    Select-Object -First 1

if ($null -eq $dllCandidate) {

    $dllCandidate = $dllCandidates |
        Where-Object { $_.FullName -match '\\lib\\net35\\' } |
        Select-Object -First 1
}

if ($null -eq $dllCandidate) {

    throw @"
Не удалось найти сборку Renci.SshNet.dll для .NET Framework
(ожидалась папка lib\net40 или lib\net35) внутри скачанного
пакета SSH.NET.

Найденные копии:

$($dllCandidates.FullName -join "`r`n")

Использование сборки для .NET Standard приведёт к ошибке при
подключении, так как ей отдельно нужна SshNet.Security.Cryptography.dll,
которая здесь не скачивается.
"@
}

Write-Host "Выбрана сборка:"
Write-Host $dllCandidate.FullName
Write-Host ""

Copy-Item `
    -LiteralPath $dllCandidate.FullName `
    -Destination $SshDll `
    -Force

Write-Host ""
Write-Host "SSH.NET DLL:"
Write-Host $SshDll
Write-Host ""

# ============================================================
# COPY DLL NEXT TO PS1 FOR DIRECT TESTING
# ============================================================

$LocalDll = Join-Path `
    $Root `
    "Renci.SshNet.dll"

Copy-Item `
    -LiteralPath $SshDll `
    -Destination $LocalDll `
    -Force

# ============================================================
# REMOVE OLD EXE
# ============================================================

if (Test-Path $Output) {

    Write-Host "Удаляем старый EXE..."

    try {

        Remove-Item `
            -LiteralPath $Output `
            -Force `
            -ErrorAction Stop

    }
    catch {

        throw @"
Не удалось удалить:

$Output

Убедись, что SSHTunnelManager.exe закрыт.
"@
    }
}

# ============================================================
# EMBED FILE
# ============================================================

$embedFiles = @{
    "%TEMP%\SSHTunnelManager\Renci.SshNet.dll" = $SshDll
}

Write-Host ""
Write-Host "Встраиваем SSH.NET в EXE..."
Write-Host ""

# ============================================================
# BUILD
# ============================================================

Invoke-ps2exe `
    -InputFile $Source `
    -OutputFile $Output `
    -NoConsole `
    -embedFiles $embedFiles `
    -Title "SSH Tunnel Manager" `
    -Description "SSH Tunnel Manager" `
    -Product "SSH Tunnel Manager" `
    -Company "SSH Tunnel Manager"

# ============================================================
# CHECK EXE
# ============================================================

if (-not (Test-Path $Output)) {

    throw "EXE не создан."
}

# ============================================================
# REMOVE DLL FROM APPLICATION DIRECTORY
# ============================================================

if (Test-Path $LocalDll) {

    Remove-Item `
        -LiteralPath $LocalDll `
        -Force
}

# ============================================================
# SUCCESS
# ============================================================

Write-Host ""
Write-Host "========================================"
Write-Host " BUILD SUCCESS"
Write-Host "========================================"
Write-Host ""

Write-Host "EXE:"
Write-Host $Output
Write-Host ""

Write-Host "SSH.NET встроен в EXE."
Write-Host ""

Write-Host "plink.exe НЕ нужен."
Write-Host ""

Write-Host "Renci.SshNet.dll рядом с EXE НЕ нужна."
Write-Host ""

Write-Host "Для распространения достаточно:"
Write-Host ""
Write-Host "    SSHTunnelManager.exe"
Write-Host ""

Write-Host "========================================"
Write-Host ""