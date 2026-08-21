import { auth0 } from "@/lib/auth0";
import { getOrCreateUser } from "@/lib/db";

export default async function Home() {
  const session = await auth0.getSession();

  if (!session) {
    return (
      <main className="wrap">
        <h1>MacroMCP</h1>
        <p>Log in to connect your account.</p>
        <a className="button" href="/auth/login">
          Log in
        </a>
      </main>
    );
  }

  const user = await getOrCreateUser(session.user);

  return (
    <main className="wrap">
      <h1>MacroMCP</h1>
      <p>
        Signed in as <strong>{user.username}</strong>.
      </p>
      <a className="button" href="/auth/logout">
        Log out
      </a>
    </main>
  );
}
