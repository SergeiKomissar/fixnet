#!/bin/bash
# access.sh — «access router» (Фаза 17.0). ЧЕТВЁРТЫЙ слой поверх netinfo/why:
#   netinfo — что со связью · fixnet — чинит локальное · why — почему URL не идёт ·
#   access  — выбирает рабочий ДОВЕРЕННЫЙ маршрут (твои уже настроенные VPN-каналы).
#
# ГРАНИЦЫ (жёстко, не нарушать):
#   - НЕ тащит чужие публичные VPN-конфиги, НЕ подбирает мутные прокси;
#   - НЕ встраивает DPI-desync/обфускацию (это не наш продукт — fixnet чинит, не обходит);
#   - НЕ обещает «обход гарантирован»;
#   - НЕ ломает систему без подтверждения; переключение (будущее --switch) — только штатное
#     и только то, чем РЕАЛЬНО можно управлять из shell (Tailscale exit-node / WireGuard).
#   - источник правды по СЛОЯМ отказа URL — why_report в netinfo; access его НЕ дублирует.
#
# Фаза 17.0 — ТОЛЬКО read-only инвентарь: чем можно управлять, а что лишь диагностировать.
set -u

R=$'\033[0;31m'; G=$'\033[0;32m'; Y=$'\033[0;33m'; B=$'\033[0;34m'; C=$'\033[0;36m'; D=$'\033[2m'; N=$'\033[0m'

# Человеческое имя страны для частых VPN-выходов (код -> имя). Остальное — как есть (код).
country_name() {
    case "$1" in
        AT) echo "Австрия" ;; BE) echo "Бельгия" ;; DE) echo "Германия" ;; NL) echo "Нидерланды" ;;
        US) echo "США" ;;     GB|UK) echo "Великобритания" ;; FR) echo "Франция" ;; FI) echo "Финляндия" ;;
        SE) echo "Швеция" ;;  CH) echo "Швейцария" ;; TR) echo "Турция" ;; RU) echo "Россия" ;;
        PL) echo "Польша" ;;  ES) echo "Испания" ;; IT) echo "Италия" ;; *) echo "$1" ;;
    esac
}

# Найти Tailscale CLI (в PATH или внутри .app).
tailscale_bin() {
    local p
    for p in tailscale /usr/local/bin/tailscale /Applications/Tailscale.app/Contents/MacOS/Tailscale; do
        command -v "$p" >/dev/null 2>&1 && { printf '%s' "$p"; return 0; }
    done
    return 1
}

# Текущий внешний выход (страна/провайдер/IP) — одна HTTPS-проба, как в netinfo --why.
current_exit() {
    command -v curl >/dev/null 2>&1 || { echo ""; return; }
    local j; j=$(curl -s --connect-timeout 4 --max-time 6 "https://ipinfo.io/json" 2>/dev/null)
    [ -z "$j" ] && { echo ""; return; }
    printf '%s' "$j" | python3 -c 'import sys,json
d=json.load(sys.stdin); print("%s\t%s\t%s"%(d.get("country","") or "", d.get("org","") or "", d.get("ip","") or ""))' 2>/dev/null
}

