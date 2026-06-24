#!/bin/bash
# Кнопка «Почему не открывается?» — диагностика КОНКРЕТНОЙ ссылки через netinfo --why.
# read-only: sudo НЕ нужен (в отличие от netinfo/fixnet — там root ради точности/ремонта).
# Берёт ссылку из БУФЕРА ОБМЕНА (ты только что её скопировал) или просит вставить.
# Канонический исходник — в репозитории fixnet; рабочая копия живёт на ~/Desktop.

NI="$HOME/bin/netinfo.sh"

clear 2>/dev/null
printf '\n  ╭───────────────────────────────────────╮\n'
printf   '  │   Почему не открывается ресурс?       │\n'
printf   '  ╰───────────────────────────────────────╯\n\n'

if [ ! -x "$NI" ]; then
    printf '  Не найден %s\n  Переустанови netinfo (cp netinfo.sh ~/bin/ && chmod +x ~/bin/netinfo.sh).\n\n' "$NI"
    printf '  Enter — закрыть.'; read -r _; exit 1
fi

# Ссылка из буфера обмена? (trim + срез переводов строк)
CLIP=$(pbpaste 2>/dev/null | tr -d '\r\n' | sed 's/^ *//; s/ *$//')
URL=""
case "$CLIP" in
    http://*|https://*)
        printf '  В буфере обмена нашлась ссылка:\n    %s\n\n' "$CLIP"
        printf '  Enter — проверить её   ·   или вставь ДРУГУЮ ссылку (Cmd+V) и Enter:\n  > '
        read -r TYPED
        if [ -n "$TYPED" ]; then URL="$TYPED"; else URL="$CLIP"; fi ;;
    *)
        printf '  Скопируй ссылку на файл/сайт, вставь сюда (Cmd+V) и нажми Enter:\n  > '
        read -r URL ;;
esac

URL=$(printf '%s' "${URL:-}" | tr -d '\r\n' | sed 's/^ *//; s/ *$//')
if [ -z "$URL" ]; then
    printf '\n  Ссылка не указана — закрываю.\n\n  Enter — закрыть.'; read -r _; exit 0
fi

printf '\n'
"$NI" --why "$URL"

printf '  Нажми Enter, чтобы закрыть.'
read -r _
