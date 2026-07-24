#!/usr/bin/env bash
# Product-image SIT for the aldehyde.logto fork.
#
# This script deliberately drives the built image, not a source checkout:
#   - schema seed and core both run as the chart's UID/GID 10001;
#   - the boot credential authenticates to the live Management API;
#   - named-secret CRUD remains retrievable and survives a reboot;
#   - repeat boot, credential rotation, and deletion/DR self-heal converge;
#   - the jwt-customizer and magic-link regressions run against that same image.
set -euo pipefail

readonly image="${1:?usage: fork/harness/image-sit.sh <image-ref>}"
readonly repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly suffix="aldehyde-image-sit-${RANDOM}-$$"
readonly network="${suffix}"
readonly database="${suffix}-database"
readonly core="${suffix}-core"
readonly database_url="postgres://postgres:postgres@${database}:5432/logto"
readonly client_id="aldehyde-sit"
readonly initial_secret="aldehyde-sit-secret-v1"
readonly rotated_secret="aldehyde-sit-secret-v2"
readonly management_resource="https://default.logto.app/api"

core_port=''

info() { printf '\033[1;36m==\033[0m %s\n' "$*"; }
pass() { printf '  \033[1;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '  \033[1;31mFAIL\033[0m %s\n' "$*" >&2; exit 1; }

cleanup() {
  docker rm -f "${core}" "${database}" >/dev/null 2>&1 || true
  docker network rm "${network}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

wait_for_database() {
  for _ in $(seq 1 60); do
    if docker exec "${database}" pg_isready -U postgres -d logto >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done

  fail 'Postgres did not become ready'
}

seed_schema() {
  info 'Seed fresh schema from the exact image as UID/GID 10001'
  docker run --rm --network "${network}" --user 10001:10001 \
    --tmpfs /etc/logto/packages/cli/alteration-scripts:uid=10001,gid=10001 \
    -e "DB_URL=${database_url}" \
    --entrypoint npm "${image}" run cli db seed -- --swe --dapc
  pass 'schema seed ran as the chart identity'
}

expect_blank_failure() {
  local expected_key="$1"
  local client_id_value="$2"
  local client_secret_value="$3"
  local output

  if output=$(timeout 45 docker run --rm --network "${network}" --user 10001:10001 \
    -e "DB_URL=${database_url}" \
    -e "ENDPOINT=http://localhost:3001" \
    -e "SEED_M2M_CLIENT_ID=${client_id_value}" \
    -e "SEED_M2M_CLIENT_SECRET=${client_secret_value}" \
    "${image}" 2>&1); then
    fail "blank ${expected_key} unexpectedly allowed core to start"
  fi

  grep -F "blank: ${expected_key}" <<<"${output}" >/dev/null \
    || fail "blank ${expected_key} did not produce the exact fail-closed diagnostic"
  pass "blank ${expected_key} fails closed"
}

start_core() {
  local secret="$1"

  docker rm -f "${core}" >/dev/null 2>&1 || true

  # Upstream rewrites `<cli-root>/alteration-scripts` on EVERY boot
  # (env-set/preconditions.ts checkAlterationState -> getAvailableAlterations ->
  # getAlterationFiles does fs.rm + fs.cp, and its own comment says the directory
  # "allows this to be a separately-mounted directory"). Under the chart's UID/GID
  # 10001 security contract the baked, root-owned copy is not writable, so the
  # server boot fails with EACCES on unlink. The production chart MUST therefore
  # mount that path as a writable volume for the runtime user; this tmpfs models
  # exactly that deployment requirement so the image can boot as UID/GID 10001.
  docker run -d --name "${core}" --network "${network}" \
    --user 10001:10001 \
    --tmpfs /etc/logto/packages/cli/alteration-scripts:uid=10001,gid=10001 \
    -p 127.0.0.1::3001 \
    -e NODE_ENV=production \
    -e "DB_URL=${database_url}" \
    -e ENDPOINT=http://localhost:3001 \
    -e LOGTO_ENDPOINT=http://localhost:3001 \
    -e "SEED_M2M_CLIENT_ID=${client_id}" \
    -e "SEED_M2M_CLIENT_SECRET=${secret}" \
    "${image}" >/dev/null

  core_port="$(docker port "${core}" 3001/tcp | awk -F: 'END { print $NF }')"
  [[ -n "${core_port}" ]] || fail 'Docker did not publish the core port'

  for _ in $(seq 1 90); do
    if curl -fsS "http://127.0.0.1:${core_port}/oidc/.well-known/openid-configuration" \
      >/dev/null 2>&1; then
      docker exec "${core}" sh -ec 'test "$(id -u)" = 10001 && test "$(id -g)" = 10001' \
        || fail 'core is not running as UID/GID 10001'
      return 0
    fi
    sleep 2
  done

  docker logs "${core}" >&2 || true
  fail 'Logto core did not become ready'
}

mint_token() {
  local secret="$1"

  curl -fsS -X POST "http://127.0.0.1:${core_port}/oidc/token" \
    -u "${client_id}:${secret}" \
    --data-urlencode grant_type=client_credentials \
    --data-urlencode "resource=${management_resource}" \
    --data-urlencode scope=all \
    | jq -er '.access_token | select(type == "string" and length > 0)'
}

api() {
  local token="$1"
  shift
  curl -fsS -H "Authorization: Bearer ${token}" "$@"
}

psql_scalar() {
  docker exec "${database}" psql -U postgres -d logto -Atc "$1"
}

cd "${repo_root}"

info 'Start isolated Postgres'
docker network create "${network}" >/dev/null
docker run -d --name "${database}" --network "${network}" \
  -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=logto \
  postgres:17-alpine >/dev/null
wait_for_database

seed_schema
seed_schema
expect_blank_failure SEED_M2M_CLIENT_ID '' "${initial_secret}"
expect_blank_failure SEED_M2M_CLIENT_SECRET "${client_id}" ''

info 'Boot the exact image and authenticate with the seeded credential'
start_core "${initial_secret}"
pass 'core runs as UID/GID 10001'
token="$(mint_token "${initial_secret}")"
api "${token}" "http://127.0.0.1:${core_port}/api/applications" >/dev/null
pass 'boot credential authenticates to the Management API'

info 'Exercise authenticated named-secret CRUD and retrievability'
created_secret="$(api "${token}" \
  -H 'Content-Type: application/json' \
  -d '{"name":"sit-generated"}' \
  "http://127.0.0.1:${core_port}/api/applications/${client_id}/secrets")"
secret_value="$(jq -er '.value | select(type == "string" and length > 0)' <<<"${created_secret}")"
api "${token}" "http://127.0.0.1:${core_port}/api/applications/${client_id}/secrets" \
  | jq -e --arg value "${secret_value}" \
    'any(.[]; .name == "sit-generated" and .value == $value)' >/dev/null
api "${token}" -X PATCH -H 'Content-Type: application/json' \
  -d '{"name":"sit-renamed"}' \
  "http://127.0.0.1:${core_port}/api/applications/${client_id}/secrets/sit-generated" \
  | jq -e --arg value "${secret_value}" '.name == "sit-renamed" and .value == $value' >/dev/null
pass 'create, retrieve, list, and update return the named secret value'

info 'Repeat boot and prove the operator-created named secret survives'
start_core "${initial_secret}"
token="$(mint_token "${initial_secret}")"
api "${token}" "http://127.0.0.1:${core_port}/api/applications/${client_id}/secrets" \
  | jq -e --arg value "${secret_value}" \
    'any(.[]; .name == "sit-renamed" and .value == $value)' >/dev/null
[[ "$(psql_scalar "select count(*) from applications where name='logto-operator'")" == 1 ]] \
  || fail 'repeat boot created a duplicate operator application'
[[ "$(psql_scalar "select count(*) from applications_roles where application_id='${client_id}'")" == 1 ]] \
  || fail 'repeat boot created a duplicate role grant'
pass 'repeat boot is idempotent and non-destructive'

info 'Rotate the boot secret and prove replace-on-mismatch'
start_core "${rotated_secret}"
if mint_token "${initial_secret}" >/dev/null 2>&1; then
  fail 'the stale boot secret still authenticated after rotation'
fi
token="$(mint_token "${rotated_secret}")"
api "${token}" "http://127.0.0.1:${core_port}/api/applications" >/dev/null
[[ "$(psql_scalar "select value from application_secrets where application_id='${client_id}' and name='bootstrap'")" == "${rotated_secret}" ]] \
  || fail 'bootstrap named secret did not rotate to the projected value'
pass 'rotation replaces the credential and preserves Management API access'

info 'Delete the operator application and prove next-boot DR self-heal'
docker rm -f "${core}" >/dev/null
docker exec "${database}" psql -U postgres -d logto -v ON_ERROR_STOP=1 -c \
  "delete from applications where id='${client_id}';" >/dev/null
[[ "$(psql_scalar "select count(*) from applications where id='${client_id}'")" == 0 ]] \
  || fail 'DR precondition did not remove the operator application'
start_core "${rotated_secret}"
token="$(mint_token "${rotated_secret}")"
api "${token}" "http://127.0.0.1:${core_port}/api/applications" >/dev/null
pass 'next image boot restores a working operator credential'

# jwt-customizer and one-time-token/magic-link non-regression, driven against the
# exact production image via the default-tenant Management API with the operator
# M2M token minted above. This deliberately avoids the upstream integration suite,
# which requires a three-endpoint dev topology (default :3001, admin :3002, cloud
# :3003) that a single production image does not serve; see the boundary note in
# fork/README.md. The `/configs/jwt-customizer/test` endpoint runs the customizer
# in the SAME local VM used for real non-cloud token issuance, so a regression in
# the script engine turns this red. Magic links are one-time-tokens under the hood,
# so the issue -> redeem lifecycle exercises that surface directly.
info 'jwt-customizer non-regression: execute the script engine via the Management API'
jwt_claims="$(api "${token}" -X POST \
  -H 'Content-Type: application/json' \
  --data-binary @- \
  "http://127.0.0.1:${core_port}/api/configs/jwt-customizer/test" <<'JSON'
{
  "tokenType": "access-token",
  "script": "const getCustomJwtClaims = async ({ token, context, environmentVariables }) => ({ home_landscape: context?.user?.customData?.home_landscape ?? 'missing', tenant: environmentVariables?.TENANT });",
  "environmentVariables": { "TENANT": "default" },
  "token": { "jti": "aldehyde-probe", "clientId": "aldehyde-sit", "scope": "all" },
  "context": { "user": { "id": "probeuser01", "customData": { "home_landscape": "aurora-canyon" } } }
}
JSON
)"
jq -e '.home_landscape == "aurora-canyon" and .tenant == "default"' <<<"${jwt_claims}" >/dev/null \
  || fail "jwt-customizer did not emit the projected claims: ${jwt_claims}"
pass 'jwt-customizer local-VM script emits claims from context and environment'

info 'one-time-token / magic-link non-regression: issue and redeem via the Management API'
ott_email='aldehyde-probe@aldehyde.test'
ott_created="$(api "${token}" -X POST \
  -H 'Content-Type: application/json' \
  -d "{\"email\":\"${ott_email}\"}" \
  "http://127.0.0.1:${core_port}/api/one-time-tokens")"
ott_token="$(jq -er '.token | select(type == "string" and length > 0)' <<<"${ott_created}")"
jq -e '.status == "active"' <<<"${ott_created}" >/dev/null \
  || fail "issued one-time token was not active: ${ott_created}"
ott_verified="$(api "${token}" -X POST \
  -H 'Content-Type: application/json' \
  -d "{\"token\":\"${ott_token}\",\"email\":\"${ott_email}\"}" \
  "http://127.0.0.1:${core_port}/api/one-time-tokens/verify")"
jq -e '.status == "consumed"' <<<"${ott_verified}" >/dev/null \
  || fail "one-time token did not transition to consumed: ${ott_verified}"
pass 'one-time-token issuance and redemption transition active -> consumed'

info 'Clean up the operator-created named secret'
api "${token}" -X DELETE \
  "http://127.0.0.1:${core_port}/api/applications/${client_id}/secrets/sit-renamed" \
  >/dev/null 2>&1 || true

info 'ALL PRODUCT-IMAGE SCENARIOS PASSED'
