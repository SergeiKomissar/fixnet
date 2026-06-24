#!/bin/bash
#
# fixnet.sh — аварийная кнопка восстановления интернета (macOS)
#
#
# ЗАЧЕМ ЭТОТ СКРИПТ
#
# Иногда после переключения или обрыва VPN интернет пропадает и сам не
# возвращается: Wi-Fi вроде подключён, но страницы не грузятся. Так бывает,
# потому что macOS теряет "маршрут по умолчанию" — перестаёт понимать, куда
# отправлять трафик. Помогает заставить систему заново собрать сетевую
# конфигурацию (перезапросить адрес и маршруты). Этот скрипт делает именно это,
# по шагам, начиная с самого мягкого вмешательства.
#
#
# ПОЧЕМУ ИМЕННО ТАК (а не "удалить лишние туннели")
#
# Рядом с поломкой часто видны "висячие" IPv6-маршруты на старых utun-
# интерфейсах от уже мёртвых VPN-сессий. Доказательств, что именно они ломают
# интернет, нет — это скорее СИМПТОМ незавершённой VPN-сессии, чем причина.
# Реально чинит ситуацию пересборка маршрутов и DHCP, а не охота за туннелями.
# Поэтому скрипт чинит мягко и не геройствует.
#
#
# ЧТО СКРИПТ НЕ ДЕЛАЕТ (чтобы можно было жать кнопку без страха)
#
#   - не удаляет и не выключает VPN-клиенты;
#   - не выгружает NetworkExtension;
#   - не удаляет сами utun-интерфейсы;
#   - не меняет DNS-серверы БЕЗ спроса (только режим --dns: с бэкапом и откатом);
#   - не трогает Tailscale (не вызывает tailscale CLI, его настройки не меняет);
#   - не делает глобальный сброс IPv6 (это рвало бы рабочий VPN).
#
# Он лишь восстанавливает нормальную маршрутизацию и DHCP, оставляя сетевое
# окружение максимально нетронутым. В обычном домашнем сценарии риск минимален:
# если причина не в сетевом стеке macOS, скрипт честно сообщит об этом и не
# будет притворяться, что всё починил.
#
#
# КАК ЗАПУСКАТЬ
#
#   sudo ./fixnet.sh        # диагностика + починка (нужен пароль)
#   ./fixnet.sh --check     # только посмотреть состояние, ничего не менять
#
#   sudo ./fixnet.sh --dns          # аварийная подмена DNS (бэкап + проверка + откат)
#   sudo ./fixnet.sh --dns-restore  # вернуть исходный DNS
#   ./fixnet.sh --dns-status        # показать активную подмену (без root)
#
#   sudo ./fixnet.sh --wifi-reset   # передёрнуть Wi-Fi (off/on + DHCP) при залипшей сессии
#   sudo ./fixnet.sh --reassoc      # то же самое (короткий технический алиас)
#

set -u

# Цвета для читаемости вывода (красный/зелёный/жёлтый/синий/сброс).
R='\033[0;31m'; G='\033[0;32m'; Y='\033[0;33m'; B='\033[0;34m'; D='\033[2m'; N='\033[0m'

# Общий слой состояния (бэкап DNS, владелец файлов). Для РЕМОНТА он ОБЯЗАТЕЛЕН:
# без него нет надёжного отката, поэтому при отсутствии — ОТКАЗ (в отличие от
# netinfo, который мягко деградирует). Подключаем рядом со скриптом или из ~/bin.
NL_OK=0
for _c in "$(dirname "${BASH_SOURCE[0]:-$0}")/netlib.sh" "$HOME/bin/netlib.sh"; do
    [ -r "$_c" ] && { . "$_c"; NL_OK=1; break; }
done
if [ "$NL_OK" -ne 1 ]; then
    echo -e "${R}netlib.sh не найден.${N} Без общего state-слоя ремонт небезопасен (нет отката). Отказ." >&2
    exit 1
fi

# DNS-серверы для аварийной подмены (Cloudflare + Google). Позже можно вынести в
# config (dns_repair_servers), но в первой реализации — фиксированная константа.
DNS_REPAIR="1.1.1.1 8.8.8.8"

# Единый cleanup. ВАЖНО: откат DNS/MTU НЕ здесь — он на файле+self-heal (trap не
# спасает от SIGKILL/ребута). Сюда — только безопасное на любом выходе (спиннер);
# будущие хуки добавлять СЮДА, не плодя новые trap. EXIT — очистка; INT/TERM —
# очистка И выход (130), иначе Ctrl-C посреди ремонта не прервёт скрипт. Частичное
# состояние (например, записан active.json до setMTU) подберёт self-heal.
cleanup() { nl_spin_stop 2>/dev/null; }
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM

# Два внешних адреса для проверки "есть ли интернет". Два — на случай, если
# конкретная сеть блокирует один из них (тогда один IP дал бы ложную аварию).
PROBE_IP1="1.1.1.1"
PROBE_IP2="8.8.8.8"
# Имена для проверки, что работает DNS (резолв имени в адрес). Два домена:
# DNS считаем живым, если резолвится хотя бы один — страховка на случай, если
# один домен временно лёг на стороне сервера (это не наша локальная поломка).
PROBE_DNS1="ya.ru"
PROBE_DNS2="apple.com"

# Определяем, через какой физический интерфейс ноутбук должен выходить в
# интернет (Wi-Fi, USB-раздача с телефона или Ethernet).
#
# Это самый ответственный шаг: если ошибиться с интерфейсом, мы перезапросим
# адрес "не там", и починка не сработает. Во время работы VPN маршрут по
# умолчанию указывает на туннель (utunX), а адрес перезапрашивать надо на
# РЕАЛЬНОМ адаптере — поэтому туннели мы как uplink не рассматриваем.
#
# Приоритеты выбора:
#   1. Интерфейс из текущего маршрута по умолчанию, если это физический enX —
#      самый точный вариант (это и есть фактический выход в сеть).
#   2. Основной Wi-Fi-интерфейс (ищем по имени устройства, не по подписи —
#      чтобы работало и на русифицированной macOS).
#   3. Первое физическое устройство в статусе "активно".
#   4. В крайнем случае — en0 (типичный Wi-Fi на маках).
detect_iface() {
    # Приоритет: брать интерфейс по ФАКТУ (через какой идёт default route),
    # а не по имени сервиса. Это корректно ловит USB-tethering поверх Wi-Fi.
    local d ifc

    # 1. фактический дефолт, если это физический enX (не utun/не пусто)
    d=$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')
    case "$d" in
        en*) echo "$d"; return ;;
    esac

    # 2. иначе — Wi-Fi-сервис (устойчиво к локали: цепляемся за "Device: enX")
    ifc=$(networksetup -listnetworkserviceorder 2>/dev/null \
        | awk -F'Device: ' '/Wi-Fi|AirPort/ && /Device: en/ {gsub(/\)/,"",$2); print $2; exit}')
    if [ -n "$ifc" ]; then
        echo "$ifc"; return
    fi

    # 3. фолбэк — первое физическое en со статусом active
    for d in $(networksetup -listallhardwareports 2>/dev/null | awk '/Device: en/{print $2}'); do
        if ifconfig "$d" 2>/dev/null | grep -q 'status: active'; then
            echo "$d"; return
        fi
    done

    echo "en0"
}

