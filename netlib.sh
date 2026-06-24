#!/bin/bash
# netlib.sh — общий слой СОСТОЯНИЯ для netinfo/fixnet (память, конфиг, бэкапы).
#
# Источник правды по пути / владельцу / формату / ротации — ТОЛЬКО здесь, чтобы
# netinfo и fixnet не разъехались. Подключение: . "<dir>/netlib.sh".
#
# ПРИНЦИП ПРОЕКТА (закреплён):
#   netinfo — наблюдает, измеряет, пишет СВОЮ локальную историю, открывает портал.
#   netinfo НЕ меняет маршруты / DNS / Wi-Fi / MTU / VPN.
#   Любое изменение сетевого состояния — только fixnet, с согласием и откатом.
#
# Все функции с префиксом nl_ . Состояние: ~/Library/Application Support/netinfo/
#   config           — настройки (history=on/off, history_max=1000)
#   history.jsonl    — журнал замеров (по строке-JSON; schema:1)
#   dns-backup/      — (Фаза 2) бэкап DNS для отката fixnet
#
# NAMESPACE переменных/функций (во избежание коллизий — урок HISTCMD):
#   nl_*  — netlib (этот файл);  NI_* — переменные netinfo/fixnet.
#   НЕ использовать имена спецпеременных bash: HISTCMD, UID, EUID, RANDOM,
#   SECONDS, LINENO, PIPESTATUS, BASH*, SHELLOPTS, GROUPS, FUNCNAME, OPTARG.

# Единые пороги числа utun-интерфейсов (общие для netinfo и fixnet — иначе разойдутся).
# 0-4:  обычно норма для современной macOS с системными туннелями;
# 5-7:  много туннелей, но без паники;
# 8+:   много старых VPN/Network Extension следов;
# 12+:  очень много; при обрывах стоит закрыть VPN-клиенты/перезагрузить.
# utun — это туннели/VPN/Network Extension/Private Relay, НЕ AWDL (тот — awdl0).
NL_UTUN_NORM=4
NL_UTUN_MANY=8
NL_UTUN_LOTS=12

# Реальный пользователь даже под sudo: кнопка зовёт `sudo netinfo.sh`, и $HOME
# тогда может стать /var/root. SUDO_USER хранит того, кто вызвал sudo.
nl_real_user() { echo "${SUDO_USER:-$(id -un)}"; }

