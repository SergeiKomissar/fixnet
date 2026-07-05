#!/usr/bin/env python3
# Генератор иконки для get.command — в ОДНОМ семействе с fixnet/netinfo/why/access
# (тёмный squircle + зелёные дуги Wi-Fi), мотив — ЖЁЛТАЯ СТРЕЛКА ЗАГРУЗКИ вниз на
# полку-«лоток»: get = «устойчиво скачать файл». Палитра та же. Рисуем 4x и ужимаем.
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

# Wi-Fi: три дуги-«шапки» над общей точкой (семейный мотив).
cx, cy = sc(512), sc(772)
for r in (sc(180), sc(335), sc(490)):
    d.arc([cx - r, cy - r, cx + r, cy + r], 212, 328, fill=GREEN, width=sc(62))
dr = sc(48)
d.ellipse([cx - dr, cy - dr, cx + dr, cy + dr], fill=GREEN)

# Стрелка загрузки (вниз) + полка-лоток. Рисуем ДВАЖДЫ: тёмное гало (отделить от дуг),
# затем жёлтое поверх. Координаты в 1024-пространстве, центр по x=512, верхняя зона.
def download(color, pad):
    # стержень
    d.rounded_rectangle([sc(512) - sc(40) - pad, sc(250) - pad,
                         sc(512) + sc(40) + pad, sc(452) + pad],
                        radius=sc(20) + pad, fill=color)
    # наконечник (треугольник вниз), расширяем от центроида на pad
    tip = (sc(512), sc(560)); lft = (sc(396), sc(410)); rgt = (sc(628), sc(410))
    if pad:
        gx = (tip[0] + lft[0] + rgt[0]) / 3.0; gy = (tip[1] + lft[1] + rgt[1]) / 3.0
        def out(p):
            dx, dy = p[0] - gx, p[1] - gy; n = (dx * dx + dy * dy) ** 0.5 or 1
            return (p[0] + dx / n * pad * 1.6, p[1] + dy / n * pad * 1.6)
        tip, lft, rgt = out(tip), out(lft), out(rgt)
    d.polygon([tip, lft, rgt], fill=color)
    # полка-«лоток» под стрелкой (куда падает файл)
    d.rounded_rectangle([sc(372) - pad, sc(612) - pad, sc(652) + pad, sc(656) + pad],
                        radius=sc(22) + pad, fill=color)

download(BG, sc(26))   # тёмное гало
download(YELLOW, 0)    # жёлтая стрелка загрузки

img.resize((1024, 1024), Image.LANCZOS).save("get_1024.png")
print("ok: get_1024.png")
