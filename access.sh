#!/bin/bash
# access.sh — «access router» (Фазы 17.0–17.1.1). ЧЕТВЁРТЫЙ слой поверх netinfo/why:
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
#   - «read-only» с одним исключением: --get пишет ТОЛЬКО сам скачиваемый файл (это его
#     продукт, по явной команде); систему/сеть/state не меняет, URL не сохраняет.
set -u

R=$'\033[0;31m'; G=$'\033[0;32m'; Y=$'\033[0;33m'; B=$'\033[0;34m'; C=$'\033[0;36m'; D=$'\033[2m'; N=$'\033[0m'

STATE_DIR="$HOME/Library/Application Support/netinfo"
MATRIX="$STATE_DIR/access-matrix.jsonl"
ensure_state() { [ -d "$STATE_DIR" ] || mkdir -p "$STATE_DIR" 2>/dev/null; }

# Допустимые ручные метки исхода (Фаза 17.1.1 — фиксируем словарь, чтобы история не «каша»).
MARKS="browser-ok region-fail login-required cloudflare-fail ok fail unknown"

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

# Таблица истории по host + рекомендация (общая для --matrix и --history). Маршрутная логика:
# browser-ok/ok → рабочий; region-fail/cloudflare-fail/fail → избегать; login-required/unknown →
# нейтрально (это не «плохой маршрут», а свойство ресурса). Метки липкие (помеч. бьёт немеч.).
print_history() {
    local host="$1"
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
for d in rows:                                   # rows в хронологическом порядке (как в файле)
    cc=d.get("route_country",""); cur=g.get(cc)
    if cur is None: g[cc]=d; continue
    dn=bool(d.get("user_note")); cn=bool(cur.get("user_note"))
    if dn or not cn: g[cc]=d                      # помеченный бьёт немеченый; иначе — позднейший
GOODN={"ok","browser-ok"}; BADN={"fail","region-fail","cloudflare-fail"}   # login-required/unknown → нейтрально
BADC={"http_forbidden","blockpage","tcp_blocked","dns_problem","slow_or_timeout","server_error","local_network"}
good=[]; bad=[]; amb=[]
if not g:
    print("\n  Истории по этому ресурсу пока нет. Прогони: access --matrix URL"); sys.exit(0)
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
    print("      access --mark browser-ok | region-fail | login-required | cloudflare-fail | ok | fail")
elif amb:
    print("    Под вопросом (нужна метка): "+", ".join(dict.fromkeys(amb)))
PY
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
    local cx cc city org ip extdev vpn=0
    cx=$(current_exit); cc=$(printf '%s' "$cx"|cut -f1); city=$(printf '%s' "$cx"|cut -f2)
    org=$(printf '%s' "$cx"|cut -f3); ip=$(printf '%s' "$cx"|cut -f4)
    extdev=$(route -n get 1.1.1.1 2>/dev/null | awk '/interface:/{print $2}'); case "$extdev" in utun*) vpn=1 ;; esac
    echo -e "  Маршрут:         ${C}$(country_name "$cc")${city:+, $city}${N} ${D}· ${org} · ${ip} · VPN $([ $vpn -eq 1 ] && echo активен || echo нет)${N}"
    local res cls code lat
    res=$(NL_NO_SPINNER=1 "$NI" --why-class "$url" 2>/dev/null | head -1)
    cls=$(printf '%s' "$res"|cut -f1); code=$(printf '%s' "$res"|cut -f2); lat=$(printf '%s' "$res"|cut -f3)
    [ -z "$cls" ] && cls="unknown"
    echo -e "  Проверка:        слой ${C}${cls}${N} ${D}· HTTP ${code:-?} · задержка ${lat:-?} мс${N}"
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
    print_history "$host"
    echo
    echo -e "  ${D}access не переключает VPN — выбери страну вручную в приложении и прогони снова.${N}"
    echo -e "  ${D}Что реально открылось в браузере, добавь меткой: ${C}access --mark browser-ok${N}${D} (или region-fail/login-required/cloudflare-fail/ok/fail).${N}"
    echo
}

