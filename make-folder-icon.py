#!/usr/bin/env python3
# Иконка папки «Интернет» (все кнопки семейства живут в ней). ПРИНЦИП: это должна быть
# УЗНАВАЕМАЯ папка macOS (не тёмный квадрат приложения!), поэтому базу берём из СИСТЕМНОЙ
# GenericFolderIcon и лишь ставим на неё фирменный значок семейства (зелёные дуги Wi-Fi +
# жёлтая точка). Так папка выглядит родной для macOS, но сразу видно, что внутри.
# Использование: сначала `sips -s format png <системная .icns> --out folder_base.png -z 1024 1024`,
# затем этот скрипт (см. кнопку установки в репо/CLAUDE.md).
from PIL import Image, ImageDraw

BASE = "folder_base.png"     # системная папка, уже сконвертированная в png 1024
OUT  = "folder_1024.png"

base = Image.open(BASE).convert("RGBA")
S = base.size[0]
scale = S / 1024.0
def sc(v): return int(round(v * scale))

# Рисуем значок в 4x на прозрачном слое и ужимаем — гладкие дуги без лесенки.
BS = S * 4
badge = Image.new("RGBA", (BS, BS), (0, 0, 0, 0))
d = ImageDraw.Draw(badge)
bscale = BS / 1024.0
def bsc(v): return int(round(v * bscale))

GREEN  = (46, 160, 100, 255)    # чуть темнее семейного — читаемо на светло-синей папке
YELLOW = (240, 185, 12, 255)

# Дуги Wi-Fi по центру тела папки (тело папки в системной иконке — нижние ~2/3).
cx, cy = bsc(512), bsc(700)
for r in (bsc(120), bsc(220), bsc(320)):
    d.arc([cx - r, cy - r, cx + r, cy + r], 212, 328, fill=GREEN, width=bsc(46))
dr = bsc(34)
d.ellipse([cx - dr, cy - dr, cx + dr, cy + dr], fill=YELLOW)   # жёлтая точка — акцент семейства

badge = badge.resize((S, S), Image.LANCZOS)
out = Image.alpha_composite(base, badge)
out.save(OUT)
print("ok:", OUT)
