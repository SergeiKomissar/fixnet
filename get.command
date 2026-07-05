#!/bin/bash
# Кнопка «Скачать устойчиво» — качает файл/ссылку через access --get: докачка с обрыва,
# ретраи, зеркала, MTU-подсказка. Для слабого интернета и «файл не скачивается».
# read-only для системы: sudo НЕ нужен (пишет ТОЛЬКО сам файл в ~/Downloads).
# Берёт ссылку из БУФЕРА ОБМЕНА (ты только что скопировал) или просит вставить, и ПОСЛЕ
# скачивания предлагает открыть папку и скачать ещё одну. Канон — в репозитории fixnet;
# рабочая копия живёт на ~/Desktop. ОБОЛОЧКА: своей логики скачивания не несёт (только access --get).

AC="$HOME/bin/access.sh"
trim() { printf '%s' "${1:-}" | tr -d '\r\n' | sed 's/^ *//; s/ *$//'; }

clear 2>/dev/null
printf '\n  ╭───────────────────────────────────────╮\n'
printf   '  │   Скачать файл (устойчиво)            │\n'
printf   '  ╰───────────────────────────────────────╯\n\n'

if [ ! -x "$AC" ]; then
    printf '  Не найден %s\n  Переустанови access (cp access.sh ~/bin/ && chmod +x ~/bin/access.sh).\n\n' "$AC"
    printf '  Enter — закрыть.'; read -r _; exit 1
fi

# Первая ссылка: из буфера обмена (если там http/https) либо ручной ввод.
CLIP=$(trim "$(pbpaste 2>/dev/null)")
URL=""
case "$CLIP" in
    http://*|https://*)
        printf '  В буфере обмена нашлась ссылка:\n    %s\n\n' "$CLIP"
        printf '  Enter — скачать её   ·   или вставь ДРУГУЮ ссылку (Cmd+V) и Enter:\n  > '
        read -r TYPED; TYPED=$(trim "$TYPED")
        if [ -n "$TYPED" ]; then URL="$TYPED"; else URL="$CLIP"; fi ;;
    *)
        printf '  Скопируй ссылку на файл, вставь сюда (Cmd+V) и нажми Enter:\n  > '
        read -r URL; URL=$(trim "$URL") ;;
esac

if [ -z "$URL" ]; then
    printf '\n  Ссылка не указана — закрываю.\n\n  Enter — закрыть.'; read -r _; exit 0
fi

# Цикл: скачиваем → предлагаем открыть папку и/или скачать ещё → пусто = закрыть.
while [ -n "$URL" ]; do
    printf '\n'
    OUT=$("$AC" --get "$URL" | tee /dev/tty | sed -n 's/^  Готово: *//p' | tail -1)
    # Если файл скачался — предложить показать его в Finder.
    if [ -n "$OUT" ]; then
        # убрать хвост «(размер)» из строки «Готово: /путь (10.0 МБ)»
        FILE=$(printf '%s' "$OUT" | sed -E 's/ \([^)]*\)$//')
        printf '  o — открыть папку с файлом   ·   Enter/ссылка — дальше\n  > '
    else
        printf '  Enter — закрыть   ·   или вставь ДРУГУЮ ссылку (Cmd+V) — скачать ещё:\n  > '
    fi
    read -r NEXT; NEXT=$(trim "$NEXT")
    case "$NEXT" in
        o|O) [ -n "${FILE:-}" ] && open -R "$FILE" 2>/dev/null
             printf '  Enter — закрыть   ·   или вставь ссылку — скачать ещё:\n  > '
             read -r NEXT; NEXT=$(trim "$NEXT") ;;
    esac
    URL="$NEXT"
done

printf '\n  Готово. Файлы — в папке «Загрузки». Хорошего дня!\n'
