#!/bin/bash
# access.sh — «access router» (Фазы 17.0–17.1). ЧЕТВЁРТЫЙ слой поверх netinfo/why:
#   netinfo — что со связью · fixnet — чинит локальное · why — почему URL не идёт ·
#   access  — выбирает рабочий ДОВЕРЕННЫЙ маршрут (твои уже настроенные VPN-каналы).
#
# ГРАНИЦЫ (жёстко, не нарушать):
#   - НЕ тащит чужие публичные VPN-конфиги, НЕ подбирает мутные прокси;
#   - НЕ встраивает DPI-desync/обфускацию (это не наш продукт — fixnet чинит, не обходит);
#   - НЕ обещает «обход гарантирован»; НЕ переключает VPN сам (17.1 только советует);
#   - источник правды по СЛОЯМ отказа URL — why_report в netinfo; access его НЕ дублирует,
#     а зовёт `netinfo --why-class` (машинный выход) и оркестрирует МАРШРУТЫ.
#   - ПРИВАТНОСТЬ: в историю пишем host + url_hash (sha256, срез), а НЕ полный URL.
set -u

R=$'\033[0;31m'; G=$'\033[0;32m'; Y=$'\033[0;33m'; B=$'\033[0;34m'; C=$'\033[0;36m'; D=$'\033[2m'; N=$'\033[0m'

STATE_DIR="$HOME/Library/Application Support/netinfo"
MATRIX="$STATE_DIR/access-matrix.jsonl"
ensure_state() { [ -d "$STATE_DIR" ] || mkdir -p "$STATE_DIR" 2>/dev/null; }

country_name() {
    case "$1" in
        AT) echo "Австрия" ;; BE) echo "Бельгия" ;; DE) echo "Германия" ;; NL) echo "Нидерланды" ;;
        US) echo "США" ;;     GB|UK) echo "Великобритания" ;; FR) echo "Франция" ;; FI) echo "Финляндия" ;;
        SE) echo "Швеция" ;;  CH) echo "Швейцария" ;; TR) echo "Турция" ;; RU) echo "Россия" ;;
        PL) echo "Польша" ;;  ES) echo "Испания" ;; IT) echo "Италия" ;; "") echo "?" ;; *) echo "$1" ;;
    esac
}

netinfo_bin() {
    local p; for p in "$HOME/bin/netinfo.sh" netinfo; do command -v "$p" >/dev/null 2>&1 && { printf '%s' "$p"; return 0; }; done
    return 1
}
tailscale_bin() {
    local p; for p in tailscale /usr/local/bin/tailscale /Applications/Tailscale.app/Contents/MacOS/Tailscale; do
        command -v "$p" >/dev/null 2>&1 && { printf '%s' "$p"; return 0; }; done
    return 1
}

# Текущий выход: country\tcity\torg\tip (одна HTTPS-проба ipinfo).
current_exit() {
    command -v curl >/dev/null 2>&1 || { echo ""; return; }
    local j; j=$(curl -s --connect-timeout 4 --max-time 6 "https://ipinfo.io/json" 2>/dev/null)
    [ -z "$j" ] && { echo ""; return; }
    printf '%s' "$j" | python3 -c 'import sys,json
d=json.load(sys.stdin); print("%s\t%s\t%s\t%s"%(d.get("country","") or "",d.get("city","") or "",d.get("org","") or "",d.get("ip","") or ""))' 2>/dev/null
}

