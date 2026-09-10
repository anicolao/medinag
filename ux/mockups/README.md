# MediNag UX Mockup Provenance

These directional mockup boards accompany `UX_DESIGN.md`. They were generated
with the built-in image-generation tool in `ui-mockup` mode and copied into the
repository for design review.

## Administrator web flow

Output: `admin-web-flow.png`

Style references:

- `tests/e2e/002-manage-schedules/screenshots/002-schedule-created.png`
- `tests/e2e/004-ios-respond-to-dose/screenshots/web/002-event-observed-on-dashboard.png`

Final prompt summary:

> Create a shippable three-panel MediNag desktop board for administrator Google
> sign-in, publishing one schedule with a public schedule code and share link,
> and configuring reminder defaults plus administrator name and escalation SMS
> number. Preserve the existing deep-teal navigation, pale canvas, white cards,
> coral actions, typography, spacing, and medical-product tone. Exclude household
> IDs, invitations, patient passwords, and pre-created membership language.

## Patient iPhone flow

Output: `patient-ios-flow.png`

Style references:

- `tests/e2e/004-ios-respond-to-dose/screenshots/ios/000-subject-sign-in.png`
- `tests/e2e/004-ios-respond-to-dose/screenshots/ios/001-firestore-event-received.png`
- `tests/e2e/004-ios-respond-to-dose/screenshots/ios/005-first-reminder-response.png`

Final prompt summary:

> Create a shippable four-panel native iPhone board for Google sign-in, choosing
> a public administrator schedule by name or code, the linked Today screen, and
> an equal-weight reminder response screen. Preserve the existing pale-mint
> canvas, oversized dark-teal type, rounded white cards, teal and orange accents,
> generous spacing, and native iOS feel. Exclude household IDs, email/password
> fields, pre-created membership language, phone-side schedule editing, and any
> default reminder response.

The written requirements in `UX_DESIGN.md` are authoritative when generated text
or detail in a board is ambiguous.
