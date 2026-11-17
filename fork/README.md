# aldehyde.logto — AtomiCloud fork of Logto OSS

> Independent fork; not affiliated with or endorsed by Silverhand Inc. / Logto.

This repository is a **pinned, CI-tested fork** of upstream
[logto-io/logto](https://github.com/logto-io/logto) carrying exactly **two
functional patches** on top of a tracked upstream tag. Everything else in the tree
is upstream, unmodified, so the monthly rebase stays cheap.

## Functional patch 2: no "Powered by Logto" line on the sign-in and account pages

- Code: [`packages/experience/src/shared/components/LogtoSignature/index.tsx`](../packages/experience/src/shared/components/LogtoSignature/index.tsx)
  — the component's default export renders nothing; the upstream component stays
  in the file as a named export (`UpstreamLogtoSignature`), so a rebase conflict is
  one line at most. The sign-in app (`experience/src/Layout/AppLayout`) and the
  account center (`account/src/App.tsx`, `account/src/components/PageFooter`) both
  import this one component.
- Commit: a single `feat(experience): never draw the Powered by Logto line`, which
  also updates the upstream account-center branding unit test to expect no signature.
- **Page-only by design.** It touches no licence, subscription or entitlement code.
  The `hideLogtoBranding` sign-in-experience setting keeps its upstream behaviour
  (on OSS it stays `false`); the page simply never draws the line.
- Proof on every build: `fork/harness/no-signature.sh` boots the built image,
  signs a real user in through headless Chrome, and asserts that the sign-in page
  and the account page carry no "Powered by" text, no `.logto_signature` element,
  no `[data-logto-signature]` element and no signature guard style. The
  `no-signature-planted` job builds the same tree with only this patch reverted
  and requires the probe to see the signature on **both** pages, so the check can
  never pass vacuously.

## Functional patch 1: boot-seed of the operator credential

**Startup boot-seed of the `logto-operator` Management API credential.**

- Code: [`packages/core/src/boot-seed/index.ts`](../packages/core/src/boot-seed/index.ts)
  plus a three-line hook in [`packages/core/src/index.ts`](../packages/core/src/index.ts).
- Commit: a single `feat(core): boot-seed logto-operator M2M credential on startup`.

### Why it exists

Logto's Management API always **server-generates** application secrets and never
accepts a caller-supplied value. A freshly-deployed (or DR-restored) instance
therefore has no way to be handed a *known* operator credential through the API —
a bootstrap chicken-and-egg. The patch resolves it at the only layer that can:
a direct, idempotent DB seed that runs on **every process boot** from
`packages/core/src/index.ts`.

### What it does (create-if-absent, replace-on-mismatch, idempotent)

Engaged only when `SEED_M2M_CLIENT_ID` / `SEED_M2M_CLIENT_SECRET` are configured;
**fails closed** (crashes) if configured but blank — never a silent skip. On each
boot, inside one transaction, it ensures:

1. the `https://default.logto.app/api` Management API resource, its `all` scope,
   and the `Logto Management API access` M2M role (defensive create-if-absent);
2. the `logto-operator` M2M application pinned to the env client id/secret, with
   a retrievable `bootstrap` named secret;
3. the role granted to that application.

Repeated boots are no-ops; rotating the secret replaces the stored value while
preserving the client id; rotating the client id removes the stale app. It
touches only the operator M2M application / role rows — never the
jwt-customizer, magic-link, or token-issuance surfaces.

## Upstream pin

Recorded in [`fork/UPSTREAM_REF`](UPSTREAM_REF):

| field | value |
| --- | --- |
| upstream | `https://github.com/logto-io/logto.git` |
| ref | `refs/tags/v1.46.0` |
| commit | `d179bf9d2d51104236a342b90c2841df66e4ba5b` |

## Deployment requirement (UID/GID 10001 + writable alteration-scripts)

The chart runs the image as UID/GID **10001**. On **every boot** upstream's
`checkAlterationState` precondition rewrites `<cli-root>/alteration-scripts`
(`fs.rm` + `fs.cp`, resolving to `/etc/logto/packages/cli/alteration-scripts` in
the image) — upstream's own comment notes the directory is meant to be writable /
separately mounted. The baked copy is root-owned, so a pod running as 10001
crash-loops on startup with `EACCES: permission denied, unlink .../alteration-scripts/...`
**unless** that path is mounted as a writable volume owned by 10001 (e.g. an
`emptyDir`). This is upstream behavior, independent of the boot-seed patch; the
product-image SIT models it with a writable tmpfs at that path for both the schema
seed and the long-lived server. The consuming chart MUST provide the equivalent
writable mount.

## Monthly rebase

The fork is rebased onto the newest upstream stable tag once a month using
[`fork/rebase.sh`](rebase.sh):

```bash
fork/rebase.sh --dry-run v1.42.0   # fetch + preview the replay, no changes
fork/rebase.sh v1.42.0             # rebase --onto, re-pin, rebuild, re-test
```

The script cherry-picks the fork commits (first-parent only) onto `<new>`,
rewrites `fork/UPSTREAM_REF`, then rebuilds and re-runs the integration harness —
so a rebase is never done until the patch still passes. Conflicts, if any, are
confined to the files the two functional patches touch (boot-seed + its hook,
and the `LogtoSignature` component + its account-center unit test).

The replay rewrites history, so the script ends with a `merge -s ours` of the
replaced fork head: the tree stays exactly the replayed one, and `aldehyde` only
ever **fast-forwards**. **Never force-push `aldehyde`**: push the result as a new
branch (for example `rebase/v1.46.0`), open a PR into `aldehyde`, and let CI plus
review pass there. Because of that merge, the next replay takes first-parent
commits only, so the replaced commits are never replayed twice.

## Test coverage & boundary

CI is [`.github/workflows/atomi-product.yml`](../.github/workflows/atomi-product.yml).

| gate | how | where it runs |
| --- | --- | --- |
| lint + typecheck of both patches | `eslint` + `build:test` / `tsc --noEmit` | `patch-quality` job |
| boot-seed idempotency | `fork/harness/run.sh` S3 | real Postgres |
| mismatch rotation (secret + client id) | harness S4, S5 | real Postgres |
| DR self-heal | harness S6 | real Postgres |
| Management API resource / scope / role + grant | harness S2 | real Postgres |
| non-destructive named-secret handling | harness S7 + authenticated API CRUD/reboot | real Postgres + built image |
| concurrent replica startup | harness S8 (six simultaneous boots) | real Postgres |
| fail-closed on blank config | harness S1 | real Postgres |
| Management API core endpoint (live) | schema-seed + boot exact image as UID/GID 10001, mint M2M token, call `/api/applications` | `product-image-sit` job |
| named-secret CRUD / retrievability | create, list, rename, reboot, re-read, and delete via authenticated Management API | `product-image-sit` job |
| jwt-customizer script engine | run the customizer in the image's local VM via `POST /api/configs/jwt-customizer/test`; assert claims projected from `context.user.customData` and `environmentVariables` | `product-image-sit` job |
| one-time-token / magic-link | issue via `POST /api/one-time-tokens` then redeem via `.../verify`; assert `active -> consumed` | `product-image-sit` job |
| no "Powered by Logto" on sign-in + account pages | headless Chrome on the built image, real sign-in, DOM + text assertions (`fork/harness/no-signature.sh`) | `product-image-sit` job |
| that check is not vacuous | same tree with only the page patch reverted must show the signature on both pages | `no-signature-planted` job |
| account-center branding unit test | upstream jest test, updated to expect no signature | `patch-quality` job |
| old-pin to current-pin monthly replay | disposable `v1.41.0 -> v1.46.0` rebase + harness | `rebase-exercise` job |
| multi-arch image (amd64 + arm64), deterministic `1.46.0` tag + digest | gated `docker/build-push-action` after every preceding job | `image` job |

`jwt-customizer` and `magic-link` remain unmodified upstream features. The fork
nevertheless gates both against every built product image because they are
load-bearing downstream contracts. Rather than stand up the full upstream
integration suite — which expects a three-endpoint dev topology (default tenant
on `:3001`, admin tenant on `:3002`, cloud on `:3003`) that a single production
image does not serve — the SIT drives both surfaces directly against the running
image through the default-tenant Management API, authenticated with the seeded
operator M2M credential:

- **jwt-customizer:** `POST /api/configs/jwt-customizer/test` runs the customizer
  script in the *same* local VM used for real non-cloud token issuance, so a
  regression in the script engine turns CI red. The test asserts claims projected
  from both `context.user.customData` and `environmentVariables`.
- **one-time-token / magic-link:** magic links are one-time-tokens underneath, so
  the SIT issues one via `POST /api/one-time-tokens` and redeems it via
  `POST /api/one-time-tokens/verify`, asserting the `active -> consumed`
  transition.

**Boundary, stated truthfully:** these canaries exercise the customizer VM and the
one-time-token lifecycle deterministically, but they do not replay a full browser
sign-in with a persisted customizer nor the end-to-end magic-link email round trip.
Those remain covered by the upstream integration suite on upstream's own topology;
reproducing that topology against a single production image is out of scope for the
one-job fork. Image publication depends on these regressions, the fork-specific
boot/API checks, and the disposable monthly-rebase exercise.

### Running the harness locally

```bash
pnpm --filter "@logto/cli..." --filter "@logto/core..." build
fork/harness/run.sh        # requires docker
fork/harness/image-sit.sh aldehyde-product-sit:local
fork/harness/no-signature.sh aldehyde-product-sit:local
fork/harness/no-signature.sh <unpatched-image> --expect-signature
fork/rebase-exercise.sh refs/tags/v1.41.0 refs/tags/v1.46.0
```
