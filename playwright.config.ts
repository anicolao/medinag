import { defineConfig } from '@playwright/test';

export default defineConfig({
  testDir: './tests/e2e',
  fullyParallel: true,
  forbidOnly: Boolean(process.env.CI),
  retries: 0,
  workers: 1,
  reporter: [['list'], ['html', { open: 'never' }]],
  timeout: 10_000,
  expect: {
    timeout: 2_000,
    toHaveScreenshot: {
      maxDiffPixels: 0,
      maxDiffPixelRatio: 0,
      threshold: 0
    }
  },
  use: {
    baseURL: 'http://127.0.0.1:5174',
    actionTimeout: 2_000,
    navigationTimeout: 2_000,
    browserName: 'chromium',
    colorScheme: 'light',
    contextOptions: { reducedMotion: 'reduce' },
    deviceScaleFactor: 1,
    locale: 'en-CA',
    serviceWorkers: 'block',
    timezoneId: 'America/Toronto',
    trace: 'retain-on-failure',
    viewport: { width: 1440, height: 900 },
    launchOptions: {
      args: [
        '--disable-accelerated-2d-canvas',
        '--disable-font-subpixel-positioning',
        '--disable-gpu',
        '--disable-lcd-text',
        '--disable-partial-raster',
        '--disable-skia-runtime-opts',
        '--disable-smooth-scrolling',
        '--font-render-hinting=none',
        '--force-device-scale-factor=1',
        '--use-gl=swiftshader'
      ]
    }
  },
  snapshotPathTemplate: '{testDir}/{testFileDir}/screenshots/{arg}{ext}',
  webServer: {
    command: 'npm run dev',
    url: 'http://127.0.0.1:5174',
    reuseExistingServer: !process.env.CI,
    timeout: 2_000
  }
});
