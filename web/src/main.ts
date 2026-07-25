import '@fontsource-variable/inter';
import './styles.css';
import { createScheduleRepository } from './schedule-repository';
import { mountSchedulesPage } from './schedules-page';

const root = document.querySelector<HTMLElement>('#app');
if (!root) {
  throw new Error('MediNag application root is missing.');
}

const welcomeMarkup = root.innerHTML;
const repository = createScheduleRepository();
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
  if (window.location.hash === '#/schedules') {
    root.classList.add('is-dashboard');
    unmountPage = mountSchedulesPage(root, repository, () => markReady(version));
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
