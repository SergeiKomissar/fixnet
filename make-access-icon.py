#!/usr/bin/env python3
# Генератор иконки для access.command — в ОДНОМ семействе с fixnet/netinfo/why
# (тёмный скруглённый квадрат + зелёные дуги Wi-Fi), но мотив — МАРШРУТ: жёлтый путь
# из узлов (выбор рабочего маршрута к ресурсу). Палитра та же. Рисуем в 4x и ужимаем.
from PIL import Image, ImageDraw

S = 4096
img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
d = ImageDraw.Draw(img)
scale = S / 1024.0
def sc(v): return int(round(v * scale))

BG     = (32, 40, 58, 255)     # тёмный сланец, как у семьи
GREEN  = (79, 209, 139, 255)   # зелёные дуги Wi-Fi
YELLOW = (246, 201, 21, 255)   # жёлтый акцент

d.rounded_rectangle([0, 0, S - 1, S - 1], radius=int(S * 0.225), fill=BG)

# Wi-Fi: три дуги-«шапки» над общей точкой (семейный мотив). PIL: 0°=3ч, 90°=6ч.
cx, cy = sc(512), sc(772)
for r in (sc(180), sc(335), sc(490)):
    d.arc([cx - r, cy - r, cx + r, cy + r], 212, 328, fill=GREEN, width=sc(62))
dr = sc(48)
d.ellipse([cx - dr, cy - dr, cx + dr, cy + dr], fill=GREEN)

# МАРШРУТ: ломаная из трёх узлов, идущая вверх-вправо (выбор пути к ресурсу).
# Рисуем дважды: тёмное гало (отделить от дуг) → жёлтый поверх.
PTS = [(sc(372), sc(560)), (sc(512), sc(408)), (sc(664), sc(318))]
def route(color, pad):
    w = sc(46) + pad
    for i in range(len(PTS) - 1):
        d.line([PTS[i], PTS[i + 1]], fill=color, width=w)
    nr = sc(50) + pad
    for i, p in enumerate(PTS):
        d.ellipse([p[0] - nr, p[1] - nr, p[0] + nr, p[1] + nr], fill=color)
    # конечный узел (цель) — кольцо: рисуем дырку фоном поверх жёлтого (только во 2-м проходе)
    if pad == 0:
        last = PTS[-1]; hr = sc(20)
        d.ellipse([last[0] - hr, last[1] - hr, last[0] + hr, last[1] + hr], fill=BG)

route(BG, sc(22))   # тёмное гало
route(YELLOW, 0)    # жёлтый маршрут

img.resize((1024, 1024), Image.LANCZOS).save("access_1024.png")
print("ok: access_1024.png")