# Проверка "есть ли вообще интернет": пингуем внешний адрес. Если первый не
# отвечает — пробуем второй (вдруг именно его режет сеть). Хватает любого ответа.
check_net() {
    ping -c1 -W3000 "$PROBE_IP1" >/dev/null 2>&1 || \
    ping -c1 -W3000 "$PROBE_IP2" >/dev/null 2>&1
}

# Проверка "работает ли DNS" — РЕАЛЬНЫЙ резолв имени, а НЕ чтение кэша.
#
# Почему важно: старая версия спрашивала dscacheutil (системный кэш). Если в кэше
# лежал недавний валидный ответ, проверка проходила, даже когда живой резолвинг
# был сломан (браузер при этом показывал ERR_NAME_NOT_RESOLVED). dig/nslookup/host
# делают новый запрос через системный резолвер и лучше показывают, жив ли DNS
# прямо сейчас, чем чтение кэша через dscacheutil.
#
# ВАЖНО: проверяем РЕАЛЬНОЕ имя (ya.ru / apple.com), которое обязано резолвиться.
# Случайный несуществующий поддомен НЕ годится: он вернёт NXDOMAIN (пустой ответ),
# что мы бы приняли за поломку — хотя быстрый NXDOMAIN, наоборот, доказывает, что
# резолвер жив. DNS считаем рабочим, если резолвится хотя бы один из двух доменов.
check_dns() {
    local d
    for d in "$PROBE_DNS1" "$PROBE_DNS2"; do
        if command -v dig >/dev/null 2>&1; then
            # ищем IPv4 (x.x.x.x) или IPv6 (наличие ':') в ответе
            dig +short +time=3 +tries=1 "$d" 2>/dev/null \
                | grep -Eq '([0-9]{1,3}\.){3}[0-9]{1,3}|:' && return 0
        elif command -v nslookup >/dev/null 2>&1; then
            nslookup -timeout=3 "$d" >/dev/null 2>&1 && return 0
        elif command -v host >/dev/null 2>&1; then
            host -W3 "$d" >/dev/null 2>&1 && return 0
        else
            # крайний фолбэк: сбросить кэш, затем спросить (чтобы не получить старое)
            dscacheutil -flushcache 2>/dev/null
            dscacheutil -q host -a name "$d" 2>/dev/null | grep -q 'ip_address' && return 0
        fi
    done
    return 1
}

# Это вообще Wi-Fi? Нужно, чтобы решить, можно ли "передёрнуть" радио на Ступени 2.
# На проводе или USB-раздаче передёргивать Wi-Fi бессмысленно.
is_wifi() {
    networksetup -getairportpower "$1" >/dev/null 2>&1
}

# Ждём появления связи до N секунд, проверяя раз в секунду. Так лучше, чем
# глухая пауза фиксированной длины: на быстрой сети выходим сразу, а медленному
# DHCP (например, в корпоративной сети) даём время, не объявляя ложную неудачу.
wait_net() {
    local n=${1:-15} i=0
    while [ "$i" -lt "$n" ]; do
        check_net && return 0
        sleep 1; i=$((i+1))
    done
    return 1
}

# wait_net со спиннером (чтобы ожидание не выглядело зависанием). Возвращает код
# wait_net без изменений — можно подставлять прямо в `if`.
wait_net_spin() {
    nl_spin_start "${2:-жду восстановления связи}"
    wait_net "$1"; local rc=$?
    nl_spin_stop
    return $rc
}

# Печатает понятный снимок состояния сети: куда идёт трафик, сколько VPN-туннелей
# висит, работают ли интернет и DNS. Используется и в режиме --check, и после починки.
diagnose() {
    local ifc=$1
    echo -e "${B}=== ДИАГНОСТИКА ===${N}"

    local gw dev
    gw=$(route -n get default 2>/dev/null | awk '/gateway:/{print $2}')
    dev=$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')
    if [ -n "$gw" ]; then
        echo -e "  default-маршрут: ${G}${gw} -> ${dev}${N}"
    elif route -n get default 2>/dev/null | grep -q 'interface:'; then
        # дефолт есть, но без gateway — обычно туннель VPN
        echo -e "  default-маршрут: ${G}через VPN (${dev})${N}"
    else
        echo -e "  default-маршрут: ${R}ОТСУТСТВУЕТ (not in table)${N}"
    fi

    # Пороги общие из netlib (NL_UTUN_*) — синхронно с netinfo (раньше fixnet ругался
    # на ≥3, давая ложную тревогу: macOS штатно держит 3-4 системных туннеля).
    local utun_cnt
    utun_cnt=$(ifconfig 2>/dev/null | grep -c '^utun')
    if [ "$utun_cnt" -le "${NL_UTUN_NORM:-4}" ]; then
        echo -e "  utun-интерфейсов: ${G}${utun_cnt}${N} (норма)"
    elif [ "$utun_cnt" -lt "${NL_UTUN_LOTS:-12}" ]; then
        echo -e "  utun-интерфейсов: ${Y}${utun_cnt}${N} (много VPN/Network Extension туннелей; возможны старые следы)"
    else
        echo -e "  utun-интерфейсов: ${Y}${utun_cnt}${N} (очень много; при обрывах закрой VPN-клиенты/перезагрузи)"
    fi

    local v6def
    v6def=$(netstat -rn -f inet6 2>/dev/null | awk '$1=="default" && $NF ~ /^utun/' | wc -l | tr -d ' ')
    [ "$v6def" -gt 0 ] && echo -e "  фантомных IPv6-дефолтов на utun: ${Y}${v6def}${N}"

    if check_net; then
        echo -e "  пинг (${PROBE_IP1}/${PROBE_IP2}): ${G}OK${N}"
    else
        echo -e "  пинг (${PROBE_IP1}/${PROBE_IP2}): ${R}НЕТ${N}"
    fi
    if check_dns; then
        echo -e "  DNS (${PROBE_DNS1}/${PROBE_DNS2}): ${G}OK${N}"
    else
        echo -e "  DNS (${PROBE_DNS1}/${PROBE_DNS2}): ${R}НЕТ${N}"
    fi
    echo
}

# --- требуется root для починки ---
need_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${R}Для починки нужен sudo.${N} Запусти:  ${Y}sudo $0${N}"
        exit 1
    fi
}

# ====================== DNS-РЕМОНТ (--dns) ======================
# Контракт: netinfo только ДИАГНОСТИРУЕТ «DNS мёртв» и печатает «sudo fixnet --dns».
# Меняет DNS ТОЛЬКО fixnet — с бэкапом (active.json), проверкой закрепления через
# networksetup и откатом (--dns-restore / self-heal). Tailscale не трогаем.

# Имя сервиса текущего uplink (через netlib).
dns_service() { nl_service_for_device "$(detect_iface)"; }

# Прочитать DNS сервиса. Печатает "mode|ip1 ip2 ...": mode=manual|empty.
# ВАЖНО: источник для бэкапа — networksetup (конфиг сервиса, что и восстановим),
# а НЕ scutil (тот показывает эффективные резолверы, включая инъекции Tailscale).
dns_read_service() {
    local out; out=$(networksetup -getdnsservers "$1" 2>/dev/null)
    case "$out" in
        *"any DNS Servers"*|"") echo "empty|" ;;
        *) echo "manual|$(echo "$out" | tr '\n' ' ' | sed -E 's/ +$//')" ;;
    esac
}

