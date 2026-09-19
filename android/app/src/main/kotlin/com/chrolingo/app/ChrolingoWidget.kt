package com.chrolingo.app

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.os.Build
import android.os.SystemClock
import android.view.View
import android.widget.RemoteViews
import org.json.JSONObject

/**
 * Виджет на рабочем столе: настроение хамелеона, серия и время до
 * полуночи.
 *
 * ═══ ПОЧЕМУ ВИДЖЕТ, А НЕ УВЕДОМЛЕНИЕ ═══
 *
 * Уведомление с Android 12 ОБЯЗАНО нести шапку системы с именем
 * приложения: «For apps targeting Android 12, notifications with custom
 * content views will no longer use the full notification area; instead,
 * the system applies a standard template». У виджета такой шапки нет ни
 * у кого — всё пространство наше, включая фон и высоту. Ровно так и
 * устроено то, что рисует Duolingo: набор заранее нарисованных
 * настроений, свой фон и счётчик до полуночи.
 *
 * ═══ КТО ЕГО ОБНОВЛЯЕТ ═══
 *
 * Приложение — после занятия и на запуске, будильник напоминания —
 * вечером, и раз в час сама система, страховкой. Отсчёт до полуночи
 * между обновлениями тикает сам: `Chronometer` считает силами системы,
 * и ему всё равно, запущено ли приложение.
 */
class ChrolingoWidget : AppWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        for (id in appWidgetIds) {
            appWidgetManager.updateAppWidget(id, build(context))
        }
    }

    companion object {
        private const val PREFS = "chrolingo.widget"
        private const val KEY_STATE = "state"

        private data class Skin(val background: String, val title: Int, val body: Int)

        /** Имена совпадают с NotificationSkin в Dart плюс «сделано». */
        private val SKINS = mapOf(
            "gold" to Skin("widget_bg_gold", 0xFF0D0D10.toInt(), 0xCC0D0D10.toInt()),
            "ember" to Skin("widget_bg_ember", 0xFFFFFFFF.toInt(), 0xE6FFFFFF.toInt()),
            "ok" to Skin("widget_bg_ok", 0xFF0D0D10.toInt(), 0xCC0D0D10.toInt()),
        )

        /** Что о виджете знает САМА СИСТЕМА.
         *
         * Нужно потому, что «виджета нет в списке» — это два разных
         * случая, и снаружи они выглядят одинаково: система не нашла
         * провайдера вовсе (беда с манифестом или ресурсами) или нашла,
         * а список в лаунчере устарел. Первое лечится сборкой, второе —
         * перезагрузкой, и путать их значит чинить не то.
         */
        fun diagnose(context: Context): Map<String, Any> {
            val manager = AppWidgetManager.getInstance(context)
            val providers = manager
                ?.getInstalledProvidersForPackage(context.packageName, null)
                ?.size ?: 0
            val placed = manager
                ?.getAppWidgetIds(ComponentName(context, ChrolingoWidget::class.java))
                ?.size ?: 0
            val pinnable = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                (manager?.isRequestPinAppWidgetSupported ?: false)
            return mapOf(
                "providers" to providers,
                "placed" to placed,
                "pinnable" to pinnable,
            )
        }

        /**
         * Попросить систему поставить виджет, минуя список лаунчера.
         *
         * СПИСОК ВИДЖЕТОВ — САМОЕ НЕНАДЁЖНОЕ ЗВЕНО: лаунчер держит его в
         * кеше и после обновления приложения обновляет когда захочет, а
         * иногда только после перезагрузки. Этот путь в кеш не смотрит.
         */
        fun requestPin(context: Context): Boolean {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
            val manager = AppWidgetManager.getInstance(context) ?: return false
            if (!manager.isRequestPinAppWidgetSupported) return false
            return manager.requestPinAppWidget(
                ComponentName(context, ChrolingoWidget::class.java),
                null,
                null,
            )
        }

        /** Запомнить состояние и перерисовать. [state] — объект JSON. */
        fun save(context: Context, state: String) {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .edit()
                .putString(KEY_STATE, state)
                .apply()
            refresh(context)
        }

        /**
         * Перерисовать все поставленные виджеты.
         *
         * НИ ОДНОГО НЕ ПОСТАВЛЕНО — это не ошибка, а обычное дело:
         * виджет ставит игрок, и большинство не ставит никогда.
         */
        fun refresh(context: Context) {
            val manager = AppWidgetManager.getInstance(context) ?: return
            val ids = manager.getAppWidgetIds(
                ComponentName(context, ChrolingoWidget::class.java)
            )
            if (ids == null || ids.isEmpty()) return
            val views = build(context)
            for (id in ids) manager.updateAppWidget(id, views)
        }

        private fun build(context: Context): RemoteViews {
            val views = RemoteViews(
                context.packageName,
                ChrolingoNotification.resource(context, "widget_chrolingo", "layout"),
            )
            val root = id(context, "widget_root")
            val timer = id(context, "widget_timer")
            val title = id(context, "widget_title")
            val body = id(context, "widget_body")
            val mascot = id(context, "widget_mascot")

            val state = load(context)
            val skin = SKINS[state?.optString("skin")] ?: SKINS.getValue("gold")

            views.setInt(
                root,
                "setBackgroundResource",
                ChrolingoNotification.resource(context, skin.background, "drawable"),
            )
            views.setTextColor(title, skin.title)
            views.setTextColor(body, skin.body)

            if (state != null) {
                views.setTextViewText(title, state.optString("title"))
                views.setTextViewText(body, state.optString("body"))
                val drawable = ChrolingoNotification.optionalResource(
                    context, state.optString("mascot"), "drawable",
                )
                if (drawable != 0) views.setImageViewResource(mascot, drawable)
            }

            // Отсчёт до полуночи — только когда серия правда догорает.
            // Вечно тикающий счётчик перестают замечать на второй день.
            val until = state?.let { if (it.isNull("countdownUntil")) 0L else it.optLong("countdownUntil") } ?: 0L
            if (until > System.currentTimeMillis()) {
                views.setViewVisibility(timer, View.VISIBLE)
                views.setTextColor(timer, skin.title)
                // Chronometer считает от ЗАГРУЗКИ УСТРОЙСТВА, а не от
                // 1970 года: перепутать — счётчик на полвека.
                val base = SystemClock.elapsedRealtime() + (until - System.currentTimeMillis())
                views.setChronometerCountDown(timer, true)
                views.setChronometer(timer, base, null, true)
            } else {
                views.setViewVisibility(timer, View.GONE)
            }

            val open = context.packageManager.getLaunchIntentForPackage(context.packageName)
            if (open != null) {
                views.setOnClickPendingIntent(
                    root,
                    PendingIntent.getActivity(
                        context,
                        0,
                        open,
                        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                    ),
                )
            }
            return views
        }

        private fun load(context: Context): JSONObject? {
            val raw = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .getString(KEY_STATE, null) ?: return null
            return try {
                JSONObject(raw)
            } catch (e: Throwable) {
                null
            }
        }

        private fun id(context: Context, name: String): Int =
            ChrolingoNotification.resource(context, name, "id")
    }
}
