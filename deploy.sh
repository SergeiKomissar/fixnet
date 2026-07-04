#!/bin/bash
#
# deploy.sh — копирует канонический fixnet.sh из репозитория в рабочую копию
# ~/bin/, которую запускает кнопка в Dock.
#
# Зачем: канон живёт в ~/projects/fixnet (под git), а кнопка запускает
# ~/bin/fixnet.sh. Без этого скрипта синхронизация держится на памяти —
# «поправил в репозитории, забыл скопировать, кнопка гоняет старую версию».
#
# Использование: ./deploy.sh   (из папки репозитория)
#
set -u

SRC="$(cd "$(dirname "$0")" && pwd)/fixnet.sh"
DST="$HOME/bin/fixnet.sh"

# Проверяем, что исходник существует и это наш скрипт, а не что-то случайное.
if [ ! -f "$SRC" ]; then
    echo "ОШИБКА: не найден $SRC" >&2
    exit 1
fi
if ! head -5 "$SRC" | grep -q "fixnet.sh"; then
    echo "ОШИБКА: $SRC не похож на fixnet.sh (нет сигнатуры в шапке)" >&2
    exit 1
fi

# Синтаксис-проверка перед деплоем: сломанный скрипт в ~/bin/ хуже старого.
if ! bash -n "$SRC" 2>/dev/null; then
    echo "ОШИБКА: синтаксическая ошибка в $SRC — деплой отменён" >&2
    bash -n "$SRC"   # показать саму ошибку
    exit 1
fi

mkdir -p "$HOME/bin"
cp "$SRC" "$DST"
chmod +x "$DST"

echo "OK: задеплоено $SRC -> $DST"
echo "Версия (первая строка diff с git HEAD, если есть git):"
if command -v git >/dev/null 2>&1 && git -C "$(dirname "$SRC")" rev-parse --short HEAD 2>/dev/null; then
    :
fi
