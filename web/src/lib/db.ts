import postgres from "postgres";

// Same database as server/ (the Python MCP resource server) - this is the
// JIT-provisioning side of Phase 2's users.auth0_sub column: on first
// login, create the linked row here; token_verifier (Phase 4) reads it.
const sql = postgres(process.env.DATABASE_URL ?? "postgresql:///macromcp");

export interface AppUser {
  id: number;
  username: string;
}

interface Auth0Profile {
  sub: string;
  email?: string;
  nickname?: string;
  name?: string;
}

// Mirrors db/schema.sql's users.username CHECK (username ~ '^[a-z0-9_]{2,32}$').
// Must match exactly, or the INSERT below fails the constraint instead of
// producing a usable account.
function slugifyUsername(raw: string): string {
  const slug = raw
    .toLowerCase()
    .replace(/[^a-z0-9_]+/g, "_")
    .replace(/^_+|_+$/g, "")
    .slice(0, 28); // leave room for a numeric suffix, still under 32
  return slug.length >= 2 ? slug : `user_${slug}`;
}

function candidateBaseUsername(profile: Auth0Profile): string {
  const source = profile.nickname || profile.email?.split("@")[0] || profile.sub;
  return slugifyUsername(source);
}

/**
 * Look up the users row for an already-verified Auth0 identity, creating it
 * (plus its user_settings row, via the existing DB trigger) on first login.
 * Idempotent - safe to call on every page load, not just once at callback.
 */
export async function getOrCreateUser(profile: Auth0Profile): Promise<AppUser> {
  const existing = await sql<AppUser[]>`
    SELECT id, username FROM users WHERE auth0_sub = ${profile.sub}
  `;
  if (existing.length > 0) {
    return existing[0];
  }

  const base = candidateBaseUsername(profile);
  const displayName = profile.name || profile.nickname || profile.email || base;

  // Try the bare slug first, then _2, _3, ... - collisions should be rare at
  // this scale, so a short bounded loop is simpler than a single clever query.
  for (let attempt = 0; attempt < 20; attempt++) {
    const candidate = attempt === 0 ? base : `${base}_${attempt + 1}`.slice(0, 32);
    const inserted = await sql<AppUser[]>`
      INSERT INTO users (username, display_name, auth0_sub)
      VALUES (${candidate}, ${displayName}, ${profile.sub})
      ON CONFLICT (username) DO NOTHING
      RETURNING id, username
    `;
    if (inserted.length > 0) {
      return inserted[0];
    }
    // username taken - loop and try the next suffix. If auth0_sub itself
    // raced onto another row in the meantime (near-impossible, but real
    // concurrent double-clicks exist), pick that up instead of looping forever.
    const raced = await sql<AppUser[]>`
      SELECT id, username FROM users WHERE auth0_sub = ${profile.sub}
    `;
    if (raced.length > 0) {
      return raced[0];
    }
  }

  throw new Error(`could not find a free username derived from "${base}" after 20 attempts`);
}
