import '@fontsource-variable/inter';
import './styles.css';
import { createApplicationServices } from './application-services';
import { mountSchedulesPage } from './schedules-page';
import { mountSettingsPage } from './settings-page';
import { mountSignInPage } from './sign-in-page';
import { mountTodayPage } from './today-page';

const root = document.querySelector<HTMLElement>('#app');
if (!root) {
  throw new Error('MediNag application root is missing.');
}

const services = createApplicationServices();
let unmountPage: (() => void) | undefined;
let routeVersion = 0;

const markReady = (version: number): void => {
  if (version === routeVersion) {
    document.documentElement.dataset.appReady = 'true';
  }
};

const renderRoute = async (): Promise<void> => {
  routeVersion += 1;
  const version = routeVersion;
  delete document.documentElement.dataset.appReady;
  unmountPage?.();
  unmountPage = undefined;

  await document.fonts.ready;
  const application = await services;
  root.classList.add('is-dashboard');
  if (application.account.kind !== 'google') {
    unmountPage = mountSignInPage(
      root,
      application.account,
      () => markReady(version)
    );
    return;
  }
  if (!application.administrator || !application.schedules || !application.today) {
    throw new Error('Authenticated application services are incomplete.');
  }

  if (window.location.hash === '#/settings') {
    unmountPage = mountSettingsPage(
      root,
      application.administrator,
      application.account,
      () => markReady(version)
    );
    return;
  }
  if (window.location.hash === '#/today') {
    unmountPage = mountTodayPage(
      root,
      application.today,
      application.administrator,
      application.account,
      () => markReady(version)
    );
    return;
  }
  unmountPage = mountSchedulesPage(
    root,
    application.schedules,
    application.administrator,
    application.account,
    () => markReady(version)
  );
};

window.addEventListener('hashchange', () => {
  void renderRoute();
});

void renderRoute();
