#!/bin/bash
#
# netinfo.sh — диагностика сети (companion к fixnet.sh)
#
#
# ЗАЧЕМ ЭТОТ СКРИПТ
#
# fixnet.sh — это "ремонт": он чинит сеть и для этого требует root и меняет
# состояние системы. netinfo.sh — это "осмотр": он НИЧЕГО не чинит и не трогает,
# только смотрит и ЧЕЛОВЕЧЕСКИМ языком рассказывает, что сейчас происходит и ГДЕ мы.
#
# Боль, которую он лечит: при подключении через слабый/далёкий VPN-сервер часто
# вообще непонятно — есть интернет или нет, какой страной нас видит мир, не потёк
# ли реальный IP. Браузер крутит спиннер, а в чём дело — неясно. Этот скрипт
# отвечает на это одним взглядом: крупный ИТОГ сверху + понятные подробности.
#
# По умолчанию вывод — для обычного человека (без жаргона). Для технического
# среза (интерфейсы, маршруты, utun, DNS-серверы) есть флаг --tech.
#
#
# ЧЕМ ОТЛИЧАЕТСЯ ОТ fixnet.sh
#
#   - read-only: не меняет маршруты, DNS, Wi-Fi — ничего (только смотрит).
#   - root НЕ обязателен: всё работает и без него. НО под root дополнительно
#     точно определяет СКРЫТУЮ сеть (флаг Hidden в known-networks.plist читается
#     только под root). Кнопка на рабочем столе запускает через sudo — ради
#     точности (это личная машина, владелец так попросил).
#   - делает запросы НАРУЖУ (geo-сервис, HTTPS-проверка, замер скорости) —
#     это осознанно. geo отключается --no-geo, скорость --no-speed.
#
#
# КАК ЗАПУСКАТЬ
#
#   sudo ./netinfo.sh        # точный осмотр (видит и скрытую сеть)
#   ./netinfo.sh             # то же без root, но без флага «скрытая»
#   ./netinfo.sh --tech      # технические подробности (для своих)
#   ./netinfo.sh --no-speed  # без замера скорости (на платной раздаче iPhone)
#   ./netinfo.sh --no-geo    # без обращения к geo-сервису (приватнее)
#   ./netinfo.sh --help
#

set -u

# ПРИНЦИП ПРОЕКТА (не размывать):
#   netinfo — наблюдает, измеряет, пишет СВОЮ локальную историю, открывает портал.
#   netinfo НЕ меняет маршруты / DNS / Wi-Fi / MTU / VPN.
#   Любое изменение сетевого состояния — только fixnet, с согласием и откатом.

# Цвета (как в fixnet.sh — для единообразия вывода).
R='\033[0;31m'; G='\033[0;32m'; Y='\033[0;33m'; B='\033[0;34m'; C='\033[0;36m'; D='\033[2m'; N='\033[0m'

# Общий слой состояния (память/конфиг). Источник — netlib.sh рядом со скриптом
# или в ~/bin. Если не найден — мягко деградируем: история выключается, всё
# остальное работает (заглушки ниже).
NL_OK=0
for _c in "$(dirname "${BASH_SOURCE[0]:-$0}")/netlib.sh" "$HOME/bin/netlib.sh"; do
    if [ -r "$_c" ]; then . "$_c"; NL_OK=1; break; fi
done
if [ "$NL_OK" -ne 1 ]; then
    nl_real_user(){ echo "${SUDO_USER:-$(id -un)}"; }
    nl_state_dir(){ echo ""; }; nl_ensure_state(){ :; }
    nl_history_append(){ :; }; nl_history_recall(){ echo ""; }
    nl_config_get(){ echo ""; }; nl_config_set(){ :; }
    nl_path_mtu(){ echo ""; }; nl_spin_start(){ :; }; nl_spin_stop(){ :; }
    nl_service_for_device(){ echo ""; }
    nl_tmp_dir(){ echo "${TMPDIR:-/tmp}/netinfo"; }; nl_ensure_tmp_dir(){ mkdir -p "$(nl_tmp_dir)" 2>/dev/null; }
    NL_UTUN_NORM=4; NL_UTUN_MANY=8; NL_UTUN_LOTS=12
fi
# Подстраховка порогов utun, даже если netlib старый/без них (NL_* — общие из netlib).
: "${NL_UTUN_NORM:=4}"; : "${NL_UTUN_MANY:=8}"; : "${NL_UTUN_LOTS:=12}"

# Спиннер прогресса как «шаг N/M»: останавливает прошлый, запускает новый с подписью.
NI_STEP=0; NI_STEPS=0
ni_step() { nl_spin_stop; NI_STEP=$((NI_STEP+1)); nl_spin_start "$1 (${NI_STEP}/${NI_STEPS})"; }
# Единый cleanup (сюда же — будущие хуки). netinfo read-only → только гашение
# спиннера. EXIT — просто очистка; INT/TERM — очистка И выход (иначе trap «съедает»
# Ctrl-C и скрипт продолжается вместо прерывания). 130 = 128+SIGINT.
# Очистка: гасим спиннер + подбираем «хвосты» tmp-файлов ai_check, если скрипт прервали
# (Ctrl-C) внутри $(ai_check) — там $bf в подоболочке, родитель его сам не видит, поэтому
# чистим по УЗКОМУ префиксу netinfo-ai.* (не трогаем чужие файлы в каталоге).
cleanup() {
    nl_spin_stop 2>/dev/null
    rm -f "$(nl_tmp_dir 2>/dev/null)"/netinfo-ai.* "$(nl_tmp_dir 2>/dev/null)"/netinfo-why.* 2>/dev/null
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM

# Два внешних адреса для ICMP-проверки. Два — на случай, если сеть режет один.
PROBE_IP1="1.1.1.1"
PROBE_IP2="8.8.8.8"
# IPv6-якоря (Фаза 9) — ТОЛЬКО для фолбэка строки задержки, когда IPv4-ping не дал RTT,
# а интернет жив (NAT64/мобильные/роуминг). Cloudflare → Google. НЕ для общего verdict.
PROBE_IP6_1="2606:4700:4700::1111"
PROBE_IP6_2="2001:4860:4860::8888"
# Реальные имена для проверки ЖИВОГО DNS-резолва (не кэша). Резолвится хотя бы
# одно — DNS жив. Случайный поддомен не годится: NXDOMAIN доказывал бы, что
# резолвер как раз ЖИВ (тот же урок, что и в fixnet.sh).
PROBE_DNS1="ya.ru"
PROBE_DNS2="apple.com"
# Эталонные URL для HTTPS-проверки (TCP 443). Берём адреса, которые отдают
# заведомо короткий ответ с предсказуемым кодом: generate_204 -> 204,
# captive.apple.com -> 200. Это ближе к "реально ли грузятся сайты", чем ICMP:
# многие сети (и хотспоты) режут ping, но пропускают 443.
HTTP_URL1="https://www.google.com/generate_204"
HTTP_URL2="https://captive.apple.com"

# Размер тела для замера скорости (5 МБ в каждую сторону). Достаточно для оценки,
# но осознанно немного: на раздаче с iPhone это ПЛАТНЫЙ трафик, не гонимся за
# точностью. Замер можно вовсе отключить флагом --no-speed.
SPEED_BYTES=5000000

# Короткая справка (длинная мотивация — в шапке файла, её здесь не вываливаем).
usage() {
    cat <<EOF
netinfo — осмотр сети macOS

Запуск:
  netinfo              короткий понятный вывод
  netinfo --tech       технические подробности
  netinfo --advice     советы по текущей сети
  netinfo --mtu        измерить path MTU (DF-зонд) и дать рекомендацию
  netinfo --probe      проверить TCP/UDP-выход для оценки пригодности VPN-протоколов
  netinfo --scan       показать соседние Wi-Fi сети (read-only, не подключает)
  netinfo --json       машиночитаемый вывод (факты и коды состояний; без рендера)
  netinfo --explain    пояснить термины простым языком (DNS, TLS, 403 и т.п.)
  netinfo --why URL    почему не открывается ресурс (слой отказа: DNS/TCP/TLS/HTTP)
  netinfo --ai         доступность AI-сервисов через VPN (OpenAI + Claude; TLS-проба)
  netinfo --ai all     + Gemini + Z.AI;  netinfo --ai list — показать цели проверки
  netinfo --no-ai      не показывать AI-блок в обычном выводе
  netinfo --no-speed   не мерить скорость
  netinfo --no-geo     не узнавать внешний IP/страну

Память (локальная история диагностики):
  Включена по умолчанию, хранится ТОЛЬКО локально, наружу не отправляется.
  netinfo --forget          очистить историю (спросит [y/N]; --yes — без вопроса)
  netinfo --no-history      разовый запуск без записи
  netinfo --history on|off|status
  netinfo --state           показать путь к данным
  netinfo --open-state      открыть папку данных в Finder

Внутри окна:
  Enter — закрыть · t — детали · a — советы · r — обновить · o — вход в сеть (если портал)

Ничего не чинит и не меняет. Под sudo дополнительно видит скрытую сеть и сигнал.
EOF
}

# --- разбор флагов ---
# Скорость меряем ПО УМОЛЧАНИЮ (это ядро утилиты — без неё непонятно, "тормозит"
# ли канал). На платной раздаче iPhone выключается флагом --no-speed.
WANT_SPEED=1
WANT_GEO=1
TECH=0          # 0 = человеческий вывод (по умолчанию), 1 = технический
ADVICE=0        # 1 = показать подробные советы «если VPN тормозит»
NO_HISTORY=0    # 1 = разовый запуск без записи в историю
MTU_PROBE=0     # 1 = режим измерения path MTU (медленный DF-зонд)
PROBE=0         # 1 = проба TCP/UDP-выхода (Фаза 5: оценка ограничений для VPN)
SCAN=0          # 1 = скан соседних Wi-Fi сетей (Фаза 6: read-only)
JSON=0          # 1 = машиночитаемый JSON-вывод (Фаза 6.1: стабильный контракт)
EXPLAIN=0       # 1 = пояснить термины простым языком (Фаза 12; клавиша ? в меню)
WHY_URL=""      # непусто = режим --why URL (Фаза 13: на каком слое не открывается ресурс)
WANT_AI=1       # 0 = не показывать AI-блок в обычном выводе (опт-аут --no-ai)
AI_FORCE=0      # 1 = режим netinfo --ai (проверить всегда, даже без VPN)
AI_MODE="default"  # default = OpenAI+Claude; all = + Gemini + Z.AI
AI_LIST=0       # 1 = netinfo --ai list (показать цели, без сети)
FORGET=0; ASSUME_YES=0; SHOW_STATE=0; OPEN_STATE=0; HIST_CMD=""
# while/shift, а не for: надёжно берёт значение «--history on» и не ломается на
# старом bash 3.2 (дефолт macOS), где трюк с «отложенным аргументом» вёл себя криво.
while [ $# -gt 0 ]; do
    case "$1" in
        --tech|-t)    TECH=1 ;;
        --advice|-a)  ADVICE=1 ;;
        --no-speed)   WANT_SPEED=0 ;;
        --speed)      WANT_SPEED=1 ;;   # совместимость: теперь и так по умолчанию
        --no-geo)     WANT_GEO=0 ;;
        --no-history) NO_HISTORY=1 ;;
        --mtu)        MTU_PROBE=1 ;;
        --probe)      PROBE=1 ;;
        --scan)       SCAN=1 ;;
        --json)       JSON=1 ;;
        --explain)    EXPLAIN=1 ;;
        --why)        if [ "$#" -ge 2 ]; then WHY_URL="$2"; shift; else WHY_URL="-"; fi ;;
        --why=*)      WHY_URL="${1#--why=}" ;;
        --ai)         AI_FORCE=1
                      if [ "$#" -ge 2 ]; then
                          case "$2" in all) AI_MODE="all"; shift ;; list) AI_LIST=1; shift ;; esac
                      fi ;;
        --ai=*)       AI_FORCE=1; case "${1#--ai=}" in all) AI_MODE="all" ;; list) AI_LIST=1 ;; esac ;;
        --no-ai)      WANT_AI=0 ;;
        --history)    if [ "$#" -ge 2 ]; then HIST_CMD="$2"; shift; else HIST_CMD="status"; fi ;;
        --history=*)  HIST_CMD="${1#--history=}" ;;
        --forget)     FORGET=1 ;;
        --yes|-y)     ASSUME_YES=1 ;;
        --state)      SHOW_STATE=1 ;;
        --open-state) OPEN_STATE=1 ;;
        -h|--help)    usage; exit 0 ;;
        *)
            echo -e "${Y}Неизвестный аргумент: $1${N}  (см. --help)" >&2 ;;
    esac
    shift
done

# --- управляющие команды состояния (не диагностика): сделать и выйти ---
if [ "$SHOW_STATE" -eq 1 ]; then
    _sd=$(nl_state_dir); _hf="$_sd/history.jsonl"
    echo "Данные netinfo: $_sd"
    _h=$(nl_config_get history); echo "История:        ${_h:-on (по умолчанию)}"
    if [ -f "$_hf" ]; then
        echo "Записей:        $(wc -l < "$_hf" | tr -d ' ')"
        echo "Владелец:       $(stat -f '%Su:%Sg' "$_hf" 2>/dev/null)"
    else
        echo "Записей:        0"
    fi
    exit 0
fi
if [ "$OPEN_STATE" -eq 1 ]; then
    nl_ensure_state; _d=$(nl_state_dir)
    if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then sudo -u "$SUDO_USER" open "$_d" 2>/dev/null
    else open "$_d" 2>/dev/null; fi
    exit 0
fi
if [ -n "$HIST_CMD" ]; then
    case "$HIST_CMD" in
        on|off) nl_config_set history "$HIST_CMD"; echo "История: $HIST_CMD (локально: $(nl_state_dir))" ;;
        status) echo "История: $(nl_config_get history)  ·  $(nl_state_dir)" ;;
        *)      echo "Использование: netinfo --history on|off|status" >&2 ;;
    esac
    exit 0
fi
if [ "$FORGET" -eq 1 ]; then
    _f="$(nl_state_dir)/history.jsonl"
    if [ "$ASSUME_YES" -ne 1 ] && [ -t 0 ]; then
        printf "Удалить локальную историю netinfo? [y/N] "; read -r _ans
        case "$_ans" in y|Y|да|Да) ;; *) echo "Отменено."; exit 0 ;; esac
    fi
    if [ -f "$_f" ]; then rm -f "$_f" && echo "История очищена."; else echo "Истории нет — нечего очищать."; fi
    exit 0
fi

# ============================ ХЕЛПЕРЫ ============================
# Намеренно дублируют логику из fixnet.sh (detect_iface / check_dns), чтобы
# netinfo.sh был самодостаточным и устанавливался отдельно. Если правишь правило
# определения интерфейса — поправь в обоих местах.

# Определяем физический uplink: факт (default route на enX) важнее имени сервиса.
detect_iface() {
    local d ifc
    d=$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')
    case "$d" in
        en*) echo "$d"; return ;;
    esac
    ifc=$(networksetup -listnetworkserviceorder 2>/dev/null \
        | awk -F'Device: ' '/Wi-Fi|AirPort/ && /Device: en/ {gsub(/\)/,"",$2); print $2; exit}')
    if [ -n "$ifc" ]; then echo "$ifc"; return; fi
    for d in $(networksetup -listallhardwareports 2>/dev/null | awk '/Device: en/{print $2}'); do
        if ifconfig "$d" 2>/dev/null | grep -q 'status: active'; then echo "$d"; return; fi
    done
    echo "en0"
}

# Есть ли вообще интернет (ICMP). Хватает любого из двух адресов.
check_net() {
    ping -c1 -W3000 "$PROBE_IP1" >/dev/null 2>&1 || \
    ping -c1 -W3000 "$PROBE_IP2" >/dev/null 2>&1
}

# Живой DNS-резолв (НЕ кэш). dig/nslookup/host делают новый запрос через
# системный резолвер и лучше показывают, жив ли DNS прямо сейчас, чем чтение
# кэша через dscacheutil. Резолвится хотя бы одно имя — DNS считаем живым.
# Спрашиваем A и AAAA явно: устойчивее к CNAME-цепочкам в выводе dig +short
# (там перед финальным адресом могут идти строки-псевдонимы).
check_dns() {
    local d
    for d in "$PROBE_DNS1" "$PROBE_DNS2"; do
        if command -v dig >/dev/null 2>&1; then
            dig +short +time=3 +tries=1 A    "$d" 2>/dev/null | grep -Eq '([0-9]{1,3}\.){3}[0-9]{1,3}' && return 0
            dig +short +time=3 +tries=1 AAAA "$d" 2>/dev/null | grep -q ':' && return 0
        elif command -v nslookup >/dev/null 2>&1; then
            nslookup -timeout=3 "$d" >/dev/null 2>&1 && return 0
        elif command -v host >/dev/null 2>&1; then
            host -W3 "$d" >/dev/null 2>&1 && return 0
        fi
    done
    return 1
}

# DoH-резолв (Фаза 8): подтверждает, что имена резолвятся хотя бы через DNS-over-HTTPS,
# когда обычный UDP-53 (check_dns) молчит. Успех = HTTP-JSON со `"Status":0` и `"data"`
# (непустой Answer). Якоря: Cloudflare → Google (двух достаточно; третий только тормозил
# бы плохую сеть). ⚠ ИНВАРИАНТ: DoH-успех НЕ равен «системный DNS работает» — приложения
# могут не использовать DoH. Это лишь «резолвинг в принципе возможен».
doh_probe() { doh_resolve ya.ru; }

# DoH-резолв КОНКРЕТНОГО хоста (Фаза 13: --why). 0 — резолвится через DoH. Хост обычный
# (буквы/цифры/точки/дефисы) — URL-кодирование не нужно.
doh_resolve() {
    command -v curl >/dev/null 2>&1 || return 1
    local h="$1" u r
    [ -z "$h" ] && return 1
    for u in "https://1.1.1.1/dns-query?name=${h}&type=A" "https://dns.google/resolve?name=${h}&type=A"; do
        r=$(curl -s --max-time 5 -H 'accept: application/dns-json' "$u" 2>/dev/null)
        case "$r" in *'"Status":0'*'"data"'*) return 0 ;; esac
    done
    return 1
}

# Это Wi-Fi? (нужно для человеческого "куда подключены")
is_wifi() { networksetup -getairportpower "$1" >/dev/null 2>&1; }

