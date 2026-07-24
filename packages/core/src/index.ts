import dotenv from 'dotenv';
import { findUp } from 'find-up';

dotenv.config({ path: await findUp('.env', {}) });

// Fork patch (aldehyde.logto): boot-seed the logto-operator M2M credential
// (create-if-absent, replace-on-mismatch) before the server starts, so a
// fresh or restored instance always has the operator's Management API access.
// No-op unless SEED_M2M_CLIENT_ID/SEED_M2M_CLIENT_SECRET are configured.
const { runBootSeed } = await import('./boot-seed/index.js');
await runBootSeed();

await import('./main.js');
