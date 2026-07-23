# Product Vision: MediNag (`medinag`)

## 1. Problem Statement

Standard medication reminder apps suffer from a fundamental flaw: **they are too easy to ignore or dismiss**. For subjects who get distracted, forget, or procrastinate taking their medication, standard iOS reminders or gentle chimes quickly blend into background noise. 

When medication compliance is critical, passive notifications are insufficient. A missed dose requires immediate persistent nagging and, if unfulfilled, an automated safety alert to a designated advisor.

---

## 2. Product Philosophy

`medinag` operates on three core principles:

1. **Zero Client Complexity for the Subject (Steve)**:
   The mobile app on Steve's iPhone and Apple Watch is an **execution-only client**. Steve cannot edit schedules, tweak rules, or disable reminders from the app. His only interaction with the app is responding to notifications.

2. **Intrusive Persistence**:
   Reminders must be persistent and attention-grabbing. The app uses prominent haptics, sound loops, and repeated notifications that demand a deliberate choice.

3. **Closed-Loop Verification & Advisor Escalation**:
   Every scheduled dose requires explicit confirmation. Tapping **"Yes, I did"** completes the loop. Tapping **"Yes, I will"** temporarily snoozes the nag. If the dose remains unconfirmed past the allowed window, the system automatically escalates by sending an SMS alert to Lori.

---

## 3. Personas & Responsibilities

### 👤 Steve (The Subject)
- **Devices**: iPhone & Apple Watch.
- **Experience**: Receives intrusive notifications at scheduled times.
- **Actions Available**:
  - **"Yes, I will"**: Snoozes the notification. The app will nag him again after the configured snooze interval.
  - **"Yes, I did"**: Confirms that the medication was taken. Registers the exact timestamp to the backend and cancels further nags for that dose.

### 👩‍💼 Lori (The Advisor & Administrator)
- **Interface**: Web Admin Dashboard (accessible from desktop/mobile browser).
- **Responsibilities**:
  - Sets medication schedules (times of day, dose descriptions).
  - Configures snooze intervals and maximum allowed snooze cycles.
  - Sets the escalation deadline (e.g., if unconfirmed 30 minutes after scheduled time, trigger SMS).
  - Configures target phone number for SMS alerts.
  - Monitors compliance logs and dose history.

---

## 4. Interaction UX Model

```text
[ Scheduled Time Reached ]
          │
          ▼
   🔔 Intrusive Alert on iPhone & Watch
          │
    ┌─────┴────────────────────────┐
    ▼                              ▼
 Taps "Yes, I will"         Taps "Yes, I did"
    │                              │
    ├─> Snoozes timer              └─> Logs completion timestamp to DB
    └─> Nags again in N mins           Cancels all upcoming alerts
                                       Dose complete!

───────────────────────────────────────────────────────────
   ⚠️ FAILSAFE ESCALATION TIMEOUT (Unconfirmed Dose)
───────────────────────────────────────────────────────────
  If (Now > Scheduled Time + Escalation Deadline) AND (Status != Completed):
    └──> Firebase Cloud Function triggers Twilio SMS to Lori:
         "ALERT: Steve has not confirmed taking his meds scheduled for 8:00 AM. Please check on him!"
```

---

## 5. Future Growth & Roadmap

- **Phase 1 (MVP)**: iOS + watchOS Notification Receiver, Web Admin Dashboard, Firebase Firestore + Cloud Functions, Twilio SMS escalation.
- **Phase 2 (iOS Critical Alerts Entitlement)**: Apply for Apple Critical Alerts permission to override Silent Mode and Do Not Disturb settings.
- **Phase 3 (Stand-alone watchOS App)**: Support standalone Apple Watch operation with local notification fallback if disconnected from iPhone.
