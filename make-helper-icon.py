#!/usr/bin/env python3
# Генератор иконки для Помощник.command — ОДНО семейство с fixnet/netinfo/why/access/get
# (тёмный скруглённый квадрат + зелёные дуги Wi-Fi). Мотив — СПАСАТЕЛЬНЫЙ КРУГ (жёлтый):
# универсальный символ «помощь», читается даже в мелком размере. Рисуем в 4x и ужимаем.
import math
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

# Wi-Fi: три дуги над общей точкой (семейный мотив; координаты как у access/why).
cx, cy = sc(512), sc(772)
for r in (sc(180), sc(335), sc(490)):
    d.arc([cx - r, cy - r, cx + r, cy + r], 212, 328, fill=GREEN, width=sc(62))
dr = sc(48)
d.ellipse([cx - dr, cy - dr, cx + dr, cy + dr], fill=GREEN)

# СПАСАТЕЛЬНЫЙ КРУГ: жёлтое кольцо с 4 тёмными насечками (как сегменты буя).
# Тёмное гало вокруг — отделяет круг от зелёных дуг (тот же приём, что у «?» на why).
bx, by = sc(512), sc(400)      # центр буя — в верхней трети, над дугами
ro, ri = sc(168), sc(84)       # внешний/внутренний радиус кольца
halo = sc(26)
d.ellipse([bx - ro - halo, by - ro - halo, bx + ro + halo, by + ro + halo], fill=BG)
d.ellipse([bx - ro, by - ro, bx + ro, by + ro], fill=YELLOW)
d.ellipse([bx - ri, by - ri, bx + ri, by + ri], fill=BG)
for ang in (45, 135, 225, 315):   # насечки по диагоналям — силуэт буя, а не «бублик»
    a = math.radians(ang)
    x1 = bx + math.cos(a) * ri * 0.85; y1 = by + math.sin(a) * ri * 0.85
    x2 = bx + math.cos(a) * (ro + halo * 0.5); y2 = by + math.sin(a) * (ro + halo * 0.5)
    d.line([(x1, y1), (x2, y2)], fill=BG, width=sc(40))

img.resize((1024, 1024), Image.LANCZOS).save("helper_1024.png")
print("ok: helper_1024.png")
