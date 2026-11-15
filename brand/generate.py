#!/usr/bin/env python3
"""Generate the Stowlark brand assets. Use --rasters with CairoSVG and Pillow."""

import argparse
from io import BytesIO
from pathlib import Path

INK = "#142D2A"
PAPER = "#EFF7F3"
TEAL = "#187A65"
MINT = "#89F2C4"
TILE_TOP = "#22483F"
TILE_BOTTOM = "#102D28"

# The wing and tail fold meet at y=32. The eye is cut out of the silhouette
# so the same geometry works against any background and at menu-bar sizes.
BIRD = (
    "M4 46l17-14L9 14l26 9 10-8a9 9 0 0 1 10 0l7 5-7 4"
    "a25 25 0 0 1-24 22H4Z"
    "M51.6 20.6a1.7 1.7 0 1 0-3.4 0 1.7 1.7 0 1 0 3.4 0Z"
)
WING = "M9 14l26 9-6 12-8-3Z"

# Hand-drawn letter paths keep the wordmark independent of installed fonts.
LETTERS = (
    "M24 17c-2.8-2.8-6.6-4-10.7-4C7 13 3 16.4 3 21.2c0 4.9 4 7.2 10 9.2"
    " 6.1 2 11.6 4.5 11.6 10 0 5.4-4.7 8.6-11.4 8.6C8 49 4 47.2 1.5 44.2",
    "M35 19v23c0 4.9 2.4 7 6.5 7H44M30 28h13.5",
    "M60 27c-6.1 0-10.7 4.4-10.7 11s4.6 11 10.7 11 10.7-4.4 10.7-11S66.1 27 60 27Z",
    "M76 28l7.5 21L92 29l8.5 20 7.5-21",
    "M116 13v36",
    "M146 28v21m0-11c0-6.5-4-11-10-11s-10.5 4.5-10.5 11 4.5 11 10.5 11 10-4.5 10-11Z",
    "M156 28v21m0-12c1.7-6 5.2-9 11.5-9",
    "M177 13v36m0-9 13.5-12m-9.5 9 11 12",
)


def mark(body, wing=None):
    silhouette = f'<path fill="{body}" fill-rule="evenodd" d="{BIRD}"/>'
    if wing is None:
        return silhouette
    return f'{silhouette}\n  <path fill="{wing}" d="{WING}"/>'


def wordmark(color):
    letters = "\n    ".join(f'<path d="{path}"/>' for path in LETTERS)
    return (
        f'<g fill="none" stroke="{color}" stroke-width="4.6" '
        'stroke-linecap="round" stroke-linejoin="round">\n'
        f'    {letters}\n  </g>'
    )


def svg(width, height, content, title="Stowlark"):
    return (
        '<svg xmlns="http://www.w3.org/2000/svg" '
        f'viewBox="0 0 {width} {height}" width="{width}" height="{height}" '
        'role="img" aria-labelledby="title">\n'
        f'  <title id="title">{title}</title>\n  {content}\n</svg>\n'
    )


def app_icon(margin, radius):
    tile_width = 1024 - 2 * margin
    scale = tile_width * 0.76 / 58
    x = 512 - 33 * scale
    y = 512 - 30 * scale
    content = f'''<defs>
    <linearGradient id="tile" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="{TILE_TOP}"/>
      <stop offset="1" stop-color="{TILE_BOTTOM}"/>
    </linearGradient>
  </defs>
  <rect x="{margin}" y="{margin}" width="{tile_width}" height="{tile_width}" rx="{radius}" fill="url(#tile)"/>
  <g transform="translate({x:.3f} {y:.3f}) scale({scale:.3f})">
    {mark(MINT, PAPER)}
  </g>'''
    return svg(1024, 1024, content, "Stowlark app icon")