# Нормализация пути для приватности: raw|file|root|app (полный URL в историю НЕ пишем).
path_class() {
    local u="$1" host path
    host=$(printf '%s' "$u" | sed -E 's#^[a-z]+://##; s#[:/].*$##')
    path=$(printf '%s' "$u" | sed -E 's#^[a-z]+://[^/]*##; s#\?.*$##')
    case "$host" in raw.*) echo raw; return ;; esac
    case "$path" in */raw/*) echo raw; return ;; esac
    case "$path" in *.pdf|*.zip|*.dmg|*.png|*.jpg|*.jpeg|*.mp4|*.gz|*.tar|*.exe|*.bin|*.iso|*.csv|*.docx|*.xlsx|*.pptx) echo file; return ;; esac
    case "$path" in ""|/) echo root; return ;; esac
    echo app
}

# ---------- Фаза 17.0: инвентарь ----------
vpn_inventory() {
    echo
    echo -e "${B}=== ACCESS — инвентарь VPN-каналов (read-only) ===${N}"
    local cx cc city org ip
    cx=$(current_exit); cc=$(printf '%s' "$cx"|cut -f1); city=$(printf '%s' "$cx"|cut -f2)
    org=$(printf '%s' "$cx"|cut -f3); ip=$(printf '%s' "$cx"|cut -f4)
    if [ -n "$cc" ]; then echo -e "  Текущий выход:   ${C}$(country_name "$cc")${city:+, $city}${N} ${D}· ${org} · ${ip}${N}"
    else echo -e "  Текущий выход:   ${D}не удалось определить${N}"; fi
    local extdev=""; extdev=$(route -n get 1.1.1.1 2>/dev/null | awk '/interface:/{print $2}')
    case "$extdev" in utun*) echo -e "  VPN-выход:       ${G}активен${N} ${D}(маршрут через ${extdev})${N}" ;;
                      *)     echo -e "  VPN-выход:       ${D}не обнаружен (выход напрямую)${N}" ;; esac
    echo
    echo -e "  ${D}Управляемые из shell (кандидаты на авто-переключение):${N}"
    local automatable=0 ts; ts=$(tailscale_bin) || ts=""
    if [ -n "$ts" ]; then
        local exits; exits=$("$ts" exit-node list 2>/dev/null | grep -E '^[0-9]' | wc -l | tr -d ' ')
        if [ "${exits:-0}" -ge 1 ]; then echo -e "    Tailscale:     ${G}CLI есть, exit-node настроены (${exits})${N} ${D}→ можно переключать${N}"; automatable=1
        else echo -e "    Tailscale:     ${Y}CLI есть, но exit-node не настроены${N} ${D}→ переключать выход нечем${N}"; fi
    else echo -e "    Tailscale:     ${D}CLI не найден${N}"; fi
    if command -v wg-quick >/dev/null 2>&1 || command -v wg >/dev/null 2>&1; then
        local wgc; wgc=$(ls /etc/wireguard/*.conf 2>/dev/null | wc -l | tr -d ' ')
        if [ "${wgc:-0}" -ge 1 ]; then echo -e "    WireGuard:     ${G}wg-quick + ${wgc} профил.${N}"; automatable=1
        else echo -e "    WireGuard:     ${Y}wg есть, но профилей .conf нет${N}"; fi
    else echo -e "    WireGuard:     ${D}нет (wg/wg-quick не найдены)${N}"; fi
    command -v openvpn >/dev/null 2>&1 && echo -e "    OpenVPN CLI:   ${Y}есть${N} ${D}(хрупко)${N}" || echo -e "    OpenVPN CLI:   ${D}нет${N}"
    echo
    echo -e "  ${D}Только GUI (переключение — вручную в приложении):${N}"
    local procs; procs=$(ps -axo comm 2>/dev/null)
    case "$procs" in *ExpressVPN*) echo -e "    ExpressVPN:    ${C}приложение активно${N} ${D}· CLI нет → выбираешь в app${N}" ;; esac
    case "$procs" in *hidemy*) echo -e "    HideMyName:    ${C}приложение активно${N} ${D}· OpenVPN NE, CLI нет → выбираешь в app${N}" ;; esac
    scutil --nc list 2>/dev/null | grep -i 'connected' | grep -viE 'tailscale' | sed -E 's/.*"([^"]*)".*/    NE-VPN:        \1/' | head -3
    echo
    if [ "$automatable" -eq 1 ]; then
        echo -e "  Вывод: ${G}есть управляемый из shell канал — авто-переключение возможно (Фаза 17.2).${N}"
    else
        echo -e "  Вывод: ${Y}авто-переключение маршрута сейчас недоступно.${N}"
        echo -e "  ${D}Коммерческие VPN — только GUI; Tailscale без exit-node. access диагностирует и советует${N}"
        echo -e "  ${D}(access --matrix URL), но переключать VPN придётся вручную. Авто-switch: настрой Tailscale exit-node.${N}"
    fi
    echo
}

