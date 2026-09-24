# ==============================================================================
# WebCadroid Release Build Automation Script (PowerShell)
# Builds WebCadroid (WPF / .NET 10 desktop) and WebCadroidClient (Flutter / Android)
# ==============================================================================

[CmdletBinding()]
param(
    [switch]$All = $false,
    [switch]$Pc = $false,
    [switch]$Desktop = $false,
    [switch]$Client = $false,
    [switch]$Apk = $false,
    [switch]$Bundle = $false,
    [switch]$Clean = $false,
    [switch]$SkipTests = $false,
    [switch]$Help = $false
)

$ErrorActionPreference = "Stop"

if ($Help) {
    Write-Host @"
Usage: .\build.ps1 [OPTIONS]

Options:
  -All            Build both desktop and Android apps (default)
  -Pc, -Desktop   Build only the desktop app (WebCadroid WPF / .NET)
  -Client, -Apk   Build only the Android app (WebCadroidClient Flutter APK)
  -Bundle         Also build Android App Bundle (.aab)
  -Clean          Clean previous build artifacts before building
  -SkipTests      Skip running unit tests and linters before building
  -Help           Show this help message
"@
    exit 0
}

# Determine what to build
$BuildPc = $true
$BuildClient = $true

if ($Pc -or $Desktop) {
    $BuildPc = $true
    $BuildClient = $false
}
elseif ($Client -or $Apk) {
    $BuildPc = $false
    $BuildClient = $true
}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$SrcDir = Join-Path $ScriptDir "src"
$DistDir = Join-Path $ScriptDir "dist"
$PcProject = Join-Path $SrcDir "WebCadroid\WebCadroid.csproj"
$ClientDir = Join-Path $SrcDir "WebCadroidClient"

Write-Host "====================================================" -ForegroundColor Cyan
Write-Host "           WebCadroid Release Build Tool            " -ForegroundColor Cyan
Write-Host "====================================================" -ForegroundColor Cyan

# 1. Check prerequisites
Write-Host "`n--> Checking prerequisites..." -ForegroundColor Cyan

if ($BuildPc) {
    if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
        Write-Error ".NET SDK (dotnet) is not installed or not in PATH."
    }
    $dotnetVer = dotnet --version
    Write-Host "  [x] .NET SDK: $dotnetVer" -ForegroundColor Green
}

if ($BuildClient) {
    if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
        Write-Error "Flutter SDK (flutter) is not installed or not in PATH."
    }
    $flutterVer = (flutter --version | Select-Object -First 1)
    Write-Host "  [x] Flutter SDK: $flutterVer" -ForegroundColor Green
}

# 2. Clean if requested
if ($Clean) {
    Write-Host "`n--> Cleaning build directories..." -ForegroundColor Yellow
    if ($BuildPc) {
        dotnet clean $PcProject -c Release | Out-Null
        $pcDist = Join-Path $DistDir "WebCadroid"
        if (Test-Path $pcDist) { Remove-Item $pcDist -Recurse -Force }
    }
    if ($BuildClient) {
        Push-Location $ClientDir
        try { flutter clean | Out-Null } finally { Pop-Location }
        $clientDist = Join-Path $DistDir "WebCadroidClient"
        if (Test-Path $clientDist) { Remove-Item $clientDist -Recurse -Force }
    }
    Write-Host "  Clean completed." -ForegroundColor Green
}

# 3. Tests & Linters
if (-not $SkipTests) {
    Write-Host "`n--> Running tests & code analysis..." -ForegroundColor Cyan
    if ($BuildClient) {
        Write-Host "  * Analyzing Flutter client..."
        Push-Location $ClientDir
        try {
            flutter analyze
            if ($LASTEXITCODE -ne 0) { throw "flutter analyze failed" }
            Write-Host "  * Running Flutter unit/widget tests..."
            flutter test
            if ($LASTEXITCODE -ne 0) { throw "flutter test failed" }
        } finally {
            Pop-Location
        }
    }
    if ($BuildPc) {
        Write-Host "  * Verifying .NET desktop build..."
        dotnet build $PcProject -c Release --no-incremental | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "dotnet build failed" }
    }
    Write-Host "  All checks passed successfully." -ForegroundColor Green
}

