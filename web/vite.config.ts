import { fileURLToPath } from 'node:url';
import { defineConfig } from 'vite';

const webRoot = fileURLToPath(new URL('.', import.meta.url));
const requestedBase = process.env.PUBLIC_BASE_PATH ?? '/';
const base = requestedBase.endsWith('/') ? requestedBase : `${requestedBase}/`;

export default defineConfig({
  root: webRoot,
  base,
  build: {
    outDir: '../build',
    emptyOutDir: true
  }
});
