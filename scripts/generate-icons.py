#!/usr/bin/env python3
"""Generate the small vector-style ExitWatch icon family.

The artwork stays deliberately simple at every size: a vivid blue gradient
background, one clean white shield outline, and a restrained glass highlight.
The status-bar PNG is a high-contrast shield mask that AppKit colors at runtime
for each monitor state.
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
from functools import lru_cache
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter


BACKGROUND_TOP = (48, 121, 255, 255)
BACKGROUND_MIDDLE = (20, 76, 190, 255)
BACKGROUND_BOTTOM = (10, 43, 143, 255)
WHITE = (255, 255, 255, 255)
GENERATED_SOURCE_PATH = Path(__file__).resolve().parents[1] / "Resources" / "ExitWatchGenerated.png"
# The generated reference contains a presentation margin around the artwork.
# A macOS icon still needs a transparent edge, but carrying the whole
# presentation canvas into the bundle makes Launchpad render the blue tile too
# small beside native icons.  Ten percent gives this artwork the same opaque
# footprint as ChatGPT, Claude and other standard 208 px Launchpad icons after
# accounting for the soft gloss/shadow pixels.
GENERATED_ICON_MARGIN = 0.10


@lru_cache(maxsize=1)
def generated_source_icon() -> Image.Image | None:
    """Load the approved generated artwork when it is available.

    The generated interior artwork is preserved, while its presentation
    canvas and mismatched white side bevels are removed before resizing. The
    vector fallback below remains useful for older checkouts that do not yet
    contain the source asset.
    """
    if not GENERATED_SOURCE_PATH.exists():
        return None
    source = Image.open(GENERATED_SOURCE_PATH).convert("RGBA")
    alpha = source.getchannel("A")
    # The reference preview used a checkerboard outside the artwork.  Those
    # pixels are transparent, but retaining their white/gray RGB values would
    # let a high-quality resize pull a faint checkerboard fringe into the
    # visible edge.  Keep the alpha untouched and neutralize only fully
    # transparent pixels before scaling.
    source_pixels = source.load()
    for y in range(source.height):
        for x in range(source.width):
            red, green, blue, opacity = source_pixels[x, y]
            if opacity == 0 and (red or green or blue):
                source_pixels[x, y] = (0, 0, 0, 0)
    # The image-generation preview gave the blue tile and the white/silver
    # bevel two slightly different silhouettes. At Launchpad size that mismatch
    # becomes a conspicuous white strip on both vertical sides. Locate the real
    # blue tile on each row, then fill between its left/right edges so the same
    # silhouette also keeps the white shield opaque.
    tile_mask = Image.new("L", source.size, 0)
    tile_mask_draw = ImageDraw.Draw(tile_mask)
    for y in range(source.height):
        row_left: int | None = None
        row_right: int | None = None
        for x in range(source.width):
            red, green, blue, opacity = source_pixels[x, y]
            is_blue_tile = (
                opacity >= 200
                and blue >= 100
                and blue - max(red, green) >= 30
            )
            if is_blue_tile:
                if row_left is None:
                    row_left = x
                row_right = x
        if row_left is not None and row_right is not None:
            tile_mask_draw.line((row_left, y, row_right, y), fill=255)

    # A sub-pixel feather supplies antialiasing without reviving the removed
    # white side pixels.
    tile_mask = tile_mask.filter(ImageFilter.GaussianBlur(0.8))
    content_bbox = tile_mask.point(lambda value: 255 if value >= 8 else 0).getbbox()
    if content_bbox is None:
        content_bbox = alpha.point(lambda value: 255 if value >= 8 else 0).getbbox()
        if content_bbox is None:
            return source
    else:
        left, top, right, bottom = content_bbox

        # Rebuild only the narrow bevel band. The generated reference's
        # metallic edge is not a single contour: its white side pixels sit a
        # few pixels outside the blue tile. A clean gradient underneath the
        # original interior keeps the look while making the border geometrical
        # and continuous at small Launchpad sizes.
        gradient_line = Image.new("RGBA", (1, source.height), (0, 0, 0, 0))
        gradient_pixels = gradient_line.load()
        stops = (BACKGROUND_TOP[:3], BACKGROUND_MIDDLE[:3], BACKGROUND_BOTTOM[:3])
        for y in range(top, bottom):
            progress = (y - top) / max(1, bottom - top - 1)
            if progress < 0.5:
                segment = 0
                local_progress = progress * 2.0
            else:
                segment = 1
                local_progress = (progress - 0.5) * 2.0
            color = tuple(
                round(stops[segment][channel] * (1.0 - local_progress)
                      + stops[segment + 1][channel] * local_progress)
                for channel in range(3)
            )
            gradient_pixels[0, y] = (*color, 255)
        gradient = gradient_line.resize(source.size, Image.Resampling.BILINEAR)
        gradient.putalpha(tile_mask)

        # Keep the shield and the reference's subtle internal lighting, but
        # discard its mismatched outer bevel by compositing only the eroded
        # interior over the clean gradient.
        core_mask = tile_mask.filter(ImageFilter.MinFilter(41))
        core_source = source.copy()
        core_source.putalpha(core_mask)
        gradient.alpha_composite(core_source)

        # The highlight must stay *inside* the blue silhouette.  Subtracting
        # an eroded mask from the full mask used to paint a bright halo over
        # the outside of the tile; at Launchpad size that halo collapsed into
        # the two conspicuous white side rails.  Two nested erosions give us a
        # single, even inner stroke while the original mask still supplies
        # antialiased blue pixels right up to the edge.
        rim_outer = tile_mask.filter(ImageFilter.MinFilter(25))
        rim_inner = tile_mask.filter(ImageFilter.MinFilter(41))
        rim_alpha = ImageChops.subtract(rim_outer, rim_inner).point(
            lambda value: round(value * 0.34)
        )
        rim = Image.new("RGBA", source.size, (220, 235, 255, 0))
        rim.putalpha(rim_alpha)
        gradient.alpha_composite(rim)

        # Let Launchpad supply most of the drop shadow. This tiny, clipped
        # shadow only separates the blue tile from transparent backgrounds and
        # never wraps around the top edge.
        blurred_mask = tile_mask.filter(ImageFilter.GaussianBlur(18))
        shadow_shift = 8
        shifted_shadow = Image.new("L", source.size, 0)
        shifted_shadow.paste(
            blurred_mask.crop((0, 0, source.width, source.height - shadow_shift)),
            (0, shadow_shift),
        )
        shifted_shadow = shifted_shadow.point(lambda value: round(value * 0.12))
        shadow = Image.new("RGBA", source.size, (0, 8, 35, 0))
        shadow.putalpha(shifted_shadow)
        cleaned_source = Image.new("RGBA", source.size, (0, 0, 0, 0))
        cleaned_source.alpha_composite(shadow)
        cleaned_source.alpha_composite(gradient)

    target_width = round(
        (right - left) / (1.0 - 2.0 * GENERATED_ICON_MARGIN)
    )
    target_height = round(
        (bottom - top) / (1.0 - 2.0 * GENERATED_ICON_MARGIN)
    )
    center_x = (left + right) / 2.0
    center_y = (top + bottom) / 2.0
    crop_left = round(center_x - target_width / 2.0)
    crop_top = round(center_y - target_height / 2.0)
    crop_right = crop_left + target_width
    crop_bottom = crop_top + target_height

    # ``make_icon`` maps this optical crop onto a square output. Independent
    # horizontal/vertical margins compensate for the generated tile being a
    # few pixels taller than wide without bringing back either white side.
    cropped = Image.new("RGBA", (target_width, target_height), (0, 0, 0, 0))
    source_left = max(0, crop_left)
    source_top = max(0, crop_top)
    source_right = min(source.width, crop_right)
    source_bottom = min(source.height, crop_bottom)
    if source_right > source_left and source_bottom > source_top:
        cropped.alpha_composite(
            cleaned_source.crop((source_left, source_top, source_right, source_bottom)),
            (source_left - crop_left, source_top - crop_top),
        )
    return cropped


def _shield_point(
    size: float,
    x: float,
    y: float,
    inset: float,
    origin: tuple[float, float],
) -> tuple[int, int]:
    """Map a normalized shield coordinate onto an antialiased canvas."""
    # Pull the two vertical sides in very slightly. This keeps the silhouette
    # optically balanced after macOS applies its own icon scaling.
    horizontal_inset = inset if x < 0.5 else -inset if x > 0.5 else 0.0
    vertical_inset = inset if y < 0.5 else -inset
    return (
        round(origin[0] + size * x + horizontal_inset),
        round(origin[1] + size * y + vertical_inset),
    )


def _cubic_segment(
    p0: tuple[int, int],
    p1: tuple[int, int],
    p2: tuple[int, int],
    p3: tuple[int, int],
    steps: int = 18,
) -> list[tuple[int, int]]:
    points: list[tuple[int, int]] = []
    for index in range(steps + 1):
        t = index / steps
        inverse = 1.0 - t
        x = (
            inverse**3 * p0[0]
            + 3 * inverse**2 * t * p1[0]
            + 3 * inverse * t**2 * p2[0]
            + t**3 * p3[0]
        )
        y = (
            inverse**3 * p0[1]
            + 3 * inverse**2 * t * p1[1]
            + 3 * inverse * t**2 * p2[1]
            + t**3 * p3[1]
        )
        points.append((round(x), round(y)))
    return points


def shield_points(
    size: float,
    inset: float = 0.0,
    origin: tuple[float, float] = (0.0, 0.0),
) -> list[tuple[int, int]]:
    """Return a smooth, plain shield outline (no inner ornamentation)."""
    point = lambda x, y: _shield_point(size, x, y, inset, origin)

    top = point(0.50, 0.14)
    right_top = point(0.75, 0.25)
    right_low = point(0.65, 0.70)
    bottom = point(0.50, 0.86)
    left_low = point(0.35, 0.70)
    left_top = point(0.25, 0.25)

    segments = [
        (top, point(0.58, 0.145), point(0.69, 0.19), right_top),
        (right_top, point(0.79, 0.33), point(0.72, 0.60), right_low),
        (right_low, point(0.61, 0.78), point(0.55, 0.83), bottom),
        (bottom, point(0.45, 0.83), point(0.39, 0.78), left_low),
        (left_low, point(0.28, 0.60), point(0.21, 0.33), left_top),
        (left_top, point(0.31, 0.19), point(0.42, 0.145), top),
    ]

    outline: list[tuple[int, int]] = []
    for index, segment in enumerate(segments):
        points = _cubic_segment(*segment)
        outline.extend(points if index == 0 else points[1:])
    return outline


def make_icon(size: int) -> Image.Image:
    source = generated_source_icon()
    if source is not None:
        return source.resize((size, size), Image.Resampling.LANCZOS)

    scale = 4
    canvas_size = size * scale
    image = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))

    # Leave a real transparent safe-area around the artwork. Without this
    # Launchpad renders the rounded square visibly larger than neighboring
    # native macOS icons.
    margin = round(canvas_size * 0.065)
    left = margin
    top = margin
    right = canvas_size - 1 - margin
    bottom = right
    inner_size = right - left + 1
    radius = round(inner_size * 0.23)
    bounds = (left, top, right, bottom)

    shadow_mask = Image.new("L", image.size, 0)
    shadow_draw = ImageDraw.Draw(shadow_mask)
    shadow_offset = round(canvas_size * 0.012)
    shadow_draw.rounded_rectangle(
        (left, top + shadow_offset, right, bottom + shadow_offset),
        radius=radius,
        fill=145,
    )
    shadow_mask = shadow_mask.filter(ImageFilter.GaussianBlur(canvas_size * 0.018))
    shadow = Image.new("RGBA", image.size, (0, 0, 0, 0))
    shadow.putalpha(shadow_mask)
    image.alpha_composite(shadow)

    background_mask = Image.new("L", image.size, 0)
    ImageDraw.Draw(background_mask).rounded_rectangle(
        bounds,
        radius=radius,
        fill=255,
    )

    background = Image.new("RGBA", image.size, (0, 0, 0, 0))
    background_pixels = background.load()
    for y in range(canvas_size):
        t = y / max(1, canvas_size - 1)
        r = round(BACKGROUND_TOP[0] * (1 - t) + BACKGROUND_BOTTOM[0] * t)
        g = round(BACKGROUND_TOP[1] * (1 - t) + BACKGROUND_BOTTOM[1] * t)
        b = round(BACKGROUND_TOP[2] * (1 - t) + BACKGROUND_BOTTOM[2] * t)
        for x in range(canvas_size):
            background_pixels[x, y] = (r, g, b, 255)
    background.putalpha(background_mask)
    image.alpha_composite(background)

    # A soft blue halo adds depth without introducing any inner shield detail.
    halo = Image.new("RGBA", image.size, (0, 0, 0, 0))
    halo_draw = ImageDraw.Draw(halo)
    halo_draw.ellipse(
        (
            left + inner_size * 0.14,
            top + inner_size * 0.02,
            left + inner_size * 0.89,
            top + inner_size * 0.77,
        ),
        fill=(151, 219, 255, 70),
    )
    halo = halo.filter(ImageFilter.GaussianBlur(canvas_size * 0.07))
    image.alpha_composite(halo)

    # ``shield_points`` already returns the final point at the top junction;
    # appending it a second time creates a visible seam after downsampling.
    shield = shield_points(inner_size, inner_size * 0.018, origin=(left, top))
    closed_shield = shield

    # A diffused white halo keeps the thin outline legible at Launchpad sizes.
    shield_glow = Image.new("RGBA", image.size, (0, 0, 0, 0))
    glow_draw = ImageDraw.Draw(shield_glow)
    glow_draw.line(
        closed_shield,
        fill=(255, 255, 255, 110),
        width=max(12, round(canvas_size * 0.078)),
        joint="curve",
    )
    shield_glow = shield_glow.filter(ImageFilter.GaussianBlur(canvas_size * 0.018))
    image.alpha_composite(shield_glow)

    # Keep the actual shield as a plain, symmetric outline. Drawing at 4x and
    # downsampling gives smooth cubic curves and rounded joins at every size.
    shield_line = Image.new("RGBA", image.size, (0, 0, 0, 0))
    line_draw = ImageDraw.Draw(shield_line)
    line_draw.line(
        closed_shield,
        fill=(255, 255, 255, 248),
        width=max(8, round(canvas_size * 0.056)),
        joint="curve",
    )
    image.alpha_composite(shield_line)

    # A continuous white rim gives the icon the crisp highlighted edge visible
    # on the reference icons, while remaining subtle in dark mode.
    edge = Image.new("RGBA", image.size, (0, 0, 0, 0))
    edge_draw = ImageDraw.Draw(edge)
    edge_draw.rounded_rectangle(
        bounds,
        radius=radius,
        outline=(255, 255, 255, 178),
        width=max(3, round(canvas_size * 0.012)),
    )
    image.alpha_composite(edge)

    return image.resize((size, size), Image.Resampling.LANCZOS)


def make_status_mask(size: int = 64) -> Image.Image:
    image = Image.new("RGBA", (size * 4, size * 4), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    shield = shield_points(size * 4, size * 0.10)
    draw.polygon(shield, fill=WHITE)
    return image.resize((size, size), Image.Resampling.LANCZOS)


def write_iconset(output_dir: Path) -> Path:
    iconset = output_dir / "ExitWatch.iconset"
    iconset.mkdir(parents=True, exist_ok=True)
    for size in (16, 32, 128, 256, 512):
        make_icon(size).save(iconset / f"icon_{size}x{size}.png")
        make_icon(size * 2).save(iconset / f"icon_{size}x{size}@2x.png")

    # Modern macOS surfaces (including Launchpad) prefer an AppIcon asset
    # catalog. Keep the same PNG family in a catalog alongside the legacy
    # .icns output so the bundle can advertise both representations.
    assets_root = output_dir / "Assets.xcassets"
    appiconset = assets_root / "AppIcon.appiconset"
    appiconset.mkdir(parents=True, exist_ok=True)
    (assets_root / "Contents.json").write_text(
        json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n",
        encoding="utf-8",
    )
    images = []
    for size in (16, 32, 128, 256, 512):
        for scale, suffix in (("1x", ""), ("2x", "@2x")):
            filename = f"icon_{size}x{size}{suffix}.png"
            shutil.copy2(iconset / filename, appiconset / filename)
            images.append(
                {
                    "filename": filename,
                    "idiom": "mac",
                    "scale": scale,
                    "size": f"{size}x{size}",
                }
            )
    (appiconset / "Contents.json").write_text(
        json.dumps({"images": images, "info": {"author": "xcode", "version": 1}}, indent=2)
        + "\n",
        encoding="utf-8",
    )

    icns = output_dir / "ExitWatch.icns"
    subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(icns)], check=True)
    return icns


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", required=True, type=Path)
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)

    write_iconset(args.output_dir)
    make_status_mask().save(args.output_dir / "ExitWatchStatus.png")


if __name__ == "__main__":
    main()
