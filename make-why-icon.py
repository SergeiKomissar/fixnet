#!/usr/bin/env python3
# Генератор иконки для why.command — в ОДНОМ семействе с fixnet/netinfo
# (тёмный скруглённый квадрат + зелёные дуги Wi-Fi), но вместо молнии/лупы —
# жёлтый знак «?»: why = «почему не открывается». Палитра та же, чтобы три
# кнопки читались как одно семейство. Рисуем в 4x и ужимаем — ради сглаживания.
from PIL import Image, ImageDraw, ImageFont
import os

S = 4096
img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
d = ImageDraw.Draw(img)

scale = S / 1024.0
def sc(v): return int(round(v * scale))

BG     = (32, 40, 58, 255)     # тёмный сланец, как фон fixnet/netinfo
GREEN  = (79, 209, 139, 255)   # зелёные дуги Wi-Fi
YELLOW = (246, 201, 21, 255)   # жёлтый акцент (как молния у fixnet, лупа у netinfo)

# Фон: скруглённый квадрат (corner radius ~0.225 — близко к "squircle" macOS).
d.rounded_rectangle([0, 0, S - 1, S - 1], radius=int(S * 0.225), fill=BG)

# Wi-Fi: три дуги-"шапки" над общей точкой (семейный мотив). PIL: 0°=3ч, 90°=6ч.
cx, cy = sc(512), sc(772)
for r in (sc(180), sc(335), sc(490)):
    d.arc([cx - r, cy - r, cx + r, cy + r], 212, 328, fill=GREEN, width=sc(62))
dr = sc(48)
d.ellipse([cx - dr, cy - dr, cx + dr, cy + dr], fill=GREEN)  # точка-источник

# Знак вопроса. SF Rounded (скруглён — в тон squircle и дугам); если нет —
# Arial Bold. Жирность добиваем обводкой (stroke), не полагаясь на вес шрифта.
def load_font(size):
    for path, variations in [
        ("/System/Library/Fonts/SFNSRounded.ttf", ["Heavy", "Black", "Bold"]),
        ("/System/Library/Fonts/SFNS.ttf",        ["Heavy", "Black", "Bold"]),
        ("/System/Library/Fonts/Supplemental/Arial Bold.ttf", None),
    ]:
        if not os.path.exists(path):
            continue
        try:
            f = ImageFont.truetype(path, size)
            if variations:
                for v in variations:
                    try:
                        f.set_variation_by_name(v); break
                    except Exception:
                        pass
            return f
        except Exception:
            pass
    return ImageFont.load_default()

ch = "?"
font = load_font(sc(620))
halo = sc(30)   # тёмное гало — отделяет жёлтый «?» от зелёных дуг в местах пересечения
fat  = sc(16)   # доводим до «жирного» независимо от веса шрифта

# Центрируем глиф по (512, 430) в координатах 1024 (верхняя зона, как лупа у netinfo).
bbox = d.textbbox((0, 0), ch, font=font, stroke_width=halo)
gw, gh = bbox[2] - bbox[0], bbox[3] - bbox[1]
tx = sc(512) - (bbox[0] + gw / 2.0)
ty = sc(430) - (bbox[1] + gh / 2.0)

# 1) тёмное гало (на фоне невидимо, на зелёных дугах — отделяющий контур);
d.text((tx, ty), ch, font=font, fill=BG, stroke_width=halo, stroke_fill=BG)
# 2) жёлтый «?» поверх, слегка утолщённый.
d.text((tx, ty), ch, font=font, fill=YELLOW, stroke_width=fat, stroke_fill=YELLOW)

img.resize((1024, 1024), Image.LANCZOS).save("why_1024.png")
print("ok: why_1024.png")
