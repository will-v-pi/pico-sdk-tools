# Heavily trimmed down from pico-setup-windows build.ps1

[CmdletBinding()]
param (
  [Parameter(Mandatory = $true,
    Position = 0,
    HelpMessage = "Path to a JSON installer configuration file.")]
  [Alias("PSPath")]
  [ValidateNotNullOrEmpty()]
  [string]
  $ConfigFile,

  [Parameter(HelpMessage = "Path to MSYS2 installation. MSYS2 will be downloaded and installed to this path if it doesn't exist.")]
  [ValidatePattern('[\\\/]msys64$')]
  [string]
  $MSYS2Path = '.\build\msys64',

  [switch]
  $SkipDownload,

  [switch]
  $SkipSigning,

  [ValidateSet('zlib', 'bzip2', 'lzma')]
  [string]
  $Compression = 'lzma',

  [ValidateSet('system', 'user')]
  [string]
  $BuildType = 'system'
)

#Requires -Version 7.2

function crawl {
    param ([string]$url)

    (Invoke-WebRequest $url -UseBasicParsing).Links |
    Where-Object {
        ($_ | Get-Member href) -and
        [uri]::IsWellFormedUriString($_.href, [System.UriKind]::RelativeOrAbsolute)
    } |
    ForEach-Object {
        $href = [System.Net.WebUtility]::HtmlDecode($_.href)

        try {
        (New-Object System.Uri([uri]$url, $href)).AbsoluteUri
        }
        catch {
            $href
        }
    }
}
    
function mkdirp {
    param ([string] $dir, [switch] $clean)

    New-Item -Path $dir -Type Directory -Force | Out-Null

    if ($clean) {
    Remove-Item -Path "$dir\*" -Recurse -Force
    }
}
    
function exec {
    param ([scriptblock]$private:cmd)
    
    $global:LASTEXITCODE = 0
    
    & $cmd
    
    if ($LASTEXITCODE -ne 0) {
        throw "Command '$cmd' exited with code $LASTEXITCODE"
    }
}
  

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

Write-Host "Building from $ConfigFile"

$version = (Get-Content "$PSScriptRoot\version.txt").Trim()
$suffix = [io.path]::GetFileNameWithoutExtension($ConfigFile) + ($BuildType -eq 'user' ? '-user' : '' )

$tools = (Get-Content '.\config\tools.json' | ConvertFrom-Json).tools
$repositories = (Get-Content '.\config\repositories.json' | ConvertFrom-Json).repositories
$config = Get-Content $ConfigFile | ConvertFrom-Json
$bitness = $config.bitness
$mingw_arch = $config.mingwArch
$downloads = $config.downloads

mkdirp "build"
mkdirp "bin"

($downloads + $tools) | ForEach-Object {
  $_ | Add-Member -NotePropertyName 'shortName' -NotePropertyValue ($_.name -replace '[^a-zA-Z0-9]', '')
  $outfile = "downloads/$($_.file)"

  if ($SkipDownload) {
    Write-Host "Checking $($_.name): " -NoNewline
    if (-not (Test-Path $outfile)) {
      Write-Error "$outfile not found"
    }
  }
  else {
    Write-Host "Downloading $($_.name): " -NoNewline
    exec { curl.exe --fail --silent --show-error --url "$($_.href)" --location --output "$outfile" --create-dirs --remote-time --time-cond "downloads/$($_.file)" }
  }

  # Display versions of packaged installers, for information only. We try to
  # extract it from:
  # 1. The file name
  # 2. The download URL
  # 3. The version metadata in the file
  #
  # This fails for MSYS2, because there is no version number (only a timestamp)
  # and the version that gets reported is 7-zip SFX version.
  $fileVersion = ''
  $versionRegEx = '([0-9]+\.)+[0-9]+'
  if ($_.file -match $versionRegEx -or $_.href -match $versionRegEx) {
    $fileVersion = $Matches[0]
  } else {
    $fileVersion = (Get-ChildItem $outfile).VersionInfo.ProductVersion
  }

  if ($fileVersion) {
    Write-Host $fileVersion
  } else {
    Write-Host $_.file
  }

  if ($_ | Get-Member dirName) {
    $strip = 0;
    if ($_ | Get-Member extractStrip) { $strip = $_.extractStrip }

    mkdirp "build\$($_.dirName)" -clean
    exec { tar -xf $outfile -C "build\$($_.dirName)" --strip-components $strip }
  }
}

if (-not (Get-Command cmake -ErrorAction SilentlyContinue)) {
  $env:PATH = $env:PATH + ';' + (Resolve-Path .\build\cmake\bin).Path
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
  $env:PATH = $env:PATH + ';' + (Resolve-Path .\build\git\cmd).Path
}

$repositories | ForEach-Object {
  $repodir = Join-Path 'build' ([IO.Path]::GetFileNameWithoutExtension($_.href))

  if ($SkipDownload) {
    Write-Host "Checking ${repodir}: " -NoNewline
    if (-not (Test-Path $repodir)) {
      Write-Error "$repodir not found"
    }
    exec { git -C "$repodir" describe --all }
  }
  else {
    if (Test-Path $repodir) {
      Remove-Item $repodir -Recurse -Force
    }

    exec { git clone -b "$($_.tree)" --depth=1 -c advice.detachedHead=false "$($_.href)" "$repodir" }

    if ($_ | Get-Member submodules) {
      exec { git -C "$repodir" submodule update --init --depth=1 }
    }
  }
}

