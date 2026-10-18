#!/usr/bin/env bash
# Helios ITMO Static Deploy — исполняемая часть composite action.
# Все параметры приходят через переменные окружения HD_* (см. action.yml).
# Удалённые команды пишутся на POSIX sh и проверены на FreeBSD (Helios) и GNU/Linux.
set -euo pipefail

HELIOS_KNOWN_HOSTS='[helios.cs.ifmo.ru]:2222 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILr5dsbF6eEBT5UFKGo1Qe3ina64YppvFELt8Wu+cZM1'

log() { printf '::notice title=helios-deploy::%s\n' "$*"; }
die() { printf '::error title=helios-deploy::%s\n' "$*"; exit 1; }
is_true() { [[ "${1,,}" == "true" || "$1" == "1" || "${1,,}" == "yes" ]]; }
out() { [[ -n "${GITHUB_OUTPUT:-}" ]] && printf '%s=%s\n' "$1" "$2" >>"$GITHUB_OUTPUT" || true; }

START=$(date +%s)

# ---------- проверка входных данных ----------
HD_HOST=${HD_HOST:-helios.cs.ifmo.ru}
HD_PORT=${HD_PORT:-2222}
HD_SOURCE=${HD_SOURCE:-site}
HD_STRATEGY=${HD_STRATEGY:-atomic}
HD_MODE=${HD_MODE:-deploy}
HD_KEEP=${HD_KEEP:-5}
HD_HC_FROM=${HD_HC_FROM:-runner}
HD_HC_RETRIES=${HD_HC_RETRIES:-6}

[[ -n "${HD_USER:-}" ]] || die "input username обязателен"
[[ -n "${HD_KEY:-}" ]] || die "input ssh-key обязателен (передайте секрет)"
[[ -n "${HD_TARGET:-}" ]] || die "input target обязателен"

