"use client"; // Error boundaries must be Client Components

export default function Error({
  error,
  retry,
}: {
  error: Error & { digest?: string };
  retry: () => void;
}) {
  return (
    <main className="wrap">
      <h1>Something went wrong</h1>
      <p>{error.message}</p>
      <button className="button" onClick={() => retry()}>
        Try again
      </button>
    </main>
  );
}
