import react from '@vitejs/plugin-react';
import { defineConfig } from 'vite';

export default defineConfig({
  plugins: [react()],
  server: {
    // `npm run dev` serves the UI from Vite on localhost:5173. Calls to /api are forwarded
    // to the API in the kind cluster, through the gateway, so the browser sees one origin
    // (no CORS), exactly like in the cluster. Needs "127.0.0.1 shop.local" in /etc/hosts.
    proxy: {
      '/api': {
        target: 'http://shop.local:8088',
        changeOrigin: true,
      },
    },
  },
});
