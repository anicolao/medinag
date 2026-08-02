import '@fontsource-variable/inter';
import './styles.css';
import { createApplicationServices } from './application-services';
import { mountSchedulesPage } from './schedules-page';
import { mountTodayPage } from './today-page';

const root = document.querySelector<HTMLElement>('#app');
if (!root) {
  throw new Error('MediNag application root is missing.');
}

const welcomeMarkup = root.innerHTML;
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
  if (window.location.hash === '#/today') {
    root.classList.add('is-dashboard');
    unmountPage = mountTodayPage(
      root,
      application.today,
      application.account,
      () => markReady(version)
    );
    return;
  }
  if (window.location.hash === '#/schedules') {
    root.classList.add('is-dashboard');
    unmountPage = mountSchedulesPage(
      root,
      application.schedules,
      application.account,
      () => markReady(version)
    );
    return;
  }

  root.classList.remove('is-dashboard');
  root.innerHTML = welcomeMarkup;
  markReady(version);
};

window.addEventListener('hashchange', () => {
  void renderRoute();
});

void renderRoute();
