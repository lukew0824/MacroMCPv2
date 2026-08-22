# Deployment notes

Practical, discovered-while-doing-it knowledge for getting MacroMCP hosted.
`docs/auth-setup.md` covers Auth0 specifically; this covers everything else.

## Database: Neon

Standalone Neon account (not provisioned through Vercel's one-click
integration) - kept deliberately decoupled from any one deployment
platform, since the database needs to be reachable from both the website
and, eventually, the Python resource server, wherever each ends up hosted.
Project `MacroMCP`, Postgres 18, AWS US East 2. Neon Auth was **not**
enabled - it would create its own competing users/sessions system
alongside the Auth0 + `users.auth0_sub` pipeline already built.

**Neon gives you two hostnames - which one matters, don't use them
interchangeably:**

- **Direct host** (`ep-....neon.tech`) - a normal Postgres connection.
  Small connection ceiling, meant for a handful of long-lived connections.
  Use this for: one-off admin work (loading `db/schema.sql`, `psql`
  sessions), local dev, and eventually the Python resource server (a
  persistent process holding its own small connection pool, not many
  short-lived ones).
- **Pooler host** (`ep-...-pooler.neon.tech`) - PgBouncer in transaction
  mode. Use this for: anything serverless - specifically `web/`'s
  `DATABASE_URL` on Vercel, where many concurrent function instances would
  otherwise each want their own direct connection and blow through the
  connection ceiling fast.

**If you use the pooler host, `prepare: false` is not optional.** PgBouncer
in transaction mode can route consecutive queries in what looks like one
"session" to different backend Postgres connections. `postgres.js` (the
npm package `web/` uses) defaults to server-side prepared statements, which
don't survive that - a statement prepared on one backend doesn't exist on
the next, and queries fail intermittently in a way that's confusing to
debug if you don't already know this is the cause. `web/src/lib/db.ts`
already sets `prepare: false` unconditionally (safe against the direct
host too, just not necessary there) - if this ever gets refactored, don't
drop that option.

Verified: schema loads clean and the full `db/tests.sql` suite (20/20)
passes against Neon directly. Also verified the JIT-provisioning path
(`getOrCreateUser`) against the pooler host specifically, with
`prepare: false` set - new-user creation and idempotent re-login both
confirmed correct. Test rows cleaned up after both verification passes -
this database should be empty and ready for real use.

## Vercel (website) - done, 2026-08-21

Live at `https://macro-mcp-v2.vercel.app`. Setup, for reference / redoing
elsewhere:

- Root Directory: `web` (this is a monorepo - `db/`, `docs/`, `server/`
  live alongside it, Vercel only builds what's under Root Directory)
- Env vars (from `web/.env.local`, except as noted):
  - `AUTH0_DOMAIN`, `AUTH0_CLIENT_ID`, `AUTH0_CLIENT_SECRET`, `AUTH0_SECRET`
    - same values as local
  - `DATABASE_URL` - Neon **pooler** host, not the direct one used for
    local dev
  - `APP_BASE_URL` - the real assigned Vercel URL, not `localhost:3000`
    (added after the first deploy, once Vercel actually assigned one)
- Added the Vercel URL to the Auth0 Application's **Allowed Callback URLs**
  (`.../auth/callback`) and **Allowed Logout URLs** - alongside the
  `localhost:3000` ones, not replacing them, so local dev keeps working too.

Full real end-to-end login (a human clicking through Google → Auth0 →
callback → JIT provisioning) confirmed working against this deployment -
see docs/auth-setup.md Part C's bottom note and project memory for the two
real Auth0 config bugs that had to be fixed to get there (Grant Types,
Default Audience) - both are exactly the kind of thing that'll bite again
on the next Auth0 Application you create by this same M2M-then-switched
path, or the next time Default Audience gets touched.

## Resource server (`server/`) - Railway, in progress

Needs a host that stays running (not classic serverless) - streamable-http
holds open server-to-client streams. Railway chosen; could also host the
database here later if consolidating off Neon ever makes sense.

- `railway.toml` at repo root defines the build (`pip install -e .`) and
  start (`python -m server.server`) commands explicitly, rather than
  trusting Nixpacks' auto-detection to guess right in a monorepo that also
  has a Next.js app in `web/`.
- **Root Directory: leave as `/` (the default), do NOT set it to `server`**
  - this is the opposite of what Vercel needed. `pyproject.toml` lives at
    the repo root, not inside `server/`; scoping Root Directory to `server`
    would hide it from Railway entirely and break the build.
- `server/config.py`/`server/server.py` bind to `0.0.0.0` and read the
  platform-injected `PORT` env var automatically when
  `MACROMCP_TRANSPORT=streamable-http` - verified locally with a simulated
  `PORT` before ever touching Railway, both the metadata endpoint and a
  real bind check.
- Env vars needed on the Railway service: `MACROMCP_TRANSPORT=streamable-http`,
  `AUTH0_DOMAIN`, `AUTH0_AUDIENCE`, `MACROMCP_DATABASE_URL` - the last one
  should be Neon's **direct** host (not the pooler `web/` uses), since this
  is one persistent process holding its own small connection pool, not many
  short-lived serverless ones.
- `AUTH0_AUDIENCE` needs to become the real Railway-assigned URL once
  deployed (see docs/auth-setup.md Part D) - the `.example` placeholder
  won't let real MCP clients discover this server.
- Still open: the Default Audience/DCR-scoping problem (docs/auth-setup.md
  Part A's note) needs solving before this is actually usable by Claude,
  not just running.
