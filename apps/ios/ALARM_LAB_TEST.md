# Physical Stop/retry comparison

Current controlled A/B experiment: [Presentation-path test](PRESENTATION_PATH_TEST.md).
The older comparisons below are historical and are not the current procedure.

## Minimal TestFlight baseline — test this first

The `MediNagAlarmBaseline` executable replaces the patient app through the
existing Alex Phone Trial channel. It uses the patient bundle identity but does
not compile the patient engine, Firebase, custom intents, shared widget metadata,
Live Activity extension, custom sound, countdown, Snooze or retries. It registers
exactly one `.fixed` AlarmKit alarm with `.default` sound and ordinary system
Stop. The required `AlarmAttributes` use an empty metadata type, nil metadata,
and only the system alert presentation. No app-created ActivityKit activity is
requested. This does not claim Apple's public AlarmKit path is identical to
Clock's internal implementation.

Hypothesis: the richer configuration or its lifecycle interactions cause the
missing presentation. This baseline isolates the public API's simplest path.
It is not a medication scheduler and is not a proposed permanent simplification.

1. Install the baseline TestFlight build; open **MediNag Baseline**.
2. Finish/cancel any run in the separate Alarm Lab, and keep the Watch off for
   a strictly phone-only comparison. In Baseline tap **Prepare baseline test**.
   This explicitly clears existing MediNag phone alarms/notifications. It does
   not alter Firebase medication records or cancel alarms in Clock or the Lab.
3. Choose a future date/time and tap **Arm baseline alarm**. Verify the displayed
   registration. Set a native Clock alarm two minutes later as a control.
4. Lock the phone. Record the actual time of sound/UI for each alarm, and use
   ordinary system Stop after observing it. If Baseline sounds only when the
   Clock alarm or your interaction wakes the phone, it failed its deadline.
5. Repeat after a long idle/overnight interval under the same conditions. A
   successful one-minute test does not establish overnight reliability.

Preserve the baseline report and USB system logs. A baseline failure requires
examining this small executable/SDK/device state; success means add features one
at a time until the failure returns, not declare the production app fixed. This
diagnostic still needs physical presentation/sound observations. Its automated
check only exercises actual permission, registration, persistence and cancellation.

Release: `MEDINAG_TESTFLIGHT_GROUP='Alex Phone Trial' npm run ios:testflight:alarm-baseline`.
Smoke check: `bash apps/ios/scripts/check-alarm-lab.sh MediNagAlarmBaseline`.
After testing, reinstall the patient build and open it online to rebuild its
schedule. Its durable patient records and server data are not erased by Baseline.
The server's existing overdue/coverage SMS policies remain active during this
diagnostic; no test mode has silently disabled them.

## Separate local Alarm Lab

MediNag Alarm Lab is a separate development-installed app:
`org.boardgamescafe.medinag.alarmlab`. It does not replace MediNag, read Firebase,
write medication responses, or cancel the patient app's alarms. These are
explicit user-created diagnostic alarms, not a production E2E simulation.

## First run: A

1. Open **MediNag Alarm Lab**, select **A — Ordinary system Stop**, and tap
   **Arm three test alarms**. Allow Alarms for this app when asked.
2. Note the three displayed deadlines (first in one minute, then +3 and +6
   minutes). Lock the phone before the first. Keep Watch, Focus, volume and
   silent-mode conditions the same in every comparison. For a strictly
   phone-only comparison, keep the Watch powered off throughout both runs.
3. Tap the **system Stop** on the first alarm. Do not use Snooze. Lock the phone
   again. Do not interact with the two follow-ups; note whether each makes sound
   and presents UI, and the actual times. OS `alerting` is not a substitute for
   those observations. Missing the deadline is a failure; do not wait hours.
4. After the last expected time, open the Lab and tap **Finish test** in the top
   toolbar. This cancels all alarms owned by the Lab, not MediNag.

## Second run: C

Repeat with **C — Stop and open app**, under the same conditions. Stop on the
first should open a diagnostic response screen. Do not finish the run or respond
there: lock the phone again and leave the two follow-ups untouched. End the run
only after the last expected deadline and record perceived times as in A.

If A and C differ, run **B — Background Stop intent** to distinguish having a
custom intent at all from requesting deferred foreground execution. All modes
use the same named sound, fixed-date schedule, post-alert countdown, Snooze
presentation and metadata. Only Stop behavior differs. None schedules anything
inside its Stop handler; all three alarms must already be verified before the
user leaves the setup screen.

The Lab's foreground handler deliberately does **not** include the patient
engine/Firebase work. It isolates the OS foreground mode; it is not an exact
production reproduction. Three alarms also do not reproduce the patient's full
55-alarm inventory. A successful Lab comparison must not be claimed as a fix or
as proof that production works. If both modes fail or both succeed, keep testing
these remaining variables rather than declaring a cause.

## Evidence and cleanup

The Lab keeps run IDs, mode, OS version, time zone, exact requested dates,
SDK registration verification, Stop entry/return and observed OS states in
`Application Support/alarm-lab.json`. **Share diagnostic report** exports all
runs. State observation times mean when code observed a state, not when a sound
began. Ordinary Stop has no app handler, so system logs are needed to time it.

While USB-connected, capture phone system logs promptly after the failed run:

```sh
sudo /usr/bin/log collect --device-name 'Alex Nicolaou’s iPhone' --last 30m --output /tmp/medinag-alarm-lab.logarchive
```

Record the human observations too. The system's `Sound Played: nil` appears even
for the known-working initial 10 PM alarm; it is not by itself proof of silence.
Compare tone-posting, scene creation, identifiers, and actual observations.

Finish the run before beginning another or deleting the Lab. The Lab never
starts alarms automatically on installation or launch. MediNag remains a
separate experimental patient build, not validated protection.

## Reproduce installation and registration smoke test

```sh
bash apps/ios/scripts/install-alarm-lab.sh <iPhone identifier>
```

The installer resolves CoreDevice identity to the physical UDID, signs the two
new bundle identities with existing local Apple configuration, and installs
without launching or arming alarms. It requires an unlocked developer-enabled
phone and existing Apple signing authority. No TestFlight/app-store record is
required for this local development installation.

`MediNagAlarmDiagnosticUITests` uses the actual SDK and permission prompt to
check three registrations, restore and cancellation. Two-second condition waits,
no sleeps or forged callbacks. This is only a registration smoke test; actual
system Stop and timed audible delivery are the manual steps above.