# Скрытая ли сеть с данным SSID. Точный флаг Hidden лежит в known-networks.plist,
# читаемом ТОЛЬКО под root (структуру сверили вживую: ключ wifi.network.ssid.<SSID>,
# поле Hidden:bool, плюс SSID:bytes для сопоставления). Эхо: "1" — скрытая, "0" —
# обычная, "" — неизвестно.
#
# ВАЖНО (граница точности): работает только для СОХРАНЁННЫХ (запомненных) сетей.
# Если сеть подключена без сохранения — её в plist нет, и мы честно МОЛЧИМ (а не
# гадаем): для незапомненной сети надёжного источника скрытости нет (wdutil и
# ipconfig её не отдают, живой скан требует Геолокации и может ошибаться). Это
# осознанный выбор владельца: лучше не показать, чем показать наугад.
wifi_hidden() {
    local ssid=$1
    [ -z "$ssid" ] && { echo ""; return; }
    [ "$(id -u)" -eq 0 ] || { echo ""; return; }
    command -v python3 >/dev/null 2>&1 || { echo ""; return; }
    python3 - "$ssid" <<'PY' 2>/dev/null
import sys, plistlib, unicodedata
def norm(s): return unicodedata.normalize("NFC", s)   # сравниваем нормализованно
ssid = norm(sys.argv[1])
p = "/Library/Preferences/com.apple.wifi.known-networks.plist"
try:
    d = plistlib.load(open(p, "rb"))
except Exception:
    sys.exit(0)
PFX = "wifi.network.ssid."
for k, e in d.items():
    if not isinstance(e, dict):
        continue
    name = None
    b = e.get("SSID")                       # основной путь — по байтам SSID
    if isinstance(b, (bytes, bytearray)):
        try: name = b.decode("utf-8")
        except Exception: name = None
    if name is None and k.startswith(PFX):  # запасной путь — по имени ключа
        name = k[len(PFX):]
    if name is not None and norm(name) == ssid:
        print("1" if e.get("Hidden") else "0")
        break
PY
}

# HTTPS-достижимость (TCP 443): возвращает HTTP-код или пусто, если не дозвонились.
http_code() {
    command -v curl >/dev/null 2>&1 || { echo ""; return; }
    curl -s -o /dev/null -w '%{http_code}' --connect-timeout 3 --max-time 6 "$1" 2>/dev/null
}

# Средний RTT (мс) до адреса по 3 пакетам. Пусто, если не ответил.
avg_rtt() {
    LC_ALL=C ping -c3 -W2000 "$1" 2>/dev/null \
        | awk -F'/' '/round-trip|min\/avg/{printf "%.0f", $5}'
}

# Стабильность задержки по джиттеру (stddev, мс) — математически точнее разброса
# max-min. Для VPN/видеосвязи дрожащий пинг рвёт связь даже при низком avg.
rtt_stability_word() {
    local j=$1
    if   [ "$j" -le 10 ]; then echo "";
    elif [ "$j" -le 30 ]; then echo ", плавает";
    else echo ", нестабильно"; fi
}

# Разделитель между экранами (после t/a/r), чтобы блоки не сливались. Без хвостовой
# пустой строки — следующий рендер начинается со своего echo (иначе двойной отступ).
divider() { echo; echo -e "${D}────────────────────────────────────────${N}"; }

# Достаём поле JSON. Предпочитаем python3 (надёжно к минификации/форматам);
# sed — фолбэк, если python3 нет. jq не требуем (его может не быть).
json_get() {
    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import sys,json
try: print(json.load(sys.stdin).get(sys.argv[1],"") or "")
except Exception: pass' "$2" <<<"$1" 2>/dev/null
    else
        echo "$1" | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1
    fi
}

# Срезаем управляющие символы — защита от ANSI-инъекции через имя сети/поля JSON
# (вредная сеть с \033[2J в SSID могла бы чистить экран при echo -e). Плюс trim.
clean() { printf '%s' "$1" | tr -d '[:cntrl:]' | sed -E 's/^ +| +$//g'; }

# байт/с -> целые Мбит/с (или пусто, если замер не удался).
to_mbps() { awk -v b="$1" 'BEGIN{ if (b+0>0) printf "%.0f", b*8/1000000; else print "" }'; }

# Человеческая оценка задержки (мс).
rtt_word() {
    local m=$1
    if   [ "$m" -le 40 ];  then echo "отлично";
    elif [ "$m" -le 90 ];  then echo "хорошо";
    elif [ "$m" -le 180 ]; then echo "терпимо";
    else echo "высокая — возможны подтормаживания"; fi
}

# Человеческая оценка скорости (целые Мбит/с). Пороги сдвинуты под VPN-сценарий:
# для слабого/далёкого VPN 11 Мбит/с — это уже «нормально», а не нижняя граница.
speed_word() {
    local m=$1
    if   [ "$m" -lt 2 ];  then echo "очень медленно";
    elif [ "$m" -lt 8 ];  then echo "терпимо";
    elif [ "$m" -lt 25 ]; then echo "нормально";
    elif [ "$m" -lt 80 ]; then echo "быстро";
    else echo "очень быстро"; fi
}

# Код страны -> человеческое имя (частые коды; остальное возвращаем как есть).
# Полный код страны остаётся в --tech, в человеческом выводе — имя.
country_name() {
    case "$1" in
        TR) echo "Турция" ;;       RU) echo "Россия" ;;
        NL) echo "Нидерланды" ;;   DE) echo "Германия" ;;
        FI) echo "Финляндия" ;;    US) echo "США" ;;
        GB|UK) echo "Великобритания" ;; FR) echo "Франция" ;;
        SE) echo "Швеция" ;;       CH) echo "Швейцария" ;;
        ES) echo "Испания" ;;      IT) echo "Италия" ;;
        PL) echo "Польша" ;;       UA) echo "Украина" ;;
        CA) echo "Канада" ;;       JP) echo "Япония" ;;
        SG) echo "Сингапур" ;;     AE) echo "ОАЭ" ;;
        KZ) echo "Казахстан" ;;    GE) echo "Грузия" ;;
        BE) echo "Бельгия" ;;      UZ) echo "Узбекистан" ;;
        CN) echo "Китай" ;;        HK) echo "Гонконг" ;;
        *)  echo "$1" ;;
    esac
}

# Имя города -> человеческое (частые города VPN-выходов; остальное как есть).
city_name() {
    case "$1" in
        Istanbul)   echo "Стамбул" ;;     Moscow)     echo "Москва" ;;
        Amsterdam)  echo "Амстердам" ;;   Frankfurt*) echo "Франкфурт" ;;
        Helsinki)   echo "Хельсинки" ;;   London)     echo "Лондон" ;;
        Paris)      echo "Париж" ;;       Stockholm)  echo "Стокгольм" ;;
        Zurich)     echo "Цюрих" ;;       Vienna)     echo "Вена" ;;
        *)          echo "$1" ;;
    esac
}

# Короткое имя провайдера для человеческого вывода: срезаем AS-номер и
# юр. суффиксы. Полную строку (с AS...) показываем в --tech. ОСТОРОЖНО: общий
# срез «Telekomunikasyon» превратил бы «Turk Telekomunikasyon» в «Turk» —
# поэтому частые случаи разбираем явно, а уже потом общий список суффиксов.
short_org() {
    local s
    s=$(echo "$1" | sed -E 's/^AS[0-9]+ //')
    case "$s" in
        *"Turk Telekom"*) echo "Turk Telekom"; return ;;
    esac
    echo "$s" \
      | sed -E 's/ (Anonim Sirketi|Limited|Ltd\.?|LLC|Inc\.?|GmbH|B\.V\.|S\.A\.|Co\.?|Corporation)//g' \
      | sed -E 's/ +$//'
}

# Качество сигнала Wi-Fi по RSSI (dBm). Пороги — общепринятые для Wi-Fi.
rssi_word() {
    local r=$1
    if   [ "$r" -ge -50 ]; then echo "отличный";
    elif [ "$r" -ge -60 ]; then echo "хороший";
    elif [ "$r" -ge -67 ]; then echo "нормальный";
    elif [ "$r" -ge -75 ]; then echo "слабый";
    else echo "очень слабый"; fi
}

# Диапазон в человеческом виде: "5GHz" -> "5 ГГц".
band_human() {
    case "$1" in
        2.4GHz|2GHz) echo "2.4 ГГц" ;;
        5GHz)        echo "5 ГГц" ;;
        6GHz)        echo "6 ГГц" ;;
        *)           echo "$1" ;;
    esac
}

# Собрать JSON-запись текущего замера для истории (schema:1). Через python3 —
# безопасное экранирование SSID/города (юникод/кавычки). Пусто, если нет python3.
history_record_json() {
    command -v python3 >/dev/null 2>&1 || { echo ""; return; }
    HJ_TS=$(date '+%Y-%m-%dT%H:%M:%S%z') \
    HJ_SSID="${SSID:-}" HJ_OPEN="${SEC_OPEN:-0}" \
    HJ_MAIN="$([ "${MAIN_OK:-0}" -eq 1 ] && echo ok || echo degraded)" HJ_Q="${QLEVEL:-}" \
    HJ_VPN="${VPN_ACTIVE:-0}" HJ_RTT="${RTT_AVG:-}" HJ_JIT="${RTT_JIT:-}" HJ_LOSS="${LOSS:-}" \
    HJ_DL="${DL_M:-}" HJ_UL="${UL_M:-}" HJ_RSSI="${RSSI:-}" HJ_SNR="${SNR:-}" \
    HJ_BAND="${BAND:-}" HJ_CHAN="${CHAN:-}" HJ_WIDTH="${CHW:-}" \
    HJ_COUNTRY="${COUNTRY:-}" HJ_CITY="${CITY:-}" HJ_CAPTIVE="${CAPTIVE:-0}" \
    python3 -c '
import os, json
def i(k):
    try: return int(float(os.environ.get(k,"")))
    except Exception: return None
o={"schema":1,"ts":os.environ.get("HJ_TS",""),
   "ssid":os.environ.get("HJ_SSID",""),"bssid":"",
   "open":i("HJ_OPEN") or 0,
   "main":os.environ.get("HJ_MAIN",""),"q":os.environ.get("HJ_Q",""),
   "vpn_exit":i("HJ_VPN") or 0,
   "rtt_avg":i("HJ_RTT"),"rtt_jitter":i("HJ_JIT"),"loss":i("HJ_LOSS"),
   "dl":i("HJ_DL"),"ul":i("HJ_UL"),"rssi":i("HJ_RSSI"),"snr":i("HJ_SNR"),
   "band":os.environ.get("HJ_BAND",""),"channel":i("HJ_CHAN"),"width":i("HJ_WIDTH"),
   "country":os.environ.get("HJ_COUNTRY",""),"city":os.environ.get("HJ_CITY",""),
   "captive":i("HJ_CAPTIVE") or 0}
print(json.dumps(o, ensure_ascii=False))
'
}

# (только для --tech) красивая строка скорости с одним знаком после запятой.
print_speed() {
    local label=$1 bps=$2 v
    v=$(awk -v b="$bps" 'BEGIN{ if (b+0>0) printf "%.1f", b*8/1000000; else print "" }')
    if [ -n "$v" ]; then
        echo -e "  ${label} ${G}${v} Мбит/с${N}"
    else
        echo -e "  ${label} ${R}замер не удался${N}"
    fi
}

# ===== СБОР ДАННЫХ (в функции: рендеры НЕ пересобирают, обновляет только r) =====
# КЛЮЧЕВОЕ архитектурное решение: измерения (ping/speed/geo) делаем ОДИН раз в
# collect_all, а t/a показывают уже собранные данные. Иначе на соседних экранах
# были бы разные цифры — пользователь терял бы доверие к диагнозу.
collect_all() {
STAMP=$(date '+%d.%m.%Y %H:%M:%S')      # для --tech (полная дата)
STAMP_SHORT=$(date '+%H:%M:%S')         # для обычного режима (только время)
IFACE=$(detect_iface)
LOCAL_IP=$(ipconfig getifaddr "$IFACE" 2>/dev/null)
IFACE_MTU=$(ifconfig "$IFACE" 2>/dev/null | grep -o 'mtu [0-9]*' | awk '{print $2}')

# Сколько «шагов» покажет спиннер (база + опциональные geo/скорость).
NI_STEP=0
NI_STEPS=3
[ "$WANT_GEO" -eq 1 ]   && NI_STEPS=$((NI_STEPS+1))
[ "$WANT_SPEED" -eq 1 ] && NI_STEPS=$((NI_STEPS+1))

# Базовая связность
ni_step "проверяю интернет"
NET=0;  check_net && NET=1
DNS=0;  check_dns && DNS=1
# HTTPS-достижимость: по HTTPS captive portal не может прозрачно подменить ответ
# (была бы TLS-ошибка -> код 000), поэтому ждём СТРОГО корректный код: 204 для
# generate_204, 200 для apple. Редиректы 30x здесь подозрительны и за «работает»
# НЕ считаем — это и был источник ложного «сайты открываются» за порталом.
H1=$(http_code "$HTTP_URL1"); HTTPS_OK=0
[ "$H1" = "204" ] && HTTPS_OK=1
if [ "$HTTPS_OK" -eq 0 ]; then
    H2=$(http_code "$HTTP_URL2")
    [ "$H2" = "200" ] && HTTPS_OK=1
fi

# DoH-фолбэк (Фаза 8): ТОЛЬКО если обычный DNS молчит, но связь в целом есть. Отличает
# «UDP-53 молчит, но резолвинг возможен (DoH)» от «резолвинг не идёт вовсе». DOH_OK:
# "" — не проверяли / 1 — DoH прошёл / 0 — не прошёл. DoH-успех ≠ «системный DNS жив».
DOH_OK=""
if [ "$DNS" -eq 0 ] && { [ "$NET" -eq 1 ] || [ "$HTTPS_OK" -eq 1 ]; }; then
    if doh_probe; then DOH_OK=1; else DOH_OK=0; fi
fi

# Captive portal (страница входа в Wi-Fi): HTTP-проба Apple. Чистый интернет ->
# тело ровно "Success"; -L уводит на портал -> любое другое тело -> это портал.
# Только чтение; не пробуем, если связи нет совсем (тогда диагноз и так 🔴).
CAPTIVE=0; CAP_URL=""
if { [ "$NET" -eq 1 ] || [ "$HTTPS_OK" -eq 0 ]; } && command -v curl >/dev/null 2>&1; then
    CAP=$(curl -sL --max-time 5 "http://captive.apple.com/hotspot-detect.html" 2>/dev/null)
    case "$CAP" in
        "")        : ;;           # не дозвонились — не утверждаем
        *Success*) : ;;           # портала нет
        *)         CAPTIVE=1 ;;   # есть тело, но не Success -> портал
    esac
    if [ "$CAPTIVE" -eq 1 ]; then
        # URL портала из заголовка Location (без -L — берём сам редирект)
        CAP_URL=$(curl -sI --max-time 5 "http://captive.apple.com/hotspot-detect.html" 2>/dev/null \
            | awk 'tolower($1)=="location:"{print $2}' | tr -d '\r' | tail -1)
    fi
fi

# Маршрут / VPN
GW=$(route -n get default 2>/dev/null | awk '/gateway:/{print $2}')
DDEV=$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')
UTUN=$(ifconfig 2>/dev/null | grep -c '^utun')

# Куда подключены (человеческое описание) + пометки безопасности сети.
# «без пароля» берём из Security: NONE (надёжно, без root). «скрытая» — из
# флага Hidden в known-networks.plist (точно, но только под root; без root тихо
# пропускаем). Обе пометки сводим в один хвост: «(скрытая, без пароля ⚠)».
WIFI_WARN=""
WIFI=0           # 1 — выход через Wi-Fi (влияет на советы про 5 ГГц/роутер)
SEC_OPEN=0       # 1 — Wi-Fi без пароля (открытая сеть)
SSID=""; SEC=""  # сброс на случай переката r с Wi-Fi на кабель (идемпотентность)
# VPN активен, если ВНЕШНИЙ трафик реально уходит в utun. Так ловим И full-tunnel
# (он зануляет default route), И сплит-дефолт (0.0.0.0/1 + 128.0.0.0/1 — частый
# трюк OpenVPN/WireGuard/Tailscale, который САМ default route не трогает, поэтому
# проверка только default-маршрута его пропускала).
VPN_ACTIVE=0
EXTDEV=$(route -n get "$PROBE_IP1" 2>/dev/null | awk '/interface:/{print $2}')
case "$EXTDEV" in utun*) VPN_ACTIVE=1 ;; esac
# Тип ФИЗИЧЕСКОГО подключения (Фаза 6): Wi-Fi / раздача с телефона / USB / кабель.
# Берём IFACE (detect_iface предпочитает enX, не utun) — поэтому даже при активном
# VPN показываем РЕАЛЬНУЮ подложку, а не «через utun» (для человека utun бесполезен;
# статус VPN и так есть в строке VPN-выход). Тип — по имени сетевого СЕРВИСА
# (`iPhone USB`/`iPad USB`/Ethernet) + подсети Personal Hotspot (Apple фиксирует
# 172.20.10.0/28 для раздачи) — это надёжные признаки, не гадание.
LINK_TYPE="unknown"; IS_HOTSPOT=0
SVC=$(nl_service_for_device "$IFACE")
case "$SVC" in
    *"iPhone USB"*) LINK_TYPE="iphone_usb"; CONN="iPhone по USB" ;;
    *"iPad USB"*)   LINK_TYPE="ipad_usb";   CONN="iPad по USB" ;;
esac
if [ "$LINK_TYPE" = "unknown" ] && is_wifi "$IFACE"; then
    WIFI=1
    SUMMARY=$(ipconfig getsummary "$IFACE" 2>/dev/null)
    SSID=$(clean "$(echo "$SUMMARY" | awk -F' SSID : ' '/ SSID : /{print $2; exit}')")
    SEC=$(echo "$SUMMARY"  | awk '$1=="Security"{print $3; exit}')
    case "$LOCAL_IP" in 172.20.10.*) IS_HOTSPOT=1 ;; esac   # фикс-подсеть Apple Personal Hotspot
    if [ "$IS_HOTSPOT" -eq 1 ]; then
        LINK_TYPE="personal_hotspot_wifi"
        # «iPhone/iPad» называем ТОЛЬКО если это видно из SSID; иначе нейтрально «телефон».
        case "$SSID" in
            *[Ii][Pp][Hh][Oo][Nn][Ee]*) CONN="Раздача с iPhone по Wi-Fi${SSID:+ — «${SSID}»}" ;;
            *[Ii][Pp][Aa][Dd]*)         CONN="Раздача с iPad по Wi-Fi${SSID:+ — «${SSID}»}" ;;
            *)                          CONN="Раздача с телефона по Wi-Fi${SSID:+ — «${SSID}»}" ;;
        esac
    else
        LINK_TYPE="wifi"
        CONN="Wi-Fi${SSID:+ — «${SSID}»}"
    fi
    NOTE=""
    [ "$(wifi_hidden "$SSID")" = "1" ] && NOTE="скрытая"
    case "$SEC" in
        NONE|None|none) NOTE="${NOTE:+$NOTE, }без пароля"; SEC_OPEN=1 ;;
    esac
    [ -n "$NOTE" ] && WIFI_WARN=" ${Y}(${NOTE} ⚠)${N}"