# Активен ли Tailscale DNS (по эффективным резолверам scutil) — для информсообщения.
dns_tailscale_active() {
    scutil --dns 2>/dev/null | grep -qE '100\.100\.100\.100|fd7a:115c:a1e0'
}

# Достать поле из active.json (списки печатаются через пробел).
dns_active_field() {
    local ap; ap=$(nl_dns_active_path); [ -f "$ap" ] || { echo ""; return; }
    NL_AP="$ap" FX_KEY="$1" python3 -c '
import os,json,sys
try: o=json.load(open(os.environ["NL_AP"]))
except Exception: sys.exit(0)
v=o.get(os.environ["FX_KEY"],"")
print(" ".join(v) if isinstance(v,list) else v)
' 2>/dev/null
}

# Записать active.json (атомарно, владельцу через netlib). python3 обязателен.
dns_write_active() {
    nl_ensure_dns_dir
    local ap; ap=$(nl_dns_active_path)
    FX_SVC="$1" FX_DEV="$2" FX_OMODE="$3" FX_ODNS="$4" FX_NDNS="$5" FX_REASON="$6" \
    FX_TS="$(date '+%Y-%m-%dT%H:%M:%S%z')" python3 -c '
import os,json
o={"schema":1,"ts":os.environ["FX_TS"],"service":os.environ["FX_SVC"],
   "device":os.environ["FX_DEV"],"old_dns_mode":os.environ["FX_OMODE"],
   "old_dns":os.environ["FX_ODNS"].split(),"new_dns":os.environ["FX_NDNS"].split(),
   "reason":os.environ["FX_REASON"],"status":"active","created_by":"fixnet --dns"}
print(json.dumps(o,ensure_ascii=False,indent=2))
' > "$ap.tmp" 2>/dev/null && mv "$ap.tmp" "$ap"
    nl_chown_state
}

# Закрыть операцию в журнале (applied/restored/superseded) — снимок active.json + статус.
dns_ops_log() {
    local ap; ap=$(nl_dns_active_path); [ -f "$ap" ] || return 0
    nl_ensure_dns_dir
    NL_AP="$ap" FX_ST="$1" FX_TS="$(date '+%Y-%m-%dT%H:%M:%S%z')" python3 -c '
import os,json,sys
try: o=json.load(open(os.environ["NL_AP"]))
except Exception: sys.exit(0)
o["status"]=os.environ["FX_ST"]; o["closed_ts"]=os.environ["FX_TS"]
print(json.dumps(o,ensure_ascii=False))
' >> "$(nl_dns_ops_log)" 2>/dev/null
    nl_chown_state
}

# Откат: вернуть исходный DNS из active.json. empty -> Empty, manual -> список.
dns_restore() {
    local ap; ap=$(nl_dns_active_path)
    [ -f "$ap" ] || { echo "Активной подмены DNS нет — откатывать нечего."; return 0; }
    local svc mode odns
    svc=$(dns_active_field service); mode=$(dns_active_field old_dns_mode); odns=$(dns_active_field old_dns)
    [ -z "$svc" ] && { echo -e "${R}Битый active.json — не могу определить сервис.${N}"; return 1; }
    if [ "$mode" = "empty" ]; then
        networksetup -setdnsservers "$svc" Empty
        echo -e "${G}DNS сервиса «${svc}» возвращён в автоматический (DHCP).${N}"
    else
        networksetup -setdnsservers "$svc" $odns
        echo -e "${G}DNS сервиса «${svc}» возвращён: ${odns}${N}"
    fi
    dscacheutil -flushcache 2>/dev/null
    killall -HUP mDNSResponder 2>/dev/null
    dns_ops_log restored
    rm -f "$ap"; nl_chown_state
}

# Self-heal: в начале запуска заметить ЗАБЫТУЮ подмену и предложить вернуть, либо
# (если DNS уже сменился) пометить superseded. Безопасно без root (тогда только
# сообщает). Гарантия отката — этот файл+self-heal, а не trap.
# Возраст бэкапа в секундах из ISO-ts (или "" если нет python3/не распарсилось).
dns_backup_age_secs() {
    command -v python3 >/dev/null 2>&1 || { echo ""; return; }
    [ -n "$1" ] || { echo ""; return; }
    FX_TS="$1" python3 - <<'PY' 2>/dev/null
import os, datetime
ts=os.environ.get("FX_TS","")
try:
    t=datetime.datetime.strptime(ts, "%Y-%m-%dT%H:%M:%S%z")
    now=datetime.datetime.now(t.tzinfo)
    s=int((now-t).total_seconds()); print(s if s>=0 else 0)
except Exception:
    pass
PY
}

dns_selfheal() {
    local ap; ap=$(nl_dns_active_path); [ -f "$ap" ] || return 0
    local svc cur; svc=$(dns_active_field service)
    cur=$(dns_read_service "$svc"); cur=" ${cur#*|} "
    if echo "$cur" | grep -q " 1.1.1.1 "; then
        # Возраст бэкапа управляет ДЕФОЛТОМ вопроса: свежий (<6 ч) — [Y/n] (вернуть),
        # старый — [y/N] (по умолчанию НЕ трогать, текущее состояние может быть рабочим).
        local ts age agestr fresh=0
        ts=$(dns_active_field ts); age=$(dns_backup_age_secs "$ts")
        if [ -n "$age" ]; then
            if   [ "$age" -lt 3600 ];  then agestr="возраст меньше часа"
            elif [ "$age" -lt 86400 ]; then agestr="возраст ~$((age/3600)) ч"
            else                            agestr="возраст ~$((age/86400)) дн"; fi
            [ "$age" -lt 21600 ] && fresh=1
        else
            agestr="возраст неизвестен"
        fi
        echo -e "${Y}Найдена активная подмена DNS (fixnet, ${ts}; ${agestr}) на «${svc}».${N}"
        if [ "$(id -u)" -eq 0 ] && [ "${ASSUME_YES:-0}" -ne 1 ] && [ -t 0 ]; then
            if [ "$fresh" -eq 1 ]; then
                printf "Вернуть исходные DNS сейчас? [Y/n] "; read -r _a
                case "$_a" in n|N|нет) : ;; *) dns_restore ;; esac
            else
                printf "Вернуть исходные DNS сейчас? [y/N] "; read -r _a
                case "$_a" in y|Y|да) dns_restore ;; *) : ;; esac
            fi
        elif [ "$(id -u)" -eq 0 ] && [ "${ASSUME_YES:-0}" -eq 1 ]; then
            # --yes НЕ восстанавливает прошлый бэкап автоматически: это не запрошенное
            # действие, а текущее состояние сети может быть рабочим. Откат — только явным
            # --dns-restore.
            echo -e "  ${D}--yes не трогает прошлый бэкап. Откат — вручную: ${Y}sudo fixnet --dns-restore${N}"
        elif [ "$(id -u)" -ne 0 ]; then
            echo -e "  Верни: ${Y}sudo fixnet --dns-restore${N}"
        fi
    else
        # DNS уже другой (сменили вручную/DHCP/Tailscale) — операция неактуальна.
        if [ "$(id -u)" -eq 0 ]; then
            dns_ops_log superseded; rm -f "$ap"; nl_chown_state
            echo -e "${Y}Прошлая подмена DNS уже неактуальна (DNS сменился) — отметка снята.${N}"
        fi
    fi
}

