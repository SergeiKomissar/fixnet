#!/bin/bash
#
# deploy.sh — синхронизирует канонические скрипты из репозитория в рабочие копии
# ~/bin/, которые запускают кнопки (Dock/рабочий стол). Канон живёт под git в
# ~/projects/fixnet, а кнопки зовут ~/bin/*.sh.
#
# ЗАЧЕМ (реальный инцидент, породивший этот скрипт): ~/bin/fixnet.sh однажды отстал
# от репозитория на ~500 строк — потерял ВЕСЬ DNS-ремонт (--dns, --wifi-reset,
# эскалацию Фазы 15.0), потому что синхронизация держалась «на памяти»: поправил в
# репо, забыл скопировать — кнопка гоняла старую версию. Этот скрипт закрывает дыру.
#
# ЧТО ДЕЛАЕТ: для каждого скрипта — проверка (шебанг + bash -n) и копия ТОЛЬКО при
# отличии. Ничего не удаляет, не трогает совпадающее, не требует root.
#
# Использование:
#   ./deploy.sh           # синхронизировать всё, что разошлось
#   ./deploy.sh --check   # только показать расхождения (ничего не писать)
#
set -u

REPO="$(cd "$(dirname "$0")" && pwd)"
DST_DIR="$HOME/bin"
CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1

# Канонические скрипты, которые запускаются из ~/bin (кнопками и из терминала).
SCRIPTS="netlib.sh fixnet.sh netinfo.sh access.sh"

mkdir -p "$DST_DIR"
changed=0
errors=0

for f in $SCRIPTS; do
    src="$REPO/$f"
    dst="$DST_DIR/$f"

    if [ ! -f "$src" ]; then
        echo "  пропуск  $f — нет в репозитории"
        continue
    fi
    # Шебанг — минимальная защита от копирования случайного файла в ~/bin.
    if ! head -1 "$src" | grep -q '^#!'; then
        echo "  ОШИБКА   $f — нет шебанга в первой строке, пропускаю"
        errors=$((errors + 1)); continue
    fi
    # Синтаксис: сломанный скрипт в ~/bin/ хуже старого рабочего.
    if ! bash -n "$src" 2>/dev/null; then
        echo "  ОШИБКА   $f — синтаксическая ошибка, пропускаю:"
        bash -n "$src"
        errors=$((errors + 1)); continue
    fi

    if [ -f "$dst" ] && cmp -s "$src" "$dst"; then
        echo "  =        $f — уже синхронен"
        continue
    fi

    note=""
    [ -f "$dst" ] && note="($(diff "$src" "$dst" 2>/dev/null | grep -c '^[<>]') строк разошлось)" || note="(нет в ~/bin — первая установка)"
    changed=$((changed + 1))

    if [ "$CHECK" -eq 1 ]; then
        echo "  ≠        $f — РАЗОШЁЛСЯ $note   [--check: не пишу]"
    else
        if cp "$src" "$dst" && chmod +x "$dst"; then
            echo "  ✔        $f — обновлён $note"
        else
            echo "  ОШИБКА   $f — не удалось записать $dst"
            errors=$((errors + 1))
        fi
    fi
done

echo
if [ "$errors" -gt 0 ]; then
    echo "Завершено с ошибками: $errors. Смотри вывод выше." >&2
    exit 1
fi
if [ "$CHECK" -eq 1 ]; then
    if [ "$changed" -eq 0 ]; then echo "Всё синхронно ✅"; else echo "Разошлось: $changed. Запусти ./deploy.sh (без --check), чтобы обновить."; fi
else
    if [ "$changed" -eq 0 ]; then echo "Всё уже было синхронно ✅"; else echo "Синхронизировано: $changed ✅"; fi
fi
