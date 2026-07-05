#!/bin/bash
# Кнопка «Помощник» — ЕДИНАЯ точка входа для неспециалиста. Спрашивает ПО-ЧЕЛОВЕЧЕСКИ
# «что случилось?» и сама запускает нужный инструмент. Своей логики НЕ несёт — только
# маршрутизирует к существующим кнопкам (get/why/netinfo/fixnet). Канон — в репо fixnet,
# рабочая копия на ~/Desktop. Смысл: человек думает проблемами, а не именами скриптов.

DIR="$(cd "$(dirname "$0")" && pwd)"
BIN="$HOME/bin"

# Запустить кнопку-сестру, если есть; иначе — соответствующий .sh из ~/bin.
run_sibling() {  # $1 = имя кнопки без расширения, $2 = .sh-фолбэк (с аргументами)
    local cmd="$DIR/$1.command"
    if [ -x "$cmd" ]; then "$cmd"; else shift; "$@"; fi
}

# Ссылка из буфера/ввода (для «файл»/«сайт», если у кнопки-сестры нет своего запроса).
ask_url() {
    local clip typed
    clip=$(pbpaste 2>/dev/null | tr -d '\r\n' | sed 's/^ *//; s/ *$//')
    case "$clip" in
        http://*|https://*)
            printf '  В буфере ссылка:\n    %s\n  Enter — взять её · или вставь другую (Cmd+V):\n  > ' "$clip" >&2 ;;
        *) printf '  Вставь ссылку (Cmd+V) и Enter:\n  > ' >&2; clip="" ;;
    esac
    read -r typed; typed=$(printf '%s' "$typed" | tr -d '\r\n' | sed 's/^ *//; s/ *$//')
    [ -n "$typed" ] && printf '%s' "$typed" || printf '%s' "$clip"
}

while true; do
    clear 2>/dev/null
    printf '\n  ╭─────────────────────────────────────────────╮\n'
    printf   '  │        Помощник с интернетом                │\n'
    printf   '  ╰─────────────────────────────────────────────╯\n\n'
    printf '  Что случилось?\n\n'
    printf '    1  —  Интернет не работает или тормозит\n'
    printf '    2  —  Файл не скачивается (или качается вечно)\n'
    printf '    3  —  Сайт или сервис не открывается\n'
    printf '    4  —  Ничего не помогает — почини сеть\n'
    printf '           (это ремонт, спросит пароль)\n\n'
    printf '    Enter — выход\n\n'
    printf '  Твой выбор (1–4): '
    read -r ans; ans=$(printf '%s' "$ans" | tr -d '\r\n' | sed 's/^ *//; s/ *$//')

    case "$ans" in
        1)  # проверить связь — netinfo (у него своё человеческое меню)
            printf '\n  Смотрю, что со связью…\n'
            run_sibling netinfo "$BIN/netinfo.sh" ;;
        2)  # устойчивое скачивание — get.command (буфер, докачка, Finder)
            run_sibling get "$BIN/access.sh" --get "$(ask_url)" ;;
        3)  # почему не открывается — why.command
            run_sibling why "$BIN/netinfo.sh" --why "$(ask_url)" ;;
        4)  # ремонт — fixnet (нужен sudo)
            printf '\n  Запускаю ремонт сети. Может попросить пароль от Mac.\n'
            if [ -x "$DIR/fixnet.command" ]; then "$DIR/fixnet.command"; else sudo "$BIN/fixnet.sh"; fi ;;
        ""|q|Q|exit|выход)
            printf '\n  Пока! Если что — жми эту кнопку снова.\n\n'; exit 0 ;;
        *)  printf '\n  Не понял «%s». Нажми 1, 2, 3 или 4.\n' "$ans" ;;
    esac

    printf '\n  ──────────────────────────────────────────────\n'
    printf '  Enter — вернуться в меню · закрой окно, чтобы выйти: '
    read -r _
done
