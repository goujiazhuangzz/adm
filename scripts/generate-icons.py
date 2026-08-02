"""从 source.png 生成全套应用图标

Tauri 2 对图标的格式要求：
  - icon.ico : 必须包含 16, 24, 32, 48, 64, 256 六种尺寸，32px 建议为第一层
  - icon.icns: macOS，建议包含 128, 256, 512
  - *.png    : RGBA, 宽高相等, 至少 32/128/256/512

用法: python scripts/generate-icons.py [源图路径]
  默认源图: src-tauri/icons/source.png
"""
import io
import struct
import sys
from pathlib import Path
from PIL import Image

# 兼容 Pillow 9.1+ (Resampling) 和旧版本 (直接属性)
try:
    from PIL.Image import Resampling
    LANCZOS = Resampling.LANCZOS
except ImportError:
    LANCZOS = Image.LANCZOS

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_SOURCE = ROOT / "src-tauri" / "icons" / "source.png"
OUT = ROOT / "src-tauri" / "icons"

source_arg = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else DEFAULT_SOURCE
img = Image.open(source_arg).convert("RGBA")
assert img.size[0] >= 256 and img.size[1] >= 256, \
    f"source image should be at least 256x256, got {img.size}"
print(f"源图: {source_arg}  ({img.size[0]}x{img.size[1]})\n")

# ── Step 1: PNG 图标 ──────────────────────────────────────────
# Tauri 需要的 PNG 图标清单
png_sizes = {
    "32x32.png":      (32, 32),
    "64x64.png":      (64, 64),
    "128x128.png":    (128, 128),
    "128x128@2x.png": (256, 256),
    "icon.png":       (512, 512),
}
for name, (w, h) in png_sizes.items():
    resized = img.resize((w, h), LANCZOS)
    path = OUT / name
    resized.save(path, "PNG")
    print(f"  [OK] {path}  ({w}x{h})")

# ── Step 2: Square*Logo.png (Windows Store / AppX, 预留) ──────
square_logos = {
    "Square30x30Logo.png":    (30, 30),
    "Square44x44Logo.png":    (44, 44),
    "Square71x71Logo.png":    (71, 71),
    "Square89x89Logo.png":    (89, 89),
    "Square107x107Logo.png":  (107, 107),
    "Square142x142Logo.png":  (142, 142),
    "Square150x150Logo.png":  (150, 150),
    "Square284x284Logo.png":  (284, 284),
    "Square310x310Logo.png":  (310, 310),
    "StoreLogo.png":          (50, 50),
}
for name, (w, h) in square_logos.items():
    resized = img.resize((w, h), LANCZOS)
    path = OUT / name
    resized.save(path, "PNG")
    print(f"  [OK] {path}  ({w}x{h})")

# ── Step 3: icon.ico (多分辨率, 32px 在前) ────────────────────
# Tauri 要求: 必须包含 16, 24, 32, 48, 64, 256; 32px 建议为第一层
ico_sizes = [32, 16, 24, 48, 64, 256]

ico_dir = b""
ico_data = b""
total_offset = 6 + len(ico_sizes) * 16  # header(6) + directory entries

for s in ico_sizes:
    im = img.resize((s, s), LANCZOS)
    w, h = im.size

    if s <= 64:
        # 小尺寸用 BMP 格式 (BITMAPINFOHEADER + BGRA + AND mask)
        bmp_header = struct.pack(
            "<IiiHHIIiiII",
            40,           # biSize
            w,            # biWidth
            h * 2,        # biHeight (doubled for ICO)
            1,            # biPlanes
            32,           # biBitCount
            0,            # biCompression
            0,            # biSizeImage
            0, 0, 0, 0,   # biXPelsPerMeter, biYPelsPerMeter, biClrUsed, biClrImportant
        )
        pixels = []
        for y in range(h - 1, -1, -1):
            for x in range(w):
                r, g, b, a = im.getpixel((x, y))
                pixels.extend([b, g, r, a])
        pixel_data = bytes(pixels)
        mask_row_size = ((w + 31) // 32) * 4
        and_mask = b"\x00" * (mask_row_size * h)
        entry_data = bmp_header + pixel_data + and_mask
    else:
        # 大尺寸用 PNG 格式 (更高效)
        buf = io.BytesIO()
        im.save(buf, "PNG")
        entry_data = buf.getvalue()

    entry_size = len(entry_data)
    ico_dir += struct.pack(
        "<BBBBHHII",
        s if s < 256 else 0,  # width (0 = 256)
        s if s < 256 else 0,  # height
        0,                     # color palette
        0,                     # reserved
        1,                     # color planes
        32,                    # bits per pixel
        entry_size,
        total_offset,
    )
    ico_data += entry_data
    total_offset += entry_size

ico_bytes = struct.pack("<HHH", 0, 1, len(ico_sizes)) + ico_dir + ico_data
with open(OUT / "icon.ico", "wb") as f:
    f.write(ico_bytes)
print(f"  [OK] {OUT / 'icon.ico'}  ({len(ico_sizes)} layers: "
      f"{', '.join(str(s) for s in ico_sizes)}, 32px first)")

# ── Step 4: icon.icns (macOS) ─────────────────────────────────
icns_types = {
    b"ic07": (128, 128),
    b"ic08": (256, 256),
    b"ic09": (512, 512),
}
icns_entries = b""
for icon_type, (w, h) in icns_types.items():
    resized = img.resize((w, h), LANCZOS)
    buf = io.BytesIO()
    resized.save(buf, "PNG")
    png_data = buf.getvalue()
    entry_size = len(icon_type) + 4 + len(png_data)
    icns_entries += icon_type + struct.pack(">I", entry_size) + png_data

icns_data = b"icns" + struct.pack(">I", 8 + len(icns_entries)) + icns_entries
with open(OUT / "icon.icns", "wb") as f:
    f.write(icns_data)
print(f"  [OK] {OUT / 'icon.icns'}  (3 layers: ic07/128, ic08/256, ic09/512)")

print("\nAll icons generated successfully.")
print("提示: 如果修改了 source.png，请重新运行此脚本，然后执行 pnpm tauri build 重新打包。")
