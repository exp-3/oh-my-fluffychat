#!/usr/bin/env python3
#
# SPDX-FileCopyrightText: 2026 exp-3
# SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
#
# SPDX-License-Identifier: AGPL-3.0-or-later

"""Render all checked-in application icons from their SVG master files.

Run from any working directory with::

    python scripts/update-icons.py

Install the renderer dependencies once with::

    python -m pip install Pillow resvg-py

The source-to-target groups below are intentional. Keep a target in the
group for its actual master SVG instead of routing every icon through one
generic PNG. The script uses relative repository paths so it is portable.
"""

from __future__ import annotations

import json
import sys
from dataclasses import dataclass
from decimal import Decimal
from io import BytesIO
from pathlib import Path

try:
    from PIL import Image
except ImportError as error:  # pragma: no cover - setup failure
    raise SystemExit(
        "Pillow is required. Install the icon tools with: "
        "python -m pip install Pillow resvg-py"
    ) from error

try:
    from resvg_py import svg_to_bytes
except ImportError as error:  # pragma: no cover - setup failure
    raise SystemExit(
        "resvg-py is required. Install the icon tools with: "
        "python -m pip install Pillow resvg-py"
    ) from error


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]


@dataclass(frozen=True)
class PngTarget:
    path: str
    width: int
    height: int
    remove_alpha: bool = False


@dataclass(frozen=True)
class IcoTarget:
    path: str
    sizes: tuple[int, ...]


def repository_path(relative_path: str) -> Path:
    """Resolve a repository-relative path and reject accidental absolutes."""

    relative = Path(relative_path)
    if relative.is_absolute() or ".." in relative.parts:
        raise ValueError(f"Icon paths must be repository-relative: {relative_path}")
    return REPOSITORY_ROOT / relative


def atomic_write(path: Path, data: bytes) -> None:
    """Write a generated asset without leaving a partially written target."""

    path.parent.mkdir(parents=True, exist_ok=True)
    temporary_path = path.with_name(f".{path.name}.tmp")
    temporary_path.write_bytes(data)
    temporary_path.replace(path)


def render_png(source: str, target: PngTarget) -> None:
    source_path = repository_path(source)
    target_path = repository_path(target.path)
    png_data = svg_to_bytes(
        svg_path=str(source_path),
        width=target.width,
        height=target.height,
    )
    with Image.open(BytesIO(png_data)) as rendered_image:
        if rendered_image.size != (target.width, target.height):
            raise RuntimeError(
                f"Unexpected render size for {source}: {rendered_image.size}; "
                f"expected {(target.width, target.height)}"
            )
        mode = "RGB" if target.remove_alpha else "RGBA"
        image = rendered_image.convert(mode)
    output = BytesIO()
    image.save(output, format="PNG")
    image.close()
    atomic_write(target_path, output.getvalue())


def render_ico(source: str, target: IcoTarget) -> None:
    source_path = repository_path(source)
    target_path = repository_path(target.path)
    largest_size = max(target.sizes)
    png_data = svg_to_bytes(
        svg_path=str(source_path),
        width=largest_size,
        height=largest_size,
    )
    with Image.open(BytesIO(png_data)) as rendered_image:
        image = rendered_image.convert("RGBA")
    output = BytesIO()
    image.save(output, format="ICO", sizes=[(size, size) for size in target.sizes])
    image.close()
    atomic_write(target_path, output.getvalue())


def android_density_targets(prefix: str, filename: str, base_size: int) -> list[PngTarget]:
    densities = (
        ("mdpi", 1, 1),
        ("hdpi", 3, 2),
        ("xhdpi", 2, 1),
        ("xxhdpi", 3, 1),
        ("xxxhdpi", 4, 1),
    )
    return [
        PngTarget(
            f"android/app/src/main/res/{prefix}-{density}/{filename}",
            base_size * numerator // denominator,
            base_size * numerator // denominator,
        )
        for density, numerator, denominator in densities
    ]


def xcasset_targets(contents_path: str, directory: str, remove_alpha: bool) -> list[PngTarget]:
    """Read Apple's declared icon sizes instead of duplicating them here."""

    contents = json.loads(repository_path(contents_path).read_text(encoding="utf-8"))
    targets: dict[str, PngTarget] = {}
    for image in contents.get("images", []):
        filename = image.get("filename")
        if not filename:
            continue
        logical_size = Decimal(image["size"].split("x", maxsplit=1)[0])
        scale = Decimal(image.get("scale", "1x").removesuffix("x"))
        pixels = int(logical_size * scale)
        target = PngTarget(
            f"{directory}/{filename}",
            pixels,
            pixels,
            remove_alpha=remove_alpha,
        )
        previous = targets.get(target.path)
        if previous and (previous.width, previous.height) != (pixels, pixels):
            raise RuntimeError(f"Conflicting dimensions for {target.path}")
        targets[target.path] = target
    return list(targets.values())


