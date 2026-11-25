#!/usr/bin/env bash
# 发布录音卡官网（ai-card.app.reai.com）与 TestFlight 邀请 API 到 cn.reai.com。
set -euo pipefail

HOST="${REMOTE_HOST:-root@cn.reai.com}"
DOMAIN="${DOMAIN:-ai-card.app.reai.com}"
WEB_ROOT="/var/www/${DOMAIN}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
NGINX_CONF_LOCAL="${SCRIPT_DIR}/ai-card.app.reai.com.conf"

echo "==> [1/4] Syncing site/ to ${HOST}:${WEB_ROOT}/..."
ssh "${HOST}" "mkdir -p '${WEB_ROOT}'"
rsync -avz --delay-updates --delete-delay \
  --exclude='.DS_Store' \
  "${REPO_ROOT}/site/" "${HOST}:${WEB_ROOT}/"

echo "==> [2/4] Syncing ai-card-beta-api & ensuring systemd service..."
ssh "${HOST}" "mkdir -p /opt/ai-card-beta-api /var/lib/ai-card-beta-api && chmod 700 /var/lib/ai-card-beta-api"
rsync -avz --delay-updates --delete-delay \
  --exclude='.DS_Store' --exclude='__pycache__/' --exclude='*.pyc' \
  --exclude='test_*.py' --exclude='.env*' \
  "${REPO_ROOT}/server/beta-api/" "${HOST}:/opt/ai-card-beta-api/"
scp "${SCRIPT_DIR}/ai-card-beta-api.service" "${HOST}:/etc/systemd/system/ai-card-beta-api.service"
ssh "${HOST}" bash -s <<'REMOTE_API'
set -euo pipefail
if [ ! -f /etc/ai-card-beta-api/official.env ]; then
  echo "❌ Missing /etc/ai-card-beta-api/official.env on server. Create it (chmod 600) before publishing."
  exit 1
fi
systemctl daemon-reload
systemctl enable ai-card-beta-api.service
systemctl restart ai-card-beta-api.service
for i in $(seq 1 15); do
  if curl -fsS http://127.0.0.1:8790/api/beta/health >/dev/null 2>&1; then
    exit 0
  fi
  sleep 1
done
echo "❌ ai-card-beta-api failed local health check"
journalctl -u ai-card-beta-api.service -n 30 --no-pager
exit 1
REMOTE_API

echo "==> [3/4] Installing formal HTTPS Nginx configuration and reloading..."
scp "${NGINX_CONF_LOCAL}" "${HOST}:/etc/nginx/sites-available/${DOMAIN}.conf"
ssh "${HOST}" bash -s <<REMOTE_NGX
set -euo pipefail
if [ -f "/etc/nginx/sites-enabled/${DOMAIN}.conf" ] && [ ! -L "/etc/nginx/sites-enabled/${DOMAIN}.conf" ]; then
  cp "/etc/nginx/sites-enabled/${DOMAIN}.conf" "/etc/nginx/sites-available/${DOMAIN}.conf.bak.\$(date +%Y%m%d%H%M%S)"
  rm -f "/etc/nginx/sites-enabled/${DOMAIN}.conf"
fi
ln -sfn "/etc/nginx/sites-available/${DOMAIN}.conf" "/etc/nginx/sites-enabled/${DOMAIN}.conf"
nginx -t
systemctl reload nginx
REMOTE_NGX

echo "==> [4/4] Verifying live HTTPS endpoints..."
for URL in \
  "https://${DOMAIN}/" \
  "https://${DOMAIN}/assets/beta-signup.js?v=20261125a" \
  "https://${DOMAIN}/assets/app.js?v=20261125a" \
  "https://${DOMAIN}/privacy.html" \
  "https://${DOMAIN}/support.html" \
  "https://${DOMAIN}/link/" \
  "https://${DOMAIN}/api/beta/health"
do
  CODE=$(curl -sS -o /dev/null -w "%{http_code}" "${URL}")
  echo "GET ${URL} -> HTTP ${CODE}"
  if [ "${CODE}" != "200" ]; then
    echo "❌ Unexpected HTTP status ${CODE} for ${URL}"
    exit 1
  fi
done

AASA_HEADERS=$(curl -sSI "https://${DOMAIN}/.well-known/apple-app-site-association")
echo "${AASA_HEADERS}" | grep -qi "200" || {
  echo "❌ AASA endpoint did not return HTTP 200"
  exit 1
}
echo "${AASA_HEADERS}" | grep -qi "application/json" || {
  echo "❌ AASA endpoint did not return application/json"
  exit 1
}
echo "GET https://${DOMAIN}/.well-known/apple-app-site-association -> HTTP 200 (application/json)"

HEALTH_JSON=$(curl -fsS "https://${DOMAIN}/api/beta/health")
echo "HEALTH ${HEALTH_JSON}"
echo "${HEALTH_JSON}" | grep -q '"ok":[[:space:]]*true' || {
  echo "❌ /api/beta/health did not return ok:true"
  exit 1
}
if echo "${HEALTH_JSON}" | grep -q '"iosBetaReviewState":[[:space:]]*"UNKNOWN"'; then
  echo "❌ /api/beta/health returned iosBetaReviewState: UNKNOWN"
  exit 1
fi

echo "✅ Published successfully: https://${DOMAIN}"
