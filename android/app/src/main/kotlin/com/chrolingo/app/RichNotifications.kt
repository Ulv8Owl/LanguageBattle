package com.chrolingo.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.graphics.BitmapFactory
import android.media.AudioAttributes
import android.net.Uri
import android.os.Build
import android.os.SystemClock
import android.widget.RemoteViews
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Уведомление со СВОЕЙ разметкой — то, чего flutter_local_notifications
 * не умеет, а без чего не получить ни яркой подложки, ни крупного
 * тикающего таймера.
 *
 * ═══ ЧЕГО ЗДЕСЬ НЕЛЬЗЯ ДОБИТЬСЯ ВООБЩЕ ═══
 *
 * Строку «Chrolingo · Сейчас» убрать НЕЛЬЗЯ. С Android 12 приложение не
 * может нарисовать уведомление целиком: «Apps targeting Android 12 (API
 * level 31) or later can't create fully custom notifications. Instead,
 * the system applies a standard template». Своей остаётся только
 * ОБЛАСТЬ СОДЕРЖИМОГО (DecoratedCustomViewStyle), шапку рисует система.
 *
 * Что убрать всё-таки можно — слово «Сейчас»: `setShowWhen(false)`
 * выключает штамп времени, и от шапки остаётся одно имя приложения.
 *
 * Залить фон ВСЕЙ карточки (`setColorized`) тоже нельзя: «the coloring
 * will only be applied if the notification is for a foreground service
 * notification», а постоянная служба ради напоминания — это обман
 * системы и батарея игрока. Поэтому цветная плашка живёт внутри своей
 * разметки, а не под шапкой.
 */