def vectors(root):
    variants = {
        "light": (TEAL, INK, INK),
        "dark": (MINT, PAPER, PAPER),
        "mono": (INK, None, INK),
        "mono-white": (PAPER, None, PAPER),
    }
    for name, (body, wing, text) in variants.items():
        bird = mark(body, wing)
        letters = wordmark(text)
        horizontal = f'{bird}\n  <g transform="translate(73 1)">{letters}</g>'
        stacked = (
            f'<g transform="translate(25 8) scale(1.6)">{bird}</g>\n'
            f'  <g transform="translate(13 89) scale(.68)">{letters}</g>'
        )
        for kind, content in (
            ("mark", svg(64, 64, bird)),
            ("horizontal", svg(272, 64, horizontal)),
            ("stacked", svg(156, 156, stacked)),
        ):
            (root / f"logo/stowlark-{kind}-{name}.svg").write_text(content)

    favicon = (
        f'<rect width="64" height="64" rx="13" fill="{TILE_BOTTOM}"/>\n'
        f'  <g transform="translate(6 8) scale(.8)">{mark(MINT, PAPER)}</g>'
    )
    (root / "logo/stowlark-favicon.svg").write_text(svg(64, 64, favicon))
    (root / "icon/stowlark-app-icon.svg").write_text(app_icon(100, 185))
    (root / "icon/stowlark-app-icon-windows.svg").write_text(app_icon(0, 230))


def rasters(root):
    import cairosvg
    from PIL import Image

    def render(path, size):
        data = cairosvg.svg2png(url=str(root / path), output_width=size, output_height=size)
        return Image.open(BytesIO(data)).convert("RGBA")

    app = render("icon/stowlark-app-icon.svg", 1024)
    for size in (16, 32, 64, 128, 256, 512, 1024):
        app.resize((size, size), Image.Resampling.LANCZOS).save(
            root / f"icon/png/stowlark-app-icon-{size}.png"
        )
    template = svg(44, 36, f'<g transform="translate(5 2) scale(.52)">{mark("#000")}</g>')
    cairosvg.svg2png(bytestring=template.encode(), write_to=str(root / "icon/png/stowlark-menubar-template@2x.png"))

    windows = render("icon/stowlark-app-icon-windows.svg", 1024)
    sizes = (16, 20, 24, 32, 40, 48, 64, 256)
    for size in sizes:
        windows.resize((size, size), Image.Resampling.LANCZOS).save(
            root / f"icon/windows/stowlark-{size}.png"
        )
    windows.save(root / "icon/windows/stowlark.ico", sizes=[(size, size) for size in sizes])

    # WiX accepts only 24-bit bitmaps. Leave room for the version stamp on
    # the dialog and the Windows Installer text on the banner.
    installer = root / "installer/windows"
    dialog = Image.new("RGB", (493, 312), "white")
    panel = Image.linear_gradient("L").resize((164, 312))
    panel = Image.composite(
        Image.new("RGB", panel.size, TILE_BOTTOM),
        Image.new("RGB", panel.size, TILE_TOP),
        panel,
    )
    dialog.paste(panel, (0, 0))
    stacked = render("logo/stowlark-stacked-dark.svg", 118)
    dialog.paste(stacked, (23, 76), stacked)
    dialog.save(installer / "wix-dialog.bmp")

    banner = Image.new("RGB", (493, 58), PAPER)
    logo_png = cairosvg.svg2png(url=str(root / "logo/stowlark-horizontal-light.svg"), output_height=26)
    horizontal = Image.open(BytesIO(logo_png)).convert("RGBA")
    banner.paste(horizontal, (493 - 14 - horizontal.width, 16), horizontal)
    banner.save(installer / "wix-banner.bmp")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path, help="brand asset directory")
    parser.add_argument("--rasters", action="store_true", help="also generate PNG, ICO and BMP files")
    args = parser.parse_args()
    for directory in ("logo", "icon/png", "icon/windows", "installer/windows"):
        (args.root / directory).mkdir(parents=True, exist_ok=True)
    vectors(args.root)
    if args.rasters:
        rasters(args.root)


if __name__ == "__main__":
    main()
