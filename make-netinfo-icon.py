#!/usr/bin/env python3
# Генератор иконки для netinfo.command — в стиле fixnet (тёмный скруглённый
# квадрат + зелёные дуги Wi-Fi), но с ЛУПОЙ вместо молнии: netinfo = осмотр.
# Палитра намеренно та же, что у fixnet (зелёные дуги + жёлтый акцент), чтобы
# две кнопки читались как одно семейство. Рисуем в 4x и ужимаем — ради сглаживания.
from PIL import Image, ImageDraw

S = 4096
img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
d = ImageDraw.Draw(img)

scale = S / 1024.0
def sc(v): return int(round(v * scale))

BG     = (32, 40, 58, 255)     # тёмный сланец, как фон fixnet
GREEN  = (79, 209, 139, 255)   # зелёные дуги Wi-Fi
YELLOW = (246, 201, 21, 255)   # жёлтый акцент (как молния у fixnet)

# Фон: скруглённый квадрат (corner radius ~0.225 — близко к "squircle" macOS).
d.rounded_rectangle([0, 0, S - 1, S - 1], radius=int(S * 0.225), fill=BG)

# Wi-Fi: три дуги-"шапки" над общей точкой (как сигнал). PIL: 0°=3ч, 90°=6ч.
cx, cy = sc(512), sc(760)
for r in (sc(180), sc(335), sc(490)):
    d.arc([cx - r, cy - r, cx + r, cy + r], 212, 328, fill=GREEN, width=sc(62))
dr = sc(48)
d.ellipse([cx - dr, cy - dr, cx + dr, cy + dr], fill=GREEN)  # точка-источник

# Лупа. Рисуем дважды: сначала тёмным "гало" (отделить от зелёных дуг),
# потом жёлтым поверх.
def magnifier(color, pad):
    rc = (sc(512), sc(440))     # центр стекла
    R = sc(168)                 # радиус кольца
    ring = sc(58) + pad
    d.ellipse([rc[0] - R, rc[1] - R, rc[0] + R, rc[1] + R], outline=color, width=ring)
    h1 = (rc[0] + int(R * 0.70), rc[1] + int(R * 0.70))   # от края кольца
    h2 = (sc(726), sc(690))                                # вниз-вправо
    w = sc(60) + pad
    d.line([h1, h2], fill=color, width=w)
    cap = w // 2                                           # круглые концы ручки
    for p in (h1, h2):
        d.ellipse([p[0] - cap, p[1] - cap, p[0] + cap, p[1] + cap], fill=color)

magnifier(BG, sc(20))   # тёмное гало
magnifier(YELLOW, 0)    # жёлтая лупа

img.resize((1024, 1024), Image.LANCZOS).save("netinfo_1024.png")
print("ok: netinfo_1024.png")
