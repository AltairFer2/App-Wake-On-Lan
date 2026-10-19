"""Genera los iconos de Lazy Wake Up a partir del logotipo original.

Uso (desde la raíz del repositorio, requiere Pillow):

    python tool/generate_launcher_icons.py

Lee ``assets/branding/lazy_wake_up_logo.png`` (icono redondeado sobre fondo
blanco con el nombre debajo) y escribe:

- ``android/app/src/main/res/mipmap-*/ic_launcher.png``: icono clásico con
  las esquinas transparentes (Android 7 o anterior).
- ``android/app/src/main/res/mipmap-*/ic_launcher_foreground.png``: capa
  frontal del icono adaptable (Android 8+); el fondo es un color sólido.
- ``assets/branding/lazy_wake_up_icon.png``: icono para usar dentro de la app.
"""

from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "assets" / "branding" / "lazy_wake_up_logo.png"
RES = ROOT / "android" / "app" / "src" / "main" / "res"
IN_APP_ICON = ROOT / "assets" / "branding" / "lazy_wake_up_icon.png"

# Cualquier píxel con una suma RGB menor se considera parte del dibujo.
WHITE_THRESHOLD = 600
# Radio de las esquinas del icono respecto a su ancho (medido en el original).
CORNER_RATIO = 0.24
# El icono adaptable mide 108 dp y el launcher muestra los 72 dp centrales.
# El dibujo ocupa un poco más para que la máscara del launcher (círculo,
# squircle) caiga casi entera dentro de sus esquinas redondeadas sin cortar
# la luna ni las ondas.
ADAPTIVE_CANVAS_DP = 108
ADAPTIVE_ART_DP = 76

DENSITIES = {"mdpi": 1.0, "hdpi": 1.5, "xhdpi": 2.0, "xxhdpi": 3.0, "xxxhdpi": 4.0}
LEGACY_DP = 48
IN_APP_SIZE = 256


def icon_bounds(image: Image.Image) -> tuple[int, int, int, int]:
    """Caja del cuadro redondeado: el primer bloque de filas no blancas."""
    rgb = image.convert("RGB")
    width, height = rgb.size
    px = rgb.load()

    def row_has_art(y: int) -> bool:
        return any(sum(px[x, y]) < WHITE_THRESHOLD for x in range(width))

    top = next(y for y in range(height) if row_has_art(y))
    bottom = top
    while bottom + 1 < height and row_has_art(bottom + 1):
        bottom += 1
    columns = [
        x
        for x in range(width)
        if any(sum(px[x, y]) < WHITE_THRESHOLD for y in range(top, bottom + 1))
    ]
    return columns[0], top, columns[-1] + 1, bottom + 1


def rounded_icon(image: Image.Image) -> Image.Image:
    """Recorta el icono, lo hace cuadrado y vuelve transparentes las esquinas."""
    left, top, right, bottom = icon_bounds(image)
    art = image.convert("RGBA").crop((left, top, right, bottom))
    side = max(art.size)
    art = art.resize((side, side), Image.LANCZOS)

    # Máscara al cuádruple de tamaño para suavizar el borde.
    scale = 4
    mask = Image.new("L", (side * scale, side * scale), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (0, 0, side * scale - 1, side * scale - 1),
        radius=int(side * scale * CORNER_RATIO),
        fill=255,
    )
    art.putalpha(mask.resize((side, side), Image.LANCZOS))
    return art


def write_png(image: Image.Image, path: Path, size: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    image.resize((size, size), Image.LANCZOS).save(path, optimize=True)


def main() -> None:
    icon = rounded_icon(Image.open(SOURCE))

    for density, factor in DENSITIES.items():
        folder = RES / f"mipmap-{density}"
        write_png(icon, folder / "ic_launcher.png", round(LEGACY_DP * factor))

        canvas_px = round(ADAPTIVE_CANVAS_DP * factor)
        art_px = round(ADAPTIVE_ART_DP * factor)
        foreground = Image.new("RGBA", (canvas_px, canvas_px), (0, 0, 0, 0))
        offset = (canvas_px - art_px) // 2
        foreground.alpha_composite(
            icon.resize((art_px, art_px), Image.LANCZOS), (offset, offset)
        )
        foreground.save(folder / "ic_launcher_foreground.png", optimize=True)

    write_png(icon, IN_APP_ICON, IN_APP_SIZE)
    print(f"Iconos generados desde {SOURCE.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
