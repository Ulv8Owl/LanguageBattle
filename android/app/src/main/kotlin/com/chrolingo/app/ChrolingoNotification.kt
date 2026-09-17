package com.chrolingo.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.media.AudioAttributes
import android.net.Uri
import android.os.Build
import android.os.SystemClock
import android.view.View
import android.widget.RemoteViews
import org.json.JSONObject

/**
 * Одно уведомление: из чего состоит и как его показать.
 *
 * ═══ ПОЧЕМУ ЭТО ОТДЕЛЬНО ОТ МОСТА С FLUTTER ═══
 *
 * Вечернее напоминание показывает BroadcastReceiver, разбуженный
 * будильником. Приложения в этот момент нет: ни Activity, ни движка
 * Flutter, ни Dart-кода. Значит, всё, что нужно для показа, обязано
 * лежать здесь и уметь собираться из сохранённого текста.
 *
 * ═══ ЧЕГО НЕЛЬЗЯ, И ЭТО ПРОВЕРЕНО ПО ДОКУМЕНТАЦИИ ═══
 *
 * Шапку с именем приложения убрать нельзя, пока targetSdk >= 31:
 * «For apps targeting Android 12, notifications with custom content
 * views will no longer use the full notification area; instead, the
 * system applies a standard template». Там же — про высоту: свёрнутое
 * уведомление ужато со 106dp до 48dp.
 */
data class NotificationSpec(
    val id: Int,
    val channelId: String,
    val channelName: String,
    val sound: String?,
    val title: String,
    val body: String,
    /** Имя ресурса настроения в res/drawable (`mascot_worried`). */
    val mascot: String?,
    val skin: String,
    /** Момент, до которого идёт обратный отсчёт. null — таймера нет. */
    val countdownUntil: Long?,
    /** Когда показать. null — немедленно. */
    val at: Long?,
    /** Повторять раз в неделю в тот же час. */
    val repeatWeekly: Boolean,
) {
    fun toJson(): JSONObject = JSONObject()
        .put("id", id)
        .put("channelId", channelId)
        .put("channelName", channelName)
        .put("sound", sound)
        .put("title", title)
        .put("body", body)
        .put("mascot", mascot)
        .put("skin", skin)
        .put("countdownUntil", countdownUntil)
        .put("at", at)
        .put("repeatWeekly", repeatWeekly)

    companion object {
        fun fromJson(json: JSONObject): NotificationSpec = NotificationSpec(
            id = json.getInt("id"),
            channelId = json.getString("channelId"),
            channelName = json.getString("channelName"),
            sound = json.optStringOrNull("sound"),
            title = json.optString("title", ""),
            body = json.optString("body", ""),
            mascot = json.optStringOrNull("mascot"),
            skin = json.optString("skin", "gold"),
            countdownUntil = json.optLongOrNull("countdownUntil"),
            at = json.optLongOrNull("at"),
            repeatWeekly = json.optBoolean("repeatWeekly", false),
        )
    }
}

private fun JSONObject.optStringOrNull(key: String): String? =
    if (isNull(key)) null else optString(key, "").ifEmpty { null }

private fun JSONObject.optLongOrNull(key: String): Long? =
    if (isNull(key)) null else optLong(key).takeIf { it != 0L }

object ChrolingoNotification {

    private data class Skin(val background: String, val title: Int, val body: Int)

    /** Расцветки. Имена приходят из Dart, цвета живут здесь — рядом с
     * разметкой, которую они красят. */
    private val SKINS = mapOf(
        "gold" to Skin("notification_bg_gold", 0xFF0D0D10.toInt(), 0xCC0D0D10.toInt()),
        "ember" to Skin("notification_bg_ember", 0xFFFFFFFF.toInt(), 0xE6FFFFFF.toInt()),
    )