# Домашняя папка реального пользователя (через dscl — надёжно и под root).
nl_real_home() {
    local u h
    u=$(nl_real_user)
    h=$(dscl . -read "/Users/$u" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
    [ -n "$h" ] && echo "$h" || echo "$HOME"
}

# Каталог состояния (нативное macOS-место для данных приложения).
nl_state_dir() { echo "$(nl_real_home)/Library/Application Support/netinfo"; }

# Вернуть владельца состояния реальному пользователю (после записи под root) —
# иначе обычный (не-sudo) запуск не сможет читать/писать. ТОЛЬКО на STATE_DIR.
nl_chown_state() {
    [ -n "${SUDO_USER:-}" ] && chown -R "$SUDO_USER":staff "$(nl_state_dir)" 2>/dev/null
    return 0
}

# Создать каталог и дефолтный config при первом запуске.
nl_ensure_state() {
    local d; d=$(nl_state_dir)
    mkdir -p "$d" 2>/dev/null || return 1
    [ -f "$d/config" ] || printf 'history=on\nhistory_max=1000\n' > "$d/config" 2>/dev/null
    nl_chown_state
}

# config get <key> -> значение (или пусто).
nl_config_get() {
    local d; d=$(nl_state_dir)
    [ -f "$d/config" ] || { echo ""; return; }
    awk -F= -v k="$1" '$1==k{print $2; exit}' "$d/config" 2>/dev/null
}

# config set <key> <value> (создаёт ключ, если его не было).
nl_config_set() {
    local d; d=$(nl_state_dir); nl_ensure_state
    local tmp="$d/config.tmp"
    awk -F= -v k="$1" -v v="$2" '
        $1==k{print k"="v; seen=1; next} {print}
        END{if(!seen) print k"="v}' "$d/config" > "$tmp" 2>/dev/null && mv "$tmp" "$d/config"
    nl_chown_state
}

# ---- Сетевые сервисы и DNS-бэкап (Фаза 2; используется fixnet) ----

# Имя сетевого СЕРВИСА по устройству: networksetup работает с "Wi-Fi", а не "en0".
# Через -listallhardwareports (блоки "Hardware Port:" + "Device:"). Пусто — если нет.
nl_service_for_device() {
    local dev="$1"
    [ -z "$dev" ] && { echo ""; return; }
    networksetup -listallhardwareports 2>/dev/null | awk -v d="$dev" '
        /^Hardware Port:/ { sub(/^Hardware Port: /,""); port=$0 }
        /^Device:/ { if ($2==d) { print port; exit } }'
}

# Временная директория для коротких файлов (тело HTTP в ai_check и т.п.). В приватном
# per-user TMPDIR (на macOS он закрыт правами — нет symlink-атаки), не в общем /tmp.
nl_tmp_dir()        { echo "${TMPDIR:-/tmp}/netinfo"; }
nl_ensure_tmp_dir() { mkdir -p "$(nl_tmp_dir)" 2>/dev/null; }

# Каталог и пути бэкапа DNS (для fixnet --dns: active.json + журнал операций).
nl_dns_dir()         { echo "$(nl_state_dir)/dns-backup"; }
nl_dns_active_path() { echo "$(nl_dns_dir)/active.json"; }
nl_dns_ops_log()     { echo "$(nl_dns_dir)/dns-ops.jsonl"; }
nl_ensure_dns_dir()  { mkdir -p "$(nl_dns_dir)" 2>/dev/null; nl_chown_state; }

# Каталог и пути бэкапа MTU (Фаза 4; fixnet --mtu).
nl_mtu_dir()         { echo "$(nl_state_dir)/mtu-backup"; }
nl_mtu_active_path() { echo "$(nl_mtu_dir)/active.json"; }
nl_mtu_ops_log()     { echo "$(nl_mtu_dir)/mtu-ops.jsonl"; }
nl_ensure_mtu_dir()  { mkdir -p "$(nl_mtu_dir)" 2>/dev/null; nl_chown_state; }

# Path MTU (IPv4) бинарным поиском DF-ping. Для IPv4 ICMP echo: packet = payload+28
# (20 IPv4 + 8 ICMP). Провал перепроверяем 1 раз (страховка от случайной потери).
_mtu_ping() {
    ping -D -s "$2" -c1 -W1000 "$1" >/dev/null 2>&1 && return 0
    ping -D -s "$2" -c1 -W1000 "$1" >/dev/null 2>&1
}
# Path MTU до ОДНОГО якоря. Печатает MTU или "" (если не проходит даже малый зонд).
nl_path_mtu_one() {
    local host="$1" lo=64 hi=1472 mid
    _mtu_ping "$host" 64 || { echo ""; return; }          # малый не прошёл → не измерить
    _mtu_ping "$host" 1472 && { echo 1500; return; }      # верх прошёл → 1500
    while [ $((lo+1)) -lt "$hi" ]; do
        mid=$(((lo+hi)/2))
        if _mtu_ping "$host" "$mid"; then lo=$mid; else hi=$mid; fi
    done
    echo $((lo+28))
}
# Path MTU = МИНИМУМ по переданным якорям (консервативно). Пусто, если ни один не измерился.
nl_path_mtu() {
    local best="" h m
    for h in "$@"; do
        m=$(nl_path_mtu_one "$h")
        [ -z "$m" ] && continue
        { [ -z "$best" ] || [ "$m" -lt "$best" ]; } && best="$m"
    done
    echo "$best"
}

# ---- Спиннер прогресса (общий для netinfo/fixnet) ----
# Показывает «живой» индикатор с подписью текущего шага во время долгих операций
# (замер скорости, geo, wait_net, MTU-зонд), чтобы ожидание не читалось как зависание.
# ВАЖНО: пишем в /dev/tty (не в stdout) — не засоряем пайпы/логи и не попадаем в $(...).
# Анимация только в живом терминале (-t 1). Кадры — МАССИВОМ: на bash 3.2 срез
# многобайтной строки (${s:i:1}) побил бы Braille-символы.
# Стиль и отключение (для проблемных терминалов / SSH / «сухого» вывода):
#   NL_SPINNER_STYLE=ascii  → простые кадры | / - \ (если Braille — квадратиками)
#   NL_NO_SPINNER=1         → полностью без анимации
NL_SPINNER_STYLE="${NL_SPINNER_STYLE:-braille}"
if [ "$NL_SPINNER_STYLE" = "ascii" ]; then
    NL_SPIN_FRAMES=('|' '/' '-' '\')
else
    NL_SPIN_FRAMES=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
fi
NL_SPIN_N=${#NL_SPIN_FRAMES[@]}
NL_SPIN_PID=""

# Можно ли крутить спиннер: не отключён явно, stdout — терминал, /dev/tty доступен.
nl_spin_ok() {
    [ "${NL_NO_SPINNER:-0}" = "1" ] && return 1
    [ -t 1 ] && [ -w /dev/tty ]
}

nl_spin_start() {
    nl_spin_ok || return 0
    NL_SPIN_LABEL="$1"
    ( i=0
      while :; do
        printf '\r%s %s… ' "${NL_SPIN_FRAMES[i]}" "$NL_SPIN_LABEL" >/dev/tty 2>/dev/null
        i=$(((i+1)%NL_SPIN_N)); sleep 0.1
      done ) &
    NL_SPIN_PID=$!
    disown 2>/dev/null || true
}
nl_spin_stop() {
    [ -n "${NL_SPIN_PID:-}" ] || return 0
    kill "$NL_SPIN_PID" 2>/dev/null
    wait "$NL_SPIN_PID" 2>/dev/null
    NL_SPIN_PID=""
    printf '\r\033[K' >/dev/tty 2>/dev/null   # стереть строку спиннера
}

# Дописать строку JSON в историю и подрезать до history_max (по умолчанию 1000).
nl_history_append() {
    local line="$1"
    [ -z "$line" ] && return 0
    local d; d=$(nl_state_dir); nl_ensure_state
    local f="$d/history.jsonl" max
    printf '%s\n' "$line" >> "$f" 2>/dev/null || return 0
    max=$(nl_config_get history_max); [ -z "$max" ] && max=1000
    if [ "$(wc -l < "$f" 2>/dev/null || echo 0)" -gt "$max" ]; then
        tail -n "$max" "$f" > "$f.tmp" 2>/dev/null && mv "$f.tmp" "$f"
    fi
    nl_chown_state
}

# Узнавание сети: по SSID -> "были тут N раз; прошлый раз (когда) — <вердикт>".
# Пусто, если визитов нет / нет python3. Причину прошлого визита РЕКОНСТРУИРУЕМ
# из сохранённых полей (честно, без выдумки).
# Режим (2-й арг): "human" (по умолчанию, строка для вывода) или "json" — тогда
# печатает машинный TSV "count\tlast_seen_human\tlast_q" (для netinfo --json).
nl_history_recall() {
    local ssid="$1" mode="${2:-human}"
    [ -z "$ssid" ] && { echo ""; return; }
    local f; f="$(nl_state_dir)/history.jsonl"
    [ -f "$f" ] || { echo ""; return; }
    command -v python3 >/dev/null 2>&1 || { echo ""; return; }
    python3 - "$ssid" "$f" "$mode" <<'PY' 2>/dev/null
import sys, json, datetime
ssid, path = sys.argv[1], sys.argv[2]
mode = sys.argv[3] if len(sys.argv)>3 else "human"
rows=[]
try:
    for ln in open(path, encoding="utf-8"):
        ln=ln.strip()
        if not ln: continue
        try: o=json.loads(ln)
        except Exception: continue
        if o.get("ssid")==ssid: rows.append(o)
except Exception:
    sys.exit(0)
if not rows: sys.exit(0)
n=len(rows); last=rows[-1]
def rel(ts):
    try:
        t=datetime.datetime.fromisoformat(ts)
        now=datetime.datetime.now(t.tzinfo) if t.tzinfo else datetime.datetime.now()
        s=(now-t).total_seconds()
        if s<300:   return "только что"
        if s<3600:  return "%d мин назад"%(s//60)
        if s<86400: return "сегодня"
        if s<172800:return "вчера"
        return "%d дн назад"%(s//86400)
    except Exception: return ""
def plural_raz(n):
    n=abs(int(n))
    if 11<=n%100<=14: return "раз"
    d=n%10
    if d==1: return "раз"
    if 2<=d<=4: return "раза"
    return "раз"
# СПОКОЙНАЯ формулировка: один тестовый всплеск не должен пугать «🔴 плохо» в
# обычном выводе. Без эмодзи и без драмы; точные цифры — в history.jsonl / --tech.
def plural_zamer(n):
    n=abs(int(n))
    if 11<=n%100<=14: return "замеров"
    d=n%10
    if d==1: return "замер"
    if 2<=d<=4: return "замера"
    return "замеров"
when=rel(last.get("ts",""))
if mode=="json":
    # машинно: число замеров, человекочитаемое «когда», код качества прошлого
    print("%d\t%s\t%s" % (n, when or "", last.get("q","")))
    sys.exit(0)
if when=="только что":
    # сравнивать с замером секунды назад бессмысленно — нейтрально
    print("сеть знакомая — %d %s; прошлый — только что" % (n, plural_zamer(n)))
else:
    gentle = "было нормально" if last.get("q")=="green" else "были замечания"
    print("сеть знакомая — %d %s; прошлый — %s (%s)" % (n, plural_zamer(n), when if when else "недавно", gentle))
PY
}
