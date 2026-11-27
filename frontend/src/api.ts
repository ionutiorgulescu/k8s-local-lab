// Calls to the shop API. Relative paths: the browser sends them to the same host it loaded
// the page from (shop.localhost), and the gateway routes /api/* to the API. No CORS needed.

export interface Product {
  id: number;
  name: string;
  price_cents: number;
}

export interface ApiVersion {
  version: string;
  revision: string;
}

async function getJson<T>(path: string, signal?: AbortSignal): Promise<T> {
  const res = await fetch(path, { signal, headers: { Accept: 'application/json' } });
  if (!res.ok) {
    throw new Error(`${path} returned HTTP ${res.status}`);
  }
  return (await res.json()) as T;
}

export const fetchProducts = (signal?: AbortSignal) => getJson<Product[]>('/api/products', signal);

export const fetchApiVersion = (signal?: AbortSignal) => getJson<ApiVersion>('/api/version', signal);