vpn_inventory() {
    echo
    echo -e "${B}=== ACCESS — инвентарь VPN-каналов (read-only) ===${N}"

    # --- текущий выход ---
    local cx cc org ip
    cx=$(current_exit); cc=$(printf '%s' "$cx" | cut -f1); org=$(printf '%s' "$cx" | cut -f2); ip=$(printf '%s' "$cx" | cut -f3)
    if [ -n "$cc" ]; then
        echo -e "  Текущий выход:   ${C}$(country_name "$cc")${N} ${D}· ${org} · ${ip}${N}"
    else
        echo -e "  Текущий выход:   ${D}не удалось определить${N}"
    fi
    # активен ли full-tunnel VPN (default route на utun)
    local extdev=""
    extdev=$(route -n get 1.1.1.1 2>/dev/null | awk '/interface:/{print $2}')
    case "$extdev" in utun*) echo -e "  VPN-выход:       ${G}активен${N} ${D}(маршрут через ${extdev})${N}" ;;
                      *)     echo -e "  VPN-выход:       ${D}не обнаружен (выход напрямую)${N}" ;; esac
    echo

    # --- что УПРАВЛЯЕМО из shell (можно автоматизировать переключение) ---
    echo -e "  ${D}Управляемые из shell (кандидаты на авто-переключение):${N}"
    local automatable=0
    local ts; ts=$(tailscale_bin) || ts=""
    if [ -n "$ts" ]; then
        local exits; exits=$("$ts" exit-node list 2>/dev/null | grep -E '^[0-9]' | grep -v 'No exit nodes' | wc -l | tr -d ' ')
        if [ "${exits:-0}" -ge 1 ]; then
            echo -e "    Tailscale:     ${G}CLI есть, exit-node настроены (${exits})${N} ${D}→ можно переключать выход${N}"; automatable=1
        else
            echo -e "    Tailscale:     ${Y}CLI есть, но exit-node не настроены${N} ${D}→ переключать выход нечем (split-VPN, внешний IP не меняет)${N}"
        fi
    else
        echo -e "    Tailscale:     ${D}CLI не найден${N}"
    fi
    if command -v wg-quick >/dev/null 2>&1 || command -v wg >/dev/null 2>&1; then
        local wgc; wgc=$(ls /etc/wireguard/*.conf 2>/dev/null | wc -l | tr -d ' ')
        if [ "${wgc:-0}" -ge 1 ]; then echo -e "    WireGuard:     ${G}wg-quick + ${wgc} профил.${N} ${D}→ можно поднимать туннели${N}"; automatable=1
        else echo -e "    WireGuard:     ${Y}wg есть, но профилей .conf нет${N}"; fi
    else
        echo -e "    WireGuard:     ${D}нет (wg/wg-quick не найдены)${N}"
    fi
    command -v openvpn >/dev/null 2>&1 \
        && { echo -e "    OpenVPN CLI:   ${Y}есть${N} ${D}(запуск .ovpn возможен, но хрупко)${N}"; } \
        || echo -e "    OpenVPN CLI:   ${D}нет${N}"
    echo

    # --- что ТОЛЬКО ДИАГНОСТИРУЕМ (переключение — вручную в приложении) ---
    echo -e "  ${D}Только GUI (переключение — вручную в приложении):${N}"
    local procs; procs=$(ps -axo comm 2>/dev/null)
    case "$procs" in *ExpressVPN*) echo -e "    ExpressVPN:    ${C}приложение активно${N} ${D}· CLI нет → страну/сервер выбираешь в app${N}" ;; esac
    case "$procs" in *hidemy*|*hidemyname*) echo -e "    HideMyName:    ${C}приложение активно${N} ${D}· OpenVPN NE, CLI нет → выбираешь в app${N}" ;; esac
    # NE-VPN сервисы из scutil (app-based full-tunnel), которых нет среди управляемых
    scutil --nc list 2>/dev/null | grep -i 'connected' | grep -viE 'tailscale' | sed -E 's/.*"([^"]*)".*/    NE-VPN:        \1/' | head -3
    echo

    # --- вывод ---
    if [ "$automatable" -eq 1 ]; then
        echo -e "  Вывод: ${G}есть управляемый из shell канал — авто-переключение маршрута возможно (Фаза 17.2).${N}"
    else
        echo -e "  Вывод: ${Y}авто-переключение маршрута сейчас недоступно.${N}"
        echo -e "  ${D}Коммерческие VPN (ExpressVPN/HideMyName) — только GUI; Tailscale без exit-node.${N}"
        echo -e "  ${D}access сможет ДИАГНОСТИРОВАТЬ маршрут и СОВЕТОВАТЬ страну/сервер (Фаза 17.1),${N}"
        echo -e "  ${D}но переключать VPN придётся вручную в приложении.${N}"
        echo -e "  ${D}Чтобы включить авто-переключение: настрой Tailscale exit-node или WireGuard-профили.${N}"
    fi
    echo
}

case "${1:-}" in
    --vpn-inventory|"") vpn_inventory ;;
    -h|--help)
        echo "access — выбор рабочего доверенного маршрута (слой поверх netinfo/why)."
        echo "  access --vpn-inventory   чем можно управлять из shell, что лишь диагностировать (read-only)"
        echo "  (в разработке) access --matrix URL    проверить URL через доступные маршруты"
        ;;
    *) echo "Неизвестная команда: $1 (см. access --help)" >&2; exit 2 ;;
esac
