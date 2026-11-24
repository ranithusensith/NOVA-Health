package com.example.nova_health;

import java.time.Instant;

/** Host JVM regression test. Requires only the JDK. */
public final class ReminderRestorePolicyTest {
    public static void main(String[] args) {
        Instant restart = Instant.parse("2026-11-02T00:00:00Z");
        String batch = "nova-reminder-v2:synthetic";
        check(ReminderRestorePolicy.isFutureReminder(batch, "UTC", "2026-11-02T00:01:00", restart));
        check(!ReminderRestorePolicy.isFutureReminder(batch, "UTC", "2026-11-01T23:59:00", restart));
        check(!ReminderRestorePolicy.isFutureReminder(batch, "UTC", "2026-11-02T00:00:00", restart));
        check(!ReminderRestorePolicy.isFutureReminder("medications", "UTC", "2026-11-02T00:01:00", restart));
        check(!ReminderRestorePolicy.isFutureReminder(batch, "America/New_York", "2026-11-02T00:01:00", restart));
        check(!ReminderRestorePolicy.isFutureReminder(batch, "UTC", "invalid", restart));
    }

    private static void check(boolean condition) {
        if (!condition) throw new AssertionError("Unexpected reboot reminder eligibility");
    }
}