# ---------- Фаза 17.1.1: история без нового прогона ----------
history() {
    [ -f "$MATRIX" ] || { echo -e "${Y}Истории нет — сначала: access --matrix URL${N}"; return 1; }
    if [ "$#" -ge 1 ] && [ -n "$1" ]; then
        echo; echo -e "${B}=== ACCESS HISTORY: ${C}$1${B} ===${N}"
        print_history "$1"; echo
    else
        echo; echo -e "${B}=== ACCESS HISTORY (все ресурсы) ===${N}"
        python3 - "$MATRIX" <<'PY'
import json,sys,collections
c=collections.Counter()
try:
    for ln in open(sys.argv[1]):
        ln=ln.strip()
        if not ln: continue
        try: d=json.loads(ln)
        except: continue
        c[d.get("host","?")]+=1
except FileNotFoundError: pass
if not c: print("  пусто — прогони: access --matrix URL")
else:
    for h,n in sorted(c.items()): print("  %-32s %d записей"%(h,n))
    print("\n  Подробно по ресурсу: access --history HOST")
PY
        echo
    fi
}

# ---------- ручная метка исхода ----------
mark() {
    local note="$1" ok=0 m
    for m in $MARKS; do [ "$note" = "$m" ] && ok=1; done
    if [ "$ok" -ne 1 ]; then
        echo -e "${Y}Неизвестная метка «${note}». Допустимые: ${MARKS// /, }.${N}"; return 2
    fi
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

# ---------- Фаза 17.3: устойчивое скачивание (--get) ----------
# Мост «слабый интернет → файл всё-таки скачался»: докачка с места обрыва (curl -C -),
# ретраи с паузами, детектор зависания (--speed-limit/--speed-time), сверка размера,
# MTU-подсказка при зависании крупного файла, зеркальные CDN для raw.githubusercontent.
# ГРАНИЦЫ: это НЕ обход блокировок — качаем ТЕМ ЖЕ маршрутом; при отказе сервера
# (регион/вход/404) честно отказываемся ДО скачивания и советуем access --matrix.
# Пишем ТОЛЬКО сам скачиваемый файл (продукт); URL в state не сохраняется.

human_size() {
    awk -v s="${1:-0}" 'BEGIN{
        if (s>=1073741824) printf "%.1f ГБ", s/1073741824;
        else if (s>=1048576) printf "%.1f МБ", s/1048576;
        else if (s>=1024) printf "%.0f КБ", s/1024;
        else printf "%d Б", s }'
}

# Зеркальные CDN ТОГО ЖЕ файла (не «другие источники»!): только для raw.githubusercontent —
# jsDelivr/githack отдают тот же контент того же owner/repo/ref. Для прочих URL зеркал
# честно нет (mirrors_for молчит). ⚠ ref-ветка мутабельна — для критичного сверять sha256.
mirrors_for() {
    local u="$1"
    case "$u" in
        https://raw.githubusercontent.com/*) : ;;
        *) return 1 ;;
    esac
    local rest own repo ref pth
    rest="${u#https://raw.githubusercontent.com/}"
    own="${rest%%/*}";  rest="${rest#*/}"
    repo="${rest%%/*}"; rest="${rest#*/}"
    ref="${rest%%/*}";  pth="${rest#*/}"
    { [ -n "$own" ] && [ -n "$repo" ] && [ -n "$ref" ] && [ -n "$pth" ] && [ "$pth" != "$ref" ]; } || return 1
    printf '%s\n' \
        "https://cdn.jsdelivr.net/gh/${own}/${repo}@${ref}/${pth}" \
        "https://rawcdn.githack.com/${own}/${repo}/${ref}/${pth}"
}