# Показать статус активной подмены (read-only, root не нужен).
dns_status() {
    local ap; ap=$(nl_dns_active_path)
    if [ -f "$ap" ]; then
        echo -e "${B}Активная подмена DNS:${N}"
        echo "  сервис:    $(dns_active_field service) ($(dns_active_field device))"
        echo "  поставлена:$(dns_active_field ts)"
        echo "  было:      $(dns_active_field old_dns_mode) [$(dns_active_field old_dns)]"
        echo "  стало:     $(dns_active_field new_dns)"
        echo -e "  вернуть:   ${Y}sudo fixnet --dns-restore${N}"
    else
        echo "Активной подмены DNS нет."
    fi
}

# Зависимости РЕМОНТА (DNS/MTU): python3 — для безопасного бэкапа active.json,
# networksetup — для самой правки. Проверяем РАНО (до подтверждения), чтобы пользователь
# не соглашался на ремонт ради отказа на полпути. $1 — что чиним (для текста).
require_repair_deps() {
    command -v python3 >/dev/null 2>&1 || { echo -e "${R}Нужен python3 для безопасного бэкапа ${1} — отказ (ремонт без отката запрещён).${N}"; exit 1; }
    command -v networksetup >/dev/null 2>&1 || { echo -e "${R}Нужен networksetup для правки ${1} — отказ.${N}"; exit 1; }
}

# Применить аварийный DNS: бэкап -> setdnsservers -> flush -> проверка закрепления
# (через networksetup!) -> проверка резолва. Провал резолва -> авто-откат.
dns_apply() {
    require_repair_deps "DNS"
    # Уже есть активная подмена? Здесь — БЕЗ интерактивного «вернуть?» (этот вопрос
    # принадлежит обычному fixnet/self-heal). Логика --dns:
    #   подмена ВСЁ ЕЩЁ в силе (DNS == наш) → ОТКАЗ (не перетираем backup);
    #   подмена устарела (DNS уже другой)   → пометить superseded и продолжить.
    local ap; ap=$(nl_dns_active_path)
    if [ -f "$ap" ]; then
        local achk; achk=$(dns_read_service "$(dns_active_field service)"); achk=" ${achk#*|} "
        if echo "$achk" | grep -q " 1.1.1.1 "; then
            echo -e "${Y}Уже есть активная DNS-подмена fixnet.${N} Сначала верни её: ${Y}sudo fixnet --dns-restore${N}"
            exit 0
        else
            dns_ops_log superseded; rm -f "$ap"; nl_chown_state
            echo -e "${Y}Прошлая подмена DNS уже неактуальна (DNS сменился) — отметка снята.${N}"
        fi
    fi
    local dev svc cur mode odns after
    dev=$(detect_iface); svc=$(dns_service)
    [ -z "$svc" ] && { echo -e "${R}Не нашёл сетевой сервис для ${dev} — DNS не трогаю.${N}"; exit 1; }
    cur=$(dns_read_service "$svc"); mode="${cur%%|*}"; odns="${cur#*|}"

    echo -e "${B}>>> Ремонт DNS на сервисе «${svc}» (${dev})${N}"
    echo -e "  текущий DNS: ${odns:-(автоматический/DHCP)}  [режим: ${mode}]"
    echo -e "  новый DNS:   ${DNS_REPAIR}"
    if dns_tailscale_active; then
        echo
        echo -e "${Y}Обнаружен Tailscale DNS.${N}"
        echo -e "  fixnet меняет DNS сервиса Wi-Fi (upstream для обычных сайтов) — настройки Tailscale не трогает."
        echo -e "  tailnet/MagicDNS-имена обычно не затрагиваются."
    fi
    if [ "${ASSUME_YES:-0}" -ne 1 ] && [ -t 0 ]; then
        printf "Продолжить? [Y/n] "; read -r _a
        case "$_a" in n|N|нет) echo "Отменено."; exit 0 ;; esac
    fi

    dns_write_active "$svc" "$dev" "$mode" "$odns" "$DNS_REPAIR" "dns_dead"
    networksetup -setdnsservers "$svc" $DNS_REPAIR
    dscacheutil -flushcache 2>/dev/null
    killall -HUP mDNSResponder 2>/dev/null
    sleep 1

    # Закрепился ли DNS на СЕРВИСЕ (networksetup, не scutil — scutil при Tailscale
    # законно покажет 100.100.100.100, это НЕ провал).
    after=$(dns_read_service "$svc")
    if ! echo " ${after#*|} " | grep -q " 1.1.1.1 "; then
        echo -e "${Y}DNS сервиса не закрепился: система/VPN/Tailscale изменили DNS после ремонта.${N}"
        echo -e "  fixnet не трогает Tailscale. Проверь DNS/upstream в клиенте Tailscale или временно отключи MagicDNS."
        exit 1   # active.json останется; self-heal при следующем запуске пометит superseded
    fi

    if check_dns; then
        echo -e "${G}DNS временно заменены на ${DNS_REPAIR} — имена резолвятся.${N}"
        echo -e "  Исходные DNS сохранены. Вернуть: ${Y}sudo fixnet --dns-restore${N}"
        dns_ops_log applied
        exit 0
    else
        echo -e "${Y}DNS заменён, но резолв всё ещё не идёт — откатываю.${N}"
        dns_restore
        exit 1
    fi
}

# ====================== MTU-РЕМОНТ (--mtu) ======================
# PMTU-blackhole: сеть молча режет крупные DF-пакеты (path MTU < MTU интерфейса).
# netinfo --mtu измеряет; здесь — понижение MTU интерфейса до пути, с бэкапом/
# откатом/self-heal/guard (как --dns). networksetup -setMTU ПЕРСИСТЕНТЕН → на другой
# сети правка может стать неуместной, поэтому бэкап обязателен. Tailscale не трогаем.
MTU_MIN=1280; MTU_MAX=1500

# Текущий MTU интерфейса (Current Setting; фолбэк ifconfig).
mtu_current() {
    local v; v=$(networksetup -getMTU "$1" 2>/dev/null | sed -nE 's/.*Current Setting: ([0-9]+).*/\1/p')
    [ -z "$v" ] && v=$(ifconfig "$1" 2>/dev/null | grep -o 'mtu [0-9]*' | awk '{print $2}')
    echo "$v"
}

mtu_active_field() {
    local ap; ap=$(nl_mtu_active_path); [ -f "$ap" ] || { echo ""; return; }
    NL_AP="$ap" FX_KEY="$1" python3 -c '
import os,json,sys
try: o=json.load(open(os.environ["NL_AP"]))
except Exception: sys.exit(0)
v=o.get(os.environ["FX_KEY"],"")
print(" ".join(map(str,v)) if isinstance(v,list) else v)
' 2>/dev/null
}

mtu_write_active() {
    nl_ensure_mtu_dir
    local ap; ap=$(nl_mtu_active_path)
    FX_SVC="$1" FX_DEV="$2" FX_OLD="$3" FX_NEW="$4" FX_PATH="$5" \
    FX_TS="$(date '+%Y-%m-%dT%H:%M:%S%z')" python3 -c '
import os,json
o={"schema":1,"ts":os.environ["FX_TS"],"service":os.environ["FX_SVC"],
   "device":os.environ["FX_DEV"],"old_mtu":int(os.environ["FX_OLD"]),
   "new_mtu":int(os.environ["FX_NEW"]),"path_mtu":int(os.environ["FX_PATH"]),
   "anchors":["1.1.1.1","8.8.8.8"],"status":"active","created_by":"fixnet --mtu"}
print(json.dumps(o,ensure_ascii=False,indent=2))
' > "$ap.tmp" 2>/dev/null && mv "$ap.tmp" "$ap"
    nl_chown_state
}

