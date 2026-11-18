#!/usr/bin/env bash
# Proves the aldehyde fork's page-only patch on a built image: the sign-in page and
# the account center page show no "Powered by Logto" line and no .logto_signature
# element. The setting `hideLogtoBranding` is left at its default (false), so the
# result comes from the page patch alone, never from a licence or entitlement path.
#
# Usage:
#   fork/harness/no-signature.sh <image-ref>                     # patched build: must be clean
#   fork/harness/no-signature.sh <image-ref> --expect-signature  # planted failure: an
#       unpatched build MUST show the signature on BOTH pages, proving the probe can see it
#
# Env (optional):
#   ALDEHYDE_SIG_PREFIX  container/network name prefix (default aldehyde-no-signature)
#   ALDEHYDE_SIG_PORT    host port for the core (default 47811); the browser and the
#                        OIDC issuer both use http://localhost:<port>
#   CHROME_PATH          Chrome binary for puppeteer (default: puppeteer's own)
set -euo pipefail

readonly image="${1:?usage: fork/harness/no-signature.sh <image-ref> [--expect-signature]}"
readonly mode="${2:-}"
[[ -z "${mode}" || "${mode}" == "--expect-signature" ]] || {
  echo "unknown option: ${mode}" >&2
  exit 64
}
readonly repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly prefix="${ALDEHYDE_SIG_PREFIX:-aldehyde-no-signature}"
readonly port="${ALDEHYDE_SIG_PORT:-47811}"
readonly network="${prefix}-net"
readonly database="${prefix}-database"
readonly core="${prefix}-core"
readonly database_url="postgres://postgres:postgres@${database}:5432/logto"
readonly endpoint="http://localhost:${port}"
readonly client_id="aldehyde-sig-probe"
readonly client_secret="aldehyde-signature-probe-secret"
readonly management_resource="https://default.logto.app/api"
readonly probe_username="sigprobe"
readonly probe_password="Aldehyde-probe-only-7f3c"
readonly redirect_uri="${endpoint}/aldehyde-probe-callback"