# Цикл докачки. Ключевая логика слабого канала: ОБРЫВ С ПРОГРЕССОМ — это нормально
# (сбрасываем счётчик застревания и продолжаем терпеливо), а вот 3 попытки подряд БЕЗ
# единого нового байта — застряло по-настоящему, дальше долбить бессмысленно.
# Детектор зависания: <512 Б/с дольше 30 с → curl сам обрывает (rc 28), мы решаем, что дальше.
# Результаты в глобалах: DL_RC (код последнего curl), DL_BREAKS (обрывов с прогрессом).
DL_RC=1; DL_BREAKS=0
dl_loop() {
    local url="$1" out="$2"
    local rc=1 stuck=0 total=0 before after delay
    DL_BREAKS=0
    while :; do
        before=0; [ -f "$out" ] && before=$(stat -f%z "$out" 2>/dev/null || echo 0)
        curl -L --fail -# -C - --connect-timeout 8 --speed-limit 512 --speed-time 30 -o "$out" "$url"
        rc=$?
        [ "$rc" -eq 0 ] && break
        if [ "$rc" -eq 33 ]; then
            # сервер не умеет Range: докачка невозможна — одна честная попытка с нуля
            echo -e "  ${Y}Сервер не поддерживает докачку — качаю файл заново (целиком, одна попытка).${N}"
            rm -f "$out"
            curl -L --fail -# --connect-timeout 8 --speed-limit 512 --speed-time 30 -o "$out" "$url"
            rc=$?; break
        fi
        after=0; [ -f "$out" ] && after=$(stat -f%z "$out" 2>/dev/null || echo 0)
        if [ "$after" -gt "$before" ]; then
            stuck=0; DL_BREAKS=$((DL_BREAKS+1))
            echo -e "  ${D}обрыв (curl ${rc}), но докачано +$(human_size $((after-before))) — продолжаю с $(human_size "$after")${N}"
        else
            stuck=$((stuck+1))
            echo -e "  ${D}попытка не продвинулась ни на байт (curl ${rc}) — ${stuck}/3${N}"
        fi
        total=$((total+1))
        [ "$stuck" -ge 3 ] && break
        [ "$total" -ge 15 ] && break   # общий предохранитель от вечного цикла
        delay=$((stuck*5+2)); sleep "$delay"
    done
    DL_RC=$rc
    [ "$rc" -eq 0 ]
}