mtu_ops_log() {
    local ap; ap=$(nl_mtu_active_path); [ -f "$ap" ] || return 0
    nl_ensure_mtu_dir
    NL_AP="$ap" FX_ST="$1" FX_TS="$(date '+%Y-%m-%dT%H:%M:%S%z')" python3 -c '
import os,json,sys
try: o=json.load(open(os.environ["NL_AP"]))
except Exception: sys.exit(0)
o["status"]=os.environ["FX_ST"]; o["closed_ts"]=os.environ["FX_TS"]
print(json.dumps(o,ensure_ascii=False))
' >> "$(nl_mtu_ops_log)" 2>/dev/null
    nl_chown_state
}

mtu_restore() {
    local ap; ap=$(nl_mtu_active_path)
    [ -f "$ap" ] || { echo "Активной правки MTU нет — откатывать нечего."; return 0; }
    local dev old; dev=$(mtu_active_field device); old=$(mtu_active_field old_mtu)
    { [ -z "$dev" ] || [ -z "$old" ]; } && { echo -e "${R}Битый active.json (MTU).${N}"; return 1; }
    networksetup -setMTU "$dev" "$old"
    echo -e "${G}MTU интерфейса «${dev}» возвращён: ${old}.${N}"
    mtu_ops_log restored
    rm -f "$ap"; nl_chown_state
}

mtu_selfheal() {
    local ap; ap=$(nl_mtu_active_path); [ -f "$ap" ] || return 0
    local dev new cur; dev=$(mtu_active_field device); new=$(mtu_active_field new_mtu)
    cur=$(mtu_current "$dev")
    if [ "$cur" = "$new" ]; then
        echo -e "${Y}Найдена активная правка MTU (fixnet, $(mtu_active_field ts)): ${dev} MTU=${new}.${N}"
        if [ "$(id -u)" -eq 0 ] && [ -t 0 ]; then
            printf "Вернуть MTU %s? [Y/n] " "$(mtu_active_field old_mtu)"; read -r _a
            case "$_a" in n|N|нет) : ;; *) mtu_restore ;; esac
        elif [ "$(id -u)" -ne 0 ]; then
            echo -e "  Верни: ${Y}sudo fixnet --mtu-restore${N}"
        fi
    else
        if [ "$(id -u)" -eq 0 ]; then
            mtu_ops_log superseded; rm -f "$ap"; nl_chown_state
            echo -e "${Y}MTU уже изменён вручную (≠ правке fixnet) — операция снята; ручное не трогаю.${N}"
        fi
    fi
}

mtu_status() {
    local ap; ap=$(nl_mtu_active_path)
    if [ -f "$ap" ]; then
        echo -e "${B}Активная правка MTU:${N}"
        echo "  устройство:$(mtu_active_field device)"
        echo "  поставлена:$(mtu_active_field ts)"
        echo "  было:      $(mtu_active_field old_mtu)"
        echo "  стало:     $(mtu_active_field new_mtu) (path MTU $(mtu_active_field path_mtu))"
        echo -e "  вернуть:   ${Y}sudo fixnet --mtu-restore${N}"
    else
        echo "Активной правки MTU нет."
    fi
}

mtu_apply() {
    require_repair_deps "MTU"
    local want="$1"
    # guard/supersede как у DNS: не перетираем original old_mtu повторным бэкапом.
    local ap; ap=$(nl_mtu_active_path)
    if [ -f "$ap" ]; then
        if [ "$(mtu_current "$(mtu_active_field device)")" = "$(mtu_active_field new_mtu)" ]; then
            echo -e "${Y}Уже есть активная правка MTU fixnet.${N} Сначала верни: ${Y}sudo fixnet --mtu-restore${N}"; exit 0
        else
            mtu_ops_log superseded; rm -f "$ap"; nl_chown_state
            echo -e "${Y}Прошлая правка MTU уже неактуальна (MTU сменился) — отметка снята.${N}"
        fi
    fi
    local dev cur target extdev vpn=0
    dev=$(detect_iface); cur=$(mtu_current "$dev")
    [ -z "$cur" ] && { echo -e "${R}Не определил текущий MTU интерфейса ${dev} — отказ.${N}"; exit 1; }
    if [ -n "$want" ]; then
        case "$want" in *[!0-9]*) echo -e "${R}MTU должен быть числом.${N}"; exit 1 ;; esac
        target="$want"
    else
        [ -t 1 ] || echo -e "${B}Измеряю path MTU (DF-зонд до ${PROBE_IP1} / ${PROBE_IP2})…${N}"
        nl_spin_start "измеряю path MTU (DF-зонд)"
        target=$(nl_path_mtu "$PROBE_IP1" "$PROBE_IP2")
        nl_spin_stop
        [ -z "$target" ] && { echo -e "${Y}Не удалось измерить (DF/ICMP-зонд не проходит даже на малом размере). MTU не трогаю.${N}"; exit 1; }
    fi
    [ "$target" -lt "$MTU_MIN" ] && { echo -e "${R}MTU ${target} < ${MTU_MIN} — ниже минимума IPv6, отказ.${N}"; exit 1; }
    [ "$target" -gt "$MTU_MAX" ] && { echo -e "${R}MTU ${target} > ${MTU_MAX} — вне диапазона, отказ.${N}"; exit 1; }
    [ "$target" -ge "$cur" ] && { echo -e "${G}Целевой MTU ${target} не меньше текущего ${cur} — менять нечего.${N}"; exit 0; }

    extdev=$(route -n get "$PROBE_IP1" 2>/dev/null | awk '/interface:/{print $2}')
    case "$extdev" in utun*) vpn=1 ;; esac
    echo -e "${B}>>> Понижение MTU интерфейса «${dev}»: ${cur} → ${target}${N}"
    echo -e "  ${D}Измерено до публичных якорей; путь до конкретного VPN-сервера может отличаться.${N}"
    [ "$vpn" -eq 1 ] && echo -e "  ${Y}Активен full-tunnel VPN: измерен путь туннеля; смена MTU физического ${dev} может не помочь.${N}"
    if [ -t 0 ]; then
        printf "Продолжить? [y/N] "; read -r _a
        case "$_a" in y|Y|да|Да) ;; *) echo "Отменено."; exit 0 ;; esac
    else
        echo -e "${Y}Нужно интерактивное подтверждение — отменено.${N}"; exit 0
    fi

    local svc; svc=$(nl_service_for_device "$dev")
    mtu_write_active "${svc:-$dev}" "$dev" "$cur" "$target" "$target"
    networksetup -setMTU "$dev" "$target"
    local after; after=$(mtu_current "$dev")
    if [ "$after" != "$target" ]; then
        echo -e "${Y}Интерфейс не принял MTU ${target} (сейчас ${after}). Откатываю.${N}"
        mtu_restore; exit 1
    fi
    dscacheutil -flushcache 2>/dev/null
    if ping -D -s $((target-28)) -c1 -W1500 "$PROBE_IP1" >/dev/null 2>&1 && check_net; then
        echo -e "${G}MTU понижен до ${target} — крупные DF-пакеты теперь проходят.${N}"
    else
        echo -e "${Y}MTU понижен до ${target}, но проверка не подтвердила улучшение однозначно.${N}"
    fi
    echo -e "  Вернуть: ${Y}sudo fixnet --mtu-restore${N}"
    mtu_ops_log applied
    exit 0
}

