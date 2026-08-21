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

## Vercel (website)

Not done yet. When setting up the project:

- Root Directory: `web` (this is a monorepo - `db/`, `docs/`, `server/`
  live alongside it, Vercel only builds what's under Root Directory)
- Env vars (from `web/.env.local`, except as noted):
  - `AUTH0_DOMAIN`, `AUTH0_CLIENT_ID`, `AUTH0_CLIENT_SECRET`, `AUTH0_SECRET`
    - same values as local
  - `DATABASE_URL` - Neon **pooler** host, not the direct one used for
    local dev
  - `APP_BASE_URL` - the real assigned Vercel URL, not `localhost:3000`
- After the first deploy, add that Vercel URL to the Auth0 Application's
  **Allowed Callback URLs** (`https://<vercel-url>/auth/callback`) and
  **Allowed Logout URLs** (`https://<vercel-url>`) - alongside the
  `localhost:3000` ones already there, not replacing them, since local dev
  should keep working too.

## Resource server (`server/`)

Not started. Needs a host that stays running (Fly.io/Render/Railway/a
small box) - streamable-http holds open server-to-client streams, which
doesn't fit classic serverless. See docs/auth-setup.md Part D for the
`AUTH0_AUDIENCE` correction: it needs to become the server's real public
URL once this is live, not stay the `.example` placeholder, since that
value is also what's advertised to OAuth clients for discovery.
