import { readFileSync, readdirSync, statSync } from 'node:fs';
import { extname, join, relative } from 'node:path';
import process from 'node:process';

const repositoryRoot = process.cwd();
const auditScript = 'scripts/audit-e2e-truthfulness.mjs';
const sourceExtensions = new Set(['.swift', '.ts', '.tsx', '.js', '.mjs', '.sh']);

function filesUnder(path) {
  const absolute = join(repositoryRoot, path);
  if (statSync(absolute).isFile()) return [path];
  return readdirSync(absolute, { withFileTypes: true }).flatMap((entry) => {
    const child = join(path, entry.name);
    if (entry.isDirectory()) {
      if (['DerivedData', 'node_modules', '.build'].includes(entry.name)) return [];
      return filesUnder(child);
    }
    return sourceExtensions.has(extname(entry.name)) ? [child] : [];
  });
}

const applicationAndTestFiles = [
  ...filesUnder('apps/ios/MediNag'),
  ...filesUnder('apps/ios/MediNagUITests'),
  ...filesUnder('apps/ios/MediNagWatch'),
  ...filesUnder('apps/ios/MediNagWatchUITests'),
  ...filesUnder('apps/ios/Shared'),
  ...filesUnder('apps/ios/AlarmPatient'),
  ...filesUnder('apps/ios/LocalNotifications'),
  ...filesUnder('apps/ios/AlarmPatientUITests'),
  ...filesUnder('apps/ios/AlarmDiagnostic'),
  ...filesUnder('apps/ios/AlarmDiagnosticUITests'),
  ...filesUnder('apps/ios/AlarmBaseline'),
  ...filesUnder('apps/ios/AlarmBaselineUITests'),
  ...filesUnder('apps/ios/AlarmPrototype'),
  ...filesUnder('apps/ios/AlarmPrototypeUITests'),
  ...filesUnder('apps/ios/AlarmPrototypeShared'),
  ...filesUnder('apps/ios/AlarmPrototypeLiveActivity'),
  ...filesUnder('tests/e2e'),
  ...filesUnder('scripts')
].filter((path) => path !== auditScript);

const rules = [
  {
    name: 'test-only notification delivery store',
    files: applicationAndTestFiles,
    pattern: /E2ENotificationDeliveryStore/
  },
  {
    name: 'manual accelerated notification delivery',
    files: applicationAndTestFiles,
    pattern: /deliverAcceleratedNotification|advanceReminderClock/
  },
  {
    name: 'notification acknowledgement backdoor',
    files: applicationAndTestFiles,
    pattern: /acknowledgedNotificationCount|e2e-deliver-notification-on-background/
  },
  {
    name: 'alternate time-interval notification trigger',
    files: filesUnder('apps/ios/MediNag'),
    pattern: /UNTimeIntervalNotificationTrigger/
  },
  {
    name: 'hidden application gesture',
    files: filesUnder('apps/ios/MediNag'),
    pattern: /\.onTapGesture\s*\{|UITapGestureRecognizer/
  },
  {
    name: 'arbitrary E2E wait',
    files: [
      ...filesUnder('apps/ios/MediNagUITests'),
      ...filesUnder('apps/ios/MediNagWatchUITests'),
      ...filesUnder('apps/ios/AlarmPatientUITests'),
      ...filesUnder('apps/ios/AlarmDiagnosticUITests'),
      ...filesUnder('apps/ios/AlarmBaselineUITests'),
      ...filesUnder('apps/ios/AlarmPrototypeUITests'),
      ...filesUnder('tests/e2e')
    ],
    pattern: /waitForTimeout\s*\(|\b(?:sleep|usleep|Thread\.sleep|Task\.sleep)\s*\(|new Promise\s*\([^)]*setTimeout/
  },
  {
    name: 'direct medication-event seeding from E2E',
    files: filesUnder('tests/e2e'),
    pattern: /medicationEvents/
  },
  {
    name: 'unsupported hosted-service claim in emulator E2E',
    files: filesUnder('tests/e2e'),
    pattern: /\breal Google (?:authentication|sign-in)\b|\bproduction Firebase\b|\bdelivered SMS\b/i
  }
];

const violations = [];
for (const rule of rules) {
  for (const path of rule.files) {
    const content = readFileSync(join(repositoryRoot, path), 'utf8');
    for (const [index, line] of content.split('\n').entries()) {
      if (rule.pattern.test(line)) {
        // Reading the real server outcome is not seeding it. Only allow this
        // explicit SDK collection read in a file with NO Firestore write API;
        // the broad medicationEvents ban remains for all other E2E references.
        const readOnlyEventInspection = rule.name === 'direct medication-event seeding from E2E'
          && /getDocs\(collection\([^)]*['"]medicationEvents['"]\)\)/.test(line)
          && !/\b(?:setDoc|updateDoc|addDoc|deleteDoc|writeBatch|runTransaction|set|update|add|delete)\s*\(/.test(content);
        if (readOnlyEventInspection) continue;
        violations.push(`${relative(repositoryRoot, path)}:${index + 1}: ${rule.name}`);
      }
    }
  }
}

if (violations.length > 0) {
  console.error('E2E truthfulness audit failed:');
  for (const violation of violations) console.error(`- ${violation}`);
  process.exitCode = 1;
} else {
  console.log(`E2E truthfulness audit passed (${applicationAndTestFiles.length} source files).`);
}