get_file() {
    local url="$1" out="${2:-}"
    case "$url" in http://*|https://*) : ;; *)
        echo -e "${Y}Нужен полный URL со схемой: access --get https://…/file.pdf [куда_сохранить]${N}"; return 2 ;; esac
    command -v curl >/dev/null 2>&1 || { echo -e "${R}curl не найден.${N}"; return 1; }
    local fname; fname=$(printf '%s' "$url" | sed -E 's#\?.*$##; s#/+$##; s#.*/##')
    [ -n "$fname" ] || fname="index.html"
    [ -n "$out" ] || out="$HOME/Downloads/$fname"
    echo
    echo -e "${B}=== ACCESS GET — устойчивое скачивание ===${N}"
    echo -e "  Ресурс:     ${C}${url}${N}"
    echo -e "  Сохраняю в: ${C}${out}${N}"

    # 1) Слой отказа ДО скачивания (источник правды — why_report через --why-class):
    #    если сервер ОТКАЗЫВАЕТ, ретраи бессмысленны — честно объясняем и не качаем.
    local NI cls="" code="" res
    if NI=$(netinfo_bin); then
        res=$(NL_NO_SPINNER=1 "$NI" --why-class "$url" 2>/dev/null | head -1)
        cls=$(printf '%s' "$res"|cut -f1); code=$(printf '%s' "$res"|cut -f2)
        [ -n "$cls" ] && echo -e "  Слой:       ${C}${cls}${N} ${D}· HTTP ${code:-?}${N}"
        case "$cls" in
            dns_problem)
                echo -e "  ${Y}Имя сайта не резолвится — качать нечего.${N} ${D}Проверь адрес; если это сеть: netinfo, sudo fixnet --dns.${N}"; return 1 ;;
            tcp_blocked|tls_blocked)
                echo -e "  ${Y}До сервера не достучаться на сетевом уровне — скачивание не начнётся.${N}"
                echo -e "  ${D}Смени сеть/VPN-сервер и повтори. Карта маршрутов: access --matrix URL.${N}"; return 1 ;;
            http_forbidden|blockpage)
                echo -e "  ${Y}Сервер отказывает (регион/политика/защита) — ретраи не помогут.${N}"
                echo -e "  ${D}Смени страну/сервер VPN и повтори; карта: access --matrix URL.${N}"; return 1 ;;
            auth_required)
                echo -e "  ${Y}Ресурс требует вход/ключ — без cookies скачивание не пройдёт. Скачай из браузера.${N}"; return 1 ;;
            not_found)
                echo -e "  ${Y}HTTP 404 — по этой ссылке файла нет (ссылка устарела или опечатка).${N}"; return 1 ;;
        esac
    fi

    # 2) Ожидаемый размер (HEAD; сервер может и не сказать) + что уже скачано.
    local explen have=0
    explen=$(curl -sIL --connect-timeout 8 --max-time 20 "$url" 2>/dev/null \
        | awk 'tolower($1)=="content-length:"{v=$2} END{gsub("\r","",v); print v}')
    case "$explen" in ''|*[!0-9]*) explen="" ;; esac
    [ -n "$explen" ] && echo -e "  Размер:     ${C}$(human_size "$explen")${N} ${D}(заявлен сервером)${N}"
    [ -f "$out" ] && have=$(stat -f%z "$out" 2>/dev/null || echo 0)
    if [ "$have" -gt 0 ]; then
        if [ -n "$explen" ] && [ "$have" -ge "$explen" ]; then
            echo -e "  ${G}Файл уже скачан полностью ($(human_size "$have")) — качать нечего.${N}"
            echo -e "  ${D}sha256: $(shasum -a 256 "$out" 2>/dev/null | cut -c1-16)…${N}"; echo; return 0
        fi
        echo -e "  ${C}Найден недокачанный кусок ($(human_size "$have")) — продолжаю с места обрыва.${N}"
    fi

    # 3) Скачивание с докачкой и ретраями.
    dl_loop "$url" "$out"
    local rc=$DL_RC breaks=$DL_BREAKS

    # 3а) Ни одного байта с основного адреса + у файла есть зеркальные CDN → пробуем их.
    #     (Частично скачанное НЕ смешиваем с зеркалом: докачиваем только с того же хоста.)
    local mused=""
    if [ "$rc" -ne 0 ]; then
        local nowhave=0; [ -f "$out" ] && nowhave=$(stat -f%z "$out" 2>/dev/null || echo 0)
        if [ "$nowhave" -eq 0 ]; then
            local m
            for m in $(mirrors_for "$url" 2>/dev/null); do
                echo -e "  ${C}Пробую зеркальный CDN того же файла:${N} ${D}${m}${N}"
                if dl_loop "$m" "$out"; then rc=0; mused="$m"; breaks=$((breaks+DL_BREAKS)); break; fi
            done
        fi
    fi

    echo
    if [ "$rc" -eq 0 ]; then
        local fin; fin=$(stat -f%z "$out" 2>/dev/null || echo 0)
        echo -e "  ${G}Готово:${N} ${C}${out}${N} ${D}($(human_size "$fin"))${N}"
        if [ -n "$explen" ] && [ "$fin" -lt "$explen" ] && [ -z "$mused" ]; then
            echo -e "  ${Y}⚠ Размер меньше заявленного ($(human_size "$fin") из $(human_size "$explen")) — файл может быть неполным.${N}"
        fi
        [ "$breaks" -gt 0 ] && echo -e "  ${D}Канал рвался ${breaks} раз — файл собран докачкой (без неё каждый обрыв = скачивание с нуля).${N}"
        if [ -n "$mused" ]; then
            local mhost; mhost=$(printf '%s' "$mused" | sed -E 's#^[a-z]+://##; s#/.*$##')
            echo -e "  ${D}Источник — зеркальный CDN (${mhost}): тот же файл того же owner/repo/ref; для критичного сверь sha256 с оригиналом.${N}"
        fi
        echo -e "  ${D}sha256: $(shasum -a 256 "$out" 2>/dev/null | cut -c1-16)… (для сверки целостности)${N}"
    else
        local part=0; [ -f "$out" ] && part=$(stat -f%z "$out" 2>/dev/null || echo 0)
        echo -e "  ${R}Скачать полностью не удалось.${N}"
        [ "$part" -gt 0 ] && echo -e "  ${D}Частично скачано $(human_size "$part")${explen:+ из $(human_size "$explen")} — кусок СОХРАНЁН: повтори ту же команду позже, докачает отсюда.${N}"
        case "$rc" in
            28)
                echo -e "  ${Y}Похоже на зависание канала: данные не шли дольше 30 секунд.${N}"
                echo -e "  ${D}Если сайты при этом открываются, а КРУПНЫЕ файлы виснут — частый признак MTU-проблемы:${N}"
                echo -e "  ${D}проверь ${C}netinfo --mtu${N}${D}, чинится ${C}sudo fixnet --mtu${N}${D} (с бэкапом и откатом).${N}" ;;
            22)
                echo -e "  ${Y}Сервер ответил HTTP-ошибкой уже в процессе скачивания.${N}"
                echo -e "  ${D}Слой и маршрут: netinfo --why URL · access --matrix URL (может помочь другая страна VPN).${N}" ;;
            6|7)
                echo -e "  ${Y}Сеть/DNS до сервера не проходит.${N} ${D}Диагноз: netinfo · починка: кнопка fixnet.${N}" ;;
            *)
                echo -e "  ${D}Код curl: ${rc}. Разбор слоя: netinfo --why URL.${N}" ;;
        esac
    fi
    echo
}

