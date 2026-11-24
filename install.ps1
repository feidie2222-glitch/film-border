param(
    [Parameter(Mandatory = $true)][string]$InstallDir,
    [Parameter(Mandatory = $true)][string]$SourceApp,
    [string]$Archive = ''
)

$ErrorActionPreference = 'Stop'
$expectedHash = '9F45EFD117012F47B59E34F1EE3EE6E9EB2FFD5D1FACBFD5D40F2195EA219E30'
$downloadUrl = 'https://github.com/JamesQiu2005/SpektraLab/releases/download/spektralab-windows-v2.0.0-alpha.1/SpektraLab-2.0.0-alpha.1-windows-x64-portable.zip'
$tempRoot = $null

try {
    $arch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    if ($arch -ne 'AMD64') { throw '此版本需要 Windows x64（Intel 或 AMD 64 位）系统。' }
    if (-not (Test-Path -LiteralPath $InstallDir -PathType Container)) { throw '安装目录不存在，请重新运行安装程序。' }
    if (-not (Test-Path -LiteralPath $SourceApp -PathType Container)) { throw '安装程序找不到应用文件。' }
    $installPath = (Resolve-Path -LiteralPath $InstallDir).Path
    $sourcePath = (Resolve-Path -LiteralPath $SourceApp).Path.TrimEnd('\')
    $runtimePath = Join-Path $installPath 'runtime'
    $appPath = Join-Path $installPath 'app'
    if (Test-Path -LiteralPath $runtimePath) { throw "安装目录中的 runtime 已存在，为保护现有文件，安装已停止：$runtimePath" }
    if (Test-Path -LiteralPath $appPath) {
        $existingApp = (Resolve-Path -LiteralPath $appPath).Path.TrimEnd('\')
        if (-not [string]::Equals($sourcePath, $existingApp, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "安装目录中的 app 已存在，为保护现有文件，安装已停止：$appPath"
        }
    }
    foreach ($name in @('index.html', 'server.js')) {
        if (-not (Test-Path -LiteralPath (Join-Path $sourcePath $name) -PathType Leaf)) { throw "安装程序缺少应用文件：$name" }
    }

    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('film-border-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempRoot | Out-Null
    $archivePath = ''
    if ($Archive -and (Test-Path -LiteralPath $Archive -PathType Leaf)) {
        $archivePath = (Resolve-Path -LiteralPath $Archive).Path
        Write-Host '正在使用本地的官方引擎压缩包...'
    } else {
        $archivePath = Join-Path $tempRoot 'portable.zip'
        Write-Host '正在从 GitHub 下载官方 Windows 引擎（约 60 MB），请稍候...'
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $downloadUrl -OutFile $archivePath -UseBasicParsing
    }
    Write-Host '正在校验文件完整性...'
    $actualHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash
    if (-not [string]::Equals($actualHash, $expectedHash, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw '官方引擎压缩包的 SHA-256 校验失败，请检查文件或重新下载。'
    }
    $extractPath = Join-Path $tempRoot 'expanded'
    Write-Host '正在解压官方引擎...'
    Expand-Archive -LiteralPath $archivePath -DestinationPath $extractPath
    $hosts = @(Get-ChildItem -LiteralPath $extractPath -Filter 'spektralab-host.exe' -File -Recurse)
    $validRoots = @($hosts | Where-Object {
        (Test-Path -LiteralPath (Join-Path $_.DirectoryName 'agents\node.exe') -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $_.DirectoryName 'host\engine\spektrafilm_constants.bin') -PathType Leaf)
    })
    if ($validRoots.Count -ne 1) { throw '官方压缩包缺少所需引擎文件，或包含多个引擎目录。' }
    Write-Host '正在安装引擎与应用文件...'
    Move-Item -LiteralPath $validRoots[0].DirectoryName -Destination $runtimePath
    if (-not (Test-Path -LiteralPath $appPath)) {
        Copy-Item -LiteralPath $sourcePath -Destination $appPath -Recurse
    }
    Write-Host '引擎安装完成。'
    exit 0
} catch {
    Write-Host ("安装失败：" + $_.Exception.Message) -ForegroundColor Red
    exit 1
} finally {
    if ($tempRoot -and (Test-Path -LiteralPath $tempRoot -PathType Container)) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
