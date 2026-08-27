# E2E Testing Guide

This project uses [Playwright](https://playwright.dev/) for the Web Admin Dashboard and [XCTest with XCUIAutomation](https://developer.apple.com/documentation/xcuiautomation) for the iOS and watchOS apps. Our E2E tests and their generated user-story walkthroughs are the primary source of truth for application correctness.

## 1. The Philosophy: "Zero-Pixel Tolerance"

We enforce a strict **Zero-Pixel Tolerance** policy for visual regression on every surface. Since visual state is the primary feedback mechanism for Lori and Steve, any deviation is considered a bug.

* **Exact comparison**: Every screenshot must match its committed baseline at the same dimensions with `maxDiffPixels: 0`, `maxDiffPixelRatio: 0`, and a color threshold of `0`. Native PNG comparison must likewise require exact per-channel equality for every pixel.
* **Deterministic rendering**: Web tests use software rendering. Native tests use pinned Xcode, iOS/watchOS runtimes, simulator models, scale, appearance, Dynamic Type size, locale, time zone, and status-bar values. Animations are disabled in test builds.
* **Deterministic infrastructure**: Tests start isolated Firebase Authentication and Firestore emulators, create fresh identities through Firebase Auth, and reset all persisted state between stories. A controllable clock may accelerate time, but it must drive the production scheduler and data path.
* **No fake application state**: Hardcoded schedules, medication events, authenticated users, fake repositories, `localStorage` seed data, and in-process Firebase substitutes are strictly forbidden in E2E tests. Story data must enter through a real user action or the same public API used by the deployed application.
* **No casual baseline updates**: A changed baseline is a product change. The pull request must show and explain every intentional pixel change.

An E2E test is a test of the deployed architecture, not merely a UI test. It must exercise real Firebase SDK calls, Auth tokens, Firestore security rules, writes, snapshot listeners, reads, and cross-client state transitions. The emulator isolates the test from production; it does not replace any application layer with a mock.

## 2. Test Structure

All E2E tests live in `tests/e2e/`. Each user story gets its own numbered directory. A story includes every product surface involved in that flow and generates one ordered walkthrough.

```text
tests/e2e/
├── helpers/
│   ├── web/                         # Playwright TestStepHelper
│   ├── apple/                       # XCTest TestStepHelper
│   └── walkthrough/                 # Shared manifest and README generator
├── 001-complete-scheduled-dose/     # User-story directory
│   ├── story.json                   # Title, narrative, inputs, and surface order
│   ├── web.spec.ts                  # Admin dashboard steps
│   ├── ios/                         # iOS UI test source or story adapter
│   ├── watchos/                     # watchOS UI test source or story adapter
│   ├── steps/                       # Auto-generated per-surface step manifests
│   │   ├── web.json
│   │   ├── ios.json
│   │   └── watchos.json
│   ├── README.md                    # Auto-generated verification walkthrough
│   └── screenshots/                 # Committed exact baselines
│       ├── web/
│       ├── ios/
│       └── watchos/
```

Every story must declare `web`, `ios`, and `watchos` as either `covered` or `not-applicable`, with a reason. The complete suite must contain walkthrough coverage for all three applications. Cross-device stories must share one emulator project and follow the document IDs created by real application writes so the generated document demonstrates the same dose moving through the whole system.

## 3. The "Unified Step Pattern"

To prevent synchronization errors between documentation, verifications, and screenshots, we use a **Unified Step API** on all platforms. You must **NEVER** manually manage screenshot filenames, counters, Markdown image links, or step numbering.

### The `TestStepHelper`

The TypeScript and Swift implementations of `TestStepHelper` expose the same concepts. A `step()` combines a human-readable description, verifications, and screenshot capture into one atomic operation.

#### Web usage

```typescript
import { test, expect } from '@playwright/test';
import { TestStepHelper } from '../helpers/web/test-step-helper';

test('Lori sees Steve complete a scheduled dose', async ({ page }, testInfo) => {
  const tester = new TestStepHelper(page, testInfo);
  tester.setMetadata(
    'Scheduled Dose Completion',
    'As Lori, I want to see when Steve confirms a scheduled dose.'
  );

  await page.goto('/');
  await tester.step('pending-dose', {
    description: 'The dashboard shows Steve\'s morning dose as pending.',
    verifications: [
      {
        spec: 'Morning dose is pending',
        check: async () =>
          await expect(page.getByTestId('morning-dose-status')).toHaveText('Pending')
      }
    ]
  });

  tester.generateDocs();
});
```

#### iOS and watchOS usage

```swift
import XCTest

final class ScheduledDoseCompletionTests: XCTestCase {
    func testSteveCompletesScheduledDose() throws {
        let app = XCUIApplication()
        let tester = TestStepHelper(
            testCase: self,
            application: app,
            surface: .iOS
        )
        tester.setMetadata(
            title: "Scheduled Dose Completion",
            narrative: "As Steve, I want to confirm that I took my scheduled dose."
        )

        app.launchArguments += firebaseEmulatorArguments(from: testEnvironment)
        app.launch()

        try tester.step(
            "pending-dose",
            description: "Steve sees the pending morning dose.",
            verifications: [
                .exists(app.staticTexts["Morning Prescription Doses"]),
                .exists(app.buttons["Yes, I did"])
            ]
        )

        try tester.generateDocs()
    }
}
```

The helper automatically:

1. Runs all verifications with the global two-second condition timeout.
2. Captures a full-surface PNG only after every condition is satisfied.
3. Generates names such as `000-pending-dose.png`, scoped under the current surface.
4. Records the step description, verification results, and screenshot in the generated manifest for the current surface.
5. Generates the user-story `README.md` in configured cross-surface order.

The watchOS UI test uses `.watchOS` for `surface` and runs against the pinned paired Watch simulator. Apple screenshots are captured with `XCUIScreen.main.screenshot()` and retained as test attachments as well as exported baselines. A system notification step captures the real SpringBoard notification element itself, excluding unrelated wallpaper pixels that the Simulator renders nondeterministically.

## 4. Event-Driven Synchronization Only

Arbitrary waiting is forbidden. This includes:

* Playwright `page.waitForTimeout()` or any timer promise used as a delay.
* Swift `sleep`, `usleep`, `Thread.sleep`, `Task.sleep`, or delayed dispatch used to make a test pass.
* Fixed-interval polling loops, "settling" delays, or retry loops that hide a race.
* Playwright `networkidle` as a proxy for application readiness.

Tests wait only for a real, observable condition caused by the preceding action:

* **Web**: locator assertions, URL changes, request/response completion, WebSocket messages, or an explicit application readiness signal.
* **iOS/watchOS**: `waitForExistence(timeout:)`, `XCTNSPredicateExpectation`, accessibility value changes, expected notifications/callbacks, or an explicit application readiness signal.
* **Cross-device/backend**: a Firestore emulator snapshot, Auth state callback, notification delivery callback, or state-version change tied to the document created by the preceding user action.

Scheduled-dose, snooze, escalation, and retry scenarios may use an injected test clock and controllable production scheduler. Tests advance time and then await the real resulting notification or database event; they must not manufacture the medication event, call the response repository directly, or bypass Firebase.

## 5. Real Firebase Test Environment

Every E2E story that touches application data must run against a newly started Firebase emulator suite.

* Create advisor and subject accounts through the Authentication emulator. Do not encode UIDs or credentials in test source.
* Establish the household and memberships with an authenticated Firebase client while Firestore security rules are enabled. Never use an Admin SDK or disabled-rules context for E2E setup.
* Configure the dashboard with `VITE_` variables generated for that emulator run. Configure Apple clients with the same project ID and emulator endpoints.
* Create schedules through Lori's visible dashboard. The resulting medication event must be written through the production repository and observed by iOS/watchOS snapshot listeners.
* Verify Steve's response by observing the resulting Firestore update from Lori's dashboard. Do not mutate or assert against an in-memory copy.
* Emulator setup may generate credentials and write them to a permission-restricted temporary state file. This is infrastructure configuration, not story data; it must not pre-create schedules or dose events.

Production Firebase remains the target for a separate, narrowly controlled smoke test. Normal E2E runs never access production data.

### Current runners

Use `npm run e2e:local` for interactive cross-client testing. It starts a fresh
Auth/Firestore emulator suite, creates run-specific advisor and subject
identities, starts Lori's dashboard at
`http://127.0.0.1:5174/#/schedules`, launches the iOS app, and prints Steve's
credentials and household ID. A schedule entered in the browser must appear in
the app through its Firestore snapshot listener while the environment remains
running. Control-C tears down the isolated environment.

Use `npm run test:e2e:connected` for the automated dashboard stories and
`npm run ios:e2e:connected` for the full dashboard-to-system-notification story.
`npm run test:e2e` is an alias for the connected dashboard suite, and CI invokes
these connected runners. Preview-only visual checks use the explicitly named
`npm run test:ui:preview`; they are not end-to-end tests and must never be
presented as evidence of an end-to-end data flow.

## 6. Timing Requirements

The maximum acceptable timeout for **any condition is 2000 ms** on every platform.

* Configure Playwright action and assertion timeouts to `2000`.
* Pass at most `2.0` to XCTest expectations and element-existence waits.
* A timeout is a failure. Do not extend it, add a delay, or rely on test retries to conceal slow or missing signals.
* Operations that legitimately exceed two seconds must expose an earlier observable progress state. Verify and capture that state, then wait up to two seconds for the next event.
* CI records per-step and per-story durations so regressions remain visible. Runtime measurement never replaces condition-based synchronization.

## 7. Platform Configuration

### Web Admin Dashboard

* Run Chromium at a pinned version, viewport, device scale factor, color scheme, locale, and time zone.
* Use software-rendering flags such as `--disable-gpu` and `--font-render-hinting=none`.
* Disable CSS animations, transitions, blinking cursors, and live timestamps in E2E mode.
* Configure screenshot assertions for exact comparison: `threshold: 0`, `maxDiffPixels: 0`, and `maxDiffPixelRatio: 0`.

### iOS and watchOS

* Pin the Xcode version, simulator runtimes, iPhone model, Apple Watch model, pairing, language, locale, time zone, appearance, contrast, orientation, and content-size category in source-controlled configuration.
* Boot clean simulators from a known snapshot and install fresh test builds.
* Normalize status-bar values and inject a fixed clock so time, carrier, network, and battery pixels cannot drift.
* Disable animations through the E2E launch configuration; do not wait for animations to finish.
* Compare exported PNGs at native simulator resolution using an exact pixel comparator. Keep successful captures as `XCTAttachment` values with `.keepAlways`.

## 8. Required User-Story Walkthroughs

The numbered story suite must grow with the product. At minimum, it must document and verify:

* **Admin web dashboard**: authentication; schedule creation, editing, and disabling; medication labels; snooze and escalation rules; SMS destination; today's live states; historical compliance; and export.
* **iOS app**: notification permission and readiness; next-dose status; intrusive alert; "Yes, I will" snooze; repeat nag; "Yes, I did" completion; cancellation of further nags; history; and offline local fallback.
* **watchOS app**: ready/next-dose status; intrusive alert; both response actions; snooze count; completion feedback; and synchronization with the phone/backend.
* **Closed-loop system**: a schedule created by Lori reaches both Apple clients; a Steve action appears on Lori's dashboard; an overdue unconfirmed dose produces exactly one captured SMS-gateway fixture and an escalated dashboard state.

Haptics, sounds, outbound SMS, and other nonvisual effects still require programmatic verification of the emitted event or gateway request. The screenshot documents the accompanying visible state.

## 9. Walkthrough and Baseline Rules

Each generated `README.md` is reviewable product documentation, not a raw test log. It must contain:

1. The user-story title and "As a... I want... so that..." narrative.
2. Deterministic emulator preconditions and generated test-environment identity.
3. Ordered steps with plain-language actions and expected outcomes.
4. Verification results and committed screenshots for every participating surface.
5. Explicit `not-applicable` explanations for omitted surfaces.

Generated files must be reproducible byte-for-byte from a clean checkout. CI fails if tests change a screenshot, manifest, or walkthrough without the regenerated artifact being committed. Baselines are created and reviewed on the pinned CI environment; local captures are diagnostic unless they reproduce that environment exactly.
