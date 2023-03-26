#!/usr/bin/env bash

set -euo pipefail

function print_usage() {
  echo "Usage: sudo bash < <(curl -sSL http://get.infini.sh) -p program_name -v version -d install_dir"
  echo "Options:"
  echo "  -p, --program-name <name>   Name of the program to install"
  echo "  -v, --version <version>     Version of the program to install"
  echo "  -d, --install-dir <dir>     Directory to install the program"
  exit 1
}

function check_dir() {
  if [[ ! -d "$install_dir" ]]; then
    mkdir -p "$install_dir"
  else
    echo "Error: Install dir should clean, please delete folder $install_dir." >&2; exit 1;
  fi
}

function check_root() {
  [[ $(id -u) == "0" ]] || { echo "Error: This script must be run as root or sudo." >&2; exit 1; }
}

check_platform() {
    local platform=$(uname)
    local arch=$(uname -m)

    case $platform in
        "Linux")
            case $arch in
                "i386"|"i686"|"x86")
                    file_ext="linux-386.tar.gz"
                    ;;
                "x86_64"|"amd64")
                    file_ext="linux-amd64.tar.gz"
                    ;;
                "aarch64"|"arm64")
                    file_ext="linux-arm64.tar.gz"
                    ;;
                "armv5tel")
                    file_ext="linux-arm5.tar.gz"
                    ;;
                "armv6l")
                    file_ext="linux-arm6.tar.gz"
                    ;;
                "armv7"|"armv7l")
                    file_ext="linux-arm7.tar.gz"
                    ;;
                "mips"|"mipsel")
                    file_ext="linux-mips.tar.gz"
                    ;;
                "mips64")
                    file_ext="linux-mips64.tar.gz"
                    ;;
                "mips64el")
                    file_ext="linux-mips64le.tar.gz"
                    ;;
                *)
                    echo "Unsupported architecture: $arch" >&2
                    exit 1
                    ;;
            esac
            ;;
        "Darwin")
            case $arch in
                "x86_64"|"amd64")
                    file_ext="mac-amd64.zip"
                    ;;
                "arm64")
                    file_ext="mac-arm64.zip"
                    ;;
                *)
                    echo "Unsupported architecture: $arch" >&2
                    exit 1
                    ;;
            esac
            ;;
        "MINGW"*|"WSL"*|"Cygwin")
            case $arch in
                "i386"|"i686")
                    file_ext="windows-386.zip"
                    ;;
                "x86_64"|"amd64")
                    file_ext="windows-amd64.zip"
                    ;;
                *)
                    echo "Unsupported architecture: $arch" >&2
                    exit 1
                    ;;
            esac
            ;;
        *)
            echo "Unsupported platform: $platform" >&2
            exit 1
            ;;
    esac
}

function install_binary() {
  local download_url="https://dl-global.infinilabs.com/${program_name}/stable/${program_name}-${version}-${file_ext}"

  tmp_dir="$(mktemp -d)"
  cd "$tmp_dir"
  if command -v curl >/dev/null 2>&1; then
    curl -# -O "$download_url" 2>&1
  elif command -v wget >/dev/null 2>&1; then
    wget -q --show-progress --progress=bar:force "$download_url" 2>&1
  else
    echo "Could not find curl or wget. Cannot download program." >&2
    exit 1
  fi
  if [[ "$file_ext" == *".tar.gz" ]]; then
      tar -C "$install_dir" -xzf "${program_name}-${version}-${file_ext}" > /dev/null 2>&1
  else
      unzip "${program_name}-${version}-${file_ext}" -d "$install_dir" > /dev/null 2>&1
  fi
  
  rm -rf "$tmp_dir"
}

function main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -p|--program-name) program_name="$2"; shift 2 ;;
      -v|--version) version="$2"; shift 2 ;;
      -d|--install-dir) install_dir="$2"; shift 2 ;;
      *) print_usage ;;
    esac
  done

  program_name=${program_name:-console}
  install_dir=${install_dir:-/opt/$program_name}
  version=${version:-0.8.1-959}
  file_ext=""

  check_dir

  check_root

  check_platform

  install_binary

  echo "Install success,You can run ${program_name} by cd ${install_dir} && sudo `ls ${install_dir}/${program_name}-*`."

}

main "$@"
