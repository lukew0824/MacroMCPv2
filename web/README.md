# MacroMCP website

Auth0 login (Google for now) plus just-in-time provisioning: on first
login, `src/lib/db.ts` links the verified Auth0 identity to a row in the
same `users` table `server/` (the Python MCP resource server) uses.

Setup: `docs/auth-setup.md` Part C, at the repo root.

```bash
npm install
cp .env.local.example .env.local   # then fill in AUTH0_CLIENT_ID/SECRET
npm run dev
```

See the repo root `README.md` for how this fits into the rest of the
project, and `docs/design-notes.md` for the database it talks to.