case "${1:-}" in
    --vpn-inventory) vpn_inventory ;;
    --matrix)        if [ "$#" -ge 2 ]; then matrix "$2"; else echo "Использование: access --matrix https://URL"; fi ;;
    --history)       history "${2:-}" ;;
    --mark)          if [ "$#" -ge 2 ]; then mark "$2"; else echo "Использование: access --mark ${MARKS// /|}"; fi ;;
    --get)           if [ "$#" -ge 2 ]; then get_file "$2" "${3:-}"; else echo "Использование: access --get https://…/file.pdf [куда_сохранить]"; fi ;;
    ""|-h|--help)
        echo "access — выбор рабочего доверенного маршрута (слой поверх netinfo/why), read-only."
        echo "  access --vpn-inventory          чем можно управлять из shell, что лишь диагностировать"
        echo "  access --matrix https://URL     проверить URL через текущий маршрут + история + рекомендация"
        echo "  access --history [HOST]          показать накопленную карту (без нового прогона)"
        echo "  access --mark <метка>            отметить РЕАЛЬНЫЙ исход последней проверки"
        echo "                                   метки: ${MARKS// /, }"
        echo "  access --get https://URL [файл]  устойчиво скачать: докачка с обрыва, ретраи, зеркала,"
        echo "                                   MTU-диагноз при зависании (слабый интернет — его стихия)"
        echo "  (Фаза 17.2 --switch — позже, только при управляемом канале: Tailscale exit-node/WireGuard)"
        ;;
    *) echo "Неизвестная команда: $1 (см. access --help)" >&2; exit 2 ;;
esac
