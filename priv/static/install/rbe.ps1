$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Fail([string]$Message) {
  throw "rbe installer: $Message"
}

$Repository = "laibulle/robine-ci"
$ApiUrl = "https://api.github.com/repos/$Repository/releases/latest"
$InstallDir = if ($env:RBE_INSTALL_DIR) { $env:RBE_INSTALL_DIR } else { Join-Path $HOME ".local\bin" }
$ConfigPath = if ($env:RBE_CONFIG_PATH) { $env:RBE_CONFIG_PATH } else { "" }
$ServerUrl = if ($env:RBE_SERVER_URL) { $env:RBE_SERVER_URL } else { "" }

if (-not [System.IO.Path]::IsPathFullyQualified($InstallDir)) {
  Fail "RBE_INSTALL_DIR must be an absolute path"
}
if ($ConfigPath -and -not [System.IO.Path]::IsPathFullyQualified($ConfigPath)) {
  Fail "RBE_CONFIG_PATH must be an absolute path"
}
if (-not (Get-Command tar.exe -ErrorAction SilentlyContinue)) {
  Fail "tar.exe is required"
}

$Architecture = switch ($env:PROCESSOR_ARCHITECTURE.ToUpperInvariant()) {
  "ARM64" { "arm64" }
  "AMD64" { "amd64" }
  default { Fail "unsupported Windows architecture: $env:PROCESSOR_ARCHITECTURE" }
}

$AssetName = "robine-runner-windows-multiarch.tar.gz"
$Headers = @{
  Accept = "application/vnd.github+json"
  "X-GitHub-Api-Version" = "2022-11-28"
}
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$TemporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("rbe-install-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $TemporaryRoot -Force | Out-Null

try {
  $Release = Invoke-RestMethod -Uri $ApiUrl -Headers $Headers -Method Get
  $Tag = [string]$Release.tag_name
  if ($Tag -notmatch '^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z][0-9A-Za-z.-]*)?$') {
    Fail "GitHub returned an invalid latest release tag"
  }

  $Asset = @($Release.assets | Where-Object { $_.name -eq $AssetName })
  if ($Asset.Count -ne 1) {
    Fail "the latest GitHub release does not contain exactly one $AssetName"
  }
  $Digest = [string]$Asset[0].digest
  if ($Digest -notmatch '^sha256:[0-9a-f]{64}$') {
    Fail "the latest GitHub release does not publish a valid SHA-256 digest for $AssetName"
  }

  $ArchivePath = Join-Path $TemporaryRoot $AssetName
  Write-Host "Downloading rbe $($Tag.Substring(1)) for Windows $Architecture..."
  Invoke-WebRequest -Uri ([string]$Asset[0].browser_download_url) -Headers $Headers -OutFile $ArchivePath

  $ActualDigest = (Get-FileHash -Algorithm SHA256 -Path $ArchivePath).Hash.ToLowerInvariant()
  if ($ActualDigest -ne $Digest.Substring(7)) {
    Fail "SHA-256 verification failed"
  }

  $Version = $Tag.Substring(1)
  $RelativeBinary = "dist/runner-go/windows/robine-runner-$Version-windows-$Architecture.exe"
  & tar.exe -xzf $ArchivePath -C $TemporaryRoot -- $RelativeBinary
  if ($LASTEXITCODE -ne 0) {
    Fail "the release archive does not contain the expected Windows $Architecture binary"
  }

  $SourceBinary = Join-Path $TemporaryRoot ($RelativeBinary -replace '/', [System.IO.Path]::DirectorySeparatorChar)
  if (-not (Test-Path -LiteralPath $SourceBinary -PathType Leaf)) {
    Fail "the extracted runner is not a regular file"
  }
  $ReleasedVersion = (& $SourceBinary version | Out-String).Trim()
  if ($ReleasedVersion -ne "robine-runner $Version") {
    Fail "the downloaded runner reported an unexpected version"
  }

  New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
  $Destination = Join-Path $InstallDir "rbe.exe"
  $TemporaryDestination = Join-Path $InstallDir (".rbe-install-" + [Guid]::NewGuid().ToString("N") + ".exe")
  Copy-Item -LiteralPath $SourceBinary -Destination $TemporaryDestination
  Move-Item -LiteralPath $TemporaryDestination -Destination $Destination -Force

  $InstalledVersion = (& $Destination version | Out-String).Trim()
  Write-Host "Installed $InstalledVersion at $Destination"

  $DefaultConfigPath = Join-Path $HOME ".config\robine-runner\config.json"
  $EffectiveConfig = if ($ConfigPath) { $ConfigPath } elseif (Test-Path -LiteralPath $DefaultConfigPath) { $DefaultConfigPath } else { "" }
  if ($EffectiveConfig) {
    Write-Host "Windows service installation is not available yet. Start the enrolled runner explicitly:"
    Write-Host "  & '$Destination' start --config '$EffectiveConfig'"
  } else {
    Write-Host "No runner config exists yet. Use the one-time enrollment command from Administration > Runners, then start it explicitly:"
    Write-Host "  & '$Destination' start --config '$DefaultConfigPath'"
  }

  if ($env:PATH.Split(';') -notcontains $InstallDir) {
    Write-Host "Add $InstallDir to your user PATH."
  }
} finally {
  if (Test-Path -LiteralPath $TemporaryRoot) {
    Remove-Item -LiteralPath $TemporaryRoot -Recurse -Force
  }
}