elif [ "$LINK_TYPE" = "unknown" ]; then
    case "$SVC" in
        *Ethernet*|*LAN*|*Thunderbolt*) LINK_TYPE="ethernet"; CONN="Ethernet / USB-LAN" ;;
        "")                             CONN="не определено" ;;
        *)                              LINK_TYPE="ethernet"; CONN="$SVC" ;;
    esac
fi

# Сигнал Wi-Fi: диапазон/канал — без root (system_profiler); сила (RSSI/шум) —
# только под root (wdutil). Поля wdutil сверены вживую: «RSSI : -46 dBm»,
# «Noise : -93 dBm», «Channel : 5g100/80», «Tx Rate», «MCS Index», «PHY Mode».
ni_step "проверяю Wi-Fi и сигнал"
RSSI=""; NOISE=""; SNR=""; BAND=""; CHAN=""; CHW=""; TXRATE=""; PHY=""; MCS=""
if [ "$WIFI" -eq 1 ]; then
    # диапазон и канал — без root: строка вида "Channel: 100 (5GHz, 80MHz)"
    CHANLINE=$(LC_ALL=C system_profiler SPAirPortDataType 2>/dev/null \
        | awk '/Current Network Information:/{f=1} f&&/Channel:/{print; exit}')
    CHAN=$(echo "$CHANLINE" | sed -nE 's/.*Channel: *([0-9]+).*/\1/p')
    BAND=$(echo "$CHANLINE" | grep -oE '[0-9.]+GHz' | head -1)
    CHW=$(echo "$CHANLINE" | grep -oE '[0-9]+MHz' | head -1 | sed 's/MHz//')
    # сила сигнала и шум — под root через wdutil
    if [ "$(id -u)" -eq 0 ] && command -v wdutil >/dev/null 2>&1; then
        WD=$(LC_ALL=C wdutil info 2>/dev/null)
        RSSI=$(echo  "$WD" | awk -F: '/^[[:space:]]*RSSI/   {gsub(/[^0-9-]/,"",$2); print $2; exit}')
        NOISE=$(echo "$WD" | awk -F: '/^[[:space:]]*Noise/  {gsub(/[^0-9-]/,"",$2); print $2; exit}')
        TXRATE=$(echo "$WD" | sed -nE 's/^[[:space:]]*Tx Rate[[:space:]]*:[[:space:]]*(.+)/\1/p' | head -1)
        PHY=$(echo  "$WD" | sed -nE 's/^[[:space:]]*PHY Mode[[:space:]]*:[[:space:]]*(.+)/\1/p' | head -1)
        MCS=$(echo  "$WD" | sed -nE 's/^[[:space:]]*MCS Index[[:space:]]*:[[:space:]]*(.+)/\1/p' | head -1)
        [ -n "$RSSI" ] && [ -n "$NOISE" ] && SNR=$((RSSI - NOISE))
        # если канал/диапазон не достали без root — возьмём из wdutil "Channel : 5g100/80"
        if [ -z "$CHAN" ]; then
            CW=$(echo "$WD" | awk -F: '/^[[:space:]]*Channel /{gsub(/ /,"",$2); print $2; exit}')
            CHAN=$(echo "$CW" | sed -nE 's/[0-9]?g([0-9]+).*/\1/p')
            CHW=${CW##*/}
            case "$CW" in 2g*) BAND="2.4GHz";; 5g*) BAND="5GHz";; 6g*) BAND="6GHz";; esac
        fi
    fi
fi

# Задержки. До шлюза — СПРАВОЧНО (ICMP к самому роутеру часто непоказателен:
# роутер может медленно отвечать на пинг к себе, но нормально маршрутизировать).
RG=""; [ -n "$GW" ] && RG=$(avg_rtt "$GW")
# Наружу — один прогон ping -c5, из него: min/avg/max, джиттер (stddev) и ПОТЕРИ
# пакетов. Для VPN/видеосвязи джиттер и потери важнее среднего. Парсим итоговую
# строку "round-trip min/avg/max/stddev = .../.../.../... ms" (режем по "= ", затем
# по "/") и строку "... X% packet loss".
ni_step "измеряю задержку"
RW=""; RTT_MIN=""; RTT_AVG=""; RTT_MAX=""; RTT_JIT=""; LOSS=""
LATENCY_PROBE=""   # "" / ipv4 / ipv6 — каким стеком измерена задержка (Фаза 9)
if [ "$NET" -eq 1 ]; then
    PINGOUT=$(LC_ALL=C ping -c5 -W2000 "$PROBE_IP1" 2>/dev/null)
    read -r RTT_MIN RTT_AVG RTT_MAX RTT_JIT <<< "$(echo "$PINGOUT" \
        | awk -F'= ' '/min\/avg/{split($2,a,"/"); printf "%.0f %.0f %.0f %.0f", a[1],a[2],a[3],a[4]}')"
    LOSS=$(echo "$PINGOUT" | awk -F',' '/packet loss/{for(i=1;i<=NF;i++) if($i ~ /packet loss/){gsub(/[^0-9.]/,"",$i); printf "%d", $i}}')
    RW="$RTT_AVG"
    [ -n "$RW" ] && LATENCY_PROBE="ipv4"
fi
# IPv6-фолбэк ТОЛЬКО для строки задержки: если IPv4 RTT не получен, но интернет жив
# (NAT64/мобильные сети). НЕ меняет общий verdict (он по HTTPS) и НЕ утверждает «IPv4
# сломан / IPv6 работает» — это лишь честная попытка не потерять метрику задержки.
# ping6 без IPv6-маршрута возвращается мгновенно («No route to host»), зависания нет.
if [ -z "$RW" ] && { [ "$HTTPS_OK" -eq 1 ] || [ "$NET" -eq 1 ]; } && command -v ping6 >/dev/null 2>&1; then
    PINGOUT6=""
    for _ip6 in "$PROBE_IP6_1" "$PROBE_IP6_2"; do
        PINGOUT6=$(LC_ALL=C ping6 -c5 -W2000 "$_ip6" 2>/dev/null)
        echo "$PINGOUT6" | grep -q 'min/avg' && break
    done
    read -r RTT_MIN RTT_AVG RTT_MAX RTT_JIT <<< "$(echo "$PINGOUT6" \
        | awk -F'= ' '/min\/avg/{split($2,a,"/"); printf "%.0f %.0f %.0f %.0f", a[1],a[2],a[3],a[4]}')"
    LOSS=$(echo "$PINGOUT6" | awk -F',' '/packet loss/{for(i=1;i<=NF;i++) if($i ~ /packet loss/){gsub(/[^0-9.]/,"",$i); printf "%d", $i}}')
    RW="$RTT_AVG"
    [ -n "$RW" ] && LATENCY_PROBE="ipv6"
fi

# DNS-серверы (для --tech)
RESOLVERS=$(LC_ALL=C scutil --dns 2>/dev/null | awk '/nameserver\[[0-9]+\]/{print $3}' | LC_ALL=C sort -u | paste -sd ' ' -)
# Активен ли Tailscale DNS (влияет на формулировку рекомендации DNS-ремонта).
TS_DNS=0
case "$RESOLVERS" in *100.100.100.100*|*fd7a:115c:a1e0*) TS_DNS=1 ;; esac

# Geo (внешний IP + страна) — индикатор состояния VPN
XIP=""; CITY=""; COUNTRY=""; ORG=""; GEO_ERR=""
if [ "$WANT_GEO" -eq 1 ]; then
    ni_step "узнаю внешний IP"
    if { [ "$NET" -eq 0 ] && [ "$HTTPS_OK" -eq 0 ]; }; then
        GEO_ERR="нет связи"
    elif ! command -v curl >/dev/null 2>&1; then
        GEO_ERR="нет curl"
    else
        GEO=$(curl -s --connect-timeout 3 --max-time 6 "https://ipinfo.io/json" 2>/dev/null)
        XIP=$(json_get "$GEO" ip); CITY=$(json_get "$GEO" city)
        COUNTRY=$(json_get "$GEO" country); ORG=$(json_get "$GEO" org)
        if [ -z "$XIP" ]; then
            # Фолбэк строго по HTTPS (НЕ http: иначе captive portal вернёт HTML и
            # утечёт реальный IP в открытом виде). ifconfig.co отдаёт country_iso —
            # КОД страны, как у ipinfo, поэтому country_name() не ломается.
            GEO=$(curl -s --connect-timeout 3 --max-time 6 "https://ifconfig.co/json" 2>/dev/null)
            XIP=$(json_get "$GEO" ip); CITY=$(json_get "$GEO" city)
            COUNTRY=$(json_get "$GEO" country_iso); ORG=$(json_get "$GEO" asn_org)
        fi
        XIP=$(clean "$XIP"); CITY=$(clean "$CITY"); COUNTRY=$(clean "$COUNTRY"); ORG=$(clean "$ORG")
        [ -z "$XIP" ] && GEO_ERR="сервис не ответил"
    fi
fi

# Скорость (приём/передача). Считаем raw байт/с, в обоих видах вывода используем.
DBPS=""; UBPS=""; SPEED_ERR=""
if [ "$WANT_SPEED" -eq 1 ]; then
    ni_step "замер скорости (~5 МБ)"
    if { [ "$NET" -eq 0 ] && [ "$HTTPS_OK" -eq 0 ]; }; then
        SPEED_ERR="нет связи"
    elif ! command -v curl >/dev/null 2>&1; then
        SPEED_ERR="нет curl"
    else
        DBPS=$(LC_ALL=C curl -s -o /dev/null -w '%{speed_download}' --max-time 30 \
            "https://speed.cloudflare.com/__down?bytes=${SPEED_BYTES}" 2>/dev/null)
        UBPS=$(dd if=/dev/zero bs=1000000 count=$((SPEED_BYTES/1000000)) 2>/dev/null \
            | LC_ALL=C curl -s -o /dev/null -w '%{speed_upload}' --max-time 30 \
                -X POST --data-binary @- "https://speed.cloudflare.com/__up" 2>/dev/null)
    fi
fi
DL_M=$(to_mbps "$DBPS")   # целые Мбит/с для человеческого вывода
UL_M=$(to_mbps "$UBPS")

# Нейросети (Фаза 7): при активном VPN и не --no-ai — компактная проверка доступности
# OpenAI/Claude через TLS-handshake. Без VPN в обычном выводе НЕ шумим (см. контракт).
AI_RESULTS=""; AI_RUN=0; AI_TOTAL=0; AI_OK=0; AI_BLOCKED=0; AI_UNCONF=0; AI_UNREACH=0; AI_BAD=0; AI_SLOW=0; AI_OK_NAMES=""; AI_BAD_NAMES=""; AI_UNCONF_NAMES=""; AI_SLOW_NAMES=""
if [ "$VPN_ACTIVE" -eq 1 ] && [ "$WANT_AI" -eq 1 ] && command -v curl >/dev/null 2>&1; then
    NI_STEPS=$((NI_STEPS+1)); ni_step "проверяю доступность нейросетей"
    AI_MODE="default"        # в основном выводе всегда базовый набор (OpenAI+Claude)
    ai_build_targets
    AI_RESULTS=$(ai_check)
    [ -n "$AI_RESULTS" ] && { AI_RUN=1; ai_summarize; }
fi

# ===================== СИНТЕЗ (диагноз, без печати) =====================
# Считаем смысловые статусы; печать — ниже по режимам. Идея ревью: сначала
# ответить «можно ли работать», потом «почему», потом «что делать».

# MAIN — что с интернетом. Критерий — ОТКРЫВАЮТСЯ ЛИ САЙТЫ (HTTPS), а не ICMP:
# ping может идти при зарезанном 443 (captive portal, корпоративная сеть, кривой
# VPN, блокировка TLS) — это НЕ «работает».
MAIN_OK=0
# DoH-уточнение (Фаза 8): если сайты открываются И имена резолвятся хотя бы через DoH —
# интернет ЕСТЬ (🟢), даже когда обычный UDP-53 молчит. Сам слой DNS при этом «жёлтый»
# (строка «адреса (DNS)» ниже честно скажет «через DoH»), но верхний вердикт не врёт.
if [ "$HTTPS_OK" -eq 1 ] && { [ "$DNS" -eq 1 ] || [ "$DOH_OK" = "1" ]; }; then
    MAIN_LINE="${G}🟢  ИНТЕРНЕТ ЕСТЬ${N}"; MAIN_OK=1
elif [ "$CAPTIVE" -eq 1 ]; then
    MAIN_LINE="${Y}🟡  НУЖНО ВОЙТИ В СЕТЬ (страница входа)${N}"
elif [ "$HTTPS_OK" -eq 1 ] && [ "$DNS" -eq 0 ]; then
    MAIN_LINE="${Y}🟡  САЙТЫ ОТКРЫВАЮТСЯ, НО DNS НЕСТАБИЛЕН${N}"
elif [ "$NET" -eq 1 ] && [ "$HTTPS_OK" -eq 0 ]; then
    MAIN_LINE="${Y}🟡  ПИНГ ЕСТЬ, НО САЙТЫ НЕ ОТКРЫВАЮТСЯ${N}"
else
    MAIN_LINE="${R}🔴  ИНТЕРНЕТА НЕТ${N}"
fi

# SECURITY — открытую сеть выносим отдельной КОРОТКОЙ строкой (объяснение — в ВЫВОД).
SECURITY_LINE=""
[ "$SEC_OPEN" -eq 1 ] && SECURITY_LINE="${Y}🟡  ОТКРЫТАЯ WI-FI СЕТЬ${N}"

# Качество для VPN — доступность + ЗАДЕРЖКА + скорость (отдельно от «есть ли сайт»).
QLEVEL=""; QWHY=""
if [ "$NET" -eq 1 ] || [ "$HTTPS_OK" -eq 1 ]; then
    JIT=${RTT_JIT:-0}; PL=${LOSS:-0}
    if [ "$HTTPS_OK" -eq 0 ] || [ "$DNS" -eq 0 ]; then
        QLEVEL=red; QWHY="сайты или DNS не работают"
    elif [ "$PL" -ge 10 ]; then
        QLEVEL=red; QWHY="большие потери пакетов ${PL}%"
    elif [ -n "$RW" ] && [ "$RW" -gt 180 ]; then
        QLEVEL=red; QWHY="очень высокая задержка ${RW} мс"
    else
        # Минусы: высокий средний RTT, ДЖИТТЕР (stddev), ПОТЕРИ пакетов и низкая
        # скорость. Для VPN/SSH/RDP/видеосвязи джиттер и потери важнее среднего.
        [ -n "$RW" ] && [ "$RW" -gt 80 ] && QWHY="высокая задержка ${RW} мс"
        if   [ "$JIT" -gt 30 ]; then QWHY="${QWHY:+$QWHY, }сильный джиттер ${JIT} мс"
        elif [ "$JIT" -gt 10 ]; then QWHY="${QWHY:+$QWHY, }задержка плавает"; fi
        [ "$PL" -gt 0 ] && QWHY="${QWHY:+$QWHY, }потери пакетов ${PL}%"
        [ -n "$DL_M" ] && [ "$DL_M" -lt 8 ] && QWHY="${QWHY:+$QWHY, }низкая скорость ${DL_M} Мбит/с"
        [ -n "$QWHY" ] && QLEVEL=yellow || QLEVEL=green
    fi
fi

# «Залипшая Wi-Fi-сессия»: радио отличное, но связь наружу СИЛЬНО нестабильна.
# Строгие пороги (loss≥10 / RTT_avg>250 / jitter>150 / RTT_max>800) — чтобы НЕ
# путать с «узким местом» (там RTT/потери ОК, низкая только скорость → не Wi-Fi).
# Требует known RSSI/SNR (только под root), иначе «сигнал хороший» не утверждаем.
STUCK=0
if [ "$WIFI" -eq 1 ] && [ "${CAPTIVE:-0}" -eq 0 ]; then
    _radio=0
    { [ -n "$RSSI" ] && [ "$RSSI" -ge -67 ]; } && _radio=1
    { [ -n "$SNR" ]  && [ "$SNR" -ge 30 ]; }   && _radio=1
    if [ "$_radio" -eq 1 ]; then
        { [ -n "$LOSS" ]    && [ "$LOSS" -ge 10 ]; }     && STUCK=1
        { [ -n "$RTT_AVG" ] && [ "$RTT_AVG" -gt 250 ]; } && STUCK=1
        { [ -n "$RTT_JIT" ] && [ "$RTT_JIT" -gt 150 ]; } && STUCK=1
        { [ -n "$RTT_MAX" ] && [ "$RTT_MAX" -gt 800 ]; } && STUCK=1
    fi
fi

