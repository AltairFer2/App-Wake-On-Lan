<#
.SYNOPSIS
    Compila FreeRDP (cliente RDP) y OpenSSL para Android y copia las
    librerías a android/app/src/main/jniLibs/<abi>.

.DESCRIPTION
    Todo se descarga con versión fija y se verifica (SHA-256 o etiqueta git)
    en -BuildRoot, una carpeta sin espacios: las herramientas nativas fallan
    con rutas como "App Wake On Lan". Pasos:
      1. MSYS2 portátil (perl y make completos para OpenSSL).
      2. OpenSSL compartido (build_openssl_android.sh).
      3. FreeRDP con CMake + Ninja del SDK de Android.
      4. libfreerdp-android.so (capa JNI) con freerdp_android_jni/CMakeLists.txt.
      5. Copia de las .so a jniLibs (FreeRDP es C: no necesita libc++_shared).
    Es incremental: omite los pasos cuyo resultado ya existe salvo -Clean.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tool/native/build_freerdp_android.ps1
#>
param(
    [string]$BuildRoot = 'D:\Desarrollo\lwu-native',
    [ValidateSet('arm64-v8a', 'armeabi-v7a', 'x86_64')][string]$Abi = 'arm64-v8a',
    [int]$ApiLevel = 24,
    [string]$NdkVersion = '28.2.13676358',
    [string]$CmakeVersion = '3.22.1',
    [switch]$Clean
)
$ErrorActionPreference = 'Stop'

# Versiones fijadas. Al actualizarlas, actualizar también el hash.
$OpenSslVersion = 'openssl-3.5.9'
$OpenSslSha256 = '603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a'
$FreeRdpTag = '3.32.2'
$Msys2Release = '2026-09-27'
$Msys2File = 'msys2-base-x86_64-20260927.tar.xz'
$Msys2Sha256 = 'ea2f31a0b6ade63914ce441ffb022f0f6aa96982bfefa2326460a26d5fb01322'

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$downloads = Join-Path $BuildRoot 'downloads'
$buildDir = Join-Path $BuildRoot 'build'
$installDir = Join-Path $BuildRoot "install\$Abi"
$freerdpSource = Join-Path $BuildRoot "src\FreeRDP-$FreeRdpTag"
$msysBash = Join-Path $BuildRoot 'msys64\usr\bin\bash.exe'
$jniLibs = Join-Path $repoRoot "android\app\src\main\jniLibs\$Abi"

if ($BuildRoot -match '\s') { throw "BuildRoot no puede contener espacios: $BuildRoot" }

function Get-ShortPath([string]$Path) {
    # El SDK vive bajo el perfil del usuario, que contiene un espacio.
    (New-Object -ComObject Scripting.FileSystemObject).GetFolder($Path).ShortPath
}

