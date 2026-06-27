#!/bin/bash
# Кнопка «Маршрут к ресурсу» (access). read-only, sudo НЕ нужен. Берёт ссылку из буфера/ввода,
# зовёт access --matrix (маршрут + история + рекомендация), потом даёт отметить РЕАЛЬНЫЙ исход
# в браузере (access --mark). Цикл: проверить → отметить → следующая. Терминал не нужен.
# Канон — access.command в репо; рабочая копия на ~/Desktop. ОБОЛОЧКА: core access не трогает.
#
# 17.1.2 UX hardening: домен без схемы → https://; невалидный ввод → переспрос (НЕ переход к метке);
# URL в поле метки трактуется как НОВАЯ проверка, а не «не понял».

AC="$HOME/bin/access.sh"
trim() { printf '%s' "${1:-}" | tr -d '\r\n' | sed 's/^ *//; s/ *$//'; }

# normalize_url <input> → печатает нормализованный URL в stdout, код: 0 валиден, 1 пусто, 2 мусор.
# Полный URL — как есть; голый домен (есть точка, нет пробела) → https://домен; иначе мусор.
normalize_url() {
    local u; u=$(trim "$1")
    [ -z "$u" ] && return 1
    case "$u" in http://*|https://*) printf '%s' "$u"; return 0 ;; esac
    case "$u" in *' '*) return 2 ;; esac
    case "${u%%/*}" in *.*) printf 'https://%s' "$u"; return 0 ;; *) return 2 ;; esac
}

# ask_url <prompt> <default> → печатает валидный URL (или default при пустом вводе). Повторяет
# при мусоре. Подсказку про домен/ошибку шлёт в stderr (видно в окне, не попадает в $()).
ask_url() {
    local prompt="$1" default="${2:-}" in norm rc
    while true; do
        printf '%s' "$prompt" >&2
        read -r in; in=$(trim "$in")
        [ -z "$in" ] && { printf '%s' "$default"; return 0; }
        norm=$(normalize_url "$in"); rc=$?
        if [ "$rc" -eq 0 ]; then
            case "$in" in http://*|https://*) : ;; *) printf '  Похоже на домен без схемы — проверяю: %s\n' "$norm" >&2 ;; esac
            printf '%s' "$norm"; return 0
        fi
        printf '  Нужен полный URL или домен вида example.com. Попробуй ещё раз.\n' >&2
    done
}

clear 2>/dev/null
printf '\n  ╭───────────────────────────────────────╮\n'
printf   '  │   Маршрут к ресурсу (через твой VPN)  │\n'
printf   '  ╰───────────────────────────────────────╯\n\n'

if [ ! -x "$AC" ]; then
    printf '  Не найден %s\n  Установи access: cp access.sh ~/bin/access.sh && chmod +x ~/bin/access.sh\n\n' "$AC"
    printf '  Enter — закрыть.'; read -r _; exit 1
fi

# --- первая ссылка (буфер либо ручной ввод), всегда нормализуем ---
CLIP=$(trim "$(pbpaste 2>/dev/null)")
case "$CLIP" in
    http://*|https://*)
        printf '  В буфере обмена нашлась ссылка:\n    %s\n\n' "$CLIP"
        URL=$(ask_url '  Enter — проверить её   ·   или вставь ДРУГУЮ ссылку (Cmd+V) и Enter:
  > ' "$CLIP") ;;
    *)
        URL=$(ask_url '  Скопируй ссылку на сервис (Gemini/Claude/…), вставь сюда (Cmd+V) и Enter:
  > ' "") ;;
esac
if [ -z "$URL" ]; then printf '\n  Ссылка не указана — закрываю.\n\n  Enter — закрыть.'; read -r _; exit 0; fi

# --- цикл: маршрут → метка исхода → следующая ссылка ---
while [ -n "$URL" ]; do
    printf '\n'
    "$AC" --matrix "$URL"
    printf '  Что в браузере?  o=открылось  r=регион-отказ  l=нужен вход  c=cloudflare  f=не работает  (Enter — пропустить)\n'
    printf '  · или вставь СЛЕДУЮЩУЮ ссылку, чтобы проверить её:\n  > '
    read -r MK; MK=$(trim "$MK")
    case "$MK" in
        o|O) "$AC" --mark browser-ok ;;
        r|R) "$AC" --mark region-fail ;;
        l|L) "$AC" --mark login-required ;;
        c|C) "$AC" --mark cloudflare-fail ;;
        f|F) "$AC" --mark fail ;;
        "")  : ;;
        http://*|https://*) printf '  Это новая ссылка — проверяю.\n'; URL="$MK"; continue ;;
        *' '*) printf '  (не понял «%s» — пропускаю метку)\n' "$MK" ;;
        *.*) URL="https://$MK"; printf '  Похоже на новую ссылку — проверяю: %s\n' "$URL"; continue ;;
        *)   printf '  (не понял «%s» — пропускаю метку)\n' "$MK" ;;
    esac
    URL=$(ask_url '
  Enter — закрыть   ·   или вставь ссылку, чтобы проверить ещё:
  > ' "")
done

printf '\n  Готово. Карта маршрутов копится — посмотреть: access --history\n'