# WORK — синтез решения «что делать» (то, что отличает утилиту от набора команд).
# Контекстный: зависит от того, открыта ли сеть, включён ли VPN и какой канал.
if [ "$MAIN_OK" -eq 1 ]; then
    # Хвост про качество канала (общий для всех веток). Пусто при green.
    QSUFFIX=""
    case "$QLEVEL" in
        yellow) QSUFFIX=", но канал нестабильный — видеосвязь, удалённый рабочий стол и VPN-работа могут дёргаться" ;;
        red)    QSUFFIX=", но канал плохой — видеосвязь, удалённый рабочий стол и большие загрузки будут страдать" ;;
    esac
    # Фаза 7: если при активном VPN проверяли AI — итог про то, ради чего VPN включён.
    # Это приоритетнее общих формулировок (но верхняя строка 🟡 ОТКРЫТАЯ всё равно видна).
    if   [ "$VPN_ACTIVE" -eq 1 ] && [ "${AI_RUN:-0}" -eq 1 ] && [ "$AI_TOTAL" -gt 0 ]; then
        if   [ "$AI_BAD" -gt 0 ]; then
            if   [ "$AI_UNREACH" -eq "$AI_TOTAL" ]; then
                # ВСЕ разом не ответили — похоже на временный сбой маршрута/VPN, а не блок
                # каждого сервиса. Не пугаем «смени страну»: сначала повтор.
                WORK="VPN включён, но все AI-домены разом не ответили — похоже на временный сбой; повтори (r/i), если повторяется — смени сервер VPN"
            elif [ "$AI_BAD" -eq "$AI_TOTAL" ] && [ "$AI_BLOCKED" -gt 0 ] && [ "$AI_UNREACH" -eq 0 ]; then
                WORK="VPN включён, но AI API-домены отклоняют доступ (регион или репутация IP) — смени страну или сервер VPN"
            elif [ "$AI_BAD" -eq "$AI_TOTAL" ]; then
                WORK="VPN включён, но AI API-домены недоступны через текущий сервер — смени страну/сервер VPN"
            else
                WORK="VPN включён, но ${AI_BAD_NAMES} отклонены/недоступны через текущий сервер — смени страну/сервер VPN"
            fi
        elif [ "$AI_UNCONF" -gt 0 ] && [ "$AI_OK" -eq 0 ]; then
            WORK="VPN включён; AI API-домены отвечают 403 «нужен ключ» — без ключа доступ не подтвердить"
        elif [ "$AI_UNCONF" -gt 0 ]; then
            WORK="VPN включён; отвечают: ${AI_OK_NAMES}; без ключа не подтверждены: ${AI_UNCONF_NAMES}${QSUFFIX}"
        else
            WORK="VPN включён; AI API-домены отвечают (${AI_OK_NAMES})${QSUFFIX}"
        fi
    # КЛЮЧЕВОЕ: ветвим по VPN_ACTIVE *и* SEC_OPEN. «Включи VPN» — ТОЛЬКО когда VPN
    # реально не активен (иначе инструмент сам видит VPN, но советует его включить).
    elif [ "$VPN_ACTIVE" -eq 1 ] && [ "$SEC_OPEN" -eq 1 ]; then
        WORK="можно работать; VPN включён, риск открытой сети снижен${QSUFFIX}"
    elif [ "$SEC_OPEN" -eq 1 ]; then
        WORK="для почты/банка/работы сначала включи VPN${QSUFFIX}"
    elif [ "$VPN_ACTIVE" -eq 1 ]; then
        WORK="можно работать; VPN включён${QSUFFIX:-, канал в порядке}"
    else
        WORK="можно работать${QSUFFIX:-; ничего срочного}"
    fi
else
    if   [ "$CAPTIVE" -eq 1 ]; then
        WORK="открой браузер и пройди вход в сеть (страница авторизации Wi-Fi)"
    elif [ "$HTTPS_OK" -eq 1 ] && [ "$DNS" -eq 0 ]; then
        WORK="в целом работает, но имена сайтов сбоят — если мешает: sudo fixnet --dns"
    elif [ "$NET" -eq 1 ] && [ "$DNS" -eq 0 ]; then
        WORK="DNS не работает — почини: sudo fixnet --dns"
    elif [ "$NET" -eq 1 ] && [ "$HTTPS_OK" -eq 0 ]; then
        WORK="сайты не открываются — возможно, VPN/блокировка; иначе нажми fixnet"
    else
        WORK="интернета нет — нажми кнопку fixnet"
    fi
fi

# --- ПАМЯТЬ (Фаза 1): узнавание сети + запись замера ---
# Пишем ТОЛЬКО здесь (collect_all = реальный замер; на t/a не пишем, на r — пишем).
# Узнавание читаем ДО записи текущего, чтобы свежий замер не попал в «прошлый раз».
RECALL=""
HIST_ON=1; [ "$(nl_config_get history)" = "off" ] && HIST_ON=0
if [ "$HIST_ON" -eq 1 ] && [ -n "${SSID:-}" ]; then
    RECALL=$(nl_history_recall "$SSID")
    [ "$NO_HISTORY" -ne 1 ] && nl_history_append "$(history_record_json)"
fi

nl_spin_stop   # измерения закончены — гасим спиннер перед печатью отчёта
}   # ===== конец collect_all =====

# ===================== РЕНДЕРЫ (печать УЖЕ собранных данных) =====================

# Верхний вердикт — общий для всех экранов: главное + риск открытой сети отдельно.
render_verdict() {
    echo
    echo -e "  ${MAIN_LINE}"
    [ -n "$SECURITY_LINE" ] && echo -e "  ${SECURITY_LINE}"
    echo
}

# Технический срез (--tech / клавиша t). Только печать — без новых замеров.
render_tech() {
    render_verdict
    echo -e "${D}Замер: ${STAMP}${N}"
    echo
    echo -e "${B}=== СЕТЬ И МАРШРУТ ===${N}"
    echo -e "  uplink-интерфейс: ${C}${IFACE}${N}${LOCAL_IP:+  (локальный IP: ${LOCAL_IP})}${WIFI_WARN}"
    echo -e "  MTU интерфейса:   ${C}${IFACE_MTU:-?}${N} ${D}(path MTU не проверялся; проверить: netinfo --mtu)${N}"
    echo -e "  ${D}Проверка TCP/UDP для VPN: netinfo --probe${N}"
    if [ -n "$GW" ]; then
        echo -e "  default-маршрут: ${G}${GW} -> ${DDEV}${N}"
    elif [ -n "$DDEV" ]; then
        echo -e "  default-маршрут: ${C}через VPN-туннель (${DDEV})${N}"
    else
        echo -e "  default-маршрут: ${R}ОТСУТСТВУЕТ${N}"
    fi
    # macOS ШТАТНО держит 3–4 utun (AWDL/Handoff/Tailscale), поэтому норма ≤4 —
    # иначе на чистой системе было бы ложное предупреждение.
    if [ "$UTUN" -le "${NL_UTUN_NORM:-4}" ]; then
        echo -e "  utun-туннелей:   ${G}${UTUN}${N} ${D}(норма)${N}"
    elif [ "$UTUN" -lt "${NL_UTUN_LOTS:-12}" ]; then
        echo -e "  utun-туннелей:   ${Y}${UTUN}${N} ${D}(много следов VPN/Network Extension)${N}"
    else
        echo -e "  utun-туннелей:   ${Y}${UTUN}${N} ${D}(очень много следов VPN/Network Extension)${N}"
    fi

    if [ "$WIFI" -eq 1 ] && { [ -n "$RSSI" ] || [ -n "$BAND" ]; }; then
        echo
        echo -e "${B}=== СИГНАЛ Wi-Fi ===${N}"
        [ -n "$RSSI" ] && echo -e "  RSSI: ${C}${RSSI} dBm${N} ($(rssi_word "$RSSI"))${NOISE:+, шум ${NOISE} dBm}${SNR:+, SNR ${SNR} дБ}"
        [ -n "$BAND" ] && echo -e "  диапазон: ${C}$(band_human "$BAND")${N}${CHAN:+, канал ${CHAN}}${CHW:+, ширина ${CHW} МГц}"
        if [ -n "$TXRATE" ]; then
            # Если линк-рейт неожиданно низкий при отличном сигнале/широком канале —
            # это сигнал (power-save, перегруженный эфир, MCS/GI, лимит AP/клиента).
            LR=$(echo "$TXRATE" | grep -oE '^[0-9]+')
            LRNOTE=""
            [ -n "$RSSI" ] && [ "$RSSI" -ge -60 ] && [ -n "$CHW" ] && [ "$CHW" -ge 80 ] && [ -n "$LR" ] && [ "$LR" -lt 500 ] \
                && LRNOTE=" (ниже ожидаемого для такого сигнала)"
            echo -e "  link rate: ${D}${TXRATE}${LRNOTE}${PHY:+, PHY ${PHY}}${MCS:+, MCS ${MCS}}${N}"
        fi
    fi

    echo
    echo -e "${B}=== СВЯЗЬ ===${N}"
    if [ -n "$GW" ]; then
        [ -n "$RG" ] && echo -e "  шлюз (${GW}): ${G}отвечает${N} ${D}(RTT ${RG} мс справочно — ICMP к роутеру непоказателен)${N}" \
                     || echo -e "  шлюз (${GW}): ${R}не отвечает${N}"
    fi
    if [ "$LATENCY_PROBE" = "ipv4" ]; then
        echo -e "  RTT наружу IPv4 (${PROBE_IP1}): ${G}min/avg/max ${RTT_MIN:-?}/${RTT_AVG:-?}/${RTT_MAX:-?} мс${N}${RTT_JIT:+ ${D}(джиттер ${RTT_JIT} мс, потери ${LOSS:-0}%)${N}}"
    elif [ "$LATENCY_PROBE" = "ipv6" ]; then
        echo -e "  RTT наружу IPv6 (${PROBE_IP6_1}): ${G}min/avg/max ${RTT_MIN:-?}/${RTT_AVG:-?}/${RTT_MAX:-?} мс${N}${RTT_JIT:+ ${D}(джиттер ${RTT_JIT} мс, потери ${LOSS:-0}%)${N}}"
        echo -e "  ${D}IPv4-ping не дал RTT; задержка измерена по IPv6. На общий verdict это не влияет.${N}"
    else
        echo -e "  пинг наружу (${PROBE_IP1}/${PROBE_IP2}): ${R}НЕТ${N}"
    fi
    [ "$HTTPS_OK" -eq 1 ] && echo -e "  HTTPS (443): ${G}сайты открываются${N}" \
                          || echo -e "  HTTPS (443): ${R}не открываются${N}"

    echo
    echo -e "${B}=== DNS ===${N}"
    [ "$DNS" -eq 1 ] && echo -e "  резолв (${PROBE_DNS1}/${PROBE_DNS2}): ${G}OK${N}" \
                     || echo -e "  резолв (${PROBE_DNS1}/${PROBE_DNS2}): ${R}НЕ РАБОТАЕТ${N}"
    [ -n "$RESOLVERS" ] && echo -e "  серверы: ${D}${RESOLVERS}${N}"
    case "$RESOLVERS" in
        *100.100.100.100*|*fd7a:115c:a1e0*) echo -e "  ${D}Tailscale DNS: обнаружен (split-VPN, внешний IP не меняет)${N}" ;;
    esac

    if [ "$WANT_GEO" -eq 1 ]; then
        echo
        echo -e "${B}=== ГДЕ МЫ (внешний IP) ===${N}"
        if [ -n "$XIP" ]; then
            echo -e "  внешний IP: ${C}${XIP}${N}"
            [ -n "$COUNTRY" ] && echo -e "  страна:     ${C}${COUNTRY}${CITY:+, ${CITY}}${N}"
            [ -n "$ORG" ]     && echo -e "  провайдер:  ${D}${ORG}${N}"
        else
            echo -e "  ${Y}geo недоступно (${GEO_ERR})${N}"
        fi
    fi

    if [ "$WANT_SPEED" -eq 1 ]; then
        echo
        echo -e "${B}=== СКОРОСТЬ ===${N}"
        if [ -n "$SPEED_ERR" ]; then
            echo -e "  ${D}пропущено — ${SPEED_ERR}${N}"
        else
            echo -e "  ${D}тест ~$((SPEED_BYTES/1000000)) МБ в каждую сторону${N}"
            print_speed "приём:   " "$DBPS"
            print_speed "передача:" "$UBPS"
        fi
    fi
    echo
    echo -e "${D}Состояние: $(nl_state_dir) · история: $(nl_config_get history)${N}"
    echo -e "${D}Примечание: качество — по внешнему RTT/HTTPS/скорости; RTT до шлюза справочный.${N}"
    echo
}

# Человеческий экран (по умолчанию / клавиша r). Только печать собранных данных.
render_human() {
    render_verdict

# Память: узнавание сети по прошлым визитам (если включена история и сеть знакома).
[ -n "${RECALL:-}" ] && echo -e "  ${D}Память:             ${RECALL}${N}"

# Captive portal: подсказка, как зайти (открыть портал — пункт меню o, без мутаций).
if [ "${CAPTIVE:-0}" -eq 1 ]; then
    if [ -n "${CAP_URL:-}" ]; then
        echo -e "  Вход в сеть:        ${Y}нужен вход${N} ${D}(в меню — клавиша o)${N}"
    else
        echo -e "  Вход в сеть:        ${Y}нужен вход${N} ${D}(открой в браузере http://captive.apple.com)${N}"
    fi
fi

# --- Где нас видит мир + статус VPN (по-человечески) ---
if [ "$WANT_GEO" -eq 1 ]; then
    if [ -n "$XIP" ]; then
        echo -e "  Выход в интернет:   ${C}$(country_name "$COUNTRY")${CITY:+, $(city_name "$CITY")}${N}"
        [ -n "$ORG" ] && echo -e "  Провайдер выхода:   ${D}$(short_org "$ORG")${N}"
        echo -e "  Внешний IP:         ${D}${XIP}${N}"
        # VPN определяем по факту (default route на utun), не по geo/IP. Если VPN
        # выключен — нейтрально, без тревоги; если включён — гео выше и есть выход.
        # Честно: «не обнаружен» (а не «выключен») — Tailscale split-VPN может быть
        # активен, но не менять внешний IP, т.е. full-tunnel-выхода нет.
        if [ "$VPN_ACTIVE" -eq 1 ]; then
            # Спокойно: активен + страна выхода (та же гео, что выше). Не пугаем
            # «отвалился» — мы не знаем ОЖИДАЕМУЮ страну, поэтому несовпадение не
            # утверждаем. Намёк «если ожидал другую — сервер не тот» нейтральный.
            VLOC=""; [ -n "$COUNTRY" ] && VLOC=" — $(country_name "$COUNTRY")${CITY:+, $(city_name "$CITY")}"
            echo -e "  VPN-выход:          ${G}активен${N}${VLOC:+ ${D}${VLOC}${N}}"
            echo -e "  ${D}Проверка VPN:       если ожидал другую страну — проверь выбранный сервер VPN${N}"
        else
            echo -e "  VPN-выход:          ${D}не обнаружен${N}"
        fi
    elif [ -n "$GEO_ERR" ] && [ "$GEO_ERR" != "нет связи" ]; then
        echo -e "  Выход в интернет:   ${Y}не удалось узнать (${GEO_ERR})${N}"
    fi
fi

# Через что реально подключены (Фаза 6): тип линка + диапазон Wi-Fi инлайн. Ставим
# после VPN-выхода: сначала «куда нас видит мир», затем «через что физически идём».
LINK_BAND=""
[ "$WIFI" -eq 1 ] && [ -n "$BAND" ] && \
    LINK_BAND=" · $(band_human "$BAND")${CHAN:+, канал ${CHAN}}${CHW:+, ${CHW} МГц}"
echo -e "  Подключение:        ${C}${CONN}${LINK_BAND}${N}${WIFI_WARN}"
# 5G/LTE с Mac НЕ определяется (для Mac раздача — просто IP-линк). Честная подсказка
# только при раздаче, чтобы не мозолила глаза в обычном Wi-Fi.
[ "$IS_HOTSPOT" -eq 1 ] && \
    echo -e "  ${D}Сотовая сеть:       5G/LTE с Mac не определяется — смотри на iPhone${N}"

# Время замера — СВЕРХУ, чтобы свежесть данных была видна сразу (а не внизу).
echo -e "  ${D}Замер:              ${STAMP_SHORT}${N}"

# --- Качество канала: сигнал + задержка + сайты + скорость одним блоком ---
echo
echo -e "  Качество:"
# Сигнал Wi-Fi: уровень (dBm) + качество + диапазон/канал. Цвет — по уровню.
if [ "$WIFI" -eq 1 ] && [ -n "$RSSI" ]; then
    if   [ "$RSSI" -ge -67 ]; then SC=$G
    elif [ "$RSSI" -ge -75 ]; then SC=$Y
    else SC=$R; fi
    echo -e "     сигнал Wi-Fi:    ${SC}${RSSI} dBm — $(rssi_word "$RSSI")${N}${BAND:+ ${D}($(band_human "$BAND")${CHAN:+, канал ${CHAN}}${CHW:+, ${CHW} МГц})${N}}"
    [ "$RSSI" -lt -67 ] && \
        echo -e "                      ${D}слабовато — ближе к роутеру или прямая видимость${N}"
elif [ "$WIFI" -eq 1 ] && [ -n "$BAND" ]; then
    echo -e "     сигнал Wi-Fi:    ${D}$(band_human "$BAND")${CHAN:+, канал ${CHAN}}${CHW:+, ${CHW} МГц} (силу покажет кнопка/sudo)${N}"
fi
if [ -n "$RW" ]; then
    _v6note=""; [ "$LATENCY_PROBE" = "ipv6" ] && _v6note=" ${D}(IPv6)${N}"
    echo -e "     задержка:        ${G}${RW} мс${N} ${D}— $(rtt_word "$RW")$(rtt_stability_word "${RTT_JIT:-0}")${N}${_v6note}"
elif [ "$HTTPS_OK" -eq 1 ]; then
    echo -e "     задержка:        ${D}не измерить (пинг режется сетью)${N}"
fi
if [ -n "$LOSS" ] && [ "$LOSS" -gt 0 ]; then
    if [ "$LOSS" -ge 10 ]; then LC=$R; else LC=$Y; fi
    echo -e "     потери:          ${LC}${LOSS}% пакетов${N} ${D}— рвёт звонки/VPN${N}"
fi
[ "$HTTPS_OK" -eq 1 ] && echo -e "     сайты:           ${G}открываются${N}" \
                      || echo -e "     сайты:           ${R}не открываются${N}"
# Строка DNS (Фаза 8): различаем «UDP-53 молчит, но DoH резолвит» от «не резолвится вовсе».
if [ "$DNS" -eq 0 ] && { [ "$NET" -eq 1 ] || [ "$HTTPS_OK" -eq 1 ]; }; then
    if   [ "$DOH_OK" = "1" ] && [ "$HTTPS_OK" -eq 1 ]; then
        echo -e "     адреса сайтов:   ${Y}обычная проверка имён не работает, но защищённая (через HTTPS) проходит${N}"
    elif [ "$DOH_OK" = "1" ]; then
        echo -e "     адреса сайтов:   ${Y}обычная проверка имён не работает; защищённая проходит${N}"
    elif [ "$DOH_OK" = "0" ]; then
        echo -e "     адреса сайтов:   ${R}имена сайтов не находятся ни обычным, ни защищённым способом${N}"
    else
        echo -e "     адреса сайтов:   ${R}не находятся${N}"
    fi
fi
if [ "$WANT_SPEED" -eq 1 ] && [ -z "$SPEED_ERR" ]; then
    [ -n "$DL_M" ] && echo -e "     скачивание:      ${G}${DL_M} Мбит/с${N} ${D}— $(speed_word "$DL_M")${N}" \
                   || echo -e "     скачивание:      ${R}замер не удался${N}"
    [ -n "$UL_M" ] && echo -e "     отдача:          ${G}${UL_M} Мбит/с${N} ${D}— $(speed_word "$UL_M")${N}" \
                   || echo -e "     отдача:          ${R}замер не удался${N}"
fi
# Узкое место: сигнал отличный, а скорость низкая => причина НЕ в Wi-Fi, а дальше
# (провайдер/хотспот/VPN/маршрут). Сильно повышает диагностическую ценность.
if [ "$WIFI" -eq 1 ] && [ -n "$RSSI" ] && [ "$RSSI" -ge -60 ] && [ -n "$DL_M" ] && [ "$DL_M" -lt 15 ]; then
    echo -e "     узкое место:     ${D}не Wi-Fi — сигнал отличный, ограничение дальше по цепочке${N}"
fi

# Нейросети (Фаза 7): компактный блок, если проверка запускалась (VPN активен + не --no-ai).
if [ -n "${AI_RESULTS:-}" ]; then
    echo
    ai_render "$AI_RESULTS"
fi

# --- Пригодность для VPN + ВЫВОД (синтез решения) ---
# Формулировка зависит от того, включён ли VPN: при выключенном это «пригодна ли
# сеть для VPN», при включённом — «как себя ведёт VPN».
echo
if [ -n "$QLEVEL" ]; then
    case "$QLEVEL" in
        green)  echo -e "  Для VPN:            ${G}🟢 хорошо${N}" ;;
        yellow) echo -e "  Для VPN:            ${Y}🟡 подойдёт, но ${QWHY}${N}" ;;
        red)    echo -e "  Для VPN:            ${R}🔴 плохо — ${QWHY}${N}" ;;
    esac