# ====================== WI-FI RESET (--wifi-reset) ======================
# Для «залипшей сессии»: радио отличное, но связь наружу нестабильна. Передёргиваем
# питание Wi-Fi (off/on) + перезапрос DHCP — переассоциация часто расклинивает
# зависшую сессию/DHCP/ARP на точке. ДЕСТРУКТИВНО (рвёт все соединения), поэтому
# дефолт подтверждения N и без --yes. Бэкап не нужен (действие самовосстановимо).
# Tailscale/VPN не трогаем — туннели переподключатся сами.

# Снимок качества: печатает "net dns rttavg loss" (net/dns=1/0; rtt/loss — пусто,
# если не измерилось). Нужен для честного сравнения до/после.
wr_snapshot() {
    local net=0 dns=0 out rtt loss
    check_net && net=1
    check_dns && dns=1
    out=$(ping -c5 -W2000 "$PROBE_IP1" 2>/dev/null)
    rtt=$(echo "$out"  | awk -F'= ' '/min\/avg/{split($2,a,"/"); printf "%.0f", a[2]}')
    loss=$(echo "$out" | awk -F',' '/packet loss/{for(i=1;i<=NF;i++) if($i ~ /packet loss/){gsub(/[^0-9.]/,"",$i); printf "%d",$i}}')
    echo "$net $dns ${rtt:-} ${loss:-}"
}

wifi_reset() {
    local ifc; ifc=$(detect_iface)
    # Проверяем НЕ только «это en», а что интерфейс реально управляется как Wi-Fi.
    if ! is_wifi "$ifc"; then
        echo -e "${R}Интерфейс ${ifc} не управляется как Wi-Fi (кабель/USB-раздача?) — отказываюсь.${N}"
        exit 1
    fi
    echo -e "${Y}Передёрну Wi-Fi (${ifc}): off → on + перезапрос адреса.${N}"
    echo -e "  ${R}⚠ Все текущие соединения на пару секунд оборвутся${N} (звонки, загрузки, SSH; VPN переподключится сам)."
    # Только осознанное интерактивное подтверждение, дефолт N. --yes намеренно НЕ
    # действует: действие деструктивное и необратимо «здесь и сейчас».
    if [ -t 0 ]; then
        printf "Продолжить? [y/N] "; read -r _a
        case "$_a" in y|Y|да|Да) ;; *) echo "Отменено."; exit 0 ;; esac
    else
        echo -e "${Y}Wi-Fi-reset требует интерактивного подтверждения — отменено.${N}"; exit 0
    fi

    local b a bnet bdns brtt bloss anet adns artt aloss
    b=$(wr_snapshot); read -r bnet bdns brtt bloss <<< "$b"

    networksetup -setairportpower "$ifc" off
    sleep 3
    networksetup -setairportpower "$ifc" on
    sleep 2
    ipconfig set "$ifc" DHCP
    [ -t 1 ] || echo -e "${B}Жду восстановления связи (до 30 c)...${N}"
    wait_net_spin 30 "жду восстановления связи (до 30 c)" >/dev/null 2>&1
    # Дать каналу устаканиться: сразу после off/on RTT/маршруты/VPN ещё в переходном
    # состоянии (видели всплеск 23→211 мс на здоровой сети). Пауза стабилизирует вердикт.
    sleep 4

    a=$(wr_snapshot); read -r anet adns artt aloss <<< "$a"

    echo
    echo -e "  до:    интернет $([ "$bnet" -eq 1 ] && echo да || echo нет), DNS $([ "$bdns" -eq 1 ] && echo да || echo нет), RTT ${brtt:-—} мс, потери ${bloss:-—}%"
    echo -e "  после: интернет $([ "$anet" -eq 1 ] && echo да || echo нет), DNS $([ "$adns" -eq 1 ] && echo да || echo нет), RTT ${artt:-—} мс, потери ${aloss:-—}%"

    # Критерии «лучше»: вернулась достижимость, ИЛИ потери упали ≥50%, ИЛИ RTT ≥30%.
    local better=0 worse=0 fully=0
    [ "$bnet" -eq 0 ] && [ "$anet" -eq 1 ] && better=1
    [ "$bdns" -eq 0 ] && [ "$adns" -eq 1 ] && better=1
    [ -n "$bloss" ] && [ -n "$aloss" ] && [ "$bloss" -ge 2 ] && [ "$aloss" -le $((bloss/2)) ] && better=1
    [ -n "$brtt" ] && [ -n "$artt" ] && [ "$brtt" -ge 1 ] && [ $((artt*10)) -le $((brtt*7)) ] && better=1
    [ "$bnet" -eq 1 ] && [ "$anet" -eq 0 ] && worse=1
    [ "$anet" -eq 1 ] && [ "$adns" -eq 1 ] && { [ -z "$aloss" ] || [ "$aloss" -lt 5 ]; } && fully=1

    echo
    if [ "$worse" -eq 1 ]; then
        echo -e "${Y}Стало хуже — связь обычно сама до-поднимается за несколько секунд.${N}"
    elif [ "$better" -eq 1 ] && [ "$fully" -eq 1 ]; then
        echo -e "${G}Помогло: связь восстановилась.${N}"
    elif [ "$better" -eq 1 ]; then
        echo -e "${Y}Стало немного лучше, но проблема полностью не ушла.${N}"
    else
        echo -e "${Y}Не помогло.${N} Похоже, дело не в Wi-Fi-сессии (провайдер/хотспот/VPN/маршрут)."
    fi
    exit 0
}

# ====================== ОСНОВНОЙ ХОД ======================

