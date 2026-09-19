package com.chrolingo.app

import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

/**
 * Мост Dart -> Android. Здесь только передача: что показывать и когда,
 * решает Dart (там это проверяется тестами), а как показывать — знают
 * [ChrolingoNotification] и [ChrolingoWidget], потому что и вечером, и
 * на рабочем столе Dart уже не запущен.
 */
class RichNotifications(private val context: android.content.Context) :
    MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "chrolingo/native"
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "show" -> {
                    val spec = NotificationSpec.fromJson(JSONObject(call.arguments as String))
                    ChrolingoNotification.post(context, spec)
                    result.success(true)
                }
                "schedule" -> {
                    ReminderAlarms.schedule(context, call.arguments as String)
                    result.success(true)
                }
                "cancelAll" -> {
                    ReminderAlarms.cancelAll(context)
                    result.success(true)
                }
                "widget" -> {
                    ChrolingoWidget.save(context, call.arguments as String)
                    result.success(true)
                }
                "dropChannels" -> {
                    ChrolingoNotification.dropChannels(
                        context,
                        org.json.JSONArray(call.arguments as String),
                    )
                    result.success(true)
                }
                "widgetDiagnose" -> result.success(ChrolingoWidget.diagnose(context))
                "widgetPin" -> result.success(ChrolingoWidget.requestPin(context))
                else -> result.notImplemented()
            }
        } catch (e: Throwable) {
            result.error("notification_failed", e.message, null)
        }
    }
}
