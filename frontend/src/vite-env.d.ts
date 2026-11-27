/// <reference types="vite/client" />

interface ImportMetaEnv {
  // The Git commit the frontend image was built from. Set at build time by CI
  // (Dockerfile: APP_REVISION -> VITE_APP_REVISION); Vite inlines it into the bundle.
  readonly VITE_APP_REVISION?: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}