# Безопасный алфавит путей: исключает инъекцию в удалённые команды и выход за пределы $HOME.
safe_path='^[A-Za-z0-9._~/-]+$'
for v in HD_TARGET HD_RELEASES_DIR HD_ROLLBACK_TO HD_SHARED; do
  val=${!v:-}
  [[ -z "$val" ]] && continue
  [[ "$v" == HD_SHARED ]] && val=${val// /}
  [[ "$val" =~ $safe_path ]] || die "$v содержит недопустимые символы: $val"
  [[ "/$val/" == *"/../"* ]] && die "$v не должен содержать '..'"
  [[ "$val" == /* ]] && die "$v задаётся относительно домашнего каталога, без ведущего /"
done
[[ "$HD_USER" =~ ^[A-Za-z0-9._-]+$ ]] || die "некорректный username"
[[ "$HD_PORT" =~ ^[0-9]+$ ]] || die "некорректный port"
[[ "$HD_KEEP" =~ ^[0-9]+$ && "$HD_KEEP" -ge 1 ]] || die "keep-releases должно быть целым >= 1"
case "$HD_STRATEGY" in direct|atomic) ;; *) die "strategy: direct | atomic" ;; esac
case "$HD_MODE" in deploy|rollback|remove|status) ;; *) die "mode: deploy | rollback | remove | status" ;; esac
[[ "$HD_MODE" != deploy && "$HD_STRATEGY" != atomic ]] && die "mode: $HD_MODE доступен только для strategy: atomic"

TARGET=${HD_TARGET%/}
REL=${HD_RELEASES_DIR:-.deploy/${TARGET//\//_}}
REL=${REL%/}

# ---------- SSH: ключ и known_hosts во временном каталоге раннера ----------
WORK=$(mktemp -d "${RUNNER_TEMP:-/tmp}/helios-deploy.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
umask 077
printf '%s\n' "$HD_KEY" | tr -d '\r' >"$WORK/key"
if [[ -n "${HD_KNOWN_HOSTS:-}" ]]; then
  printf '%s\n' "$HD_KNOWN_HOSTS" >"$WORK/known_hosts"
elif [[ "$HD_HOST" == "helios.cs.ifmo.ru" && "$HD_PORT" == "2222" ]]; then
  printf '%s\n' "$HELIOS_KNOWN_HOSTS" >"$WORK/known_hosts"
else
  die "укажите known-hosts: action не отключает проверку ключа хоста (StrictHostKeyChecking)"
fi
umask 022

SSH_OPTS=(-i "$WORK/key" -p "$HD_PORT"
  -o IdentitiesOnly=yes -o BatchMode=yes
  -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$WORK/known_hosts"
  -o ConnectTimeout=30 -o ServerAliveInterval=15 -o ServerAliveCountMax=4)
DEST="$HD_USER@$HD_HOST"
RSYNC_SSH="ssh ${SSH_OPTS[*]}"

# remote VAR=value... <<'SCRIPT' — выполнить POSIX-скрипт на сервере, передав переменные.
remote() {
  local header="set -eu; cd \"\$HOME\";"
  local kv
  for kv in "$@"; do header+=" ${kv%%=*}=$(printf '%q' "${kv#*=}");"; done
  { printf '%s\n' "$header"; cat; } | ssh "${SSH_OPTS[@]}" "$DEST" sh -s
}

COMMON_REMOTE=(TARGET="$TARGET" REL="$REL")

# Функции, общие для удалённых скриптов: активация релиза атомарной подменой симлинка.
REMOTE_LIB='
activate() {
  # $1 — id релиза. Новый симлинк создаётся рядом и переименовывается поверх старого:
  # rename(2) атомарен, поэтому посетитель видит либо старую, либо новую версию целиком.
  mkdir -p "$(dirname "$TARGET")"
  tmp="$TARGET.hd-new.$$"
  rm -f "$tmp"
  ln -s "$HOME/$REL/releases/$1" "$tmp"
  if [ -e "$TARGET" ] && [ ! -L "$TARGET" ]; then
    # первая выкладка поверх обычного каталога: сохраняем его как релиз legacy-*
    legacy="legacy-$(date -u +%Y%m%dT%H%M%SZ)"
    mv "$TARGET" "$REL/releases/$legacy"
    echo "$legacy" >>"$REL/history"
  fi
  mv -h "$tmp" "$TARGET" 2>/dev/null || mv -Tf "$tmp" "$TARGET"
  echo "$1" >>"$REL/history"
}
current() { if [ -L "$TARGET" ]; then basename "$(readlink "$TARGET")"; fi; }
'

# ---------- healthcheck ----------
healthcheck() {
  [[ -z "${HD_HC_URL:-}" ]] && return 0
  local i body url="$HD_HC_URL"
  for ((i = 1; i <= HD_HC_RETRIES; i++)); do
    if [[ "$HD_HC_FROM" == remote ]]; then
      body=$(remote URL="$url" <<<'curl -fsSL -m 20 -H "Cache-Control: no-cache" "$URL"' 2>"$WORK/hc.err") || body=""
    else
      body=$(curl -fsSL -m 20 -H 'Cache-Control: no-cache' "$url" 2>"$WORK/hc.err") || body=""
    fi
    if [[ -n "$body" ]] && { [[ -z "${HD_HC_CONTAINS:-}" ]] || grep -qF -- "$HD_HC_CONTAINS" <<<"$body"; }; then
      log "healthcheck OK ($url, попытка $i)"
      return 0
    fi
    echo "healthcheck: попытка $i/$HD_HC_RETRIES не прошла: $(head -c 300 "$WORK/hc.err" 2>/dev/null)"
    sleep 5
  done
  printf '::error title=helios-deploy::healthcheck не прошёл: %s (ожидалась строка: %s)\n' "$url" "${HD_HC_CONTAINS:-<любой 2xx>}"
  return 1
}

summary() {
  [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] || return 0
  {
    echo "### Helios deploy: $HD_MODE ($HD_STRATEGY)"
    echo "| параметр | значение |"
    echo "|---|---|"
    echo "| хост | \`$HD_HOST:$HD_PORT\` |"
    echo "| target | \`~/$TARGET\` |"
    [[ "$HD_STRATEGY" == atomic ]] && echo "| релиз | \`${1:-}\` (был \`${2:-—}\`) |"
    echo "| время доставки | $(( $(date +%s) - START )) с |"
  } >>"$GITHUB_STEP_SUMMARY"
}

# ---------- direct ----------
if [[ "$HD_STRATEGY" == direct ]]; then
  [[ -d "$HD_SOURCE" ]] || die "source '$HD_SOURCE' не найден"
  remote "${COMMON_REMOTE[@]}" <<<'mkdir -p "$TARGET"'
  args=(-rltz "--chmod=D755,F644" -e "$RSYNC_SSH")
  is_true "${HD_DELETE:-false}" && args+=(--delete)
  # shellcheck disable=SC2206
  [[ -n "${HD_RSYNC_ARGS:-}" ]] && args+=($HD_RSYNC_ARGS)
  rsync "${args[@]}" "$HD_SOURCE/" "$DEST:$TARGET/"
  healthcheck
  out duration "$(( $(date +%s) - START ))"
  summary
  exit 0
fi

# ---------- atomic: status ----------
if [[ "$HD_MODE" == status ]]; then
  res=$(remote "${COMMON_REMOTE[@]}" <<SCRIPT
$REMOTE_LIB
echo "target: \$TARGET -> \$(readlink "\$TARGET" 2>/dev/null || echo '<нет симлинка>')"
echo "releases (\$REL/releases):"
for r in \$(ls -1 "\$REL/releases" 2>/dev/null | sort); do
  mark=""; [ "\$r" = "\$(current)" ] && mark=" <- active"
  echo "  \$r  \$(du -sk "\$REL/releases/\$r" | cut -f1) KB  \$(find "\$REL/releases/\$r" -type f | wc -l | tr -d ' ') files\$mark"
done
echo "history (последние 10 активаций):"
tail -n 10 "\$REL/history" 2>/dev/null | sed 's/^/  /'
SCRIPT
)
  printf '%s\n' "$res"
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    { echo '### Helios deploy: status'; echo '```'; printf '%s\n' "$res"; echo '```'; } >>"$GITHUB_STEP_SUMMARY"
  fi
  out release "$(sed -n 's#^target: .* -> .*/##p' <<<"$res")"
  exit 0
fi

# ---------- atomic: remove ----------
if [[ "$HD_MODE" == remove ]]; then
  remote "${COMMON_REMOTE[@]}" <<'SCRIPT'
[ -L "$TARGET" ] && rm -f "$TARGET"
rm -rf "$REL"
echo "removed $TARGET and $REL"
SCRIPT
  out duration "$(( $(date +%s) - START ))"
  summary "" ""
  exit 0
fi

# ---------- atomic: rollback ----------
if [[ "$HD_MODE" == rollback ]]; then
  res=$(remote "${COMMON_REMOTE[@]}" WANT="${HD_ROLLBACK_TO:-}" <<SCRIPT
$REMOTE_LIB
cur=\$(current)
[ -n "\$cur" ] || { echo "ERR: \$TARGET не является симлинком на релиз" >&2; exit 3; }
if [ -n "\$WANT" ]; then
  to=\$WANT
else
  # последний активировавшийся релиз, отличный от текущего и ещё существующий
  to=\$(awk '{a[NR]=\$0} END {for (i = NR; i > 0; i--) print a[i]}' "\$REL/history" \
      | while read -r r; do [ "\$r" != "\$cur" ] && [ -d "\$REL/releases/\$r" ] && { echo "\$r"; break; }; done)
fi
[ -n "\$to" ] && [ -d "\$REL/releases/\$to" ] || { echo "ERR: нет релиза для отката (\$to)" >&2; ls -1 "\$REL/releases" >&2; exit 4; }
activate "\$to"
echo "\$cur \$to"
SCRIPT
)
  read -r prev now <<<"$res"
  log "откат: $prev -> $now"
  out release "$now"; out previous-release "$prev"
  healthcheck
  out duration "$(( $(date +%s) - START ))"
  summary "$now" "$prev"
  exit 0
fi

# ---------- atomic: deploy ----------
[[ -d "$HD_SOURCE" ]] || die "source '$HD_SOURCE' не найден"
SHA=${GITHUB_SHA:-manual}
ID="$(date -u +%Y%m%dT%H%M%SZ)-${SHA:0:7}"

# 1. подготовка каталогов и определение текущего релиза
PREV=$(remote "${COMMON_REMOTE[@]}" <<SCRIPT
$REMOTE_LIB
mkdir -p "\$REL/releases" "\$REL/shared"
touch "\$REL/history"
current
SCRIPT
)
log "текущий релиз: ${PREV:-нет}; новый: $ID"

# 2. загрузка в новый каталог; неизменившиеся файлы — жёсткие ссылки на предыдущий релиз
args=(-rlzc --delete "--chmod=D755,F644" -e "$RSYNC_SSH")
[[ -n "$PREV" ]] && args+=(--link-dest="../$PREV")
# shellcheck disable=SC2206
[[ -n "${HD_RSYNC_ARGS:-}" ]] && args+=($HD_RSYNC_ARGS)
rsync "${args[@]}" "$HD_SOURCE/" "$DEST:$REL/releases/$ID/"

# 3. общие каталоги, переключение симлинка, очистка старых релизов
remote "${COMMON_REMOTE[@]}" ID="$ID" KEEP="$HD_KEEP" SHARED="${HD_SHARED:-}" <<SCRIPT
$REMOTE_LIB
for d in \$SHARED; do
  rm -rf "\$REL/releases/\$ID/\$d"
  mkdir -p "\$REL/shared/\$d" "\$(dirname "\$REL/releases/\$ID/\$d")"
  ln -s "\$HOME/\$REL/shared/\$d" "\$REL/releases/\$ID/\$d"
done
activate "\$ID"
cur=\$(current)
ls -1 "\$REL/releases" | grep '^[0-9]' | sort -r | awk -v k="\$KEEP" 'NR > k' | while read -r old; do
  [ "\$old" = "\$cur" ] || rm -rf "\$REL/releases/\$old"
done
tail -n 50 "\$REL/history" >"\$REL/history.tmp" && mv "\$REL/history.tmp" "\$REL/history"
echo "active: \$cur"
SCRIPT

out release "$ID"
out previous-release "${PREV:-}"

# 4. healthcheck и автооткат
if ! healthcheck; then
  if is_true "${HD_ROLLBACK_ON_FAILURE:-true}" && [[ -n "$PREV" ]]; then
    # провалившийся релиз удаляется, чтобы последующий mode: rollback не вернул его из истории
    remote "${COMMON_REMOTE[@]}" PREV="$PREV" ID="$ID" <<SCRIPT
$REMOTE_LIB
activate "\$PREV"
rm -rf "\$REL/releases/\$ID"
SCRIPT
    printf '::error title=helios-deploy::выполнен автоматический откат на %s\n' "$PREV"
    out release "$PREV"
  fi
  summary "$ID (FAILED)" "$PREV"
  exit 1
fi

out duration "$(( $(date +%s) - START ))"
summary "$ID" "$PREV"
