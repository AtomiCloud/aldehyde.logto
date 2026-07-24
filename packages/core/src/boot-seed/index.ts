/**
 * @fileoverview
 * aldehyde.logto boot-seed patch — the ONE functional divergence this AtomiCloud
 * fork carries on top of upstream Logto OSS.
 *
 * The chicken-and-egg: a freshly-deployed Logto has no Management-API credential
 * for `logto-operator` to authenticate with, and OSS gives no way to install one
 * deterministically — the Management API always *server-generates* application
 * secrets on create and never accepts a caller-supplied value (spike finding,
 * goals/aldehyde-logto.md §2). So the only way to pin a KNOWN,
 * operator-minted credential is a DB-level direct insert.
 *
 * This module does exactly that, on every process boot (hooked from
 * `packages/core/src/index.ts`, so it survives redeploys/restarts by
 * construction — no init container, no one-shot Job):
 *
 *   - upsert the `logto-operator` M2M application whose client_id / client_secret
 *     are the operator-minted boot credential read from `SEED_M2M_CLIENT_ID` /
 *     `SEED_M2M_CLIENT_SECRET`;
 *   - ensure the pre-seeded Management API resource `https://default.logto.app/api`
 *     + its `all` scope + the `Logto Management API access` M2M role exist
 *     (create-if-absent — defensive for DR restores against a partial DB);
 *   - grant that role to the operator application.
 *
 * Semantics: **create-if-absent, replace-on-mismatch, idempotent**. Repeated
 * boots produce no duplicate rows and leave `client_id` stable; rotating the
 * boot secret (new value in the mode's source of record → roll the pods) makes
 * the next boot's upsert replace the stored secret to match.
 *
 * Load-bearing twice over (goals/aldehyde-logto.md §2):
 *   - Bootstrap: installs the operator credential into a brand-new instance
 *     before Management-API authentication exists.
 *   - DR / self-heal: after a restore-from-backup (fresh or stale-credential DB)
 *     the next boot re-seeds the operator credential from the still-live source.
 *
 * This is deliberately a single self-contained module plus a three-line hook in
 * `index.ts`, so the monthly upstream rebase (goals/aldehyde-logto.md "Cadence")
 * is a trivial reapply. It reuses upstream deterministic-id / direct-insert
 * patterns (the CLI `db seed` machinery and `mapi-proxy`) rather than inventing
 * one, and touches ONLY the `logto-operator` M2M application / role rows — never
 * the jwt-customizer storage, user `custom_data`, or the token-issuance pipeline
 * (§5), and never any one-time-token / magic-link surface (§6).
 */

import { createPoolWithRetry } from '@logto/cli/lib/pool-retry.js';
import {
  PredefinedScope,
  defaultTenantId,
  getManagementApiResourceIndicator,
} from '@logto/schemas';
import { ConsoleLog, generateStandardId } from '@logto/shared';
import {
  createInterceptorsPreset,
  createPool,
  parseDsn,
  sql,
  type CommonQueryMethods,
} from '@silverhand/slonik';
import chalk from 'chalk';

const consoleLog = new ConsoleLog(chalk.green('boot-seed'));

// Environment keys carrying the operator-minted boot credential.
const clientIdKey = 'SEED_M2M_CLIENT_ID';
const clientSecretKey = 'SEED_M2M_CLIENT_SECRET';

// Stable logical identity of the operator's own M2M application. The NAME is the
// identity; the client_id is the application row `id` (varchar(21)).
const operatorAppName = 'logto-operator';
// The pre-configured Management API M2M role name. MUST match what
// logto-operator's adapter expects (goals/logto-operator.md §0, §2.4).
const managementApiRoleName = 'Logto Management API access';
const managementApiResourceName = 'Logto Management API';
// Named application secret used as the create-once / retrievable boot secret.
const bootSecretName = 'bootstrap';

// Column widths: `applications.id` is varchar(21), the secret columns varchar(64).
const maxClientIdLength = 21;
const maxClientSecretLength = 64;

/**
 * Whether the boot-seed is engaged for this process. It engages when the boot
 * credential is *configured* — i.e. either env key is present, even if blank.
 * When neither key is present at all, the seed is a no-op so that plain upstream
 * usage and unit tests boot unchanged. The AtomiCloud chart always sets both
 * keys, so a missing/blank secret in a real deployment engages the seed and then
 * fails closed below — the design's "empty ⇒ CrashLoop, never a silent skip"
 * (goals/aldehyde-logto.md §3).
 */
export const isBootSeedEngaged = (): boolean =>
  clientIdKey in process.env || clientSecretKey in process.env;

export type BootCredential = {
  clientId: string;
  clientSecret: string;
};

/** Read + validate the boot credential. Throws (fail-closed) on any misconfig. */
export const readBootCredential = (): BootCredential => {
  const clientId = (process.env[clientIdKey] ?? '').trim();
  const clientSecret = (process.env[clientSecretKey] ?? '').trim();

  if (!clientId || !clientSecret) {
    const blankKeys = [!clientId && clientIdKey, !clientSecret && clientSecretKey]
      .filter(Boolean)
      .join(' and ');
    throw new Error(
      `[boot-seed] ${clientIdKey} and ${clientSecretKey} must both be non-blank when the boot credential is configured; blank: ${blankKeys} (empty ⇒ fail-closed by design).`
    );
  }

  if (clientId.length > maxClientIdLength) {
    throw new Error(
      `[boot-seed] ${clientIdKey} must be at most ${maxClientIdLength} characters (Logto application id width).`
    );
  }

  if (clientSecret.length > maxClientSecretLength) {
    throw new Error(
      `[boot-seed] ${clientSecretKey} must be at most ${maxClientSecretLength} characters.`
    );
  }

  return { clientId, clientSecret };
};

