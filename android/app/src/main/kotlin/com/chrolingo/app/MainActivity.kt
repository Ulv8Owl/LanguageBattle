package com.chrolingo.app

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Уведомления со своей разметкой. Плагин так не умеет, а без
        // своей разметки нет ни цветной плашки, ни крупного таймера.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, RichNotifications.CHANNEL)
            .setMethodCallHandler(RichNotifications(applicationContext))
    }
}
