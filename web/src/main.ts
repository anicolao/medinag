import '@fontsource-variable/inter';
import './styles.css';

void document.fonts.ready.then(() => {
  document.documentElement.dataset.appReady = 'true';
});