# ---------- Фаза 17.1: матрица доступа ----------
matrix() {
    local url="$1"
    case "$url" in http://*|https://*) : ;; *) echo -e "${Y}Нужен полный URL со схемой: access --matrix https://example.com/${N}"; return 2 ;; esac
    local NI; NI=$(netinfo_bin) || { echo -e "${R}netinfo не найден (нужен ~/bin/netinfo.sh).${N}"; return 1; }
    echo
    echo -e "${B}=== ACCESS MATRIX ===${N}"
    echo -e "  Ресурс:          ${C}${url}${N}"
    # текущий маршрут
    local cx cc city org ip extdev vpn=0
    cx=$(current_exit); cc=$(printf '%s' "$cx"|cut -f1); city=$(printf '%s' "$cx"|cut -f2)
    org=$(printf '%s' "$cx"|cut -f3); ip=$(printf '%s' "$cx"|cut -f4)
    extdev=$(route -n get 1.1.1.1 2>/dev/null | awk '/interface:/{print $2}'); case "$extdev" in utun*) vpn=1 ;; esac
    echo -e "  Маршрут:         ${C}$(country_name "$cc")${city:+, $city}${N} ${D}· ${org} · ${ip} · VPN $([ $vpn -eq 1 ] && echo активен || echo нет)${N}"
    # прогон через why (источник правды по слоям)
    local res cls code lat
    res=$(NL_NO_SPINNER=1 "$NI" --why-class "$url" 2>/dev/null | head -1)
    cls=$(printf '%s' "$res"|cut -f1); code=$(printf '%s' "$res"|cut -f2); lat=$(printf '%s' "$res"|cut -f3)
    [ -z "$cls" ] && cls="unknown"
    echo -e "  Проверка:        слой ${C}${cls}${N} ${D}· HTTP ${code:-?} · задержка ${lat:-?} мс${N}"
    # запись (нормализованно: host + hash, без полного URL)
    local host hash pclass ts
    host=$(printf '%s' "$url" | sed -E 's#^[a-z]+://##; s#@[^/]*##; s#[:/].*$##')
    hash=$(printf '%s' "$url" | shasum -a 256 2>/dev/null | cut -c1-16)
    pclass=$(path_class "$url"); ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    ensure_state
    python3 - "$ts" "$host" "$hash" "$pclass" "$cc" "$city" "$ip" "$org" "$vpn" "$cls" "${code:-0}" "${lat:-0}" "$MATRIX" <<'PY'
import json,sys
a=sys.argv
rec={"ts":a[1],"host":a[2],"url_hash":a[3],"path_class":a[4],"route_country":a[5],"route_city":a[6],
     "ip":a[7],"provider":a[8],"vpn_active":a[9]=="1","class":a[10],
     "http_code":int(a[11] or 0),"latency_ms":int(a[12] or 0),"user_note":""}
open(a[13],"a").write(json.dumps(rec,ensure_ascii=False)+"\n")
PY
    # таблица истории + рекомендация по host
    python3 - "$host" "$MATRIX" <<'PY'
import json,sys,collections
host,path=sys.argv[1],sys.argv[2]
NAME={"AT":"Австрия","BE":"Бельгия","DE":"Германия","NL":"Нидерланды","US":"США","GB":"Британия",
      "FR":"Франция","FI":"Финляндия","SE":"Швеция","CH":"Швейцария","TR":"Турция","RU":"Россия",
      "PL":"Польша","ES":"Испания","IT":"Италия","":"?"}
rows=[]
try:
    for ln in open(path):
        ln=ln.strip()
        if not ln: continue
        try: d=json.loads(ln)
        except: continue
        if d.get("host")==host: rows.append(d)