# Локализатор обрыва: проходит цепочку "ноутбук -> роутер -> интернет -> DNS"
# по звеньям и человеческим языком говорит, ГДЕ именно разрыв. Возвращает
# короткий код причины, по которому основной ход решает, что чинить:
#   noip    — интерфейс не получил IP-адрес (нет связи с точкой доступа на уровне адреса)
#   gateway — не отвечает шлюз (роутер/хотспот): проблема в линке до точки доступа
#   uplink  — шлюз жив, но интернета за ним нет: отвалился источник (провайдер/сотовая)
#   vpndns  — интернет есть, но не работает DNS: вероятно, завис резолвер (часто после VPN)
#   route   — интернет недоступен, а дефолт висит на мёртвом VPN-туннеле (наша частая причина)
#   unknown — связь есть, явного разрыва не видно
locate_break() {
    local ifc=$1 gw

    # Всю человекочитаемую диагностику печатаем в stderr (>&2), чтобы пользователь
    # её видел всегда, а в stdout вернуть ТОЛЬКО короткий код причины — его ловит
    # вызывающий код. Так не нужен хрупкий tee /dev/tty.
    echo -e "${B}=== ЧТО ПРОИЗОШЛО ===${N}" >&2

    # 1. Взял ли интерфейс IP-адрес?
    if ! ifconfig "$ifc" 2>/dev/null | grep -q 'inet '; then
        echo -e "  ${R}✗${N} Адаптер ${ifc} не получил IP-адрес." >&2
        echo -e "    Похоже, нет связи с точкой доступа на базовом уровне." >&2
        echo "noip"; return
    fi
    echo -e "  ${G}✓${N} Адаптер ${ifc} имеет IP-адрес." >&2

    # 2. Отвечает ли шлюз (роутер/хотспот)?
    gw=$(route -n get default 2>/dev/null | awk '/gateway:/{print $2}')
    local ddev
    ddev=$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')
    if [ -n "$gw" ]; then
        # есть обычный шлюз (физическая сеть) — пингуем его
        if ping -c1 -W2000 "$gw" >/dev/null 2>&1; then
            echo -e "  ${G}✓${N} Шлюз ${gw} отвечает (роутер/хотспот на связи)." >&2
        else
            echo -e "  ${R}✗${N} Шлюз ${gw} не отвечает." >&2
            echo -e "    Проблема в линке до роутера/хотспота, а не в самом ноутбуке." >&2
            echo "gateway"; return
        fi
    elif [ -n "$ddev" ]; then
        # Дефолт без gateway, но через интерфейс (обычно utun) — трафик идёт
        # через VPN. Жив ли туннель — НЕ утверждаем здесь, это покажет проверка
        # интернета ниже. Просто констатируем факт маршрутизации.
        echo -e "  ${G}•${N} Маршрут по умолчанию идёт через VPN-туннель (${ddev}). Проверяю, жив ли он." >&2
    else
        # вот ТЕПЕРЬ дефолта действительно нет — поломка. Уточняем, есть ли мусор.
        if netstat -rn -f inet6 2>/dev/null | awk '$1=="default" && $NF ~ /^utun/' | grep -q .; then
            echo -e "  ${R}✗${N} Маршрута по умолчанию нет, но висят дефолты на VPN-туннелях." >&2
            echo -e "    Похоже, VPN отключился некорректно и оставил мусор в маршрутах." >&2
            echo "route"; return
        fi
        echo -e "  ${R}✗${N} Маршрута по умолчанию нет вообще." >&2
        echo "route"; return
    fi

    # 3. Есть ли выход в интернет за шлюзом?
    if check_net; then
        echo -e "  ${G}✓${N} Интернет за шлюзом доступен." >&2
    else
        echo -e "  ${R}✗${N} Шлюз отвечает, но интернета за ним нет." >&2
        echo -e "    Скорее всего, отвалился сам источник (провайдер или сотовая сеть телефона)." >&2
        echo "uplink"; return
    fi

    # 4. Работает ли DNS?
    if check_dns; then
        echo -e "  ${G}✓${N} DNS резолвит имена." >&2
        echo "unknown"; return
    else
        echo -e "  ${R}✗${N} Интернет есть, но имена сайтов не превращаются в адреса (DNS)." >&2
        echo -e "    Часто бывает после переключения VPN — завис DNS-резолвер." >&2
        echo "vpndns"; return
    fi
}

# --- режимы DNS-ремонта (свой вывод; перехватываем до банера ремонта) ---
ASSUME_YES=0
for _a in "$@"; do case "$_a" in --yes|-y) ASSUME_YES=1 ;; esac; done
case "${1:-}" in
    --dns)                  need_root; dns_apply ;;          # dns_apply сам делает exit
    --dns-restore)          need_root; dns_restore; exit $? ;;
    --dns-status)           dns_status; exit 0 ;;
    --wifi-reset|--reassoc) need_root; wifi_reset ;;        # wifi_reset сам делает exit
    --mtu)                  need_root; mtu_apply "${2:-}" ;; # mtu_apply сам делает exit
    --mtu-restore)          need_root; mtu_restore; exit $? ;;
    --mtu-status)           mtu_status; exit 0 ;;
esac

IFACE=$(detect_iface)
echo -e "${B}Сетевой uplink-интерфейс: ${IFACE}${N}\n"

diagnose "$IFACE"

# режим --check: только диагностика, выходим (но локализатор показываем — для наглядности)
if [ "${1:-}" = "--check" ]; then
    locate_break "$IFACE" >/dev/null   # печать идёт в stderr, код причины не нужен
    echo
    echo -e "${B}Режим проверки. Починка не выполнялась.${N}"
    exit 0
fi

# Self-heal: если с прошлого раза осталась забытая подмена DNS / правка MTU —
# заметить и (под root) предложить вернуть. Безопасно без root (тогда только сообщит).
dns_selfheal
mtu_selfheal

# РАЗВИЛКА: лечим ровно настолько, насколько нужно — не больше.
#
# Три возможных ситуации:
#   1. Интернет есть и DNS работает  -> всё в порядке, ничего не трогаем.
#   2. Интернет есть, но DNS не резолвит -> чиним только DNS (маршруты целы).
#   3. Интернета нет вообще -> запускаем полную процедуру восстановления.
#
# Такой подход бережёт рабочую сеть: незачем пересобирать маршруты, если
# сломан только кэш имён.
if check_net; then
    if check_dns; then
        echo -e "${G}Сеть работает. Чинить нечего.${N}"
        exit 0
    fi
    # Случай 2: связь есть, но имена не резолвятся (как в случае с
    # ERR_NAME_NOT_RESOLVED при живом пинге). Маршруты целы — чиним только DNS.
    need_root
    echo -e "${B}>>> Интернет есть, но DNS не резолвит. Чиню резолвер (маршруты не трогаю).${N}"

    # Шаг 1 — мягко: сброс кэша + "разбудить" резолвер сигналом.
    echo -e "  • сбрасываю кэш DNS и перечитываю конфиг резолвера..."
    dscacheutil -flushcache 2>/dev/null
    killall -HUP mDNSResponder 2>/dev/null
    sleep 2

    if check_dns; then
        echo -e "${G}DNS восстановлен (мягкий сброс). Маршруты не трогались.${N}"
        exit 0
    fi

    # Шаг 2 — жёстко: полный перезапуск процесса mDNSResponder. Это то же, что
    # делает перезагрузка для DNS, но без перезагрузки. Система поднимет процесс
    # заново автоматически.
    echo -e "${Y}  • мягкий сброс не помог — жёстко перезапускаю системный DNS-процесс...${N}"
    killall mDNSResponder 2>/dev/null
    killall mDNSResponderHelper 2>/dev/null
    dscacheutil -flushcache 2>/dev/null
    sleep 3

    if check_dns; then
        echo -e "${G}DNS восстановлен (перезапуск резолвера). Перезагрузка не понадобилась.${N}"
    else
        echo -e "${R}DNS всё ещё не резолвит.${N} Вероятные причины:"
        echo -e "  • VPN-клиент подменил DNS-серверы и не вернул их (проверь, выключив VPN);"
        echo -e "  • в Сеть -> DNS прописан недоступный сервер."
        echo -e "  Если ничего не помогает — перезагрузка гарантированно сбросит DNS."
    fi
    exit 0
fi

# Случай 3: интернета нет — сначала ЛОКАЛИЗУЕМ обрыв, потом чиним адресно.
need_root

CAUSE=$(locate_break "$IFACE")
echo

