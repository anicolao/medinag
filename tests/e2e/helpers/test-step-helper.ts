import { expect, type Page, type TestInfo } from '@playwright/test';
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';

export interface Verification {
  spec: string;
  check: () => Promise<void>;
}

export interface StepOptions {
  description: string;
  verifications: Verification[];
}

interface DocStep {
  title: string;
  image: string;
  specs: string[];
}

interface StoryMetadata {
  title: string;
  narrative: string;
}

interface SurfaceCoverage {
  status: 'covered' | 'not-applicable';
  reason?: string;
}

interface StoryManifest {
  title: string;
  narrative: string;
  surfaces: Record<'web' | 'ios' | 'watchos', SurfaceCoverage>;
}

export class TestStepHelper {
  private metadata?: StoryMetadata;
  private stepCount = 0;
  private readonly steps: DocStep[] = [];

  constructor(
    private readonly page: Page,
    private readonly testInfo: TestInfo,
    private readonly surfaceDirectory = ''
  ) {}

  setMetadata(title: string, narrative: string): void {
    this.metadata = { title, narrative };
  }

  async step(id: string, options: StepOptions): Promise<void> {
    for (const verification of options.verifications) {
      await verification.check();
    }

    const index = String(this.stepCount).padStart(3, '0');
    const safeId = id.replaceAll('_', '-');
    const filename = `${index}-${safeId}.png`;

    const screenshotPath = this.surfaceDirectory
      ? [this.surfaceDirectory, filename]
      : filename;
    await expect(this.page).toHaveScreenshot(screenshotPath, {
      animations: 'disabled',
      caret: 'hide',
      maxDiffPixelRatio: 0,
      maxDiffPixels: 0,
      scale: 'css',
      threshold: 0,
      timeout: 2_000
    });

    this.steps.push({
      title: options.description,
      image: `./screenshots/${
        Array.isArray(screenshotPath) ? screenshotPath.join('/') : screenshotPath
      }`,
      specs: options.verifications.map(({ spec }) => spec)
    });
    this.stepCount += 1;
  }

  generateDocs(): void {
    if (!this.metadata) {
      throw new Error('Set user-story metadata before generating documentation.');
    }

    const sections = this.steps.map((step) => {
      const checks = step.specs.map((spec) => `- [x] ${spec}`).join('\n');
      return [
        `## ${step.title}`,
        '',
        `![${step.title}](${step.image})`,
        '',
        '**Verifications:**',
        '',
        checks
      ].join('\n');
    });

    const storyDirectory = dirname(this.testInfo.file);
    const manifest = JSON.parse(
      readFileSync(join(storyDirectory, 'story.json'), 'utf8')
    ) as StoryManifest;
    if (
      manifest.title !== this.metadata.title ||
      manifest.narrative !== this.metadata.narrative
    ) {
      throw new Error('Test metadata must match the story manifest.');
    }
    const surfaceNames = {
      web: 'Web Admin Dashboard',
      ios: 'iOS',
      watchos: 'watchOS'
    };
    const coverage = (Object.keys(surfaceNames) as Array<keyof typeof surfaceNames>).map(
      (surface) => {
        const entry = manifest.surfaces[surface];
        const reason = entry.reason ? ` — ${entry.reason}` : '';
        return `- **${surfaceNames[surface]}:** ${entry.status}${reason}`;
      }
    );

    const content = [
      `# Test: ${this.testInfo.title}`,
      '',
      `> ${this.metadata.narrative}`,
      '',
      '## Surface coverage',
      '',
      ...coverage,
      '',
      ...sections.flatMap((section) => [section, ''])
    ].join('\n');
    const docPath = join(storyDirectory, 'README.md');

    let existing = '';
    try {
      existing = readFileSync(docPath, 'utf8');
    } catch {
      // The first successful run creates the walkthrough.
    }

    if (existing !== content) {
      writeFileSync(docPath, content);
    }
  }
}
