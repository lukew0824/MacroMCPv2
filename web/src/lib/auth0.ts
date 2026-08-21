import { Auth0Client } from "@auth0/nextjs-auth0/server";

// Single client instance, reused across requests. Configuration comes
// entirely from env vars (AUTH0_DOMAIN, AUTH0_CLIENT_ID, AUTH0_CLIENT_SECRET,
// AUTH0_SECRET, APP_BASE_URL) - see .env.local.example. Default routes are
// under /auth/* (login, logout, callback, profile) - middleware.ts mounts them.
export const auth0 = new Auth0Client();