/**
 * Idempotently seed (create-if-absent, replace-on-mismatch) the operator M2M
 * application and its Management API role grant, inside a single transaction.
 *
 * Exported so the in-repo integration harness can drive it directly against a
 * real Postgres pool without booting the full server.
 */
export const seedOperatorM2m = async (
  pool: CommonQueryMethods,
  { clientId, clientSecret }: BootCredential
): Promise<void> => {
  const indicator = getManagementApiResourceIndicator(defaultTenantId);

  await pool.transaction(async (tx) => {
    // 1. Management API resource (create-if-absent; reuse upstream fixed id).
    //    ON CONFLICT on the (tenant_id, indicator) business key returns the
    //    existing row id when it is already present (normal, seeded by `db seed`).
    const { id: resourceId } = await tx.one<{ id: string }>(sql`
      insert into resources (tenant_id, id, name, indicator)
      values (${defaultTenantId}, 'management-api', ${managementApiResourceName}, ${indicator})
      on conflict (tenant_id, indicator) do update set name = resources.name
      returning id
    `);

    // 2. The `all` scope on that resource.
    const { id: scopeId } = await tx.one<{ id: string }>(sql`
      insert into scopes (tenant_id, id, resource_id, name, description)
      values (
        ${defaultTenantId}, ${generateStandardId()}, ${resourceId}, ${PredefinedScope.All},
        'Default scope for Management API, allows all permissions.'
      )
      on conflict (tenant_id, resource_id, name) do update set resource_id = scopes.resource_id
      returning id
    `);

    // 3. The pre-configured "Logto Management API access" M2M role.
    const { id: roleId } = await tx.one<{ id: string }>(sql`
      insert into roles (tenant_id, id, name, description, type)
      values (
        ${defaultTenantId}, ${generateStandardId()}, ${managementApiRoleName},
        'This default role grants access to the Logto management API.',
        ${'MachineToMachine'}::role_type
      )
      on conflict (tenant_id, name) do update set name = roles.name
      returning id
    `);

    // 4. Grant the role the `all` scope.
    await tx.query(sql`
      insert into roles_scopes (tenant_id, id, role_id, scope_id)
      values (${defaultTenantId}, ${generateStandardId()}, ${roleId}, ${scopeId})
      on conflict (tenant_id, role_id, scope_id) do nothing
    `);

    // 5. Drop any stale operator app carrying our name but a different client_id
    //    (client_id rotation): cascades to its secrets + role grants.
    await tx.query(sql`
      delete from applications
      where tenant_id = ${defaultTenantId} and name = ${operatorAppName} and id != ${clientId}
    `);

    // 6. Upsert the operator M2M application, pinned to the env client_id.
    await tx.query(sql`
      insert into applications
        (tenant_id, id, name, secret, description, type,
         oidc_client_metadata, custom_client_metadata, custom_data, is_third_party)
      values (
        ${defaultTenantId}, ${clientId}, ${operatorAppName}, ${clientSecret},
        'Boot-seeded M2M application for logto-operator (AtomiCloud aldehyde fork).',
        ${'MachineToMachine'}::application_type,
        ${sql.jsonb({ redirectUris: [], postLogoutRedirectUris: [] })},
        ${sql.jsonb({})}, ${sql.jsonb({})}, false
      )
      on conflict (id) do update set
        secret = excluded.secret,
        name = excluded.name,
        type = excluded.type,
        description = excluded.description
    `);

    // 7. Upsert ONLY the pinned `bootstrap` named secret (create-if-absent,
    //    replace-on-mismatch). We deliberately do NOT prune other named secrets:
    //    the fork's one job is to pin the boot credential, and OSS exposes a
    //    Management API secret CRUD surface, so operators may legitimately add
    //    further named secrets on this application. Clobbering them every boot
    //    would exceed the fork's scope and race every replica's startup.
    await tx.query(sql`
      insert into application_secrets (tenant_id, application_id, name, value)
      values (${defaultTenantId}, ${clientId}, ${bootSecretName}, ${clientSecret})
      on conflict (tenant_id, application_id, name) do update set value = excluded.value
    `);

    // 8. Grant the operator application the Management API role.
    await tx.query(sql`
      insert into applications_roles (tenant_id, id, application_id, role_id)
      values (${defaultTenantId}, ${generateStandardId()}, ${clientId}, ${roleId})
      on conflict (tenant_id, application_id, role_id) do nothing
    `);
  });
};

/**
 * Boot entrypoint. No-op when the boot credential is not configured; otherwise
 * fails closed on misconfig, opens a short-lived pool, and runs the idempotent
 * seed with the same connection-retry policy the server itself uses.
 */
export const runBootSeed = async (): Promise<void> => {
  if (!isBootSeedEngaged()) {
    return;
  }

  const credential = readBootCredential();

  const databaseUrl = process.env.DB_URL;
  if (!databaseUrl || !parseDsn(databaseUrl).databaseName) {
    throw new Error('[boot-seed] DB_URL with a database name is required to boot-seed.');
  }

  // Same connection-retry policy the server itself uses (env-set/create-pool via the CLI);
  // createPoolWithRetry already runs a readiness probe on the returned pool.
  const pool = await createPoolWithRetry(async () =>
    createPool(databaseUrl, { interceptors: createInterceptorsPreset() })
  );

  try {
    await seedOperatorM2m(pool, credential);
    consoleLog.info(
      `Ensured ${operatorAppName} M2M + Management API role grant (client_id preserved).`
    );
  } finally {
    await pool.end();
  }
};
