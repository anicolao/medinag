# Test: US-003: Lori links her existing schedules to Google

> As Lori, I want to link my existing schedules to my Google account so that my work is preserved and ready to sync with Steve's devices.

## Surface coverage

- **Web Admin Dashboard:** covered
- **iOS:** not-applicable — Phase 1 establishes the shared Firebase contract before the iOS client is implemented.
- **watchOS:** not-applicable — The watchOS client is explicitly deferred until after the iOS MVP.

## Lori sees the schedule she entered in her anonymous Firebase workspace

![Lori sees the schedule she entered in her anonymous Firebase workspace](./screenshots/000-existing-guest-schedules.png)

**Verifications:**

- [x] The dashboard is connected as an anonymous Firebase user
- [x] The real Google linking action is available
- [x] The schedule written through the UI is visible before linking

## Lori links a Google-provider identity and Firestore migrates her schedule

![Lori links a Google-provider identity and Firestore migrates her schedule](./screenshots/001-google-account-linked.png)

**Verifications:**

- [x] The linked dashboard finishes rendering after the real Auth callback
- [x] The dashboard reports the linked Firebase identity
- [x] The migration confirms one preserved Firestore schedule
- [x] The migrated schedule arrives from the household Firestore collection