class RichNotifications(private val context: Context) : MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "chrolingo/notifications"

        /** Значок в разметке — 44dp; 192px хватает даже самому плотному
         * экрану, а посылку между процессами не переполняет. */
        private const val MAX_IMAGE_PX = 192

        /** Расцветки. Имя приходит из Dart, цвета живут здесь — в одном
         * месте с разметкой, которую они красят. */
        private val SKINS = mapOf(
            "gold" to Skin("notification_bg_gold", 0xFF0D0D10.toInt(), 0xCC0D0D10.toInt()),
            "ember" to Skin("notification_bg_ember", 0xFFFFFFFF.toInt(), 0xE6FFFFFF.toInt()),
        )
    }

    private data class Skin(val background: String, val title: Int, val body: Int)

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "show") {
            result.notImplemented()
            return
        }
        try {
            show(call)
            result.success(true)
        } catch (e: Throwable) {
            result.error("show_failed", e.message, null)
        }
    }

    private fun show(call: MethodCall) {
        val id = call.argument<Int>("id") ?: 1
        val channelId = call.argument<String>("channelId") ?: "chrolingo.reminders.v1"
        val channelName = call.argument<String>("channelName") ?: "Напоминания"
        val sound = call.argument<String>("sound")
        val title = call.argument<String>("title") ?: ""
        val body = call.argument<String>("body") ?: ""
        val imagePath = call.argument<String>("imagePath")
        val skin = SKINS[call.argument<String>("skin")] ?: SKINS.getValue("gold")
        // Момент, до которого идёт обратный отсчёт, в обычном времени.
        // null — таймера нет.
        val countdownUntil = call.argument<Number>("countdownUntil")?.toLong()

        ensureChannel(channelId, channelName, sound)

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, channelId)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(context).setPriority(Notification.PRIORITY_MAX)
        }

        val open = context.packageManager.getLaunchIntentForPackage(context.packageName)
        if (open != null) {
            builder.setContentIntent(
                PendingIntent.getActivity(
                    context,
                    id,
                    open,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                )
            )
        }

        builder
            .setSmallIcon(drawable("ic_notification"))
            // Заголовок и текст системе всё равно нужны: по ним
            // уведомление читает экран блокировки и озвучивает
            // TalkBack, а своей разметки они не видят.
            .setContentTitle(title)
            .setContentText(body)
            .setAutoCancel(true)
            // Вот это и убирает «Сейчас» из шапки. Больше из неё убрать
            // нечего: имя приложения рисует система.
            .setShowWhen(false)
            .setCategory(Notification.CATEGORY_REMINDER)
            .setStyle(Notification.DecoratedCustomViewStyle())

        // Внутри своих уведомлений порядок задаём сами: у срочного ключ
        // меньше, значит оно выше. Между ПРИЛОЖЕНИЯМИ порядок решает
        // система — по важности канала и свежести, и повлиять на него
        // приложение не может ничем.
        builder.setSortKey(if (countdownUntil == null) "1" else "0")

        builder.setCustomContentView(view(skin, title, body, imagePath, countdownUntil))
        builder.setCustomHeadsUpContentView(view(skin, title, body, imagePath, countdownUntil))
        builder.setCustomBigContentView(view(skin, title, body, imagePath, countdownUntil))

        manager().notify(id, builder.build())
    }

    private fun view(
        skin: Skin,
        title: String,
        body: String,
        imagePath: String?,
        countdownUntil: Long?,
    ): RemoteViews {
        val views = RemoteViews(context.packageName, layout("notification_chrolingo"))
        val root = id("reminder_root")
        val timer = id("reminder_timer")
        val titleId = id("reminder_title")
        val bodyId = id("reminder_body")
        val mascot = id("reminder_mascot")

        views.setInt(root, "setBackgroundResource", drawable(skin.background))
        views.setTextViewText(titleId, title)
        views.setTextColor(titleId, skin.title)
        views.setTextViewText(bodyId, body)
        views.setTextColor(bodyId, skin.body)

        if (countdownUntil == null) {
            views.setViewVisibility(timer, android.view.View.GONE)
            views.setViewVisibility(titleId, android.view.View.VISIBLE)
        } else {
            // ЗАГОЛОВОК УСТУПАЕТ МЕСТО ТАЙМЕРУ, а не тесни́тся рядом с
            // ним: во всплывающем уведомлении есть около 88dp высоты, и
            // на крупные цифры плюс две строки текста её хватает ровно.
            views.setViewVisibility(titleId, android.view.View.GONE)
            views.setViewVisibility(timer, android.view.View.VISIBLE)
            views.setTextColor(timer, skin.title)
            // Chronometer считает в своём времени — от загрузки
            // устройства, а не от полуночи 1970 года. Перепутать их
            // значит получить счётчик, показывающий десятки лет.
            val base = SystemClock.elapsedRealtime() + (countdownUntil - System.currentTimeMillis())
            views.setChronometerCountDown(timer, true)
            views.setChronometer(timer, base, null, true)
        }

        val bitmap = if (imagePath == null) null else scaled(imagePath)
        if (bitmap != null) views.setImageViewBitmap(mascot, bitmap)
        return views
    }

    /**
     * Картинка, уменьшенная до размера значка.
     *
     * УМЕНЬШАТЬ ОБЯЗАТЕЛЬНО, И ЭТО НЕ ПРО ЭКОНОМИЮ. `setImageViewBitmap`,
     * в отличие от `setLargeIcon`, НЕ масштабирует ничего: картинка
     * уезжает в системный процесс как есть. Наши 616x688 — это 1,7 МБ в
     * одной посылке, а размер посылки между процессами ограничен. Всё,
     * что видит игрок при переполнении, — отсутствие уведомления.
     */
    private fun scaled(path: String): android.graphics.Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(path, bounds)
        val longest = maxOf(bounds.outWidth, bounds.outHeight)
        if (longest <= 0) return null
        var sample = 1
        while (longest / sample > MAX_IMAGE_PX) sample *= 2
        return BitmapFactory.decodeFile(
            path,
            BitmapFactory.Options().apply { inSampleSize = sample },
        )
    }

    private fun ensureChannel(channelId: String, name: String, sound: String?) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        if (manager().getNotificationChannel(channelId) != null) return
        val channel = NotificationChannel(channelId, name, NotificationManager.IMPORTANCE_HIGH)
        if (sound != null) {
            channel.setSound(
                Uri.parse("android.resource://${context.packageName}/raw/$sound"),
                AudioAttributes.Builder()
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .setUsage(AudioAttributes.USAGE_NOTIFICATION)
                    .build(),
            )
        }
        manager().createNotificationChannel(channel)
    }

    private fun manager() =
        context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    // Ресурсы ищем по ИМЕНИ, а не через сгенерированный R: имя одно и то
    // же и в Dart, и в keep.xml, и здесь, и его видно глазами.
    private fun drawable(name: String) = identifier(name, "drawable")

    private fun layout(name: String) = identifier(name, "layout")

    private fun id(name: String) = identifier(name, "id")

    private fun identifier(name: String, type: String): Int {
        val res = context.resources.getIdentifier(name, type, context.packageName)
        require(res != 0) { "нет ресурса $type/$name" }
        return res
    }
}