except FileNotFoundError: pass
g=collections.OrderedDict()
for d in rows:                                  # rows в хронологическом порядке (как в файле)
    cc=d.get("route_country",""); cur=g.get(cc)
    if cur is None: g[cc]=d; continue
    dn=bool(d.get("user_note")); cn=bool(cur.get("user_note"))
    if dn or not cn: g[cc]=d                     # помеченный бьёт немеченый; иначе — позднейший
GOODN={"ok","browser-ok"}; BADN={"fail","region-fail"}
BADC={"http_forbidden","blockpage","tcp_blocked","dns_problem","slow_or_timeout","server_error","local_network"}
good=[]; bad=[]; amb=[]
print("\n  История по ресурсу (маршрутов: %d):"%len(g))
for cc,d in g.items():
    nm=NAME.get(cc,cc) or "?"; c=d.get("class",""); note=d.get("user_note","")
    print("    %-12s %-18s %s"%(nm+(" VPN" if d.get("vpn_active") else ""), c, ("· "+note) if note else ""))
    if note in GOODN or (not note and c=="ok"): good.append(nm)
    elif note in BADN or c in BADC: bad.append(nm)
    else: amb.append(nm)
print("\n  Рекомендация:")
if good: print("    Рабочие маршруты: "+", ".join(dict.fromkeys(good)))
if bad:  print("    Избегать: "+", ".join(dict.fromkeys(bad)))
if amb and not good:
    print("    Пока неясно (%s): отметь руками после проверки в браузере —"%", ".join(dict.fromkeys(amb)))
    print("      access --mark browser-ok | region-fail | ok | fail")
elif amb:
    print("    Под вопросом (нужна метка): "+", ".join(dict.fromkeys(amb)))
if not (good or bad or amb):
    print("    Истории пока нет. Переключи VPN на другую страну и прогони снова.")
PY
    echo
    echo -e "  ${D}access не переключает VPN — выбери страну вручную в приложении и прогони снова.${N}"
    echo -e "  ${D}Что реально открылось в браузере, добавь меткой: ${C}access --mark browser-ok${N}${D} (или region-fail/ok/fail).${N}"
    echo
}

# ---------- ручная метка исхода (app_shell сам не знает, открылось ли в браузере) ----------
mark() {
    local note="$1"
    case "$note" in ok|fail|browser-ok|region-fail) : ;; *) echo -e "${Y}Метка: ok | fail | browser-ok | region-fail${N}"; return 2 ;; esac
    [ -f "$MATRIX" ] || { echo -e "${Y}Истории нет — сначала: access --matrix URL${N}"; return 1; }
    python3 - "$note" "$MATRIX" <<'PY'
import json,sys
note,path=sys.argv[1],sys.argv[2]
lines=[l for l in open(path).read().splitlines() if l.strip()]
if not lines: print("пусто"); sys.exit(0)
last=json.loads(lines[-1]); last["user_note"]=note
lines[-1]=json.dumps(last,ensure_ascii=False)
open(path,"w").write("\n".join(lines)+"\n")
print("  отмечено: host=%s страна=%s → %s"%(last.get("host"),last.get("route_country") or "?",note))
PY
}

case "${1:-}" in
    --vpn-inventory) vpn_inventory ;;
    --matrix)        [ "$#" -ge 2 ] && matrix "$2" || echo "Использование: access --matrix https://URL" ;;
    --mark)          [ "$#" -ge 2 ] && mark "$2" || echo "Использование: access --mark ok|fail|browser-ok|region-fail" ;;
    ""|-h|--help)
        echo "access — выбор рабочего доверенного маршрута (слой поверх netinfo/why), read-only."
        echo "  access --vpn-inventory          чем можно управлять из shell, что лишь диагностировать"
        echo "  access --matrix https://URL     проверить URL через текущий маршрут + таблица истории + рекомендация"
        echo "  access --mark browser-ok|...    отметить РЕАЛЬНЫЙ исход последней проверки (видишь глазами в браузере)"
        echo "  (Фаза 17.2 --switch — позже, только при управляемом канале: Tailscale exit-node/WireGuard)"
        ;;
    *) echo "Неизвестная команда: $1 (см. access --help)" >&2; exit 2 ;;
esac
