#!/bin/bash
# Кнопка «Маршрут к ресурсу» (access). read-only, sudo НЕ нужен. Берёт ссылку из буфера/ввода,
# зовёт access --matrix (текущий маршрут + история + рекомендация), потом даёт отметить РЕАЛЬНЫЙ
# исход в браузере (access --mark). Цикл: проверить → отметить → следующая. Терминал открывать
# не надо. Канон — access.command в репо; рабочая копия на ~/Desktop.

AC="$HOME/bin/access.sh"
trim() { printf '%s' "${1:-}" | tr -d '\r\n' | sed 's/^ *//; s/ *$//'; }

clear 2>/dev/null
printf '\n  ╭───────────────────────────────────────╮\n'
printf   '  │   Маршрут к ресурсу (через твой VPN)  │\n'
printf   '  ╰───────────────────────────────────────╯\n\n'

if [ ! -x "$AC" ]; then
    printf '  Не найден %s\n  Установи access: cp access.sh ~/bin/access.sh && chmod +x ~/bin/access.sh\n\n' "$AC"
    printf '  Enter — закрыть.'; read -r _; exit 1
fi

# Первая ссылка: из буфера обмена (если http/https) либо ручной ввод.
CLIP=$(trim "$(pbpaste 2>/dev/null)")
URL=""
case "$CLIP" in
    http://*|https://*)
        printf '  В буфере обмена нашлась ссылка:\n    %s\n\n' "$CLIP"
        printf '  Enter — проверить её   ·   или вставь ДРУГУЮ ссылку (Cmd+V) и Enter:\n  > '
        read -r T; T=$(trim "$T"); if [ -n "$T" ]; then URL="$T"; else URL="$CLIP"; fi ;;
    *)
        printf '  Скопируй ссылку на сервис (Gemini/Claude/…), вставь сюда (Cmd+V) и Enter:\n  > '
        read -r URL; URL=$(trim "$URL") ;;
esac
if [ -z "$URL" ]; then printf '\n  Ссылка не указана — закрываю.\n\n  Enter — закрыть.'; read -r _; exit 0; fi

# Цикл: маршрут → отметка исхода → следующая ссылка.
while [ -n "$URL" ]; do
    printf '\n'
    "$AC" --matrix "$URL"
    # отметить, что РЕАЛЬНО увидел в браузере (access сам этого не знает)
    printf '  Что в браузере?  o=открылось  r=регион-отказ  l=нужен вход  c=cloudflare   (Enter — пропустить): '
    read -r MK; MK=$(trim "$MK")
    case "$MK" in
        o|O|о|О) "$AC" --mark browser-ok ;;
        r|R|р|Р) "$AC" --mark region-fail ;;
        l|L|л|Л) "$AC" --mark login-required ;;
        c|C|с|С) "$AC" --mark cloudflare-fail ;;
        "")      : ;;
        *)       printf '  (не понял «%s» — пропускаю метку)\n' "$MK" ;;
    esac
    # следующая ссылка или закрыть
    printf '\n  Enter — закрыть   ·   или вставь ссылку, чтобы проверить ещё:\n  > '
    read -r NX; URL=$(trim "$NX")
done

printf '\n  Готово. Карта маршрутов копится — посмотреть: access --history\n'
