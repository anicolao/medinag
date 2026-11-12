import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { basename, dirname, join, relative, resolve } from 'node:path';
import process from 'node:process';

if (process.argv.length !== 4) {
  throw new Error('usage: node scripts/generate-walkthrough.mjs <claims.json> <story-directory>');
}

const claimsPath = resolve(process.argv[2]);
const storyDirectory = resolve(process.argv[3]);
const claims = JSON.parse(readFileSync(claimsPath, 'utf8'));
const story = JSON.parse(readFileSync(join(dirname(claimsPath), 'story.json'), 'utf8'));

for (const field of ['title', 'narrative']) {
  if (claims[field] !== story[field]) {
    throw new Error(`${basename(claimsPath)} ${field} must match story.json.`);
  }
}
if (JSON.stringify(claims.surfaces) !== JSON.stringify(story.surfaces)) {
  throw new Error(`${basename(claimsPath)} surfaces must match story.json.`);
}

const environmentNames = new Set(Object.keys(claims.environments));
const stepIds = new Set();
const claimIds = new Set();
for (const step of claims.steps) {
  if (stepIds.has(step.id)) throw new Error(`Duplicate walkthrough step: ${step.id}`);
  stepIds.add(step.id);
  const image = join(storyDirectory, 'screenshots', step.surface, step.image);
  if (!existsSync(image)) {
    throw new Error(`Walkthrough evidence is missing: ${relative(process.cwd(), image)}`);
  }
  for (const claim of step.claims) {
    if (claimIds.has(claim.id)) throw new Error(`Duplicate walkthrough claim: ${claim.id}`);
    claimIds.add(claim.id);
    if (!environmentNames.has(claim.environment)) {
      throw new Error(`Claim ${claim.id} names unknown environment ${claim.environment}.`);
    }
    if (!claim.assertion?.trim()) {
      throw new Error(`Claim ${claim.id} does not map to a verifying assertion.`);
    }
  }
}

const surfaceNames = {
  web: 'Web Admin Dashboard',
  ios: 'iOS',
  watchos: 'watchOS'
};
const coverage = Object.entries(surfaceNames).map(([surface, name]) => {
  const entry = claims.surfaces[surface];
  const reason = entry.reason ? ` — ${entry.reason}` : '';
  return `- **${name}:** ${entry.status}${reason}`;
});
const environments = Object.entries(claims.environments).map(
  ([name, description]) => `- **${name}:** ${description}`
);
const preconditions = claims.preconditions.map((value) => `- ${value}`);
const steps = claims.steps.map((step) => {
  const checks = step.claims.map((claim) => `- [x] ${claim.text}`).join('\n');
  return [
    `## ${step.description}`,
    '',
    `![${step.description}](./screenshots/${step.surface}/${step.image})`,
    '',
    '**Verifications:**',
    '',
    checks
  ].join('\n');
});

const output = [
  `# Test: ${claims.title}`,
  '',
  `> ${claims.narrative}`,
  '',
  '## Surface coverage',
  '',
  ...coverage,
  '',
  '## Evidence environments',
  '',
  ...environments,
  '',
  '## Deterministic preconditions',
  '',
  ...preconditions,
  '',
  ...steps.flatMap((step) => [step, ''])
].join('\n');

writeFileSync(join(storyDirectory, 'README.md'), output);
console.log(`Generated walkthrough from ${relative(process.cwd(), claimsPath)}.`);
