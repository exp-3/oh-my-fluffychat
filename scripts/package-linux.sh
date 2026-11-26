#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 The Oh-My-FluffyChat Project
#
# SPDX-License-Identifier: AGPL-3.0-or-later

set -euo pipefail

if [[ "$#" -ne 1 ]]; then
  printf 'Usage: bash scripts/package-linux.sh <x64|arm64>\n' >&2
  exit 1
fi

build_arch=$1
case "$build_arch" in
  x64) deb_arch=amd64 ;;
  arm64) deb_arch=arm64 ;;
  *)
    printf 'Unsupported architecture: %s. Expected x64 or arm64.\n' "$build_arch" >&2
    exit 1
    ;;
esac

project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$project_dir"
bundle_dir="$project_dir/build/linux/$build_arch/release/bundle"

if [[ ! -f "$bundle_dir/fluffychat" || ! -d "$bundle_dir/lib" || ! -d "$bundle_dir/data" ]]; then
  printf 'No complete Linux release bundle found in %s. Build it with Flutter first.\n' "$bundle_dir" >&2
  exit 1
fi

if [[ "$(dpkg --print-architecture)" != "$deb_arch" ]]; then
  printf 'Package this bundle on a native %s runner.\n' "$deb_arch" >&2
  exit 1
fi

version=$(awk '/^version:/ { print $2; exit }' pubspec.yaml)
dpkg --validate-version "$version"
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT
trap 'exit 1' HUP INT TERM
package_dir="$work_dir/debian/fluffychat"
app_dir="$package_dir/usr/lib/fluffychat"

mkdir -p "$package_dir/DEBIAN" "$app_dir" "$package_dir/usr/bin" \
  "$package_dir/usr/share/applications"
cp -a "$bundle_dir/." "$app_dir/"
ln -s ../lib/fluffychat/fluffychat "$package_dir/usr/bin/fluffychat"
sed 's|^Icon=.*|Icon=chat.fluffy.fluffychat|' snap/gui/fluffychat.desktop \
  > "$package_dir/usr/share/applications/chat.fluffy.fluffychat.desktop"
install -Dm644 snap/gui/fluffychat.png \
  "$package_dir/usr/share/pixmaps/chat.fluffy.fluffychat.png"
install -Dm644 LICENSE "$package_dir/usr/share/doc/fluffychat/copyright"
find "$package_dir" -type d -exec chmod 755 {} +
chmod 755 "$app_dir/fluffychat"

cat > "$work_dir/debian/control" <<'EOF'
Source: fluffychat

Package: fluffychat
Architecture: any
Description: Matrix messenger with end-to-end encryption
EOF

elf_files=("-e$app_dir/fluffychat")
while IFS= read -r -d '' library; do
  if ! readelf -h "$library" >/dev/null 2>&1; then
    continue
  fi
  elf_files+=("-e$library")
done < <(find "$app_dir/lib" -type f -print0)

library_paths=()
while IFS= read -r -d '' library_dir; do
  installed_library_dir=${library_dir#"$package_dir"}
  library_paths+=("-l$installed_library_dir")
done < <(find "$app_dir/lib" -type d -print0)

shlibs_output=$(
  cd "$work_dir" && dpkg-shlibdeps -O -Sdebian/fluffychat -xfluffychat \
    "${library_paths[@]}" "${elf_files[@]}"
)
dependencies=${shlibs_output#shlibs:Depends=}
if [[ "$shlibs_output" != shlibs:Depends=* || -z "$dependencies" ]]; then
  printf 'Unable to determine the Linux runtime dependencies.\n' >&2
  exit 1
fi
dependencies="$dependencies, libmpv2, libblas3, liblapack3"
installed_size=$(du -sk "$package_dir/usr" | cut -f1)

cat > "$package_dir/DEBIAN/control" <<EOF
Package: fluffychat
Version: $version
Section: net
Priority: optional
Architecture: $deb_arch
Maintainer: Oh-My-FluffyChat contributors <noreply@github.com>
Depends: $dependencies
Installed-Size: $installed_size
Homepage: https://github.com/exp-3/oh-my-fluffychat
Description: Matrix messenger with end-to-end encryption
 Chat with friends using the decentralized Matrix network.
EOF
chmod 644 "$package_dir/DEBIAN/control"

output="$project_dir/fluffychat-linux-$build_arch.deb"
dpkg-deb --build --root-owner-group --uniform-compression -Zxz "$package_dir" "$output"

if [[ "$(ar t "$output")" != $'debian-binary\ncontrol.tar.xz\ndata.tar.xz' ]]; then
  printf 'The Debian package does not contain the expected xz archives.\n' >&2
  exit 1
fi

[[ "$(dpkg-deb --field "$output" Architecture)" == "$deb_arch" ]]
[[ "$(dpkg-deb --field "$output" Version)" == "$version" ]]
dpkg-deb --fsys-tarfile "$output" | tar -tf - > "$work_dir/package-files.txt"
for entry in fluffychat lib/ data/; do
  grep -Fxq "./usr/lib/fluffychat/$entry" "$work_dir/package-files.txt"
done
dpkg-deb --info "$output"
