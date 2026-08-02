/// <reference types="vite/client" />

interface ImportMetaEnv {
  readonly VITE_FIREBASE_API_KEY?: string;
  readonly VITE_FIREBASE_AUTH_DOMAIN?: string;
  readonly VITE_FIREBASE_PROJECT_ID?: string;
  readonly VITE_FIREBASE_STORAGE_BUCKET?: string;
  readonly VITE_FIREBASE_MESSAGING_SENDER_ID?: string;
  readonly VITE_FIREBASE_APP_ID?: string;
  readonly VITE_FIREBASE_PROJECT_NUMBER?: string;
  readonly VITE_FIREBASE_CONFIG_VERSION?: string;
  readonly VITE_USE_FIREBASE_EMULATOR?: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}

interface Window {
  __MEDINAG_E2E__?: boolean;
  __MEDINAG_E2E_ACCOUNT_LINK__?: boolean;
}
