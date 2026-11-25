package com.example.nova_health;

import android.app.AlarmManager;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import com.dexterous.flutterlocalnotifications.ScheduledNotificationBootReceiver;
import com.dexterous.flutterlocalnotifications.ScheduledNotificationReceiver;
import java.time.Instant;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

public final class ReminderBootReceiver extends BroadcastReceiver {
    // flutter_local_notifications 20.x persists alarm requests in this cache.
    private static final String CACHE = "scheduled_notifications";

    @Override
    public void onReceive(Context context, Intent intent) {
        String action = intent.getAction();
        boolean invalidate = Intent.ACTION_TIMEZONE_CHANGED.equals(action)
                || Intent.ACTION_MY_PACKAGE_REPLACED.equals(action);
        boolean boot = Intent.ACTION_BOOT_COMPLETED.equals(action)
                || "android.intent.action.QUICKBOOT_POWERON".equals(action)
                || "com.htc.intent.action.QUICKBOOT_POWERON".equals(action);
        if (!invalidate && !boot) return;

        SharedPreferences preferences = context.getSharedPreferences(CACHE, Context.MODE_PRIVATE);
        JSONArray retained = new JSONArray();
        Instant now = Instant.now();
        try {
            JSONArray cached = new JSONArray(preferences.getString(CACHE, "[]"));
            for (int i = 0; i < cached.length(); i++) {
                JSONObject entry = cached.optJSONObject(i);
                if (entry == null) continue;
                int id = entry.optInt("id", -1);
                if (id < 1) continue;
                if (boot && id <= 60 && ReminderRestorePolicy.isFutureReminder(
                        entry.optString("payload"), entry.optString("timeZoneName"),
                        entry.optString("scheduledDateTime"), now)) {
                    retained.put(entry);
                } else {
                    cancelAlarm(context, id);
                }
            }
        } catch (JSONException invalidCache) {
            // A damaged cache cannot be safely replayed.
        }
        if (invalidate) {
            NotificationManager manager = context.getSystemService(NotificationManager.class);
            if (Intent.ACTION_MY_PACKAGE_REPLACED.equals(action)) {
                manager.cancelAll(); // Clear legacy previews when upgrading.
            } else {
                // A time-zone change invalidates medication times only.
                for (int id = 1; id <= 60; id++) {
                    manager.cancel(id);
                }
                manager.cancel(900001); // Reminder test.
            }
        }
        if (preferences.edit().putString(CACHE, retained.toString()).commit() && boot) {
            new ScheduledNotificationBootReceiver().onReceive(context, intent);
        }
    }

    private void cancelAlarm(Context context, int id) {
        Intent scheduled = new Intent(context, ScheduledNotificationReceiver.class);
        PendingIntent pending = PendingIntent.getBroadcast(
                context, id, scheduled, PendingIntent.FLAG_NO_CREATE | PendingIntent.FLAG_IMMUTABLE);
        if (pending != null) {
            context.getSystemService(AlarmManager.class).cancel(pending);
            pending.cancel();
        }
    }
}