$sdkVersion = (cmake -P .\packages\pico-setup-windows\pico-sdk-version.cmake -N | Select-String -Pattern 'PICO_SDK_VERSION_STRING=(.*)$').Matches.Groups[1].Value
if (-not ($sdkVersion -match $versionRegEx)) {
  Write-Error 'Could not determine Pico SDK version.'
}

if (-not (Test-Path $MSYS2Path)) {
  Write-Host 'Extracting MSYS2'
  exec { & .\downloads\msys2.exe -y "-o$(Resolve-Path (Split-Path $MSYS2Path -Parent))" }
}

function sign {
  param ([string[]] $filesToSign)

  if ($SkipSigning) {
    Write-Warning "Skipping code signing."
  } else {
    $cert = Get-ChildItem -Path Cert:\CurrentUser\My -CodeSigningCert | Where-Object { $_.Subject -like "CN=Raspberry Pi*" }
    if (-not $cert) {
      Write-Error "No suitable code signing certificates found."
    }

    $filesToSign | Set-AuthenticodeSignature -Certificate $cert -TimestampServer "http://timestamp.digicert.com" -HashAlgorithm SHA256 | Tee-Object -Variable signatures
    $signatures | ForEach-Object {
      if ($_.Status -ne 0) {
        Write-Error "Error signing $($_.Path)"
      }
    }
  }
}

function msys {
  param ([string] $cmd)

  exec { & "$MSYS2Path\usr\bin\bash" -leo pipefail -c "$cmd" }
}

# Preserve the current working directory
$env:CHERE_INVOKING = 'yes'
# Start MINGW32/64 environment
$env:MSYSTEM = "MINGW$bitness"

if (-not $SkipDownload) {
  # First run setup
  msys 'uname -a'
  # Core update
  msys 'pacman --noconfirm -Syuu'
  # Normal update
  msys 'pacman --noconfirm -Suu'

  msys "pacman -S --noconfirm --needed autoconf automake git libtool make pactoys pkg-config wget"
  # pacboy adds MINGW_PACKAGE_PREFIX to package names suffixed with :p
  msys "pacboy -S --noconfirm --needed cmake:p ninja:p toolchain:p libusb:p hidapi:p"
}

if (-not (Test-Path ".\build\openocd-install\mingw$bitness")) {
  msys "cd build && ../packages/openocd/build-openocd.sh $bitness $mingw_arch"
}

if (-not (Test-Path ".\build\picotool-install\mingw$bitness")) {
  msys "cd build && ../packages/picotool/build-picotool.sh $bitness $mingw_arch"
}

$template = Get-Content ".\packages\pico-sdk-tools\pico-sdk-tools-config-version.cmake" -Raw
$ExecutionContext.InvokeCommand.ExpandString($template) | Set-Content ".\build\pico-sdk-tools\mingw$bitness\pico-sdk-tools-config-version.cmake"

# Sign files before packaging up the installer
sign "build\openocd-install\mingw$bitness\bin\openocd.exe",
"build\pico-sdk-tools\mingw$bitness\elf2uf2.exe",
"build\pico-sdk-tools\mingw$bitness\pioasm.exe",
"build\picotool-install\mingw$bitness\picotool.exe"

# Package pico-sdk-tools separately as well

$filename = 'pico-sdk-tools-{0}-{1}.zip' -f
  $version,
  $suffix

Write-Host "Saving pico-sdk-tools package to $filename"
exec { tar -a -cf "bin\$filename" -C "build\pico-sdk-tools\mingw$bitness\" * }

# Package picotool separately as well

$version = (cmd /c ".\build\picotool-install\mingw$bitness\picotool.exe" version '2>&1')
Write-Host "Picotool version $version"
if (-not ($version -match 'picotool v(?<version>[0-9\.\-+]+) \(.*\)$')) {
  Write-Error 'Could not determine picotool version'
}

$filename = 'picotool-{0}-{1}.zip' -f
  $Matches.version,
  $suffix

Write-Host "Saving pico-sdk-tools package to $filename"
exec { tar -a -cf "bin\$filename" -C "build\picotool-install\mingw$bitness\" * }

# Package OpenOCD separately as well

$version = (cmd /c ".\build\openocd-install\mingw$bitness\bin\openocd.exe" --version '2>&1')[0]
if (-not ($version -match 'Open On-Chip Debugger (?<version>[a-zA-Z0-9\.\-+]+) \((?<timestamp>[0-9\-:]+)\)')) {
  Write-Error 'Could not determine openocd version'
}

$filename = 'openocd-{0}-{1}.zip' -f
  ($Matches.version -replace '-.*$', ''),
  $suffix

Write-Host "Saving OpenOCD package to $filename"
exec { tar -a -cf "bin\$filename" -C "build\openocd-install\mingw$bitness\bin" * -C "..\share\openocd" "scripts" }
