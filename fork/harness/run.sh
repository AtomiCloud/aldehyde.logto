#!/usr/bin/env bash
# aldehyde.logto boot-seed integration harness.
#
# Spins up an ephemeral Postgres, seeds the real Logto schema with the upstream
# CLI, then drives the fork's `runBootSeed` through every patch-specific gate the
# goal requires, asserting the resulting DB state with psql:
#
#   S0  no-op when SEED_M2M_* are absent
#   S1  fail-closed when configured but blank (CrashLoop, never silent skip)
#   S2  create: operator M2M app + Management API resource/scope/role + grants
#   S3  idempotency: a second boot changes nothing and preserves client_id
#   S4  mismatch rotation (secret): stored secret replaced, client_id preserved
#   S5  client_id rotation: stale operator app removed, new one pinned
#   S6  DR self-heal: deleted operator app + grant reappear on next boot
#   S7  non-destructive: an operator-added named secret survives a reboot
#       (the fork pins ONLY the bootstrap secret; it must not clobber others)
#   S8  concurrency-safe: N simultaneous boots converge to a single operator
#       app / bootstrap secret / role grant with no duplicate rows or errors
#
# Every assertion runs against a real database. Requires docker + a built core
# (`pnpm --filter "@logto/core..." build`). Exits non-zero on the first failure.
set -euo pipefail

readonly script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly repo_root="$(cd "${script_dir}/../.." && pwd)"

readonly pg_image="postgres:17-alpine"
readonly container="aldehyde-logto-bootseed-$$"
readonly pg_password="postgres"
readonly db_name="logto"

readonly operator_app_name="logto-operator"
readonly boot_secret_name="bootstrap"
readonly resource_indicator="https://default.logto.app/api"
readonly role_name="Logto Management API access"
readonly tenant="default"

host_port=""
db_url=""

