import react from '@vitejs/plugin-react';
import { defineConfig } from 'vite';

export default defineConfig({
  plugins: [react()],
  server: {
    // `npm run dev` serves the UI from Vite on localhost:5173. Calls to /api are forwarded
    // to the API in the kind cluster, through the gateway, so the browser sees one origin
    // (no CORS), exactly like in the cluster.
    proxy: {
      '/api': {
        // The gateway as published by kind on this Mac. Connect to localhost (Node doesn't
        // resolve *.localhost names by itself) and send the hostname the HTTPRoute expects.
        target: 'http://localhost:8088',
        headers: { host: 'shop.localhost' },
      },
    },
  },
});