fi
echo -e "  Вывод:              ${WORK}"

# DNS-ремонт: рекомендация (НЕ действие — netinfo сам DNS не меняет). Ветвление по DoH
# (Фаза 8): не зовём ремонт там, где сайты открываются и DoH резолвит (ложная тревога);
# зовём при «UDP-53 мёртв, DoH жив, сайты не открываются»; честно оговариваем, если
# мёртв и DoH (ремонт может не помочь). DoH-успех НЕ выдаём за «DNS работает».
if [ "$DNS" -eq 0 ] && [ "${CAPTIVE:-0}" -eq 0 ] && { [ "$NET" -eq 1 ] || [ "$HTTPS_OK" -eq 1 ]; }; then
    if   [ "$DOH_OK" = "1" ] && [ "$HTTPS_OK" -eq 1 ]; then
        : # ложной тревоги нет — строка «адреса (DNS)» уже сказала «резолв через DoH»; ремонт не нужен
    elif [ "$DOH_OK" = "1" ]; then
        echo
        echo -e "  ${Y}Обычная проверка имён сайтов, вероятно, не работает; защищённая — проходит.${N}"
        [ "${TS_DNS:-0}" -eq 1 ] && \
            echo -e "  ${D}Обнаружен Tailscale DNS — вероятно, не работает upstream DNS текущей сети.${N}"
        echo -e "  Ремонт: ${Y}sudo fixnet --dns${N}"
    elif [ "$DOH_OK" = "0" ]; then
        echo
        echo -e "  ${R}Имена сайтов не находятся ни обычным, ни защищённым способом${N} — проблема глубже, ${D}fixnet --dns может не помочь.${N}"
    else
        echo
        echo -e "  ${Y}DNS не работает:${N} интернет по IP есть, но имена сайтов не находятся."
        [ "${TS_DNS:-0}" -eq 1 ] && \
            echo -e "  ${D}Обнаружен Tailscale DNS — вероятно, не работает upstream DNS текущей сети.${N}"
        echo -e "  Ремонт: ${Y}sudo fixnet --dns${N}"
    fi
fi

# Залипшая Wi-Fi-сессия: рекомендация (НЕ действие). Осторожно: «нестабильна
# наружу» (потери на внешнем ping не доказывают, что кадры падают на самом Wi-Fi).
if [ "${STUCK:-0}" -eq 1 ]; then
    echo
    echo -e "  ${Y}Похоже, Wi-Fi-сессия залипла:${N} сигнал отличный, но связь наружу сильно нестабильна."
    echo -e "  Иногда помогает передёрнуть Wi-Fi: ${Y}sudo fixnet --wifi-reset${N}"
    echo -e "  ${D}⚠ это на пару секунд оборвёт все соединения (звонки, загрузки, VPN).${N}"
fi

# Подробные советы инлайн НЕ показываем (перегружало экран + давало казус «VPN
# выключен, а советы про тормозящий VPN»). Их печатает render_advice (клавиша a
# или флаг --advice). Здесь — только короткий указатель, когда канал не «хорошо».
if [ "$QLEVEL" = yellow ] || [ "$QLEVEL" = red ]; then
    echo -e "  ${D}Подробные советы: netinfo --advice${N}"
fi
# Соседние сети — read-only скан (медленный, потому отдельной командой/клавишей).
[ "$WIFI" -eq 1 ] && echo -e "  ${D}Соседние сети: netinfo --scan${N}"

# Старые VPN-следы — по-человечески «туннелей» (слово utun остаётся в --tech). Пороги
# общие из netlib (NL_UTUN_*), чтобы netinfo и fixnet не противоречили. Без слова
# «утечка» (звучит как security-leak): это просто следы VPN/Network Extension/Private Relay.
if [ "$UTUN" -ge "$NL_UTUN_LOTS" ]; then
    echo
    echo -e "  ${Y}⚠ Очень много туннелей (utun): ${UTUN}.${N}"
    echo -e "  ${D}  Если есть обрывы — закрой VPN-клиенты и перезагрузи Mac.${N}"
elif [ "$UTUN" -ge "$NL_UTUN_MANY" ]; then
    echo
    echo -e "  ${Y}⚠ Много VPN/Network Extension туннелей: ${UTUN} — возможны старые следы VPN.${N}"
    echo -e "  ${D}  Не срочно. Если начнутся обрывы — закрой VPN-клиенты и перезагрузи Mac.${N}"
fi
}   # ===== конец render_human =====

# Контекстные советы (--advice / клавиша a). Ветвление по ситуации, чтобы не было
# казуса «VPN выключен, а советы про тормозящий VPN».
render_advice() {
    echo
    # Локальная проверка «Wi-Fi хороший, но скорость низкая» — переиспользуем.
    local wifi_ok_slow=0
    [ "$WIFI" -eq 1 ] && [ -n "$RSSI" ] && [ "$RSSI" -ge -60 ] && [ -n "$DL_M" ] && [ "$DL_M" -lt 15 ] && wifi_ok_slow=1

    # Открытая сеть: характер совета зависит от того, активен ли VPN (он снижает риск).
    if [ "$SEC_OPEN" -eq 1 ]; then
        if [ "$VPN_ACTIVE" -eq 1 ]; then
            echo -e "  ${D}Открытая Wi-Fi сеть: риск снижает активный VPN; всё равно избегай паролей/платежей, если VPN отвалится.${N}"
        else
            echo -e "  ${D}Открытая Wi-Fi сеть: для почты, банка и работы сначала включи VPN.${N}"
        fi
        echo
    fi

    # Приоритет — по фактической причине «сейчас».
    if [ "$WIFI" -eq 1 ] && [ -n "$RSSI" ] && [ "$RSSI" -lt -67 ]; then
        echo -e "  ${D}Совет (слабый сигнал Wi-Fi):${N}"
        echo -e "  ${D}  • подойди ближе к роутеру / прямая видимость;${N}"
        echo -e "  ${D}  • выбери 5 ГГц или 6 ГГц, если сеть их даёт;${N}"
        echo -e "  ${D}  • избегай 2.4 ГГц в людных местах (помехи).${N}"
    elif [ "$VPN_ACTIVE" -eq 0 ] && [ "$SEC_OPEN" -eq 1 ]; then
        echo -e "  ${D}Совет (сеть открытая):${N}"
        [ "$wifi_ok_slow" -eq 1 ] && \
        echo -e "  ${D}  • Wi-Fi-сигнал отличный — узкое место не в радио (провайдер/хотспот/маршрут);${N}"
        echo -e "  ${D}  • если после включения VPN станет медленно — смени сервер ближе;${N}"
        echo -e "  ${D}  • при важной работе — iPhone по USB.${N}"
    elif [ "$VPN_ACTIVE" -eq 1 ]; then
        echo -e "  ${D}Совет (если VPN тормозит):${N}"
        echo -e "  ${D}  • смени VPN-сервер ближе;${N}"
        echo -e "  ${D}  • другой протокол: Lightway / IKEv2 / OpenVPN TCP 443;${N}"
        echo -e "  ${D}  • отключи второй VPN/Tailscale, если не нужен;${N}"
        echo -e "  ${D}  • при важной работе — iPhone по USB.${N}"
    elif [ "$wifi_ok_slow" -eq 1 ]; then
        echo -e "  ${D}Wi-Fi как радиоканал хороший: сигнал ${RSSI} dBm${BAND:+, $(band_human "$BAND")}${CHAN:+, канал ${CHAN}}.${N}"
        echo -e "  ${D}Дело не в расстоянии до роутера. Вероятные причины: медленный внешний канал,${N}"
        echo -e "  ${D}перегруженный хотспот/отель, VPN, роуминг, ограничение провайдера или раздача.${N}"
        echo -e "  ${D}Что попробовать:${N}"
        echo -e "  ${D}  1. Это отельный/публичный Wi-Fi — посмотри соседние сети: netinfo --scan;${N}"
        [ "$IS_HOTSPOT" -eq 1 ] && \
        echo -e "  ${D}  2. Это раздача с телефона — глянь на iPhone, сейчас 5G или LTE;${N}"
        echo -e "  ${D}  3. Если включён VPN — сравни скорость временно без него;${N}"
        echo -e "  ${D}  4. Для тяжёлых загрузок канал слабый (${DL_M} Мбит/с) — отложи большое.${N}"
    else
        echo -e "  ${D}Совет:${N}"
        [ "$WIFI" -eq 1 ] && echo -e "  ${D}  • при тормозах — ближе к роутеру / 5 ГГц / меньше помех;${N}"
        echo -e "  ${D}  • при важной работе — iPhone по USB;${N}"
        echo -e "  ${D}  • включай VPN только если он нужен (часто замедляет).${N}"
    fi
    # Узкий канал на 5/6 ГГц — частая причина низкой скорости при отличном сигнале
    # (ограничение самой точки доступа / плотный эфир). В основной вывод не тащим.
    if [ "$WIFI" -eq 1 ] && [ "$CHW" = "20" ] && { [ "$BAND" = "5GHz" ] || [ "$BAND" = "6GHz" ]; }; then
        echo
        echo -e "  ${D}Канал узкий: 20 МГц на $(band_human "$BAND") — скорость может ограничивать сама точка доступа.${N}"
    fi
    # Контекстный указатель на пробу выхода: когда VPN активен (тормозит) или сеть
    # открытая и его захотят включить. В обычный вывод НЕ тащим — только сюда.
    if [ "$VPN_ACTIVE" -eq 1 ] || [ "$SEC_OPEN" -eq 1 ]; then
        echo -e "  ${D}VPN тормозит или не подключается? Проверь сетевые ограничения: netinfo --probe${N}"
    fi
}

# Интерактивное меню (только в терминале). t/a РЕНДЕРЯТ уже собранное (без новых
# замеров); пересобирает данные только r — поэтому цифры на экранах не «прыгают».
# Открыть страницу входа в сети в браузере. Под root — в сессии пользователя
# (иначе откроется в контексте root). НЕ мутация сети — поэтому допустимо в netinfo.
open_portal() {
    local url="${CAP_URL:-http://captive.apple.com}"
    if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
        sudo -u "$SUDO_USER" open "$url" 2>/dev/null
    else
        open "$url" 2>/dev/null
    fi
    echo -e "  ${D}Открываю страницу входа в браузере…${N}"
}

interactive_menu() {
    local choice opt="" wopt=""
    [ "${CAPTIVE:-0}" -eq 1 ] && opt=" · o — вход в сеть"
    [ "${WIFI:-0}" -eq 1 ] && wopt=" · s — Wi-Fi сети"
    while true; do
        echo
        printf "  Enter — закрыть · t — детали · a — советы · r — обновить%s%s · i — AI · ? — пояснения: " "$opt" "$wopt"
        read -r choice || break
        case "$choice" in
            t|T) divider; render_tech ;;
            a|A) divider; render_advice ;;
            s|S) divider; scan_report ;;
            i|I) divider; AI_MODE="all"; AI_LIST=0; ai_report ;;   # по `i` — полный набор (+Gemini+Z.AI)
            \?)  divider; render_explain ;;
            r|R) divider; collect_all; render_human
                 [ "${CAPTIVE:-0}" -eq 1 ] && opt=" · o — вход в сеть" || opt=""
                 [ "${WIFI:-0}" -eq 1 ] && wopt=" · s — Wi-Fi сети" || wopt="" ;;
            o|O) open_portal ;;
            *)   break ;;
        esac
    done
}

# Режим --mtu: read-only измерение path MTU (медленный DF-зонд по двум якорям) +
# рекомендация. НЕ меняет MTU (это делает fixnet --mtu). Порог рекомендации ≥8 байт.
mtu_report() {
    local ifc ifmtu path diff extdev vpn=0
    ifc=$(detect_iface)
    ifmtu=$(networksetup -getMTU "$ifc" 2>/dev/null | sed -nE 's/.*Current Setting: ([0-9]+).*/\1/p')
    [ -z "$ifmtu" ] && ifmtu=$(ifconfig "$ifc" 2>/dev/null | grep -o 'mtu [0-9]*' | awk '{print $2}')
    echo
    echo -e "${B}=== MTU ===${N}"
    [ -t 1 ] || echo -e "  ${D}Измеряю path MTU (DF-зонд до ${PROBE_IP1} / ${PROBE_IP2})…${N}"
    nl_spin_start "измеряю path MTU (DF-зонд)"
    path=$(nl_path_mtu "$PROBE_IP1" "$PROBE_IP2")
    nl_spin_stop
    extdev=$(route -n get "$PROBE_IP1" 2>/dev/null | awk '/interface:/{print $2}')
    case "$extdev" in utun*) vpn=1 ;; esac
    if [ -z "$path" ]; then
        echo -e "  ${Y}Не удалось измерить:${N} DF/ICMP-зонд не проходит даже на малом размере."
        echo -e "  ${D}Менять MTU не нужно (нет надёжных данных).${N}"
        echo
        return
    fi
    echo -e "  Path MTU:   ${C}${path}${N}  ${D}(минимум по ${PROBE_IP1} / ${PROBE_IP2})${N}"
    echo -e "  Интерфейс:  ${C}${ifmtu:-?}${N}  (${ifc})"
    [ "$vpn" -eq 1 ] && echo -e "  ${Y}Сейчас full-tunnel VPN: измерен путь туннеля, не физической сети.${N}"
    echo -e "  ${D}Измерено до публичных якорей; путь до конкретного VPN-сервера может отличаться.${N}"
    diff=$(( ${ifmtu:-1500} - path ))
    if   [ "$diff" -le 0 ]; then
        echo -e "  Вывод: ${G}MTU в норме${N} — менять не нужно."
    elif [ "$diff" -lt 8 ]; then
        echo -e "  Вывод: сужение всего ${diff} б — ${D}менять не рекомендую${N}."
    elif [ "$diff" -le 40 ]; then
        echo -e "  Вывод: ${Y}есть сужение пути на ${diff} б.${N} TCP обычно живёт (MSS-clamping), но VPN/UDP/тяжёлый контент могут зависать."
        echo -e "  Ремонт: ${Y}sudo fixnet --mtu${N}"
    else
        echo -e "  Вывод: ${R}выраженное сужение пути на ${diff} б.${N} Тяжёлый контент/VPN/TLS могут зависать."
        echo -e "  Ремонт: ${Y}sudo fixnet --mtu${N}"
    fi
    echo
}

# Режим --probe (Фаза 5): проба сетевого ВЫХОДА для оценки пригодности VPN-протоколов.
# read-only, без root, без записи state, fixnet НЕ участвует.
# ПРИНЦИП ЧЕСТНОСТИ: TCP-connect доказуем (open/closed), UDP — НЕТ. Поэтому UDP
# меряем ТОЛЬКО через рефлекторы, ОБЯЗАННЫЕ ответить (DNS/NTP/STUN), и выводы делаем
# по ним — с «похоже / скорее всего». НЕ стучим в 1194/51820/500/4500 пустыми UDP
# (молчание недоказуемо). НЕ пишем «порт VPN заблокирован» / «DPI доказан».
probe_tcp() {  # host port -> "open"|"closed"  (через nc; nc на macOS есть штатно)
    command -v nc >/dev/null 2>&1 || { echo "skip"; return; }
    nc -G2 -z "$1" "$2" >/dev/null 2>&1 && echo "open" || echo "closed"
}
probe_udp_dns() {  # DNS over UDP 53 к 1.1.1.1: непустой ответ = рефлектор ответил
    command -v dig >/dev/null 2>&1 || { echo "skip"; return; }
    local a; a=$(dig +short +time=2 +tries=1 @1.1.1.1 ya.ru 2>/dev/null | head -1)
    [ -n "$a" ] && echo "yes" || echo "no"
}
probe_udp_ntp() {  # NTP over UDP 123: ответ sntp содержит "+/-" (offset +/- err)
    command -v sntp >/dev/null 2>&1 || { echo "skip"; return; }
    local h o
    for h in time.apple.com time.google.com; do
        o=$(sntp -t 2 "$h" 2>/dev/null)
        case "$o" in *"+/-"*) echo "yes"; return ;; esac
    done
    echo "no"
}
probe_udp_stun() {  # STUN over UDP 3478 (cloudflare) → fallback 19302 (google), ≤2с/якорь
    command -v python3 >/dev/null 2>&1 || { echo "skip"; return; }
    python3 - <<'PY' 2>/dev/null
import socket, os
def stun(host, port):
    msg = b'\x00\x01\x00\x00' + b'\x21\x12\xa4\x42' + os.urandom(12)
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(2)
    try:
        s.sendto(msg, (host, port)); d, _ = s.recvfrom(1024)
        return len(d) >= 20
    except Exception:
        return False
    finally:
        s.close()
print("yes" if (stun("stun.cloudflare.com", 3478) or stun("stun.l.google.com", 19302)) else "no")
PY
}
# Печать факта рефлектора с учётом "skip" (инструмента нет → "не проверено").
_probe_word() { case "$1" in yes) echo "${G}отвечает${N}";; no) echo "${R}не ответил${N}";; *) echo "${D}не проверено${N}";; esac; }