log()  { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }
pass() { printf '  \033[1;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '  \033[1;31mFAIL\033[0m %s\n' "$*" >&2; exit 1; }

cleanup() {
  docker rm -f "${container}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# --- psql helpers (run inside the container so no host psql is required) ------
psql_q() {
  # Scalar query -> trimmed value on stdout.
  docker exec -e PGPASSWORD="${pg_password}" "${container}" \
    psql -U postgres -d "${db_name}" -tAc "$1"
}

expect_eq() {
  local actual="$1" want="$2" what="$3"
  if [[ "${actual}" == "${want}" ]]; then
    pass "${what} (=${want})"
  else
    fail "${what}: expected '${want}', got '${actual}'"
  fi
}

# Run the fork's runBootSeed once with the given SEED_M2M_* environment.
# Usage: invoke_boot_seed <expected_exit> <client_id|__unset__> <secret|__unset__>
invoke_boot_seed() {
  local expect_exit="$1" cid="$2" secret="$3"
  local -a env_prefix=("DB_URL=${db_url}")
  [[ "${cid}"    != "__unset__" ]] && env_prefix+=("SEED_M2M_CLIENT_ID=${cid}")
  [[ "${secret}" != "__unset__" ]] && env_prefix+=("SEED_M2M_CLIENT_SECRET=${secret}")

  set +e
  env "${env_prefix[@]}" node "${script_dir}/invoke-boot-seed.mjs"
  local code=$?
  set -e

  if [[ "${code}" -ne "${expect_exit}" ]]; then
    fail "runBootSeed exit ${code}, expected ${expect_exit} (cid='${cid}' secret='${secret}')"
  fi
}

# ------------------------------------------------------------------------------
main() {
  command -v docker >/dev/null || fail "docker is required"
  [[ -d "${repo_root}/packages/core/build" ]] || \
    fail "core build missing; run: pnpm --filter \"@logto/core...\" build"

  log "Pull Postgres image (${pg_image})"
  docker pull "${pg_image}" >/dev/null

  log "Start ephemeral Postgres (${pg_image})"
  docker rm -f "${container}" >/dev/null 2>&1 || true
  docker run -d --rm --name "${container}" \
    -e POSTGRES_PASSWORD="${pg_password}" \
    -P "${pg_image}" >/dev/null
  host_port="$(docker inspect --format '{{ (index (index .NetworkSettings.Ports "5432/tcp") 0).HostPort }}' "${container}")"
  db_url="postgresql://postgres:${pg_password}@127.0.0.1:${host_port}/${db_name}"

  log "Wait for Postgres readiness"
  for _ in $(seq 1 90); do
    if docker exec "${container}" pg_isready -U postgres >/dev/null 2>&1; then break; fi
    sleep 1
  done
  docker exec "${container}" pg_isready -U postgres >/dev/null 2>&1 || fail "Postgres never became ready"
  pass "Postgres ready on 127.0.0.1:${host_port}"

  log "Seed the real Logto schema with the upstream CLI (db seed)"
  # DB_URL drives the CLI non-interactively; --dapc skips the pwned-password
  # network call so the seed is hermetic. The CLI creates the `logto` database.
  ( cd "${repo_root}" && DB_URL="${db_url}" pnpm cli db seed --dapc )
  pass "schema + base data seeded"

  # Baseline: the upstream seed does NOT create a logto-operator application.
  log "S0  no-op when SEED_M2M_* absent"
  invoke_boot_seed 0 __unset__ __unset__
  expect_eq "$(psql_q "select count(*) from applications where tenant_id='${tenant}' and name='${operator_app_name}'")" \
    "0" "no operator app created when unconfigured"

  log "S1  fail-closed when configured but blank"
  # Present-but-empty value -> engaged -> must throw (CrashLoop by design).
  invoke_boot_seed 1 "" "some-secret"        # blank client id
  invoke_boot_seed 1 "aldehyde-operator-1" "" # blank secret
  expect_eq "$(psql_q "select count(*) from applications where tenant_id='${tenant}' and name='${operator_app_name}'")" \
    "0" "no operator app created on fail-closed"

  local cid_a="aldehyde-operator-1" secret_v1="boot-secret-v1"
  log "S2  create operator M2M + Management API resource/scope/role + grants"
  invoke_boot_seed 0 "${cid_a}" "${secret_v1}"
  expect_eq "$(psql_q "select id from applications where tenant_id='${tenant}' and name='${operator_app_name}'")" \
    "${cid_a}" "operator application pinned to client_id"
  expect_eq "$(psql_q "select type from applications where id='${cid_a}'")" \
    "MachineToMachine" "operator application type"
  expect_eq "$(psql_q "select value from application_secrets where application_id='${cid_a}' and name='${boot_secret_name}'")" \
    "${secret_v1}" "bootstrap named secret value (retrievable)"
  expect_eq "$(psql_q "select secret from applications where id='${cid_a}'")" \
    "${secret_v1}" "mirrored legacy applications.secret"
  expect_eq "$(psql_q "select count(*) from resources where tenant_id='${tenant}' and indicator='${resource_indicator}'")" \
    "1" "Management API resource present"
  # NOTE: OSS seeds a Management API resource with this indicator in BOTH the
  # `default` and `admin` tenants, so every indicator join is filtered to the
  # default tenant — the tenant the operator credential lives in.
  expect_eq "$(psql_q "select count(*) from scopes s join resources r on s.resource_id=r.id where r.tenant_id='${tenant}' and r.indicator='${resource_indicator}' and s.name='all'")" \
    "1" "Management API 'all' scope present"
  expect_eq "$(psql_q "select count(*) from roles where tenant_id='${tenant}' and name='${role_name}'")" \
    "1" "Management API role present"
  expect_eq "$(psql_q "select count(*) from roles_scopes rs join roles ro on rs.role_id=ro.id join scopes s on rs.scope_id=s.id join resources r on s.resource_id=r.id where rs.tenant_id='${tenant}' and ro.name='${role_name}' and r.indicator='${resource_indicator}' and s.name='all'")" \
    "1" "role granted the Management API 'all' scope"
  expect_eq "$(psql_q "select count(*) from applications_roles ar join roles ro on ar.role_id=ro.id where ar.tenant_id='${tenant}' and ar.application_id='${cid_a}' and ro.name='${role_name}'")" \
    "1" "operator application granted the Management API role"

  log "S3  idempotency (second identical boot changes nothing)"
  invoke_boot_seed 0 "${cid_a}" "${secret_v1}"
  expect_eq "$(psql_q "select count(*) from applications where tenant_id='${tenant}' and name='${operator_app_name}'")" \
    "1" "still exactly one operator app"
  expect_eq "$(psql_q "select id from applications where name='${operator_app_name}' and tenant_id='${tenant}'")" \
    "${cid_a}" "client_id preserved"
  expect_eq "$(psql_q "select count(*) from application_secrets where application_id='${cid_a}'")" \
    "1" "still exactly one secret"
  expect_eq "$(psql_q "select count(*) from applications_roles where application_id='${cid_a}'")" \
    "1" "still exactly one role grant"

  local secret_v2="boot-secret-v2-rotated"
  log "S4  mismatch rotation (secret replaced, client_id preserved)"
  invoke_boot_seed 0 "${cid_a}" "${secret_v2}"
  expect_eq "$(psql_q "select value from application_secrets where application_id='${cid_a}' and name='${boot_secret_name}'")" \
    "${secret_v2}" "bootstrap secret rotated"
  expect_eq "$(psql_q "select secret from applications where id='${cid_a}'")" \
    "${secret_v2}" "legacy secret column rotated"
  expect_eq "$(psql_q "select id from applications where name='${operator_app_name}' and tenant_id='${tenant}'")" \
    "${cid_a}" "client_id still preserved through secret rotation"

  local cid_b="aldehyde-operator-2"
  log "S5  client_id rotation (stale operator app removed, new one pinned)"
  invoke_boot_seed 0 "${cid_b}" "${secret_v2}"
  expect_eq "$(psql_q "select count(*) from applications where id='${cid_a}'")" \
    "0" "old client_id application removed"
  expect_eq "$(psql_q "select count(*) from applications where tenant_id='${tenant}' and name='${operator_app_name}'")" \
    "1" "exactly one operator app after id rotation"
  expect_eq "$(psql_q "select id from applications where name='${operator_app_name}' and tenant_id='${tenant}'")" \
    "${cid_b}" "new client_id pinned"

  log "S6  DR self-heal (deleted operator app + grant reappear)"
  docker exec -e PGPASSWORD="${pg_password}" "${container}" \
    psql -U postgres -d "${db_name}" -qc \
    "delete from applications where id='${cid_b}';" >/dev/null
  expect_eq "$(psql_q "select count(*) from applications where id='${cid_b}'")" \
    "0" "precondition: operator app deleted (simulated restore gap)"
  invoke_boot_seed 0 "${cid_b}" "${secret_v2}"
  expect_eq "$(psql_q "select id from applications where name='${operator_app_name}' and tenant_id='${tenant}'")" \
    "${cid_b}" "operator app self-healed"
  expect_eq "$(psql_q "select count(*) from applications_roles ar join roles ro on ar.role_id=ro.id where ar.application_id='${cid_b}' and ro.name='${role_name}'")" \
    "1" "role grant self-healed"
  expect_eq "$(psql_q "select value from application_secrets where application_id='${cid_b}' and name='${boot_secret_name}'")" \
    "${secret_v2}" "bootstrap secret self-healed"

  log "S7  non-destructive (an operator-added named secret survives a reboot)"
  # Simulate a secret an operator created through the Management API secret CRUD
  # surface. The fork pins ONLY the bootstrap secret and must leave others alone.
  docker exec -e PGPASSWORD="${pg_password}" "${container}" \
    psql -U postgres -d "${db_name}" -qc \
    "insert into application_secrets (tenant_id, application_id, name, value) values ('${tenant}', '${cid_b}', 'operator-added', 'must-survive');" >/dev/null
  expect_eq "$(psql_q "select count(*) from application_secrets where application_id='${cid_b}'")" \
    "2" "precondition: operator-added secret present alongside bootstrap"
  invoke_boot_seed 0 "${cid_b}" "${secret_v2}"
  expect_eq "$(psql_q "select count(*) from application_secrets where application_id='${cid_b}'")" \
    "2" "operator-added secret NOT clobbered by boot-seed"
  expect_eq "$(psql_q "select value from application_secrets where application_id='${cid_b}' and name='operator-added'")" \
    "must-survive" "operator-added secret value intact"
  expect_eq "$(psql_q "select value from application_secrets where application_id='${cid_b}' and name='${boot_secret_name}'")" \
    "${secret_v2}" "bootstrap secret still pinned"

  local cid_c="aldehyde-operator-3"
  log "S8  concurrency-safe repeated boot (every replica runs this startup path)"
  # Fire N boots in parallel against the SAME target credential. Each is a full
  # runBootSeed (own pool + transaction). All must exit 0 and the DB must
  # converge to exactly one operator app / bootstrap secret / role grant — no
  # duplicate rows, no deadlock/unique-violation aborts.
  local concurrency=6 pids=() rc=0
  for _ in $(seq 1 "${concurrency}"); do
    env "DB_URL=${db_url}" "SEED_M2M_CLIENT_ID=${cid_c}" "SEED_M2M_CLIENT_SECRET=${secret_v2}" \
      node "${script_dir}/invoke-boot-seed.mjs" >/dev/null 2>&1 &
    pids+=("$!")
  done
  for pid in "${pids[@]}"; do
    if ! wait "${pid}"; then rc=1; fi
  done
  [[ "${rc}" -eq 0 ]] && pass "all ${concurrency} concurrent boots exited 0" \
    || fail "at least one concurrent boot failed (deadlock / unique violation?)"
  expect_eq "$(psql_q "select count(*) from applications where tenant_id='${tenant}' and name='${operator_app_name}'")" \
    "1" "exactly one operator app after ${concurrency} concurrent boots"
  expect_eq "$(psql_q "select id from applications where tenant_id='${tenant}' and name='${operator_app_name}'")" \
    "${cid_c}" "operator app pinned to the concurrent target client_id"
  expect_eq "$(psql_q "select count(*) from application_secrets where application_id='${cid_c}'")" \
    "1" "exactly one (bootstrap) secret on the fresh operator app"
  expect_eq "$(psql_q "select count(*) from applications_roles ar join roles ro on ar.role_id=ro.id where ar.application_id='${cid_c}' and ro.name='${role_name}'")" \
    "1" "exactly one Management API role grant after concurrent boots"

  log "ALL SCENARIOS PASSED"
}

main "$@"