# РАЗВИЛКА ПО ПРИЧИНЕ — теперь это реальное решение, а не декорация.
# Если разрыв ВНЕ ноутбука, полную починку маршрутов НЕ делаем: она бесполезна,
# проблему создаёт роутер/провайдер/телефон. Честно сообщаем и выходим.
case "$CAUSE" in
    uplink)
        # Шлюз жив, но интернета за ним нет — источник (провайдер/сотовая) лёг.
        # На ноутбуке чинить нечего. Выходим, не трогая маршруты.
        echo -e "${Y}Проблема вне ноутбука: роутер/хотспот на связи, но интернета за ним нет.${N}"
        echo -e "  • у телефона мог пропасть сотовый сигнал — проверь;"
        echo -e "  • у домашнего провайдера возможен сбой."
        echo -e "${Y}Полную починку маршрутов не выполняю — она тут не поможет.${N}"
        echo
        diagnose "$IFACE"
        exit 1
        ;;
    gateway)
        # Шлюз не отвечает. Обычно это вне ноутбука, но иногда — залипший Wi-Fi-
        # линк, который оживает от передёргивания радио. Делаем ОДНУ осторожную
        # аварийную попытку (если это Wi-Fi) и выходим. Полный route flush не делаем.
        echo -e "${Y}Разрыв до точки доступа (роутер/хотспот не отвечает).${N}"
        echo -e "  • проверь, включён ли роутер / раздача на iPhone."
        if is_wifi "$IFACE"; then
            echo -e "${B}Осторожная аварийная попытка: передёргиваю Wi-Fi...${N}"
            networksetup -setairportpower "$IFACE" off
            sleep 3
            networksetup -setairportpower "$IFACE" on
            ipconfig set "$IFACE" DHCP
            if wait_net_spin 15; then
                echo -e "${G}Помогло — связь вернулась.${N}\n"
                diagnose "$IFACE"
                exit 0
            fi
            echo -e "${Y}Не помогло. Похоже, проблема действительно вне ноутбука.${N}"
        else
            echo -e "${Y}Это не Wi-Fi — передёргивать радио нечем. Переподключи источник вручную.${N}"
        fi
        echo
        diagnose "$IFACE"
        exit 1
        ;;
    vpndns)
        # Интернет есть, но завис DNS — чиним только DNS, маршруты не трогаем.
        echo -e "${B}>>> Чиню только DNS (маршруты целы).${N}"
        dscacheutil -flushcache 2>/dev/null
        killall -HUP mDNSResponder 2>/dev/null
        sleep 2
        check_dns && echo -e "${G}DNS восстановлен.${N}" || echo -e "${Y}DNS всё ещё не резолвит.${N}"
        exit 0
        ;;
    route|noip|unknown)
        # Вот это — действительно сбой сетевого стека/маршрутов на ноутбуке.
        # Только здесь имеет смысл полная починка (Ступени 1-2 ниже).
        echo -e "${B}Похоже на сбой сетевого стека/маршрутов — это чиню.${N}"
        echo
        ;;
esac

# СТУПЕНЬ 1 — самая частая поломка после переключения VPN.
#
# macOS теряет маршрут по умолчанию и перестаёт понимать, куда отправлять
# интернет-трафик. Здесь мы:
#   1. очищаем повреждённые IPv4-маршруты;
#   2. убираем оставшиеся после VPN "висячие" IPv6-маршруты на utun;
#   3. заново просим у сети адрес и маршруты (DHCP);
#   4. обновляем кэш DNS.
# Если дело действительно в сетевом стеке macOS — этого обычно достаточно.
echo -e "${B}>>> Ступень 1: сброс IPv4-маршрутов, перезапрос DHCP, чистка DNS${N}"
route -n flush -inet >/dev/null 2>&1      # только IPv4-таблица (явно указываем -inet)

# После аварийного отключения VPN иногда остаются "висячие" IPv6-маршруты по
# умолчанию на старых utun-интерфейсах. Нет доказательств, что именно они ломают
# интернет, но это явный признак незавершённой VPN-сессии. Удаляем ТОЛЬКО эти
# маршруты по умолчанию на utun — остальную IPv6-конфигурацию системы не трогаем.
netstat -rn -f inet6 2>/dev/null | awk '$1=="default" && $NF ~ /^utun/{print $NF}' | sort -u \
| while read -r u; do
    # основной способ удаления — -ifscope; если не сработал, запасной — -interface
    route -n delete -inet6 default -ifscope "$u" >/dev/null 2>&1 || \
    route -n delete -inet6 default -interface "$u" >/dev/null 2>&1
done
ipconfig set "$IFACE" DHCP                # перезапрос адреса/маршрутов у сети
dscacheutil -flushcache 2>/dev/null       # сброс кэша DNS
killall -HUP mDNSResponder 2>/dev/null    # перезапуск DNS-резолвера

if wait_net_spin 15; then
    echo -e "${G}Ступень 1 помогла. Связь восстановлена.${N}\n"
    diagnose "$IFACE"
    exit 0
fi

# СТУПЕНЬ 2 — если мягкая починка не помогла, "перезагружаем" сам Wi-Fi.
#
# Выключаем и включаем радио — это заставляет ноутбук заново подключиться к
# точке доступа и с нуля получить сетевые настройки. Делаем это ТОЛЬКО если
# uplink действительно Wi-Fi: на проводе или USB-раздаче передёргивать радио
# нечем и незачем.
echo -e "${Y}Ступень 1 не помогла.${N}"
if is_wifi "$IFACE"; then
    echo -e "${B}>>> Ступень 2: передёргиваю Wi-Fi (${IFACE})${N}"
    networksetup -setairportpower "$IFACE" off
    sleep 3
    networksetup -setairportpower "$IFACE" on
    route -n flush -inet >/dev/null 2>&1
    ipconfig set "$IFACE" DHCP
    if wait_net_spin 20; then
        echo -e "${G}Ступень 2 помогла. Связь восстановлена.${N}\n"
        diagnose "$IFACE"
        exit 0
    fi
else
    echo -e "${Y}Ступень 2 пропущена: ${IFACE} — не Wi-Fi.${N}"
    echo -e "${Y}Если это USB-tethering/Ethernet, переподключи кабель или источник сети вручную.${N}"
fi

# Сюда попадаем, только если ни одна ступень не вернула связь. Значит причина,
# скорее всего, ВНЕ ноутбука — называем вероятные внешние причины, а не делаем
# вид, что починили.
echo -e "${R}Автоматически не восстановилось.${N}"
echo -e "Вероятные причины:"
echo -e "  • источник сети сам отвалился — проверь роутер / хотспот iPhone;"
echo -e "  • завис kill switch коммерческого VPN — выключи его в клиенте;"
echo -e "  • переподключись к сети Wi-Fi вручную в меню."
echo
diagnose "$IFACE"

# Если накопилось много utun-туннелей — это мусор от мёртвых VPN-сессий.
# Сам по себе он почти безвреден, но со временем мешает. Скрипт его НЕ удаляет
# (нельзя безопасно выгрузить чужой VPN на лету) — только подсказывает, как
# почистить: выйти из VPN-клиентов и при случае перезагрузиться.
UTUN=$(ifconfig 2>/dev/null | grep -c '^utun')
if [ "$UTUN" -gt 2 ]; then
    echo -e "${Y}Примечание:${N} ${UTUN} utun-интерфейсов. Это остаточные расширения мёртвых VPN."
    echo -e "Скрипт их не трогает (нельзя выгрузить чужой NetworkExtension на лету)."
    echo -e "Чистка: Cmd-Q всем VPN-клиентам -> при необходимости перезагрузка ->"
    echo -e "поднять только нужный (один коммерческий за раз, Tailscale — по требованию)."
fi
exit 1
