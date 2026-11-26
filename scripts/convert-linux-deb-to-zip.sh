#!/bin/sh

# SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
#
# SPDX-License-Identifier: AGPL-3.0-or-later

set -eu

usage() {
  cat <<'EOF'
Usage: sh convert-linux-deb-to-zip.sh [--help]

Place this script in the same directory as either or both of these files:
  fluffychat-linux-x64.deb
  fluffychat-linux-arm64.deb

Run the script from any directory to create a matching ZIP for each package.
Each ZIP contains the application bundle and is saved beside its Debian package.
Requires: ar, tar with xz support, xz, zip, and mktemp.
No root privileges or package installation are required.
EOF
}

if [ "$#" -eq 1 ]; then
  case "$1" in
    -h|--help) usage; exit 0 ;;
  esac
fi

if [ "$#" -gt 0 ]; then
  usage >&2
  exit 1
fi

case "$0" in
  /*) script_path=$0 ;;
  *) script_path=$PWD/$0 ;;
esac
script_dir=$(CDPATH= cd -P "$(dirname "$script_path")" && pwd)
set -- "$script_dir/fluffychat-linux-x64.deb" "$script_dir/fluffychat-linux-arm64.deb"

if [ ! -f "$1" ] && [ ! -f "$2" ]; then
  printf 'No supported Debian packages were found beside this script.\n' >&2
  usage >&2
  exit 1
fi

for tool in ar tar xz zip mktemp; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'Required command not found: %s\n' "$tool" >&2
    exit 1
  fi
done

work_dir=$(mktemp -d "$script_dir/.fluffychat-deb-to-zip.XXXXXX")
trap 'rm -rf "$work_dir"' 0
trap 'exit 1' HUP INT TERM
status=0

for package do
  [ -f "$package" ] || continue
  package_name=${package##*/}
  destination=${package%.deb}.zip
  package_work_dir=$work_dir/${package_name%.deb}
  printf 'Converting %s...\n' "$package_name"

  if ! (
    mkdir -p "$package_work_dir/unpacked" || exit 1
    ar p "$package" data.tar.xz > "$package_work_dir/data.tar.xz" || exit 1
    tar -xJf "$package_work_dir/data.tar.xz" -C "$package_work_dir/unpacked" || exit 1
    bundle_dir=$package_work_dir/unpacked/usr/lib/fluffychat
    if [ ! -f "$bundle_dir/fluffychat" ]; then
      printf 'Application bundle not found in %s.\n' "$package_name" >&2
      exit 1
    fi
    cd "$bundle_dir" || exit 1
    zip -q -r -y "$package_work_dir/bundle.zip" . || exit 1
    mv -f "$package_work_dir/bundle.zip" "$destination" || exit 1
  ); then
    printf 'Failed to convert %s.\n' "$package_name" >&2
    status=1
    continue
  fi

  printf 'Created %s\n' "$destination"
done

exit "$status"
