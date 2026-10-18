#!/usr/bin/env bash
# shellcheck disable=SC2015  # конструкции "проверка && pass || fail": fail завершает скрипт
# Интеграционный тест deploy.sh против локального sshd (Ubuntu-раннер GitHub Actions или контейнер).
# Поднимает sshd на 127.0.0.1:2222 и HTTP-сервер на 127.0.0.1:8080, раздающий ~/public_html,
# и прогоняет сценарии: deploy → deploy → shared-каталог → rollback → провал healthcheck с автооткатом → remove.
set -euo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
DEPLOY="$HERE/deploy.sh"
USER_NAME=${TEST_USER:-$(id -un)}
W=$(mktemp -d)
export RUNNER_TEMP="$W/tmp" GITHUB_OUTPUT="$W/out" GITHUB_STEP_SUMMARY="$W/summary"
mkdir -p "$RUNNER_TEMP"

pass() { printf '\033[32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[31mFAIL\033[0m %s\n' "$*"; exit 1; }

# --- sshd ---
ssh-keygen -q -t ed25519 -N '' -f "$W/client"
ssh-keygen -q -t ed25519 -N '' -f "$W/hostkey"
mkdir -p ~/.ssh && chmod 700 ~/.ssh
cat "$W/client.pub" >>~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys
SUDO=""; [[ $(id -u) -ne 0 ]] && SUDO=sudo
$SUDO mkdir -p /run/sshd
$SUDO "$(command -v sshd || echo /usr/sbin/sshd)" -p 2222 -h "$W/hostkey" -o ListenAddress=127.0.0.1 \
  -o PasswordAuthentication=no -o PidFile="$W/sshd.pid" -o AuthorizedKeysFile=.ssh/authorized_keys
KNOWN="[127.0.0.1]:2222 $(cut -d' ' -f1,2 "$W/hostkey.pub")"

# --- http ---
mkdir -p ~/public_html
(cd ~/public_html && exec python3 -m http.server 8080 --bind 127.0.0.1 >"$W/http.log" 2>&1) &
HTTP_PID=$!
trap '$SUDO kill "$(cat "$W/sshd.pid")" 2>/dev/null || true; kill $HTTP_PID 2>/dev/null || true' EXIT
sleep 1

run() {
  : >"$GITHUB_OUTPUT"
  env HD_HOST=127.0.0.1 HD_PORT=2222 HD_USER="$USER_NAME" HD_KEY="$(cat "$W/client")" \
    HD_KNOWN_HOSTS="$KNOWN" HD_TARGET=public_html/site "$@" bash "$DEPLOY"
}
outv() { grep "^$1=" "$GITHUB_OUTPUT" | tail -1 | cut -d= -f2-; }
page() { curl -fsS "http://127.0.0.1:8080/site/$1"; }

mk_site() { rm -rf "$W/site" && mkdir -p "$W/site/sub" && echo "$1" >"$W/site/index.html" && echo static >"$W/site/sub/a.txt"; }

# 1. первая выкладка
mk_site "<p>v1</p>"
GITHUB_SHA=1111111aaaa run HD_SOURCE="$W/site" HD_SHARED=preview HD_HC_URL=http://127.0.0.1:8080/site/ HD_HC_CONTAINS=v1
R1=$(outv release)
[[ "$(page index.html)" == "<p>v1</p>" ]] && pass "deploy v1 ($R1)" || fail "deploy v1"

# 2. shared-каталог (имитация превью ветки) переживает следующую выкладку
mkdir -p ~/.deploy/public_html_site/shared/preview/feature && echo preview >~/.deploy/public_html_site/shared/preview/feature/index.html
sleep 1
mk_site "<p>v2</p>"
GITHUB_SHA=2222222bbbb run HD_SOURCE="$W/site" HD_SHARED=preview HD_HC_URL=http://127.0.0.1:8080/site/ HD_HC_CONTAINS=v2
R2=$(outv release)
[[ "$(page index.html)" == "<p>v2</p>" ]] && pass "deploy v2 ($R2)" || fail "deploy v2"
[[ "$(page preview/feature/index.html)" == preview ]] && pass "shared dir preview/ сохранился" || fail "shared dir"
[[ "$(outv previous-release)" == "$R1" ]] && pass "previous-release = $R1" || fail "previous-release"
# неизменившийся файл — жёсткая ссылка на предыдущий релиз
[[ $(stat -c %h ~/.deploy/public_html_site/releases/"$R2"/sub/a.txt) -ge 2 ]] && pass "link-dest: hardlink" || fail "link-dest"

# 3. откат
run HD_MODE=rollback
[[ "$(page index.html)" == "<p>v1</p>" && "$(outv release)" == "$R1" ]] && pass "rollback -> $R1" || fail "rollback"
run HD_MODE=rollback HD_ROLLBACK_TO="$R2"
[[ "$(page index.html)" == "<p>v2</p>" ]] && pass "rollback-to $R2" || fail "rollback-to"

# 4. провал healthcheck → автооткат, код возврата != 0
sleep 1
mk_site "<p>broken</p>"
if GITHUB_SHA=3333333cccc run HD_SOURCE="$W/site" HD_HC_URL=http://127.0.0.1:8080/site/ HD_HC_CONTAINS=v3 HD_HC_RETRIES=1; then
  fail "healthcheck должен был провалиться"
fi
[[ "$(page index.html)" == "<p>v2</p>" ]] && pass "healthcheck fail -> автооткат на $R2" || fail "auto-rollback"

# 5. отказ без known_hosts для чужого хоста
if env HD_HOST=127.0.0.1 HD_PORT=2222 HD_USER=x HD_KEY=x HD_TARGET=t bash "$DEPLOY" 2>/dev/null; then
  fail "должен отказать без known-hosts"
fi
pass "без known-hosts — отказ"

# 6. недопустимый путь
if run HD_SOURCE="$W/site" HD_TARGET='public_html/../../etc' 2>/dev/null; then fail "path traversal"; fi
pass "path traversal отклонён"

# 7. direct + delete
mkdir -p "$W/d" && echo d1 >"$W/d/index.html" && echo old >"$W/d/old.txt"
run HD_STRATEGY=direct HD_TARGET=public_html/direct HD_SOURCE="$W/d"
rm "$W/d/old.txt"
run HD_STRATEGY=direct HD_TARGET=public_html/direct HD_SOURCE="$W/d" HD_DELETE=true
[[ ! -e ~/public_html/direct/old.txt ]] && pass "direct --delete" || fail "direct --delete"

# 8. remove
run HD_MODE=remove
[[ ! -e ~/public_html/site && ! -e ~/.deploy/public_html_site ]] && pass "remove" || fail "remove"

echo "все сценарии пройдены"
