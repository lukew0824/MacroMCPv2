import type { NextRequest } from "next/server";
import { auth0 } from "@/lib/auth0";

// Next.js 16 renamed middleware.ts -> proxy.ts (same mechanics, file/export
// renamed). This mounts Auth0's routes (/auth/login, /auth/callback, etc.)
// and refreshes the session cookie on every request.
export async function proxy(request: NextRequest) {
  return auth0.middleware(request);
}

export const config = {
  matcher: ["/((?!_next/static|_next/image|favicon.ico).*)"],
};
