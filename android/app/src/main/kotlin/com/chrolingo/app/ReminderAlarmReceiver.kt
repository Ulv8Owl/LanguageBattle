package com.chrolingo.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Кто показывает вечернее напоминание.
 *
 * Приложения в этот момент нет. Есть будильник, этот класс и то, что
 * лежит в настройках, — поэтому ни строчки Dart здесь позвать нельзя.
 *
 * Он же ловит перезагрузку телефона: система забывает все заведённые
 * будильники, и без этого напоминания молча прекращаются до следующего
 * запуска приложения.
 */
class ReminderAlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_MY_PACKAGE_REPLACED,
            "android.intent.action.QUICKBOOT_POWERON",
            "com.htc.intent.action.QUICKBOOT_POWERON" -> {
                ReminderAlarms.rearm(context)
                // Виджет после перезагрузки система нарисует сама, но
                // нарисует ПРОШЛЫМ состоянием: день мог смениться, пока
                // телефон был выключен.
                ChrolingoWidget.refresh(context)
                return
            }
        }

        val id = intent.getIntExtra(ReminderAlarms.EXTRA_ID, -1)
        if (id < 0) return
        val spec = ReminderAlarms.find(context, id) ?: return
        ChrolingoNotification.post(context, spec)
        // Раз уж проснулись — и виджет заодно: к вечеру нарисованное
        // утром уже устарело.
        ChrolingoWidget.refresh(context)
        if (spec.repeatWeekly) ReminderAlarms.rearmWeekly(context, spec)
    }
}
