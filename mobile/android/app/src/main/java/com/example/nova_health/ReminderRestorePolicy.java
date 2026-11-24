package com.example.nova_health;

import java.time.DateTimeException;
import java.time.Instant;
import java.time.LocalDateTime;
import java.time.ZoneOffset;

final class ReminderRestorePolicy {
    private ReminderRestorePolicy() {}

    static boolean isFutureReminder(String payload, String zone, String scheduledDateTime, Instant now) {
        if (!payload.startsWith("nova-reminder-v2:") || !"UTC".equals(zone)) {
            return false;
        }
        try {
            return LocalDateTime.parse(scheduledDateTime).toInstant(ZoneOffset.UTC).isAfter(now);
        } catch (DateTimeException invalidDate) {
            return false;
        }
    }
}