def source_groups() -> list[tuple[str, list[PngTarget]]]:
    """Return explicit SVG-master to PNG-target mappings."""

    groups: list[tuple[str, list[PngTarget]]] = []

    # logo.svg: the default logo, Android legacy icons, Apple icons, the
    # Fastlane store logo, and the 500px in-app mini logo.
    logo_targets = [
        PngTarget("assets/logo/img/logo.png", 2000, 2000),
        PngTarget("assets/logo/mini/logo_mini.png", 500, 500),
        PngTarget("android/fastlane/metadata/android/en-US/images/logo.png", 2000, 2000),
        *android_density_targets("mipmap", "ic_launcher.png", 48),
        *xcasset_targets(
            "ios/Runner/Assets.xcassets/AppIcon.appiconset/Contents.json",
            "ios/Runner/Assets.xcassets/AppIcon.appiconset",
            remove_alpha=True,
        ),
        *xcasset_targets(
            "macos/Runner/Assets.xcassets/AppIcon.appiconset/Contents.json",
            "macos/Runner/Assets.xcassets/AppIcon.appiconset",
            remove_alpha=False,
        ),
    ]
    groups.append(("assets/logo/vector/logo.svg", logo_targets))

    # logo_background.svg: Android adaptive-icon background layers.
    groups.append(
        (
            "assets/logo/vector/logo_background.svg",
            [
                PngTarget("assets/logo/img/logo_background.png", 2000, 2000),
                *android_density_targets("drawable", "ic_launcher_background.png", 108),
            ],
        )
    )

    # logo_foreground.svg: Android adaptive-icon foreground layers.
    groups.append(
        (
            "assets/logo/vector/logo_foreground.svg",
            [
                PngTarget("assets/logo/img/logo_foreground.png", 2000, 2000),
                *android_density_targets("drawable", "ic_launcher_foreground.png", 108),
            ],
        )
    )

    # logo_mono.svg: Android adaptive monochrome layers and the mini logo.
    groups.append(
        (
            "assets/logo/vector/logo_mono.svg",
            [
                PngTarget("assets/logo/img/logo_mono.png", 2000, 2000),
                PngTarget("assets/logo/mini/logo_mono_mini.png", 500, 500),
                *android_density_targets("drawable", "ic_launcher_monochrome.png", 108),
            ],
        )
    )

    # logo_standalone.svg: Web icons, including the extra sizes referenced by
    # web/index.html in addition to the sizes declared in web/manifest.json.
    groups.append(
        (
            "assets/logo/vector/logo_standalone.svg",
            [
                PngTarget("assets/logo/img/logo_standalone.png", 2000, 2000),
                PngTarget("snap/gui/fluffychat.png", 500, 500),
                PngTarget("web/favicon.png", 16, 16),
                PngTarget("web/icons/Icon-16.png", 16, 16),
                PngTarget("web/icons/Icon-32.png", 32, 32),
                PngTarget("web/icons/Icon-48.png", 48, 48),
                PngTarget("web/icons/Icon-192.png", 192, 192),
                PngTarget("web/icons/Icon-512.png", 512, 512),
                PngTarget("web/icons/Icon-maskable-192.png", 192, 192),
                PngTarget("web/icons/Icon-maskable-512.png", 512, 512),
            ],
        )
    )

    # logo_notification.svg: Android notification icons are white-on-
    # transparent and intentionally remain separate from launcher artwork.
    groups.append(
        (
            "assets/logo/vector/logo_notification.svg",
            android_density_targets("drawable", "notifications_icon.png", 24),
        )
    )

    return groups


def main() -> int:
    for source, targets in source_groups():
        print(f"[{source}]")
        for target in targets:
            print(f"  -> {target.path} ({target.width}x{target.height})")
            render_png(source, target)

    # Use the same rounded standalone artwork as the Snap/Linux icon for the
    # Windows ICO, including its transparent corners and drop shadow.
    ico = IcoTarget("windows/runner/resources/app_icon.ico", (16, 32, 48, 64, 128, 256))
    print("[assets/logo/vector/logo_standalone.svg]")
    print(f"  -> {ico.path} (ICO sizes: {', '.join(map(str, ico.sizes))})")
    render_ico("assets/logo/vector/logo_standalone.svg", ico)

    print("\nIcon assets updated.")
    print(
        "Preserved files without an SVG master: logo_font*.png, "
        "Android splash.png, drawable/background.png, iOS launch images, "
        "and phone screenshots."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
