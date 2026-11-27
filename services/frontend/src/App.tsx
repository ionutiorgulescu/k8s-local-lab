import { useEffect, useState } from 'react';
import { fetchApiVersion, fetchProducts, type ApiVersion, type Product } from './api';

type State =
  | { status: 'loading' }
  | { status: 'error'; message: string }
  | { status: 'ready'; products: Product[] };

const price = new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' });
const frontendRevision = import.meta.env.VITE_APP_REVISION ?? 'dev';
const short = (revision: string) => (revision === 'dev' ? 'dev' : revision.slice(0, 7));

export function App() {
  const [state, setState] = useState<State>({ status: 'loading' });
  const [apiVersion, setApiVersion] = useState<ApiVersion | null>(null);
  // Bumping this re-runs the effect: the "Try again" button.
  const [attempt, setAttempt] = useState(0);

  useEffect(() => {
    // Abort the requests if the component re-renders or unmounts before they finish.
    const controller = new AbortController();
    setState({ status: 'loading' });

    fetchProducts(controller.signal)
      .then((products) => setState({ status: 'ready', products }))
      .catch((err: unknown) => {
        if (controller.signal.aborted) return;
        setState({ status: 'error', message: err instanceof Error ? err.message : String(err) });
      });

    // Best effort: the footer just shows less if this fails.
    fetchApiVersion(controller.signal).then(setApiVersion).catch(() => setApiVersion(null));

    return () => controller.abort();
  }, [attempt]);

  return (
    <main>
      <h1>Shop</h1>

      {state.status === 'loading' && <p className="muted">Loading products…</p>}

      {state.status === 'error' && (
        <div className="error" role="alert">
          <p>Couldn't load products: {state.message}</p>
          <button type="button" onClick={() => setAttempt((n) => n + 1)}>
            Try again
          </button>
        </div>
      )}

      {state.status === 'ready' && state.products.length === 0 && (
        <p className="muted">No products yet.</p>
      )}

      {state.status === 'ready' && state.products.length > 0 && (
        <ul className="products">
          {state.products.map((p) => (
            <li key={p.id}>
              <span>{p.name}</span>
              <span className="price">{price.format(p.price_cents / 100)}</span>
            </li>
          ))}
        </ul>
      )}

      <footer className="muted">
        frontend version {short(frontendRevision)}
        {apiVersion && (
          <>
            {' · '}API {apiVersion.version} ({short(apiVersion.revision)})
          </>
        )}
      </footer>
    </main>
  );
}