function ConvertTo-MsysPath([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    '/' + $full.Substring(0, 1).ToLower() + $full.Substring(2).Replace('\', '/')
}

function Invoke-Checked([string]$Description, [scriptblock]$Command) {
    Write-Host "==> $Description"
    & $Command
    if ($LASTEXITCODE -ne 0) { throw "$Description falló (código $LASTEXITCODE)." }
}

function Save-VerifiedFile([string]$Url, [string]$Destination, [string]$Sha256) {
    if (-not (Test-Path $Destination)) {
        Write-Host "==> Descargando $Url"
        Invoke-WebRequest $Url -OutFile $Destination -UseBasicParsing
    }
    $actual = (Get-FileHash $Destination -Algorithm SHA256).Hash.ToLower()
    if ($actual -ne $Sha256) {
        Remove-Item $Destination
        throw "SHA-256 inesperado para $(Split-Path $Destination -Leaf): $actual"
    }
}

$sdk = Get-ShortPath (Join-Path $env:LOCALAPPDATA 'Android\Sdk')
$ndk = Join-Path $sdk "ndk\$NdkVersion"
$cmakeBin = Join-Path $sdk "cmake\$CmakeVersion\bin"
foreach ($required in $ndk, $cmakeBin) {
    if (-not (Test-Path $required)) { throw "No existe $required. Instálalo desde el SDK Manager." }
}

if ($Clean) { Remove-Item -Recurse -Force $buildDir, $installDir -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force $downloads, $buildDir, $installDir, $jniLibs | Out-Null

# 1. MSYS2 portátil con perl y make.
if (-not (Test-Path $msysBash)) {
    $archive = Join-Path $downloads $Msys2File
    Save-VerifiedFile "https://github.com/msys2/msys2-installer/releases/download/$Msys2Release/$Msys2File" $archive $Msys2Sha256
    Invoke-Checked 'Extrayendo MSYS2' { tar -xf $archive -C $BuildRoot }
}
$env:MSYSTEM = 'MSYS'
$env:CHERE_INVOKING = '1'
Invoke-Checked 'Preparando perl y make en MSYS2' {
    & $msysBash -lc 'pacman -S --noconfirm --needed perl make >/dev/null'
}

# 2. OpenSSL.
if (-not (Test-Path (Join-Path $installDir 'lib\libssl.so'))) {
    $tarball = Join-Path $downloads "$OpenSslVersion.tar.gz"
    Save-VerifiedFile "https://github.com/openssl/openssl/releases/download/$OpenSslVersion/$OpenSslVersion.tar.gz" $tarball $OpenSslSha256
    $script = ConvertTo-MsysPath (Join-Path $PSScriptRoot 'build_openssl_android.sh')
    $arguments = @($tarball, $buildDir, $ndk, $installDir) | ForEach-Object { ConvertTo-MsysPath $_ }
    $log = Join-Path $buildDir "openssl-$Abi.log"
    Invoke-Checked "Compilando OpenSSL ($Abi, registro en $log)" {
        & $msysBash -lc "bash '$script' '$($arguments[0])' '$($arguments[1])' '$($arguments[2])' $Abi $ApiLevel '$($arguments[3])' > '$(ConvertTo-MsysPath $log)' 2>&1"
    }
}

# 3. FreeRDP.
if (-not (Test-Path $freerdpSource)) {
    Invoke-Checked "Clonando FreeRDP $FreeRdpTag" {
        git -c advice.detachedHead=false clone --quiet --depth 1 --branch $FreeRdpTag `
            https://github.com/FreeRDP/FreeRDP.git $freerdpSource
    }
}
$toolchain = Join-Path $ndk 'build\cmake\android.toolchain.cmake'
$commonArgs = @(
    '-G', 'Ninja',
    "-DCMAKE_MAKE_PROGRAM=$(Join-Path $cmakeBin 'ninja.exe')",
    "-DCMAKE_TOOLCHAIN_FILE=$toolchain",
    "-DANDROID_ABI=$Abi",
    "-DANDROID_PLATFORM=android-$ApiLevel",
    '-DANDROID_STL=c++_shared',
    '-DCMAKE_BUILD_TYPE=Release'
)
if (-not (Test-Path (Join-Path $installDir 'lib\libfreerdp-client3.so'))) {
    $freerdpBuild = Join-Path $buildDir "freerdp-$Abi"
    # Mismas opciones que el superbuild oficial (client/Android/cmake),
    # sin códecs externos: RemoteFX y GFX funcionan sin ellos.
    $freerdpArgs = $commonArgs + @(
        '-S', $freerdpSource, '-B', $freerdpBuild,
        "-DCMAKE_INSTALL_PREFIX=$installDir",
        "-DCMAKE_PREFIX_PATH=$installDir",
        "-DOPENSSL_ROOT_DIR=$installDir",
        '-DBUILD_SHARED_LIBS=ON',
        '-DCMAKE_SHARED_LINKER_FLAGS=-Wl,-z,max-page-size=16384',
        '-DWITHOUT_WINPR_3x_DEPRECATED=ON', '-DWITHOUT_FREERDP_3x_DEPRECATED=ON',
        '-DWITH_CLIENT_SDL=OFF', '-DWITH_SAMPLE=OFF', '-DWITH_SERVER=OFF',
        '-DWITH_MANPAGES=OFF', '-DWITH_SYSTEMD=OFF',
        '-DWITH_INTERNAL_RC4=ON', '-DWITH_INTERNAL_MD4=ON', '-DWITH_INTERNAL_MD5=ON',
        '-DWITH_OPENSSL=ON',
        '-DWITH_MEDIACODEC=OFF', '-DWITH_FFMPEG=OFF', '-DWITH_SWSCALE=OFF',
        '-DWITH_OPENH264=OFF', '-DWITH_VAAPI_H264_ENCODING=OFF',
        '-DWINPR_UTILS_IMAGE_PNG=OFF', '-DWINPR_UTILS_IMAGE_WEBP=OFF', '-DWINPR_UTILS_IMAGE_JPEG=OFF',
        '-DWITH_OPUS=OFF', '-DWITH_JSON_DISABLED=ON', '-DWITH_AAD=OFF',
        '-DWITH_URIPARSER=OFF', '-DWITH_KRB5=OFF', '-DWITH_FUSE=OFF', '-DWITH_PKCS11=OFF',
        '-DWITH_OPENSLES=OFF', '-DWITH_AAUDIO=OFF',
        '-DCHANNEL_PRINTER_CLIENT=OFF', '-DCHANNEL_RDPECAM_CLIENT=OFF',
        '-DWITH_VERBOSE_WINPR_ASSERT=OFF'
    )
    Invoke-Checked 'Configurando FreeRDP' { & (Join-Path $cmakeBin 'cmake.exe') @freerdpArgs }
    Invoke-Checked 'Compilando FreeRDP' { & (Join-Path $cmakeBin 'cmake.exe') --build $freerdpBuild }
    Invoke-Checked 'Instalando FreeRDP' { & (Join-Path $cmakeBin 'cmake.exe') --install $freerdpBuild }
}

# 4. Capa JNI.
$jniBuild = Join-Path $buildDir "freerdp-android-jni-$Abi"
$jniArgs = $commonArgs + @(
    '-S', (Join-Path $PSScriptRoot 'freerdp_android_jni'), '-B', $jniBuild,
    "-DFREERDP_SOURCE_DIR=$freerdpSource",
    "-DFREERDP_INSTALL_DIR=$installDir"
)
Invoke-Checked 'Configurando la capa JNI' { & (Join-Path $cmakeBin 'cmake.exe') @jniArgs }
Invoke-Checked 'Compilando la capa JNI' { & (Join-Path $cmakeBin 'cmake.exe') --build $jniBuild }

# 5. Copia a jniLibs.
$libraries = @(
    (Join-Path $jniBuild 'libfreerdp-android.so'),
    (Join-Path $installDir 'lib\libfreerdp-client3.so'),
    (Join-Path $installDir 'lib\libfreerdp3.so'),
    (Join-Path $installDir 'lib\libwinpr3.so'),
    (Join-Path $installDir 'lib\libssl.so'),
    (Join-Path $installDir 'lib\libcrypto.so')
)
Get-ChildItem $jniLibs -Filter '*.so' | Remove-Item
foreach ($library in $libraries) { Copy-Item $library $jniLibs }
Write-Host "==> Librerías copiadas a $jniLibs"
Get-ChildItem $jniLibs | ForEach-Object { '{0,-28} {1,8:N0} KB' -f $_.Name, ($_.Length / 1KB) }
