// @ts-nocheck
/**
 * Thin invoker for the aldehyde.logto boot-seed integration harness.
 *
 * It imports the REAL compiled fork code (`runBootSeed` from the tsup build of
 * packages/core) and runs it exactly as `packages/core/src/index.ts` does on
 * process boot — reading SEED_M2M_CLIENT_ID / SEED_M2M_CLIENT_SECRET / DB_URL
 * from the environment and opening its own pool. The surrounding shell driver
 * (`run.sh`) sets the environment, mutates DB state with psql, and asserts the
 * results; this script is only the "run the fork code once" step.
 *
 * Exit code 0 = runBootSeed resolved; non-zero = it threw (fail-closed path).
 * The chunk filename is content-hashed by tsup, so we glob for it rather than
 * hard-coding the hash.
 */
import { readdirSync } from 'node:fs';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = join(here, '..', '..');
const buildDir = join(repoRoot, 'packages', 'core', 'build');

const chunk = readdirSync(buildDir).find(
  (name) => name.startsWith('boot-seed-') && name.endsWith('.js')
);

if (!chunk) {
  console.error(
    `[harness] no boot-seed-*.js chunk in ${buildDir}; run \`pnpm --filter "@logto/core..." build\` first.`
  );
  process.exit(3);
}

const { runBootSeed } = await import(pathToFileURL(join(buildDir, chunk)).href);

try {
  await runBootSeed();
  console.log('[harness] runBootSeed resolved');
  process.exit(0);
} catch (error) {
  console.error('[harness] runBootSeed threw:', error?.message ?? error);
  process.exit(1);
}
