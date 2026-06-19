#!/bin/bash
# Лаунчер: двойной клик открывает Терминал и запускает fixnet.sh с правами root.
clear
echo "=== FIXNET — реаниматор сети ==="
echo
sudo "$HOME/bin/fixnet.sh"
echo
echo "Готово. Окно можно закрыть (Cmd-W)."