info() { printf '\033[1;36m==\033[0m %s\n' "$*"; }
pass() { printf '  \033[1;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '  \033[1;31mFAIL\033[0m %s\n' "$*" >&2; exit 1; }

cleanup() {
  docker rm -f "${core}" "${database}" >/dev/null 2>&1 || true
  docker network rm "${network}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

cd "${repo_root}"
cleanup

info "Start isolated Postgres and seed the schema from ${image}"
docker network create "${network}" >/dev/null
docker run -d --name "${database}" --network "${network}" \
  -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=logto \
  postgres:17-alpine >/dev/null
for _ in $(seq 1 120); do
  docker exec "${database}" pg_isready -U postgres -d logto >/dev/null 2>&1 && break
  sleep 1
done
docker exec "${database}" pg_isready -U postgres -d logto >/dev/null 2>&1 \
  || { docker logs "${database}" >&2 || true; fail 'Postgres did not become ready'; }
docker run --rm --network "${network}" --user 10001:10001 \
  --tmpfs /etc/logto/packages/cli/alteration-scripts:uid=10001,gid=10001 \
  -e "DB_URL=${database_url}" \
  --entrypoint npm "${image}" run cli db seed -- --swe >/dev/null 2>&1 \
  || fail "schema seed failed"

# An unpatched upstream image has no boot-seed, so the operator credential is
# inserted with the same rows the boot-seed writes. The patched image re-asserts
# the same values on boot (create-if-absent / replace-on-mismatch).
info 'Provision the Management API credential'
docker exec -i "${database}" psql -U postgres -d logto -v ON_ERROR_STOP=1 >/dev/null <<SQL
insert into applications
  (tenant_id, id, name, secret, description, type,
   oidc_client_metadata, custom_client_metadata, custom_data, is_third_party)
values ('default', '${client_id}', 'signature-probe', '${client_secret}', 'probe',
        'MachineToMachine', '{"redirectUris":[],"postLogoutRedirectUris":[]}'::jsonb,
        '{}'::jsonb, '{}'::jsonb, false);
insert into application_secrets (tenant_id, application_id, name, value)
values ('default', '${client_id}', 'probe', '${client_secret}');
insert into applications_roles (tenant_id, id, application_id, role_id)
select 'default', 'sigproberole', '${client_id}', id from roles
where tenant_id = 'default' and name = 'Logto Management API access';
SQL
[[ "$(docker exec "${database}" psql -U postgres -d logto -Atc \
  "select count(*) from applications_roles where application_id = '${client_id}'")" == 1 ]] \
  || fail 'the Management API role was not granted to the probe credential'

info "Boot ${image} as UID/GID 10001 on ${endpoint}"
docker run -d --name "${core}" --network "${network}" \
  --user 10001:10001 \
  --tmpfs /etc/logto/packages/cli/alteration-scripts:uid=10001,gid=10001 \
  -p "127.0.0.1:${port}:3001" \
  -e NODE_ENV=production \
  -e "DB_URL=${database_url}" \
  -e "ENDPOINT=${endpoint}" \
  "${image}" >/dev/null
ready=false
for _ in $(seq 1 90); do
  if curl -fsS "${endpoint}/oidc/.well-known/openid-configuration" >/dev/null 2>&1; then
    ready=true
    break
  fi
  sleep 2
done
[[ "${ready}" == true ]] || { docker logs "${core}" >&2 || true; fail 'Logto core did not become ready'; }
pass 'core is up'

token="$(curl -fsS -X POST "${endpoint}/oidc/token" \
  -u "${client_id}:${client_secret}" \
  --data-urlencode grant_type=client_credentials \
  --data-urlencode "resource=${management_resource}" \
  --data-urlencode scope=all \
  | jq -er '.access_token | select(type == "string" and length > 0)')"
api() { curl -fsS -H "Authorization: Bearer ${token}" -H 'Content-Type: application/json' "$@"; }

info 'Create the probe app, the probe user, and enable the account center'
spa_id="$(api -X POST "${endpoint}/api/applications" -d "$(jq -n --arg uri "${redirect_uri}" \
  '{name: "signature-probe-spa", type: "SPA", oidcClientMetadata: {redirectUris: [$uri], postLogoutRedirectUris: []}}')" \
  | jq -er '.id')"
api -X POST "${endpoint}/api/users" -d "$(jq -n --arg u "${probe_username}" --arg p "${probe_password}" \
  '{username: $u, password: $p}')" >/dev/null
api -X PATCH "${endpoint}/api/account-center" \
  -d '{"enabled":true,"fields":{"name":"Edit","username":"Edit","password":"Edit"}}' >/dev/null
sie="$(api "${endpoint}/api/sign-in-exp")"
jq -e '.hideLogtoBranding == false' <<<"${sie}" >/dev/null \
  || fail 'hideLogtoBranding is not false; the probe must not rely on the setting'
jq -e 'any(.signIn.methods[]; .identifier == "username" and .password == true)' <<<"${sie}" >/dev/null \
  || fail 'username + password sign-in is not enabled in the seeded sign-in experience'
pass "probe app ${spa_id}, user ${probe_username}, account center on, hideLogtoBranding=false"

info 'Drive the sign-in and account pages in headless Chrome'
set +e
report="$(PROBE_ENDPOINT="${endpoint}" PROBE_CLIENT_ID="${spa_id}" \
  PROBE_REDIRECT_URI="${redirect_uri}" PROBE_USERNAME="${probe_username}" \
  PROBE_PASSWORD="${probe_password}" node fork/harness/no-signature.mjs)"
status=$?
set -e
printf '%s\n' "${report}"

case "${status}" in
  0) found=none ;;
  3) found=some ;;
  *) fail "the browser probe could not render both pages (exit ${status}); it proves nothing" ;;
esac

if [[ "${mode}" == "--expect-signature" ]]; then
  jq -e '.signIn.signature == true and .account.signature == true' <<<"${report}" >/dev/null \
    || fail 'planted failure: the unpatched build did not show the signature on BOTH pages'
  pass 'planted failure: the probe sees the signature on the sign-in AND account pages of an unpatched build'
  exit 0
fi

[[ "${found}" == none ]] || fail 'the built image still shows "Powered by Logto" (see the report above)'
pass 'sign-in page: no Powered by Logto text, no .logto_signature element'
pass 'account page: no Powered by Logto text, no .logto_signature element'
info 'NO-SIGNATURE CHECK PASSED'