    fun post(context: Context, spec: NotificationSpec) {
        ensureChannel(context, spec)
        val skin = SKINS[spec.skin] ?: SKINS.getValue("gold")

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, spec.channelId)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(context).setPriority(Notification.PRIORITY_MAX)
        }

        val open = context.packageManager.getLaunchIntentForPackage(context.packageName)
        if (open != null) {
            builder.setContentIntent(
                PendingIntent.getActivity(
                    context,
                    spec.id,
                    open,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                )
            )
        }

        builder
            .setSmallIcon(resource(context, "ic_notification", "drawable"))
            // Заголовок и текст системе нужны и при своей разметке: по
            // ним уведомление читает экран блокировки и озвучивает
            // TalkBack, а RemoteViews они не видят.
            .setContentTitle(spec.title)
            .setContentText(spec.body)
            .setAutoCancel(true)
            // Единственное, что из шапки вообще убирается, — штамп
            // времени. Имя приложения рисует система.
            .setShowWhen(false)
            .setCategory(Notification.CATEGORY_REMINDER)
            .setStyle(Notification.DecoratedCustomViewStyle())
            // Внутри своих уведомлений порядок задаём сами: у срочного
            // ключ меньше — значит выше. Между ПРИЛОЖЕНИЯМИ порядок
            // решает система, и повлиять на него нельзя ничем.
            .setSortKey(if (spec.countdownUntil == null) "1" else "0")

        builder.setCustomContentView(views(context, spec, skin))
        builder.setCustomHeadsUpContentView(views(context, spec, skin))
        builder.setCustomBigContentView(views(context, spec, skin))

        manager(context).notify(spec.id, builder.build())
    }

    private fun views(
        context: Context,
        spec: NotificationSpec,
        skin: Skin,
    ): RemoteViews {
        val views = RemoteViews(
            context.packageName,
            resource(context, "notification_chrolingo", "layout"),
        )
        val root = resource(context, "reminder_root", "id")
        val timer = resource(context, "reminder_timer", "id")
        val title = resource(context, "reminder_title", "id")
        val body = resource(context, "reminder_body", "id")
        val mascot = resource(context, "reminder_mascot", "id")

        views.setInt(root, "setBackgroundResource",
            resource(context, skin.background, "drawable"))
        views.setTextViewText(title, spec.title)
        views.setTextColor(title, skin.title)
        views.setTextViewText(body, spec.body)
        views.setTextColor(body, skin.body)

        if (spec.countdownUntil == null) {
            views.setViewVisibility(timer, View.GONE)
            views.setViewVisibility(title, View.VISIBLE)
        } else {
            // ЗАГОЛОВОК УСТУПАЕТ МЕСТО ЦИФРАМ, а не теснится рядом с
            // ними: во всплывающем уведомлении около 88dp высоты, и на
            // всё сразу её не хватает.
            views.setViewVisibility(title, View.GONE)
            views.setViewVisibility(timer, View.VISIBLE)
            views.setTextColor(timer, skin.title)
            // Chronometer считает от ЗАГРУЗКИ УСТРОЙСТВА, а не от 1970
            // года. Передать ему обычные миллисекунды — это счётчик на
            // полвека.
            val base = SystemClock.elapsedRealtime() +
                (spec.countdownUntil - System.currentTimeMillis())
            views.setChronometerCountDown(timer, true)
            views.setChronometer(timer, base, null, true)
        }

        // КАРТИНКА — РЕСУРСОМ, А НЕ КАРТИНКОЙ. `setImageViewBitmap`
        // отправляет пиксели в системный процесс как есть (616x688 —
        // это 1,7 МБ в одной посылке, а размер посылки ограничен), и
        // при переполнении уведомление просто не приходит. Ресурс же
        // уезжает одним числом, а рисунок система берёт из нашего APK —
        // и берёт даже тогда, когда приложение ни разу не запускали.
        val drawable = optionalResource(context, spec.mascot, "drawable")
        if (drawable != 0) views.setImageViewResource(mascot, drawable)
        return views
    }

    private fun ensureChannel(context: Context, spec: NotificationSpec) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = manager(context)
        if (manager.getNotificationChannel(spec.channelId) != null) return
        val channel = NotificationChannel(
            spec.channelId,
            spec.channelName,
            NotificationManager.IMPORTANCE_HIGH,
        )
        val sound = spec.sound
        if (sound != null) {
            channel.setSound(
                Uri.parse("android.resource://${context.packageName}/raw/$sound"),
                AudioAttributes.Builder()
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .setUsage(AudioAttributes.USAGE_NOTIFICATION)
                    .build(),
            )
        }
        manager.createNotificationChannel(channel)
    }

    fun manager(context: Context): NotificationManager =
        context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    // Ресурсы ищем ПО ИМЕНИ, а не через сгенерированный R: имя одно и то
    // же в Dart, в keep.xml и здесь, и его видно глазами.
    internal fun resource(context: Context, name: String, type: String): Int {
        val id = context.resources.getIdentifier(name, type, context.packageName)
        require(id != 0) { "нет ресурса $type/$name" }
        return id
    }

    /** То же, но для необязательного: 0 вместо исключения.
     *
     * Настроение приходит из Dart строкой. Опечатка в ней не должна
     * стоить уведомления целиком — без картинки оно всё равно придёт,
     * а без текста уже нет. */
    internal fun optionalResource(context: Context, name: String?, type: String): Int {
        if (name.isNullOrEmpty()) return 0
        return context.resources.getIdentifier(name, type, context.packageName)
    }
}
