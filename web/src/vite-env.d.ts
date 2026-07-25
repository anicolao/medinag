/// <reference types="vite/client" />

interface ImportMetaEnv {
  readonly VITE_FIREBASE_API_KEY?: string;
  readonly VITE_FIREBASE_AUTH_DOMAIN?: string;
  readonly VITE_FIREBASE_PROJECT_ID?: string;
  readonly VITE_FIREBASE_APP_ID?: string;
  readonly VITE_USE_FIREBASE_EMULATOR?: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}

interface Window {
  __MEDINAG_E2E__?: boolean;
}
