# Auth0 setup runbook (Phase 1)

Everything in this file has to be done by hand in Auth0's dashboard (and
later, Google/Apple/Facebook's) — none of it is scriptable from here, since
it requires your own account credentials and interactive consent screens.
This is the checklist; once you've done it, hand back the four values at
the bottom and the code side (Phase 4 - `token_verifier`, streamable-http
transport) gets wired up against them.

Scoped to **Google only** for the first pass. Apple and Facebook follow the
identical "Authentication → Social" pattern once you have developer
accounts for them (Apple Developer Program is $99/yr; Facebook Login
requires app review for many permissions in production) - not worth the
friction until the Google + Claude path is proven end to end.

---

## Part A — Auth0 tenant and API

1. Create an Auth0 tenant (or use an existing one) at auth0.com.

2. **APIs → + Create API**
   - Name: `MacroMCP` (or whatever - cosmetic)
   - Identifier: a URL that identifies this resource, e.g.
     `https://api.macromcp.app/` — this does NOT need to resolve to
     anything yet, it's just the audience string tokens get scoped to. Use
     whatever domain you expect to actually deploy the resource server to
     eventually, since changing it later means re-issuing tokens.
   - Signing algorithm: RS256 (default - leave it).

3. **Settings → General → Default Audience**: set this to the same
   Identifier from step 2. This matters specifically for DCR-registered
   clients (Claude) - Auth0's authorization requests from DCR clients don't
   reliably include an explicit `audience` parameter, so a default audience
   is what makes the issued token actually scoped to our API instead of a
   generic one our `token_verifier` would reject.

4. **Settings → Advanced**: enable **OIDC Dynamic Application
   Registration**. This is the RFC 7591 DCR support Claude requires - off
   by default.

5. Still in **Settings → Advanced**, confirm **Enable Application
   Connections** is checked (needed so a client dynamically registered via
   DCR actually gets a usable login connection, not an empty shell).

**Known tradeoff, not a mistake:** Auth0's own current guidance recommends
CIMD over DCR for production MCP servers (better credential hygiene, no
runtime registration). We're enabling DCR anyway because Claude Code
currently requires it with no fallback - see the compatibility issue link
in `docs/design-notes.md`'s history if that changes later. Practical
consequence: every fresh Claude connection registers a new Auth0
Application. Check **Applications** in the dashboard occasionally once
this is live - if it's accumulating fast, that's the point to look at
pruning stale ones or revisiting CIMD.

---

## Part B — Google social login

1. In [Google Cloud Console](https://console.cloud.google.com/), create a
   project (or use an existing one) → **APIs & Services → Credentials →
   Create Credentials → OAuth client ID** → Application type: **Web
   application**.
2. Under **Authorized redirect URIs**, add your Auth0 tenant's callback:
   `https://YOUR_AUTH0_DOMAIN/login/callback` (find the exact value on
   Auth0's own social connection setup page - it fills this in for you).
3. Save the generated **Client ID** and **Client Secret**.
4. In Auth0: **Authentication → Social → Google** (or "+ Create
   Connection" if not listed) → paste the Client ID/Secret from step 3 →
   enable it for the Application created for the website (Part A didn't
   create a website-login Application yet - see note below).

**Note:** Part A's API is for the *resource server* (what Claude/ChatGPT
get tokens for). The *website's own login* needs a separate, regular Auth0
**Application** (type: Regular Web Application) if one doesn't already
exist - that's what Phase 3 (the Next.js site) will actually authenticate
against, with Google as one of its connections. Create that Application
now if you want Part B fully working before Phase 3's code exists; it can
also wait until we're actively building the site.

---

## What to hand back

Once Part A (and optionally Part B) is done, give me:

- Auth0 domain (e.g. `your-tenant.us.auth0.com`)
- The API Identifier from Part A step 2 (the audience string)
- If you created the website login Application: its Client ID
- Confirmation that DCR + default audience are both set

That's enough to write `token_verifier` in `server/db.py`/`server/server.py`
and switch the transport to `streamable-http` (Phase 4), and to wire the
Next.js site's Auth0 SDK config (Phase 3) once we get there.

---

## Part C — Wiring the website's Auth0 Application (Phase 3)

The `web/` app (built) needs two more values from the **MacroMCP Website**
Auth0 Application (the one that started as an auto-created Machine-to-
Machine "Test Application" and got switched to Regular Web Application in
Settings) - not the Google Cloud OAuth client, and not the API from Part A.

1. Open that Application in Auth0 → **Settings**
2. Copy **Client ID** and **Client Secret**, add them to `web/.env.local`:
   ```
   AUTH0_CLIENT_ID=...
   AUTH0_CLIENT_SECRET=...
   ```
3. Still in that Application's Settings, set:
   - **Allowed Callback URLs**: `http://localhost:3000/auth/callback`
   - **Allowed Logout URLs**: `http://localhost:3000`

   (Auth0 rejects the login/logout redirect if the URL isn't explicitly
   whitelisted here - this is a different setting from the Google Cloud
   redirect URI from Part B, which points at Auth0 itself, not at our app.)
4. Save, then `cd web && npm run dev` and visit `http://localhost:3000` -
   "Log in" should now complete a real Google login and land back on the
   page showing your generated username.

Add the real production URL to both Allowed lists later, once Vercel
deployment (still open - see chat) gives you one.