probe_report() {
    local tcp_ip tcp_dom udp_dns udp_ntp udp_stun
    echo
    echo -e "${B}=== Проверка ограничений TCP/UDP для VPN ===${N}"
    [ -t 1 ] || echo -e "  ${D}Проверяю TCP/UDP-выход…${N}"
    nl_spin_start "проверяю TCP/UDP-выход"
    tcp_ip=$(probe_tcp 1.1.1.1 443)          # IP-baseline без DNS
    tcp_dom=$(probe_tcp www.apple.com 443)   # требует DNS — для развязки «DNS vs сеть»
    udp_dns=$(probe_udp_dns)
    udp_ntp=$(probe_udp_ntp)
    udp_stun=$(probe_udp_stun)
    nl_spin_stop

    # --- Таблица фактов (только то, что реально проверено) ---
    echo
    echo -e "  ${D}TCP:${N}"
    case "$tcp_ip"  in open) echo -e "    1.1.1.1:443          ${G}open${N}";; closed) echo -e "    1.1.1.1:443          ${R}не открылся${N}";; *) echo -e "    1.1.1.1:443          ${D}не проверено (нет nc)${N}";; esac
    case "$tcp_dom" in open) echo -e "    www.apple.com:443    ${G}open${N}";; closed) echo -e "    www.apple.com:443    ${R}не открылся${N}";; *) echo -e "    www.apple.com:443    ${D}не проверено${N}";; esac
    echo -e "  ${D}UDP-рефлекторы:${N}"
    echo -e "    53/DNS @1.1.1.1      $(_probe_word "$udp_dns")"
    echo -e "    123/NTP              $(_probe_word "$udp_ntp")"
    echo -e "    3478/STUN            $(_probe_word "$udp_stun")"
    echo

    # --- Вывод (по весовой логике; TCP-baseline обязателен для UDP-вердикта) ---
    local tcp_base=0
    [ "$tcp_ip" = "open" ] || [ "$tcp_dom" = "open" ] && tcp_base=1

    if [ "$tcp_base" -eq 0 ]; then
        echo -e "  Вывод: ${Y}TCP 443 наружу не открывается.${N}"
        echo -e "  ${D}Это сначала про связь / портал / локальную фильтрацию, а не про DPI."
        echo -e "  Проверь основной осмотр: netinfo${N}"
        echo
        return
    fi

    # «IP открыт, домен — нет» = это DNS, не DPI (важная развязка).
    if [ "$tcp_ip" = "open" ] && [ "$tcp_dom" = "closed" ]; then
        echo -e "  ${Y}Замечание:${N} TCP до 1.1.1.1 открыт, до www.apple.com — нет → ${D}похоже на проблему DNS, не сети.${N}"
    fi

    # Весовая логика UDP (STUN — лучший прокси произвольного UDP, потому весомее).
    local strong=0 yescount=0
    [ "$udp_dns"  = "yes" ] && yescount=$((yescount+1))
    [ "$udp_ntp"  = "yes" ] && yescount=$((yescount+1))
    [ "$udp_stun" = "yes" ] && yescount=$((yescount+1))
    { [ "$udp_stun" = "yes" ] || [ "$yescount" -ge 2 ]; } && strong=1

    if [ "$strong" -eq 1 ]; then
        echo -e "  Вывод: ${G}Общий UDP-выход работает. Полной блокировки UDP не видно.${N}"
        echo -e "  ${D}Если конкретный VPN всё равно не работает — возможна точечная блокировка"
        echo -e "  порта/протокола, MTU или проблема сервера (это отсюда не доказывается).${N}"
    elif [ "$yescount" -ge 1 ]; then
        echo -e "  Вывод: ${Y}Проходит лишь часть UDP (служебные порты), произвольный UDP отвечает плохо.${N}"
        echo -e "  ${D}UDP-VPN может не подключаться. Попробуй VPN через TCP 443 / Lightway TCP / OpenVPN TCP.${N}"
    else
        echo -e "  Вывод: ${Y}TCP 443 работает, но UDP-рефлекторы не ответили.${N}"
        echo -e "  ${D}UDP-VPN, скорее всего, не подключится. Попробуй режим TCP 443 / Lightway TCP / OpenVPN TCP.${N}"
    fi
    echo -e "  ${D}Если VPN всё равно плохой — проверь MTU (netinfo --mtu) и смени сервер/протокол.${N}"
    echo
}

# Режим --scan (Фаза 6): соседние Wi-Fi сети (read-only). `airport -s` удалён в новых
# macOS, поэтому источник — system_profiler SPAirPortDataType (блок «Other Local
# Wi-Fi Networks»). Сигнал macOS отдаёт НЕ для всех сетей — где нет, честно «—».
# Сам НЕ подключаемся (read-only + открытые сети без VPN небезопасны).
# Пояснения простым языком (Фаза 12): `netinfo --explain` или клавиша `?` в меню.
# Цель — чтобы термины из основного вывода были понятны не-сисадмину. Технические
# детали остаются в --tech; здесь — «что это значит» по-человечески.
render_explain() {
    echo
    echo -e "${B}=== Что это значит (простыми словами) ===${N}"
    echo
    echo -e "  ${C}Адреса сайтов (DNS)${N}"
    echo -e "  ${D}  «Телефонная книга» интернета: переводит site.com в IP-адрес. Если не работает —${N}"
    echo -e "  ${D}  сайт не откроется даже при отличном Wi-Fi.${N}"
    echo -e "  ${C}Защищённая проверка имён (DoH)${N}"
    echo -e "  ${D}  То же, но через зашифрованный HTTPS. Если обычная не работает, а защищённая${N}"
    echo -e "  ${D}  проходит — интернет есть, но проверка имён в этой сети ведёт себя странно.${N}"
    echo -e "  ${C}Соединение с сервером (TCP)${N}"
    echo -e "  ${D}  Попытка «дозвониться» до сервера. Не проходит — до сервера не достучаться.${N}"
    echo -e "  ${C}Защищённое соединение (TLS)${N}"
    echo -e "  ${D}  Тот самый «замочек». Если соединение есть, а защищённое не встаёт — сервер${N}"
    echo -e "  ${D}  найден, но безопасный канал рвётся (фильтрация, прокси, сбой сертификата).${N}"
    echo -e "  ${C}Ответ сервера (HTTP)${N}"
    echo -e "  ${D}  403 — «доступ запрещён» (регион, IP VPN, антибот, политика сайта).${N}"
    echo -e "  ${D}  401 — сервер жив, но требует вход/ключ.   451 — ограничен по юр. причинам.${N}"
    echo -e "  ${C}Задержка (RTT) и нестабильность (джиттер)${N}"
    echo -e "  ${D}  Время «туда-обратно» до проверочного сервера и насколько оно прыгает.${N}"
    echo -e "  ${D}  Большие значения и скачки = рывки в звонках, VPN, SSH, видеосвязи.${N}"
    echo -e "  ${C}Туннели (utun)${N}"
    echo -e "  ${D}  Виртуальные туннели macOS (их создают VPN и системные расширения). Много —${N}"
    echo -e "  ${D}  не авария, но при обрывах стоит закрыть VPN-клиенты или перезагрузить Mac.${N}"
    echo -e "  ${C}AI API-домены${N}"
    echo -e "  ${D}  Входы к сервисам вроде OpenAI или Claude для программного доступа. Если домен${N}"
    echo -e "  ${D}  отвечает — сеть до сервиса проходит, но это ещё НЕ проверка аккаунта, API-ключа${N}"
    echo -e "  ${D}  и не запрос к самой модели.${N}"
    echo -e "  ${C}Tailscale DNS (100.100.100.100)${N}"
    echo -e "  ${D}  Обслуживает внутренние имена твоей tailnet. Сам по себе НЕ означает, что весь${N}"
    echo -e "  ${D}  внешний интернет идёт через Tailscale (это split-VPN, внешний IP он не меняет).${N}"
    echo
    echo -e "  ${D}Технические значения (TLS-мс, HTTP-коды, RTT min/avg/max) — в netinfo --tech.${N}"
    echo
}

# Набор СОХРАНЁННЫХ Mac сетей (для метки «★ сохранена»). Источник тот же, что у
# wifi_hidden — known-networks.plist (root-only). Печатает имена (NFC), по одному в строке;
# пусто, если не root / нет python3 / файл не прочитался. ВАЖНО: отсутствие имени в этом
# списке НЕ значит «не сохранена» (без root мы его вообще не видим) — поэтому метку
# ставим только при наличии, а её отсутствие ничего не утверждает.
wifi_known_ssids() {
    [ "$(id -u)" -eq 0 ] || { echo ""; return; }
    command -v python3 >/dev/null 2>&1 || { echo ""; return; }
    python3 - <<'PY' 2>/dev/null
import plistlib, unicodedata
p="/Library/Preferences/com.apple.wifi.known-networks.plist"
try: d=plistlib.load(open(p,"rb"))
except Exception: raise SystemExit(0)
PFX="wifi.network.ssid."; seen=set()
for k,e in d.items():
    if not isinstance(e,dict): continue
    name=None; b=e.get("SSID")
    if isinstance(b,(bytes,bytearray)):
        try: name=b.decode("utf-8")
        except Exception: name=None
    if name is None and k.startswith(PFX): name=k[len(PFX):]
    if name:
        n=unicodedata.normalize("NFC",name)
        if n not in seen: seen.add(n); print(n)
PY
}

# Добивка строки пробелами до ШИРИНЫ В СИМВОЛАХ (не байтах): printf %-Ns и ${#} считают
# кириллицу/эмодзи в БАЙТАХ (локаль скрипта — C), и колонки разъезжаются. Символы надёжно
# считает `wc -m` под UTF-8-локалью (точечно, без глобальной смены локали).
scol() {
    local n; n=$(printf '%s' "$1" | LC_ALL=en_US.UTF-8 wc -m | tr -d ' ')
    printf '%s' "$1"; while [ "$n" -lt "$2" ]; do printf ' '; n=$((n+1)); done
}

scan_report() {
    echo
    echo -e "${B}=== Доступные Wi-Fi сети ===${N}"
    local ifc; ifc=$(detect_iface)
    if ! is_wifi "$ifc"; then
        echo -e "  ${D}Сейчас подключение не по Wi-Fi — сканировать нечем.${N}"; echo; return
    fi
    command -v python3 >/dev/null 2>&1 || { echo -e "  ${D}Нужен python3 для разбора скана.${N}"; echo; return; }
    [ -t 1 ] || echo -e "  ${D}Сканирую соседние сети…${N}"
    nl_spin_start "сканирую соседние Wi-Fi сети"
    local raw; raw=$(LC_ALL=C system_profiler SPAirPortDataType 2>/dev/null)
    nl_spin_stop
    local cur; cur=$(clean "$(ipconfig getsummary "$ifc" 2>/dev/null | awk -F' SSID : ' '/ SSID : /{print $2; exit}')")
    local known; known=$(wifi_known_ssids)   # сохранённые сети (★), root-only; иначе пусто
    # python: парсит соседей + текущий диапазон, ставит saved-флаг, считает дубль-SSID,
    # сортирует по score (диапазон+сигнал+saved−open) — порядок, НЕ оценки в UI.
    # Первая строка — META<TAB>cur_band<TAB>dup; дальше TSV-строки сетей.
    local rows
    rows=$(SCAN_RAW="$raw" SCAN_CUR="$cur" SCAN_KNOWN="$known" python3 - <<'PY' 2>/dev/null
import os, re, unicodedata
raw=os.environ.get("SCAN_RAW",""); cur=os.environ.get("SCAN_CUR","")
known=set(unicodedata.normalize("NFC",x) for x in os.environ.get("SCAN_KNOWN","").split("\n") if x.strip())
def clean(s): return "".join(ch for ch in s if ord(ch)>=32).strip()
def nfc(s): return unicodedata.normalize("NFC", s)
lines=raw.split("\n")
# 1) соседние сети
start=None; base=0
for i,ln in enumerate(lines):
    if ln.strip()=="Other Local Wi-Fi Networks:":
        start=i; base=len(ln)-len(ln.lstrip()); break
nets=[]
if start is not None:
    entry=None; node=None
    for ln in lines[start+1:]:
        if not ln.strip(): continue
        ind=len(ln)-len(ln.lstrip())
        if ind<=base: break                      # вышли из блока (соседний интерфейс)
        if entry is None: entry=ind
        if ind==entry and ln.rstrip().endswith(":"):
            node={"name":clean(ln.strip()[:-1]),"band":"","chan":"","width":"","sec":"","rssi":None}
            nets.append(node)
        elif node is not None and ind>entry:
            s=ln.strip()
            m=re.match(r"Channel:\s*(\d+)\s*\(([^,]+),\s*(\d+)MHz", s)
            if m: node["chan"]=m.group(1); node["band"]=m.group(2).strip(); node["width"]=m.group(3)
            elif s.startswith("Security:"): node["sec"]=s.split(":",1)[1].strip()
            elif s.startswith("Signal / Noise:"):
                mm=re.search(r"(-?\d+)\s*dBm", s)
                if mm: node["rssi"]=int(mm.group(1))
# 2) текущий диапазон (Current Network Information) — авторитетно для дубль-подсказки
cur_band=""; ci=None
for i,ln in enumerate(lines):
    if ln.strip()=="Current Network Information:": ci=i; break
if ci is not None:
    cbase=len(lines[ci])-len(lines[ci].lstrip())
    for ln in lines[ci+1:]:
        if not ln.strip(): continue
        if (len(ln)-len(ln.lstrip()))<=cbase: break
        mm=re.match(r"Channel:\s*\d+\s*\(([^,]+),", ln.strip())
        if mm: cur_band=mm.group(1).strip(); break
for n in nets: n["saved"]= 1 if nfc(n["name"]) in known else 0
# дубль: текущий на 2.4, а тот же SSID виден на 5/6 ГГц → стоит попробовать 5 ГГц
dup="0"
if cur and cur_band=="2GHz" and any(nfc(n["name"])==nfc(cur) and n["band"] in ("5GHz","6GHz") for n in nets):
    dup="1"
def score(n):
    # RSSI ДОМИНИРУЕТ (слабый сигнал топит независимо от диапазона: 5 ГГц/−82 хуже,
    # чем 2.4/−45 — иначе сорт «по диапазону» врал бы). band — лёгкий тай-брейк среди
    # сопоставимых по сигналу; открытость — небольшой минус (не топит сильную сеть).
    r=n["rssi"]
    if   r is None: s=-1000
    elif r>=-50: s=50
    elif r>=-60: s=40
    elif r>=-70: s=25
    elif r>=-80: s=10
    else: s=0
    if n["band"]=="6GHz": s+=6
    elif n["band"]=="5GHz": s+=4
    if n["sec"] in ("None","NONE","none"): s-=8
    if n["saved"]: s+=3
    return s
def key(n):
    return (0 if (cur and nfc(n["name"])==nfc(cur)) else 1,   # текущая первой
            0 if n["rssi"] is not None else 1,                # затем с сигналом, без — ниже
            -score(n), n["name"].lower())
def f(x): return x if (x is not None and x!="") else "-"   # сентинел: нет подряд табов
print("META\t%s\t%s" % (cur_band or "-", dup))
marked=False
for n in sorted(nets, key=key):
    if not n["name"]: continue
    iscur="0"
    if cur and nfc(n["name"])==nfc(cur) and not marked: iscur="1"; marked=True
    print("\t".join([f(n["name"]),f(n["band"]),f(n["chan"]),f(n["width"]),f(n["sec"]),
                     f(None if n["rssi"] is None else str(n["rssi"])), iscur, str(n["saved"])]))
PY
)
    # META — первая строка; данные — остальное.
    local meta cur_band dup data
    meta=$(printf '%s\n' "$rows" | head -1)
    cur_band=$(printf '%s' "$meta" | cut -f2); dup=$(printf '%s' "$meta" | cut -f3)
    data=$(printf '%s\n' "$rows" | tail -n +2)
    if [ -z "$data" ]; then
        echo -e "  ${D}Соседних сетей не видно. macOS отдаёт скан только при включённой Геолокации"
        echo -e "  для Терминала (Настройки → Конфиденциальность → Службы геолокации). Кнопка идёт под sudo.${N}"
        echo; return
    fi
    { printf '  '; scol "сеть" 26; scol "сигнал" 10; scol "диапазон/канал" 17; scol "защита" 13; echo "примечание"; }
    local has_open=0 saw_saved=0
    while IFS=$'\t' read -r name band chan width sec rssi iscur saved; do
        [ -z "$name" ] || [ "$name" = "-" ] && continue
        [ "$band" = "-" ] && band=""; [ "$chan" = "-" ] && chan=""; [ "$rssi" = "-" ] && rssi=""
        local bandh; [ -n "$band" ] && bandh=$(band_human "$band") || bandh="?"
        local bc="${bandh}${chan:+ / ${chan}}"
        local sech="$sec"
        case "$sec" in
            None|NONE|none) sech="открытая ⚠"; has_open=1 ;;
            "-"|"")         sech="?" ;;
            *WPA3*) sech="WPA3";; *WPA2*) sech="WPA2";; *WPA*) sech="WPA";; *WEP*) sech="WEP";;
        esac
        local sigcell="—"; [ -n "$rssi" ] && sigcell="${rssi} dBm"
        # Примечание: «вы здесь» приоритетнее; иначе «★ сохранена» (только если знаем).
        local note=""
        if   [ "$iscur" = "1" ]; then note="← вы здесь"
        elif [ "$saved" = "1" ]; then note="★ сохранена"; saw_saved=1
        fi
        { printf '  '; scol "$name" 26; scol "$sigcell" 10; scol "$bc" 17; scol "$sech" 13; printf '%s\n' "$note"; }
    done <<EOF
$data
EOF
    echo
    echo -e "  ${D}Подсказки:${N}"
    if [ "$dup" = "1" ]; then
        echo -e "  ${D}  • Вы на 2.4 ГГц, но «${cur}» видна и на 5 ГГц — для VPN/видео 5 ГГц обычно лучше,${N}"
        echo -e "  ${D}    если сигнал достаточный. Переподключиться можно вручную в меню Wi-Fi.${N}"
    fi
    [ "$has_open" -eq 1 ] && echo -e "  ${D}  • Открытые сети без VPN лучше не использовать для почты, банка и работы.${N}"
    [ "$saw_saved" -eq 1 ] && echo -e "  ${D}  • ★ сохранена — сеть известна macOS (не гарантия подключения: пароль/портал могли смениться).${N}"
    echo -e "  ${D}  • Для VPN и видеосвязи 5/6 ГГц обычно предпочтительнее 2.4 ГГц, если сигнал не слабый.${N}"
    echo -e "  ${D}  • Сигнал macOS отдаёт не для всех сетей; «—» не означает плохой сигнал. Сеть не выбираем за тебя.${N}"
    echo
}

# ---- Фаза 7: доступность AI-сервисов через VPN (read-only, TLS-handshake) ----
# Проверяем НЕ ICMP (CDN отвечает с граничного узла — врёт), а время установки TLS
# до API-домена. Любой HTTP-код (401/403/405/200…) = сервис достижим; code=000/таймаут
# = не достучались. Без ключей, без промптов, без записи state. Конфиг — только ДАННЫЕ
# (TSV), НИКОГДА не source/eval. Метрика «отклик» = time_appconnect (DNS+TCP+TLS).
AI_TARGETS=""   # построчно "name<TAB>url" (заполняет ai_build_targets)
AI_WARN=""      # предупреждения о битых строках конфига (для --tech/--ai)

