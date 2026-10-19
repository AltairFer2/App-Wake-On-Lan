#!/usr/bin/env bash
# Compila OpenSSL como librerías compartidas para Android (una ABI).
# Se ejecuta dentro de MSYS2 (perl y make completos); lo invoca
# build_freerdp_android.ps1.
#
# Uso: build_openssl_android.sh <tarball> <dir-trabajo> <ndk> <abi> <api> <prefijo>
set -euo pipefail

tarball=$1 work_dir=$2 ndk=$3 abi=$4 api=$5 prefix=$6

case "$abi" in
  arm64-v8a) target=android-arm64 ;;
  armeabi-v7a) target=android-arm ;;
  x86_64) target=android-x86_64 ;;
  *) echo "ABI no soportada: $abi" >&2; exit 1 ;;
esac

source_dir="$work_dir/$(basename "$tarball" .tar.gz)-$abi"
rm -rf "$source_dir"
mkdir -p "$source_dir"
tar -xzf "$tarball" -C "$source_dir" --strip-components=1
cd "$source_dir"

export ANDROID_NDK_ROOT="$ndk"
export PATH="$ndk/toolchains/llvm/prebuilt/windows-x86_64/bin:$PATH"

perl Configure "$target" shared no-tests no-apps no-docs \
  -U__ANDROID_API__ "-D__ANDROID_API__=$api" \
  "--prefix=$prefix" --libdir=lib

# SHLIB_EXT=.so: Android solo empaqueta librerías sin sufijo de versión
# (libssl.so en lugar de libssl.so.3).
make -j"$(nproc)" SHLIB_EXT=.so build_libs
make SHLIB_EXT=.so install_sw
