package com.chrolingo.app

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import org.json.JSONArray

/**
 * Расписание напоминаний на будильниках Android.
 *
 * ═══ ПОЧЕМУ РАСПИСАНИЕ ХРАНИТСЯ ЦЕЛИКОМ ═══
 *
 * Будильник не переживает перезагрузку телефона: система забывает все
 * заведённые alarm'ы. Единственный способ их вернуть — дождаться
 * BOOT_COMPLETED и завести заново, а для этого нужно знать, что именно
 * было заведено. Приложение в этот момент не запущено и спросить его
 * нельзя, поэтому весь план лежит текстом в настройках.
 *
 * ═══ ПОЧЕМУ НЕТОЧНЫЕ БУДИЛЬНИКИ ═══
 *
 * `setAndAllowWhileIdle` переживает режим сна и НЕ требует разрешения.
 * Точные (`setExactAndAllowWhileIdle`) с Android 14 требуют отдельного
 * разрешения, которое игрок должен выдать руками. «Около восьми
 * вечера» — ровно та точность, которая нужна напоминанию.
 */
object ReminderAlarms {

    const val EXTRA_ID = "chrolingo.reminder.id"

    private const val PREFS = "chrolingo.reminders"
    private const val KEY_PLAN = "plan"
    private const val WEEK_MS = 7L * 24 * 60 * 60 * 1000

    /** Заменить расписание целиком. [plan] — массив JSON из Dart. */
    fun schedule(context: Context, plan: String) {
        cancelAll(context)
        prefs(context).edit().putString(KEY_PLAN, plan).apply()
        arm(context, JSONArray(plan))
    }

    /** Завести заново то, что уже сохранено: после перезагрузки. */
    fun rearm(context: Context) {
        val plan = prefs(context).getString(KEY_PLAN, null) ?: return
        arm(context, JSONArray(plan))
    }

    fun cancelAll(context: Context) {
        val plan = prefs(context).getString(KEY_PLAN, null)
        if (plan != null) {
            val array = JSONArray(plan)
            for (i in 0 until array.length()) {
                val id = array.getJSONObject(i).getInt("id")
                val pending = pending(context, id, PendingIntent.FLAG_NO_CREATE)
                if (pending != null) alarms(context).cancel(pending)
                ChrolingoNotification.manager(context).cancel(id)
            }
        }
        prefs(context).edit().remove(KEY_PLAN).apply()
    }

    /** Что показывать по будильнику с этим номером. */
    fun find(context: Context, id: Int): NotificationSpec? {
        val plan = prefs(context).getString(KEY_PLAN, null) ?: return null
        val array = JSONArray(plan)
        for (i in 0 until array.length()) {
            val json = array.getJSONObject(i)
            if (json.getInt("id") == id) return NotificationSpec.fromJson(json)
        }
        return null
    }

    /** Повторяющееся напоминание заводит само себя на неделю вперёд. */
    fun rearmWeekly(context: Context, spec: NotificationSpec) {
        val pending = pending(context, spec.id, PendingIntent.FLAG_UPDATE_CURRENT) ?: return
        alarms(context).setAndAllowWhileIdle(
            AlarmManager.RTC_WAKEUP,
            System.currentTimeMillis() + WEEK_MS,
            pending,
        )
    }

    private fun arm(context: Context, array: JSONArray) {
        val now = System.currentTimeMillis()
        for (i in 0 until array.length()) {
            val spec = NotificationSpec.fromJson(array.getJSONObject(i))
            var at = spec.at ?: continue
            if (at <= now) {
                // Прошедший момент система показала бы НЕМЕДЛЕННО —
                // посреди дня, без повода. Разовое просто пропускаем,
                // повторяющееся подтягиваем вперёд целыми неделями.
                if (!spec.repeatWeekly) continue
                while (at <= now) at += WEEK_MS
            }
            val pending = pending(context, spec.id, PendingIntent.FLAG_UPDATE_CURRENT) ?: continue
            alarms(context).setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pending)
        }
    }

    private fun pending(context: Context, id: Int, flags: Int): PendingIntent? {
        val intent = Intent(context, ReminderAlarmReceiver::class.java)
            .putExtra(EXTRA_ID, id)
        return PendingIntent.getBroadcast(
            context,
            id,
            intent,
            flags or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun alarms(context: Context): AlarmManager =
        context.getSystemService(Context.ALARM_SERVICE) as AlarmManager

    private fun prefs(context: Context) =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
}