# Список целей: встроенные дефолты + (опц.) конфиг ~/.../netinfo/ai-targets как ДАННЫЕ.
ai_build_targets() {
    AI_TARGETS=""; AI_WARN=""
    local seen="" cf name url _r
    _ai_add() {  # name url — dedupe по имени (первый выигрывает)
        case " $seen " in *" $1 "*) return ;; esac
        seen="$seen $1"; AI_TARGETS="${AI_TARGETS}$1	$2
"
    }
    _ai_add "OpenAI" "https://api.openai.com/v1/models"
    _ai_add "Claude" "https://api.anthropic.com/v1/messages"
    if [ "$AI_MODE" = "all" ]; then
        _ai_add "Gemini" "https://generativelanguage.googleapis.com/v1/models"
        _ai_add "Z.AI"   "https://api.z.ai/api/paas/v4/models"
    fi
    cf="$(nl_state_dir)/ai-targets"
    [ -n "$cf" ] && [ -f "$cf" ] && while IFS=$'\t' read -r name url _r || [ -n "$name" ]; do
        case "$name" in ''|\#*) continue ;; esac              # пусто/комментарий
        name=$(clean "$name"); [ -z "$name" ] && continue
        case "$url" in https://*) ;; *) AI_WARN="${AI_WARN}${AI_WARN:+; }«${name}»: нужен https://"; continue ;; esac
        _ai_add "$name" "$url"
    done < "$cf"
}

# Классификатор: код + lowercased-тело → "verdict<TAB>reason". 4 класса:
#   blocked     — явный регион/политика-отказ (маркеры тела / 451) ИЛИ «голый» 403
#                 (forbidden без объяснения «нужен ключ») — напр. Claude из РФ;
#   unconfirmed — 403 с фразой «нужен ключ» (Gemini): без ключа НЕ отличить блок от
#                 нет-ключа, поэтому честно «не подтверждён», а не зелёный/красный;
#   ok          — обычный ответ (401/405/400/429/200…), сеть прошла, не forbidden.
# ВАЖЕН ПОРЯДОК: региональные маркеры проверяем ДО «нужен ключ» (Google-регион тоже
# PERMISSION_DENIED, но с текстом про location — это блок, а не «нет ключа»).
ai_classify() {  # $1=http_code  $2=lowercased_body  → "verdict\treason"
    [ "$1" = "451" ] && { printf 'blocked\thttp_451\n'; return; }
    case "$2" in
        *unsupported_country_region_territory*) printf 'blocked\tunsupported_country_region_territory\n'; return ;;
        *unsupported_country*|*"unsupported country"*) printf 'blocked\tunsupported_country\n'; return ;;
        *"user location is not supported"*) printf 'blocked\tuser_location_not_supported\n'; return ;;
        *"location is not supported"*) printf 'blocked\tlocation_not_supported\n'; return ;;
        *"country, region, or territory not supported"*|*"region, or territory not supported"*) printf 'blocked\tregion_not_supported\n'; return ;;
        *"not available in your country"*|*"not supported in your country"*) printf 'blocked\tnot_available_in_country\n'; return ;;
        *"request not allowed"*) printf 'blocked\trequest_not_allowed\n'; return ;;   # Anthropic регион-отказ (в рабочем регионе он 405)
        *"just a moment"*|*"attention required"*|*"checking your browser"*) printf 'blocked\tcloudflare_antibot\n'; return ;;
        *"error code: 1020"*) printf 'blocked\tcloudflare_1020\n'; return ;;
        *"you have been blocked"*) printf 'blocked\tblocked_page\n'; return ;;
        *"access denied"*) printf 'blocked\taccess_denied\n'; return ;;
    esac
    if [ "$1" = "403" ]; then
        case "$2" in
            *"api key"*|*"unregistered callers"*|*"missing bearer"*|*authenticat*|*"x-api-key"*|*credential*|*permission_denied*)
                printf 'unconfirmed\tneeds_key\n'; return ;;
            *)  printf 'blocked\thttp_403_forbidden\n'; return ;;
        esac
    fi
    printf 'ok\t-\n'
}

# Прогон целей: TLS-handshake + ЧТЕНИЕ ТЕЛА (региональный отказ виден только в теле).
# Печатает TSV (через $()): name host net_reachable(0/1) http_code latency_ms dns_ms
#   verdict(network_ok|blocked|unreachable) grade(good|degraded|slow|-) block_reason err
# Сентинел "-" вместо пустых полей — иначе подряд табы схлопнулись бы в read (урок --scan).
ai_check() {
    command -v curl >/dev/null 2>&1 || return 0
    # Тело HTTP — в приватный per-user tmp с УЗКИМ префиксом netinfo-ai.* (его и чистит
    # cleanup при Ctrl-C, не задевая чужие файлы). mktemp с фолбэком на $$-имя.
    nl_ensure_tmp_dir
    local _td; _td=$(nl_tmp_dir)
    local bf; bf=$(mktemp "$_td/netinfo-ai.XXXXXX" 2>/dev/null) || bf="$_td/netinfo-ai.$$"
    printf '%s' "$AI_TARGETS" | while IFS=$'\t' read -r name url; do
        [ -z "$name" ] && continue
        local host meta code ta tn rc ms dns net verdict grade reason err lb cls
        host=$(printf '%s' "$url" | sed -E 's#^https?://##; s#/.*$##')
        : > "$bf"
        meta=$(LC_ALL=C curl -sS -L -o "$bf" -w '%{http_code}\t%{time_appconnect}\t%{time_namelookup}' \
               --connect-timeout 5 --max-time 8 "$url" 2>/dev/null); rc=$?
        code=$(printf '%s' "$meta" | cut -f1); ta=$(printf '%s' "$meta" | cut -f2); tn=$(printf '%s' "$meta" | cut -f3)
        ms=$(awk "BEGIN{printf \"%d\", ($ta+0)*1000}"); dns=$(awk "BEGIN{printf \"%d\", ($tn+0)*1000}")
        grade="-"; reason="-"; err="-"
        if [ "$rc" -ne 0 ] || [ -z "$code" ] || [ "$code" = "000" ]; then
            net=0; verdict="unreachable"; ms=0
            case "$rc" in
                28) err="таймаут" ;; 7) err="отказ соединения" ;; 6) err="DNS не разрешился" ;;
                35|51|58|59|60) err="ошибка TLS" ;; *) err="не достучались" ;;
            esac
        else
            net=1
            lb=$(head -c 8192 "$bf" 2>/dev/null | tr '[:upper:]' '[:lower:]')
            cls=$(ai_classify "$code" "$lb")
            verdict=$(printf '%s' "$cls" | cut -f1); reason=$(printf '%s' "$cls" | cut -f2)
            if [ "$verdict" = "ok" ]; then
                verdict="network_ok"; reason="-"
                if   [ "$ms" -le 400 ]; then grade="good"
                elif [ "$ms" -le 800 ]; then grade="degraded"
                else grade="slow"; fi
            fi
        fi
        printf '%s\t%s\t%d\t%s\t%d\t%d\t%s\t%s\t%s\t%s\n' \
            "$name" "$host" "$net" "${code:-000}" "$ms" "$dns" "$verdict" "$grade" "$reason" "$err"
    done
    rm -f "$bf" 2>/dev/null
}

# Свод по AI_RESULTS → глобальные AI_* (текущий шелл, heredoc). «Не работает» =
# blocked ИЛИ unreachable (TLS прошёл ≠ можно пользоваться).
ai_summarize() {
    AI_TOTAL=0; AI_OK=0; AI_BLOCKED=0; AI_UNCONF=0; AI_UNREACH=0; AI_SLOW=0
    AI_OK_NAMES=""; AI_BAD_NAMES=""; AI_UNCONF_NAMES=""; AI_SLOW_NAMES=""
    local name host net code ms dns verdict grade reason err
    while IFS=$'\t' read -r name host net code ms dns verdict grade reason err; do
        [ -z "$name" ] && continue
        AI_TOTAL=$((AI_TOTAL+1))
        case "$verdict" in
            network_ok)  AI_OK=$((AI_OK+1)); AI_OK_NAMES="${AI_OK_NAMES}${AI_OK_NAMES:+, }${name}"
                         { [ "$grade" = "slow" ] || [ "$grade" = "degraded" ]; } && { AI_SLOW=$((AI_SLOW+1)); AI_SLOW_NAMES="${AI_SLOW_NAMES}${AI_SLOW_NAMES:+, }${name}"; } ;;
            unconfirmed) AI_UNCONF=$((AI_UNCONF+1)); AI_UNCONF_NAMES="${AI_UNCONF_NAMES}${AI_UNCONF_NAMES:+, }${name}" ;;
            blocked)     AI_BLOCKED=$((AI_BLOCKED+1)); AI_BAD_NAMES="${AI_BAD_NAMES}${AI_BAD_NAMES:+, }${name}" ;;
            *)           AI_UNREACH=$((AI_UNREACH+1)); AI_BAD_NAMES="${AI_BAD_NAMES}${AI_BAD_NAMES:+, }${name}" ;;
        esac
    done <<EOF
$AI_RESULTS
EOF
    AI_BAD=$((AI_BLOCKED+AI_UNREACH))
}

# Человеческий блок «AI API-домены:». mode=detail добавляет «, HTTP <код>».
# Формулировки осторожные: «сервер отвечает» (не «доступен»), «региональный отказ»
# (не «РКН/DPI/госблок» — по телу видим лишь отказ сервиса/CDN/политики).
ai_render() {  # $1 = TSV, $2 = "detail"|""
    echo -e "  AI API-домены:"
    local name host net code ms dns verdict grade reason err col label act
    while IFS=$'\t' read -r name host net code ms dns verdict grade reason err; do
        [ -z "$name" ] && continue
        case "$verdict" in
            network_ok)
                # Человеческий язык: «сервер отвечает / защищённое соединение» вместо
                # «сеть проходит / TLS» (термины — в --tech и в пояснениях по «?»).
                case "$grade" in
                    slow) col=$Y; label="🟠 сервер отвечает, но медленно — защищённое соединение ${ms} мс" ;;
                    degraded) col=$Y; label="🟡 сервер отвечает — защищённое соединение ${ms} мс" ;;
                    *) col=$G; label="🟢 сервер отвечает — защищённое соединение ${ms} мс" ;;
                esac
                [ "${2:-}" = "detail" ] && label="${label}, HTTP ${code}" ;;
            unconfirmed)
                col=$Y
                if [ "${2:-}" = "detail" ]; then label="🟡 нельзя проверить без ключа — сервер требует API-ключ (HTTP ${code})"
                else label="🟡 нельзя проверить без ключа — сервер требует API-ключ"; fi ;;
            blocked)
                col=$R; act="смени страну VPN"
                case "$reason" in
                    cloudflare_antibot|cloudflare_1020|blocked_page|access_denied)
                        label="🔴 антибот-защита (IP в чёрном списке)"; act="смени сервер/IP (лучше не дата-центр)" ;;
                    http_403_forbidden) label="🔴 доступ запрещён (403)"; act="смени сервер/страну VPN" ;;
                    http_451)           label="🔴 заблокирован (451)" ;;
                    *)                  label="🔴 региональный отказ" ;;
                esac
                if [ "${2:-}" = "detail" ]; then label="${label} — HTTP ${code}"
                else label="${label} — ${act}"; fi ;;
            *)
                col=$R; label="🔴 не достучались — ${err}" ;;
        esac
        echo -e "     $(printf '%-9s' "${name}:") ${col}${label}${N}"
    done <<EOF
$1
EOF
}

# Режим netinfo --ai [all|list]: отдельный отчёт (без полного collect_all).
ai_report() {
    echo
    echo -e "${B}=== Проверка AI API-доменов ===${N}"
    local extdev vpn=0
    extdev=$(route -n get "$PROBE_IP1" 2>/dev/null | awk '/interface:/{print $2}')
    case "$extdev" in utun*) vpn=1 ;; esac
    ai_build_targets
    if [ "$AI_LIST" -eq 1 ]; then
        echo -e "  ${D}Цели проверки (профиль: ${AI_MODE}):${N}"
        printf '%s' "$AI_TARGETS" | while IFS=$'\t' read -r n u; do [ -n "$n" ] && echo "     $n  →  $u"; done
        [ -n "$AI_WARN" ] && echo -e "  ${Y}Конфиг: ${AI_WARN}${N}"
        echo; return
    fi
    command -v curl >/dev/null 2>&1 || { echo -e "  ${D}Нужен curl.${N}"; echo; return; }
    [ "$vpn" -eq 0 ] && echo -e "  ${D}VPN не активен — проверяю напрямую.${N}"
    [ -t 1 ] || echo -e "  ${D}Проверяю AI API-домены…${N}"
    echo -e "  ${D}Без ключей — сетевая и региональная проверка:${N}"
    nl_spin_start "проверяю AI API-домены"
    AI_RESULTS=$(ai_check)
    nl_spin_stop
    echo
    ai_render "$AI_RESULTS" detail
    ai_summarize
    echo
    # Хвост про медленные домены (network_ok с grade slow/degraded) — чтобы итог учитывал
    # оранжевую строку, а не игнорировал её (правка по ревью).
    local slow_tail=""
    [ "${AI_SLOW:-0}" -gt 0 ] && slow_tail="; ${Y}${AI_SLOW_NAMES} отвечает медленно${N}"
    if [ "$vpn" -eq 0 ]; then
        echo -e "  ${D}Вывод: проверка напрямую, без VPN; если домены отклоняют — включи VPN и повтори netinfo --ai${N}"
    elif [ "$AI_BAD" -eq 0 ] && [ "$AI_UNCONF" -eq 0 ]; then
        echo -e "  Вывод: ${G}VPN включён; AI API-домены отвечают без признаков регионального отказа${N}${slow_tail}."
    elif [ "$AI_BAD" -eq 0 ]; then
        if [ "$AI_OK" -eq 0 ]; then
            echo -e "  Вывод: ${Y}домены отвечают 403 «нужен ключ» — без ключа доступ/блок не подтвердить.${N}"
        else
            echo -e "  Вывод: ${G}отвечают: ${AI_OK_NAMES}${N}${slow_tail}${Y}; без ключа не подтверждены: ${AI_UNCONF_NAMES}.${N}"
        fi
    elif [ "$AI_UNREACH" -eq "$AI_TOTAL" ]; then
        echo -e "  ${Y}Все AI-домены одновременно дали таймаут.${N} ${D}Похоже на временный сбой маршрута/VPN,${N}"
        echo -e "  ${D}а не на блок каждого сервиса. Повтори проверку (r/i); если повторяется — смени сервер VPN.${N}"
    elif [ "$AI_BAD" -eq "$AI_TOTAL" ]; then
        if [ "$AI_BLOCKED" -gt 0 ] && [ "$AI_UNREACH" -eq 0 ]; then
            echo -e "  Вывод: ${Y}все AI API-домены отклоняют доступ из этого региона — смени страну VPN.${N}"
        else
            echo -e "  Вывод: ${Y}AI API-домены недоступны через текущий сервер — смени страну VPN.${N}"
        fi
    else
        echo -e "  Вывод: ${Y}отклонены/недоступны: ${AI_BAD_NAMES} — смени страну VPN${AI_OK_NAMES:+ (отвечают: ${AI_OK_NAMES})}.${N}"
    fi
    [ -n "$AI_WARN" ] && echo -e "  ${D}Конфиг: ${AI_WARN}${N}"
    echo -e "  ${D}«Сервер отвечает» = API-домен ответил без явных признаков регионального отказа.${N}"
    echo -e "  ${D}Это НЕ проверка API-ключа, НЕ запрос к модели и НЕ гарантия скорости генерации.${N}"
    echo
}