# 4. Build Desktop
if ($BuildPc) {
    Write-Host "`n====================================================" -ForegroundColor Cyan
    Write-Host "  Building WebCadroid (Windows Desktop .NET Release) " -ForegroundColor Cyan
    Write-Host "====================================================" -ForegroundColor Cyan

    $pcDist = Join-Path $DistDir "WebCadroid"
    New-Item -ItemType Directory -Path $pcDist -Force | Out-Null

    dotnet publish $PcProject -c Release -r win-x64 --self-contained true -o $pcDist
    if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed" }

    Write-Host "Desktop build completed successfully!" -ForegroundColor Green
}

# 5. Build Android Client
if ($BuildClient) {
    Write-Host "`n====================================================" -ForegroundColor Cyan
    Write-Host "  Building WebCadroidClient (Flutter Android Release)" -ForegroundColor Cyan
    Write-Host "====================================================" -ForegroundColor Cyan

    $clientDist = Join-Path $DistDir "WebCadroidClient"
    New-Item -ItemType Directory -Path $clientDist -Force | Out-Null

    Push-Location $ClientDir
    try {
        Write-Host "  * Fetching Flutter dependencies..."
        flutter pub get

        Write-Host "  * Compiling release APK..."
        flutter build apk --release
        if ($LASTEXITCODE -ne 0) { throw "flutter build apk failed" }

        $apkSrc = Join-Path $ClientDir "build\app\outputs\flutter-apk\app-release.apk"
        if (Test-Path $apkSrc) {
            $destApk = Join-Path $clientDist "WebCadroidClient.apk"
            Copy-Item $apkSrc $destApk -Force
        }

        if ($Bundle) {
            Write-Host "  * Compiling release App Bundle (.aab)..."
            flutter build appbundle --release
            if ($LASTEXITCODE -ne 0) { throw "flutter build appbundle failed" }

            $aabSrc = Join-Path $ClientDir "build\app\outputs\bundle\release\app-release.aab"
            if (Test-Path $aabSrc) {
                $destAab = Join-Path $clientDist "WebCadroidClient.aab"
                Copy-Item $aabSrc $destAab -Force
            }
        }
    } finally {
        Pop-Location
    }

    Write-Host "Android client build completed successfully!" -ForegroundColor Green
}

# 6. Summary
Write-Host "`n====================================================" -ForegroundColor Green
Write-Host "             BUILD FINISHED SUCCESSFULLY!           " -ForegroundColor Green
Write-Host "====================================================" -ForegroundColor Green
Write-Host "Artifacts available in: $DistDir`n"

if ($BuildPc) {
    $exePath = Join-Path $DistDir "WebCadroid\WebCadroid.exe"
    if (Test-Path $exePath) {
        $exeSizeMb = [math]::Round((Get-Item $exePath).Length / 1MB, 2)
        Write-Host "Desktop Artifacts:" -ForegroundColor Cyan
        Write-Host "  * $exePath ($exeSizeMb MB)"
        Write-Host "  * $(Join-Path $DistDir 'WebCadroid\Utils\') (Native drivers & tools)"
    }
}

if ($BuildClient) {
    $apkPath = Join-Path $DistDir "WebCadroidClient\WebCadroidClient.apk"
    if (Test-Path $apkPath) {
        $apkSizeMb = [math]::Round((Get-Item $apkPath).Length / 1MB, 2)
        Write-Host "`nAndroid Artifacts:" -ForegroundColor Cyan
        Write-Host "  * $apkPath ($apkSizeMb MB)"
    }
}
Write-Host ""
