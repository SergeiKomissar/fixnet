export const meta = {
  name: 'fixnet-regression',
  description: 'Регрессия fixnet/netinfo/access/deploy: синтаксис, инварианты CLAUDE.md, read-only CLI-прогоны',
  phases: [{ title: 'Checks', detail: '8 независимых проверок параллельно' }],
}

const REPO = '/Users/komissarov/projects/fixnet'
const RES = {type:'object',properties:{pass:{type:'boolean'},details:{type:'string'},failures:{type:'array',items:{type:'string'}}},required:['pass','details']}
const RO = ' ВАЖНО: работай строго read-only — только диагностические команды, НИЧЕГО не редактировать, не коммитить, состояние сети не менять, sudo не использовать. Верни pass=true только если всё ок; details — краткая сводка на русском; failures — конкретика по каждому провалу.'

const CHECKS = [
  {key: 'syntax', prompt: `В ${REPO}: прогони /bin/bash -n для каждого из: netlib.sh fixnet.sh netinfo.sh access.sh deploy.sh why.command access.command fixnet.command netinfo.command (пропусти несуществующие). Также проверь, что первая строка каждого — шебанг #!. pass=true если все существующие прошли обе проверки.`},
  {key: 'invariants', prompt: `В ${REPO} проверь grep'ом инварианты из CLAUDE.md: (1) в netinfo.sh, fixnet.sh, access.sh НОЛЬ вхождений слов: РКН, ТСПУ, госблок (политлексика запрещена даже в коде); (2) в netinfo.sh НОЛЬ вхождений слова "утечка"; (3) в fixnet.sh НЕ используется переменная \${C} (палитра fixnet — R G Y B D N; \${C} есть только в netinfo — под set -u дала бы unbound variable); (4) в access.sh строка, пишущая в access-matrix.jsonl, использует url_hash, а НЕ полный URL. pass=true если все 4 держатся.`},
  {key: 'dup-sync', prompt: `В ${REPO}: функции detect_iface и check_dns НАМЕРЕННО продублированы в fixnet.sh и netinfo.sh и должны быть логически синхронны (CLAUDE.md: "при правке правила интерфейса синхронизировать оба файла"). Вырежи тела обеих функций из обоих файлов (awk '/^detect_iface\\(\\)/,/^}/' и аналогично) и сравни diff'ом. Мелкие косметические отличия (комментарии, имена локальных переменных) — ок; расхождение ЛОГИКИ (порядок приоритетов, условия) — провал. pass=true если логика совпадает.`},
  {key: 'deploy', prompt: `В ${REPO}: прогони ./deploy.sh --check. pass=true если вывод говорит "Всё синхронно" (все 4 скрипта в ~/bin идентичны репо). Приведи вывод в details.`},
  {key: 'json', prompt: `Прогони: ~/bin/netinfo.sh --json --no-speed --no-history 2>/dev/null | python3 -m json.tool. pass=true если JSON валиден И содержит верхнеуровневые ключи status, exit, link, quality, vpn, codes. В details — какие codes[] активны.`},
  {key: 'fixnet-check', prompt: `Прогони: ~/bin/fixnet.sh --check (без sudo, это read-only диагностика). pass=true если exit-код 0 И в ~/Library/Application\\ Support/netinfo/fixnet-logs/ появился НОВЫЙ файл журнала (сравни mtime с моментом запуска), внутри которого есть строки "СНИМОК (до)" и "СНИМОК (после)".`},
  {key: 'access', prompt: `Прогони read-only команды: ~/bin/access.sh --history и ~/bin/access.sh --vpn-inventory. pass=true если обе завершились без ошибок (exit 0) и вывод осмысленный (не пустой, без bash-ошибок вида "unbound variable" или "command not found").`},
  {key: 'why', prompt: `Прогони две проверки режима --why: (1) ~/bin/netinfo.sh --why https://example.com — ожидаем класс ok (страница статична, отдаётся 200/206); (2) ~/bin/netinfo.sh --why example.com (БЕЗ схемы) — ожидаем честный отказ с подсказкой про полный http/https URL, БЕЗ падения. pass=true если оба поведения соответствуют.`},
]

phase('Checks')
const out = await parallel(CHECKS.map(c => () =>
  agent(c.prompt + RO, {label: c.key, phase: 'Checks', schema: RES})
    .then(r => ({key: c.key, ...r}))
))
const res = out.filter(Boolean)
const failed = res.filter(r => !r.pass)
log(`${res.length - failed.length}/${res.length} проверок прошло`)
return {
  passed: res.length - failed.length,
  total: res.length,
  failed: failed.map(f => ({key: f.key, details: f.details, failures: f.failures || []})),
  ok: res.filter(r => r.pass).map(r => r.key),
}