# Режим --json (Фаза 6.1): машиночитаемый вывод. ПРИНЦИП: скучный, стабильный,
# только ФАКТЫ и КОДЫ состояний — никаких человеческих фраз («можно работать»):
# человеческий текст это слой рендера, его собирают render_*. Всё строит python3
# (корректное экранирование SSID: пробелы/кавычки/emoji/ANSI-подобные — clean()
# уже срезал управляющие; json.dumps экранирует остальное). Запускается ПОСЛЕ
# collect_all (нужны все собранные поля).
json_report() {
    command -v python3 >/dev/null 2>&1 || { echo '{"error":"python3 required"}'; return; }
    local mem seen last
    mem=$(nl_history_recall "$SSID" json)         # "count\tlast_seen_human\tlast_q"
    seen=$(printf '%s' "$mem" | cut -f1); last=$(printf '%s' "$mem" | cut -f2)
    JS_INTERNET="$MAIN_OK" JS_OPEN="$SEC_OPEN" JS_VPN="$VPN_ACTIVE" JS_AT="$STAMP_SHORT" \
    JS_WIFI="$WIFI" JS_COUNTRY="$COUNTRY" JS_CNAME="$(country_name "$COUNTRY")" \
    JS_CITY="$CITY" JS_PROV="$ORG" JS_IP="$XIP" \
    JS_LTYPE="$LINK_TYPE" JS_SVC="$SVC" JS_IFACE="$IFACE" JS_SSID="$SSID" \
    JS_HOTSPOT="$IS_HOTSPOT" JS_BAND="$BAND" JS_CHAN="$CHAN" JS_CHW="$CHW" JS_RSSI="$RSSI" \
    JS_LAT="$RW" JS_DL="$DL_M" JS_UL="$UL_M" JS_QLEVEL="$QLEVEL" JS_UTUN="$UTUN" \
    JS_LATPROBE="$LATENCY_PROBE" \
    JS_SEEN="$seen" JS_LASTSEEN="$last" JS_AI="$AI_RESULTS" JS_DNS="$DNS" JS_DOH="$DOH_OK" \
    python3 - <<'PY'
import os, json
def s(k):
    v=os.environ.get(k,"").strip(); return v if v else None
def i(k):
    v=os.environ.get(k,"").strip()
    try: return int(v)
    except Exception: return None
def b(k): return os.environ.get(k,"").strip()=="1"

internet=b("JS_INTERNET"); open_wifi=b("JS_OPEN"); vpn=b("JS_VPN"); wifi=b("JS_WIFI")
country=s("JS_COUNTRY"); cname=s("JS_CNAME")
if cname==country: cname=None   # неизвестный код → country_name вернул сам код → null
band=s("JS_BAND"); chw=i("JS_CHW"); rssi=i("JS_RSSI")
dl=i("JS_DL"); ul=i("JS_UL"); lat=i("JS_LAT"); utun=i("JS_UTUN"); qlevel=s("JS_QLEVEL")

bottleneck = "not_wifi" if (wifi and rssi is not None and rssi>=-60 and dl is not None and dl<15) else None
vq=None
if   qlevel=="green":  vq="good"
elif qlevel=="yellow": vq="degraded"
elif qlevel=="red":    vq="bad_latency" if (lat is not None and lat>180) else "bad"
narrow = bool(wifi and chw==20 and band in ("5GHz","6GHz"))
many   = bool(utun is not None and utun>7)
seen=i("JS_SEEN"); known = bool(seen is not None and seen>0)

# DNS (Фаза 8): udp53 — жив ли обычный резолвер; doh — null если не проверяли (DNS жив),
# иначе bool. DoH-успех НЕ означает «системный DNS работает» — это отдельные факты.
udp53 = b("JS_DNS")
_dohv = os.environ.get("JS_DOH","").strip()
doh = None if _dohv=="" else (_dohv=="1")

# AI API-домены (Фаза 7): блок только если проверка запускалась (непустой JS_AI).
# network_reachable=true И verdict=blocked НЕ противоречат: сеть дошла, сервер отказал.
ai=[]
for ln in os.environ.get("JS_AI","").split("\n"):
    if not ln.strip(): continue
    p=ln.split("\t")
    if len(p)<10: continue
    name,host,net_,code_,ms_,dns_,verdict_,grade_,reason_,err_=p[:10]
    ai.append({
        "name":name,"url_host":host,
        "network_reachable":(net_=="1"),
        "http_code":(int(code_) if code_.isdigit() and code_!="000" else None),
        "latency_ms":(int(ms_) if (net_=="1" and ms_.lstrip("-").isdigit()) else None),
        "dns_ms":(int(dns_) if dns_.lstrip("-").isdigit() else None),
        "verdict":verdict_,
        "block_reason":(reason_ if reason_ not in ("","-") else None),
        "error":(err_ if err_ not in ("","-") else None),
    })

codes=[]
if open_wifi and vpn:       codes.append("open_wifi_with_vpn")
if open_wifi and not vpn:   codes.append("open_wifi_without_vpn")
if vq=="bad_latency":       codes.append("bad_latency")
if bottleneck=="not_wifi":  codes.append("not_wifi_bottleneck")
if narrow:                  codes.append("narrow_5ghz_channel")
if many:                    codes.append("many_vpn_traces")
if not udp53 and doh is True:  codes.append("dns_doh_only")
if not udp53 and doh is False: codes.append("dns_unresolvable")
if ai:
    codes.append("ai_checked")
    bl=[a for a in ai if a["verdict"]=="blocked"]
    ur=[a for a in ai if a["verdict"]=="unreachable"]
    uc=[a for a in ai if a["verdict"]=="unconfirmed"]
    if bl and len(bl)==len(ai): codes.append("ai_region_blocked")
    elif bl:                    codes.append("ai_partial_blocked")
    if ur and len(ur)==len(ai): codes.append("ai_unreachable")
    if uc:                      codes.append("ai_unconfirmed")
    if any(a["verdict"]=="network_ok" and a["latency_ms"] is not None and a["latency_ms"]>400 for a in ai):
        codes.append("ai_high_latency")

out={
  "status":  {"internet":internet,"open_wifi":open_wifi,"vpn_active":vpn,"measured_at":s("JS_AT")},
  "exit":    {"country":s("JS_COUNTRY"),"country_name":cname,"city":s("JS_CITY"),
              "provider":s("JS_PROV"),"ip":s("JS_IP")},
  "link":    {"type":s("JS_LTYPE"),"service":s("JS_SVC"),"interface":s("JS_IFACE"),"ssid":s("JS_SSID"),
              "is_open":open_wifi,"is_hotspot":b("JS_HOTSPOT"),"band":band,"channel":i("JS_CHAN"),
              "channel_width_mhz":chw,"rssi_dbm":rssi},
  "quality": {"latency_ms":lat,"latency_probe":s("JS_LATPROBE"),"download_mbps":dl,"upload_mbps":ul,"bottleneck":bottleneck},
  "dns":     {"udp53":udp53,"doh":doh},
  "vpn":     {"active":vpn,
              "exit_country":s("JS_COUNTRY") if vpn else None,
              "exit_city":s("JS_CITY") if vpn else None,
              "quality":vq},
  "memory":  {"known_network":known,"seen_count":(seen if seen is not None else 0),
              "last_seen_human":s("JS_LASTSEEN")},
  "warnings":{"many_vpn_traces":many,"vpn_trace_count":(utun if utun is not None else 0),
              "narrow_5ghz_channel":narrow},
  "codes":   codes,
}
if ai: out["ai"]=ai   # блок присутствует только если AI-проверка запускалась
print(json.dumps(out, ensure_ascii=False, indent=2))
PY
}

# ---- Фаза 13: `netinfo --why URL` — на каком слое не открывается ресурс ----
# Послойная диагностика: интернет → DNS(+DoH) → TCP → TLS → HTTP(код+тело). Контраст
# «сеть или ресурс» (контрольная проверка интернета). read-only: один GET --range 0-0
# (1 байт), без ключей, без записи state, систему НЕ меняем. Честно: называем СЛОЙ
# отказа, НЕ «причину блокировки»; не пишем «РКН/DPI/госблок».
why_report() {
    local url="$1"
    echo
    echo -e "${B}=== Почему не открывается ресурс ===${N}"
    case "$url" in
        http://*|https://*) : ;;
        "") echo -e "  ${D}Укажи полный URL: ${C}netinfo --why https://example.com/file${N}"; echo; return ;;
        *)  echo -e "  ${Y}Нужен полный URL со схемой, напр.: ${C}netinfo --why https://${url}${N}"; echo; return ;;
    esac
    command -v curl >/dev/null 2>&1 || { echo -e "  ${D}Нужен curl.${N}"; echo; return; }
    local scheme host
    scheme="${url%%://*}"
    host=$(printf '%s' "$url" | sed -E 's#^[a-z]+://##; s#@[^/]*##; s#[:/].*$##')
    echo -e "  Ресурс:             ${C}${url}${N}"
    echo -e "  Хост:               ${C}${host}${N}"
    [ "$scheme" = "http" ] && echo -e "  ${Y}Схема: HTTP — соединение не шифруется.${N}"
    # VPN — только как контекст (route на utun); без geo, чтобы не тормозить.
    local extdev vpn=0
    extdev=$(route -n get "$PROBE_IP1" 2>/dev/null | awk '/interface:/{print $2}')
    case "$extdev" in utun*) vpn=1 ;; esac
    [ "$vpn" -eq 1 ] && echo -e "  VPN:                ${G}активен${N}" \
                     || echo -e "  VPN:                ${D}не активен (проверка напрямую)${N}"

    nl_spin_start "проверяю ${host}"
    # Контроль «сеть вообще жива» — отделяет «у меня сеть лежит» от «ресурс не открывается».
    local base_ok=0
    { [ "$(http_code "$HTTP_URL1")" = "204" ] || [ "$(http_code "$HTTP_URL2")" = "200" ]; } && base_ok=1
    # DNS хоста (обычный → DoH-фолбэк). IP-литерал DNS не требует — считаем разрешённым.
    local hip="" dns_ok=0 doh_ok=0
    if printf '%s' "$host" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
        hip="$host"; dns_ok=1
    else
        command -v dig >/dev/null 2>&1 && hip=$(dig +short +time=3 +tries=1 A "$host" 2>/dev/null | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1)
        [ -n "$hip" ] && dns_ok=1
        [ "$dns_ok" -eq 0 ] && { doh_resolve "$host" && doh_ok=1; }
    fi
    # ОДИН curl: тайминги по слоям + код + тип + тело (1 байт через range).
    local bf; nl_ensure_tmp_dir; bf=$(mktemp "$(nl_tmp_dir)/netinfo-why.XXXXXX" 2>/dev/null) || bf="$(nl_tmp_dir)/netinfo-why.$$"
    : > "$bf"
    local meta rc code tcon tapp ctype
    meta=$(LC_ALL=C curl -sS -L --range 0-0 -o "$bf" --connect-timeout 5 --max-time 12 \
           -w '%{http_code}\t%{time_connect}\t%{time_appconnect}\t%{content_type}' "$url" 2>/dev/null); rc=$?
    nl_spin_stop
    code=$(printf '%s' "$meta" | cut -f1); tcon=$(printf '%s' "$meta" | cut -f2)
    tapp=$(printf '%s' "$meta" | cut -f3); ctype=$(printf '%s' "$meta" | cut -f4)
    local tcp_ok=0 tls_ok=0
    awk "BEGIN{exit !(($tcon+0)>0)}" && tcp_ok=1
    awk "BEGIN{exit !(($tapp+0)>0)}" && tls_ok=1

    # --- Классификация по слою ---
    local wclass="" wreason="-"
    if [ "$dns_ok" -eq 0 ] && [ "$doh_ok" -eq 0 ]; then
        if [ "$base_ok" -eq 0 ]; then wclass="local_network"; else wclass="dns_problem"; fi
    elif [ "$dns_ok" -eq 0 ] && [ "$doh_ok" -eq 1 ]; then
        wclass="dns_doh_only"
    elif [ "$rc" -ne 0 ] || [ -z "$code" ] || [ "$code" = "000" ]; then
        if   [ "$tcp_ok" -eq 0 ]; then { [ "$base_ok" -eq 0 ] && wclass="local_network"; } || wclass="tcp_blocked"
        elif [ "$tls_ok" -eq 0 ]; then wclass="tls_blocked"
        else wclass="slow_or_timeout"; fi
    else
        # HTTP-ответ есть → код+тело. Переиспользуем ai_classify (регион/antibot/needs_key/451).
        local lb cls v
        lb=$(head -c 8192 "$bf" 2>/dev/null | tr 'A-Z' 'a-z')
        cls=$(ai_classify "$code" "$lb"); v=$(printf '%s' "$cls" | cut -f1); wreason=$(printf '%s' "$cls" | cut -f2)
        if   [ "$v" = "blocked" ]; then wclass="http_forbidden"
        elif [ "$v" = "unconfirmed" ]; then wclass="auth_required"
        else
            case "$code" in
                401) wclass="auth_required" ;;
                404) wclass="not_found" ;;
                429) wclass="rate_limited" ;;
                5*)  wclass="server_error" ;;
                2*)  case "$ctype" in
                         text/html*) why_is_file "$url" && wclass="html_instead_of_file" || wclass="ok" ;;
                         *) wclass="ok" ;;
                     esac ;;
                3*)  wclass="redirect_loop" ;;
                *)   wclass="ok" ;;
            esac
        fi
    fi
    rm -f "$bf" 2>/dev/null

    # --- Проверки (человеческий послойный срез) ---
    echo
    echo -e "  ${D}Проверки:${N}"
    if   [ "$dns_ok" -eq 1 ]; then echo -e "     Адрес сайта:       ${G}найден${N} ${D}(${hip})${N}"
    elif [ "$doh_ok" -eq 1 ]; then echo -e "     Адрес сайта:       ${Y}обычным способом не найден, но найден защищённой проверкой${N}"
    else echo -e "     Адрес сайта:       ${R}не найден${N}"; fi
    if [ "$dns_ok" -eq 1 ] || [ "$doh_ok" -eq 1 ]; then
        [ "$tcp_ok" -eq 1 ] && echo -e "     Дозвон до сервера: ${G}есть${N}" || echo -e "     Дозвон до сервера: ${R}нет${N}"
        if   [ "$tls_ok" -eq 1 ]; then echo -e "     Защищ. соединение: ${G}установлено${N}"
        elif [ "$tcp_ok" -eq 1 ]; then echo -e "     Защищ. соединение: ${R}не установилось${N}"; fi
        if [ -n "$code" ] && [ "$code" != "000" ]; then
            echo -e "     Ответ сервера:     ${C}HTTP ${code}${N}"
            [ -n "$ctype" ] && echo -e "     Тип ответа:        ${D}${ctype}${N}"
        else
            echo -e "     Ответ сервера:     ${R}не получен${N}"
        fi
    fi

    # --- Вывод (слой отказа + что доказано + что попробовать) ---
    echo
    local vpnhint=""
    [ "$vpn" -eq 0 ] && vpnhint="включи VPN и повтори: netinfo --why ${url}" || vpnhint="попробуй другой сервер VPN и повтори"
    case "$wclass" in
        ok)
            echo -e "  Вывод: ${G}Ресурс отвечает нормально (HTTP ${code}).${N}"
            echo -e "  ${D}Если в браузере всё равно не открывается — дело в самом приложении/расширении/кэше, не в сети.${N}" ;;
        local_network)
            echo -e "  Вывод: ${R}Проблема не в этом ресурсе — не прошла даже контрольная проверка интернета.${N}"
            echo -e "  ${D}Сначала почини сеть: запусти netinfo (общий осмотр) или войди в Wi-Fi-портал.${N}" ;;
        dns_problem)
            echo -e "  Вывод: ${Y}Интернет есть, но имя «${host}» не находится ни обычной, ни защищённой проверкой.${N}"
            echo -e "  ${D}Либо домена не существует (опечатка?), либо DNS этой сети его фильтрует.${N}"
            echo -e "  ${D}Если сайт точно существует — попробуй sudo fixnet --dns или VPN и повтори.${N}" ;;
        dns_doh_only)
            echo -e "  Вывод: ${Y}Имя «${host}» не находится обычной проверкой, но находится защищённой (DoH).${N}"
            echo -e "  ${D}Обычный DNS сети ведёт себя странно; ресурс может открыться через VPN или смену DNS.${N}" ;;
        tcp_blocked)
            echo -e "  Вывод: ${Y}Адрес нашёлся, но соединение с сервером не устанавливается.${N}"
            echo -e "  ${D}Не похоже на Wi-Fi: возможна фильтрация маршрута или недоступность сервера из этой сети.${N}"
            echo -e "  ${D}${vpnhint}.${N}" ;;
        tls_blocked)
            echo -e "  Вывод: ${Y}До сервера дозвонились, но защищённое соединение не встаёт.${N}"
            echo -e "  ${D}Возможны фильтрация TLS, корпоративный прокси, сбой сертификата или несовместимость.${N}"
            echo -e "  ${D}${vpnhint}.${N}" ;;
        http_forbidden)
            echo -e "  Вывод: ${R}До сервера достучались, но он отклонил доступ (HTTP ${code}).${N}"
            case "$wreason" in
                cloudflare_antibot|cloudflare_1020|blocked_page|access_denied)
                    echo -e "  ${D}Похоже на антибот-защиту (IP сервера/VPN в чёрном списке). Смени сервер/IP (лучше не дата-центр).${N}" ;;
                http_403_forbidden)
                    # «голый» 403 без явного маркера — НЕ утверждаем регион. Перечисляем причины.
                    echo -e "  ${D}Сервер/CDN отклонил доступ. Возможные причины: авторизация, политика сайта, IP VPN, регион или антибот-защита.${N}"
                    echo -e "  ${D}Попробуй другой VPN-сервер или войди в аккаунт, если ресурс закрытый.${N}" ;;
                *)  # явный региональный/политический маркер (unsupported_country/location/451/request_not_allowed)
                    echo -e "  ${D}Похоже на отказ по региону/политике (сервис не поддерживает этот регион). Смени страну VPN и повтори.${N}" ;;
            esac ;;
        auth_required)
            echo -e "  Вывод: ${Y}Ресурс жив, но требует вход или ключ (HTTP ${code}).${N}"
            echo -e "  ${D}Это не блокировка — нужна авторизация, cookie или прямая ссылка (не страница входа).${N}" ;;
        html_instead_of_file)
            echo -e "  Вывод: ${Y}Сервер ответил HTML-страницей вместо файла.${N}"
            echo -e "  ${D}Вероятно, ссылка ведёт на страницу входа/предпросмотр или это непрямая ссылка, а не сам файл.${N}" ;;
        not_found)
            echo -e "  Вывод: ${Y}Сервер ответил 404 — по этому адресу ресурс не найден (возможно, ссылка устарела).${N}" ;;
        rate_limited)
            echo -e "  Вывод: ${Y}Сервер ответил 429 — слишком много запросов. Повтори позже.${N}" ;;
        server_error)
            echo -e "  Вывод: ${Y}Сервер ответил ошибкой (HTTP ${code}) — проблема на стороне сервиса, не у тебя.${N}" ;;
        redirect_loop)
            echo -e "  Вывод: ${Y}Редиректы зациклились (HTTP ${code}) — возможно, нужна авторизация или cookie.${N}" ;;
        slow_or_timeout)
            echo -e "  Вывод: ${Y}Соединение установилось, но ответ не пришёл за отведённое время (таймаут).${N}"
            echo -e "  ${D}Маршрут/канал перегружен или сервер не отвечает. Повтори позже; ${vpnhint}.${N}" ;;
    esac
    echo -e "  ${D}Это проверка СЛОЯ отказа (read-only, 1 байт). Не проверка причины блокировки, аккаунта или содержимого.${N}"
    echo
}

# Похоже ли, что URL запрашивает ФАЙЛ (по расширению пути) — для «HTML вместо файла».
why_is_file() {
    case "$1" in
        *.pdf|*.zip|*.docx|*.xlsx|*.pptx|*.csv|*.jpg|*.jpeg|*.png|*.gif|*.mp4|*.mp3|*.dmg|*.pkg|*.exe|*.tar|*.gz|*.tgz|*.7z|*.rar|*.iso|*.apk) return 0 ;;
    esac
    return 1
}

# ===================== ДИСПЕТЧЕР =====================
# Сбор — ОДИН раз; дальше только рендеры. Меню — лишь когда вывод в терминал.
if [ "$MTU_PROBE" -eq 1 ]; then mtu_report; exit 0; fi
if [ "$PROBE" -eq 1 ]; then probe_report; exit 0; fi
if [ "$SCAN" -eq 1 ]; then scan_report; exit 0; fi
if [ "$AI_FORCE" -eq 1 ]; then ai_report; exit 0; fi
if [ "$EXPLAIN" -eq 1 ]; then render_explain; exit 0; fi
if [ -n "$WHY_URL" ]; then why_report "$([ "$WHY_URL" = "-" ] && echo "" || echo "$WHY_URL")"; exit 0; fi
collect_all
if [ "$JSON" -eq 1 ]; then json_report; exit 0; fi
if [ "$TECH" -eq 1 ]; then
    render_tech
elif [ "$ADVICE" -eq 1 ]; then
    render_human; render_advice
elif [ -t 0 ] && [ -t 1 ]; then
    render_human; interactive_menu
else
    render_human
    echo; echo -e "  ${D}Подробнее: netinfo --tech · netinfo --advice${N}"
fi
echo
