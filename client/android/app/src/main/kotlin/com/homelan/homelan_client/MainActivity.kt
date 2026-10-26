package com.homelan.homelan_client

import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity

class MainActivity : FlutterFragmentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Запрет скриншотов, записи экрана и превью в списке недавних приложений.
        window.setFlags(WindowManager.LayoutParams.FLAG_SECURE, WindowManager.LayoutParams.FLAG_SECURE)
        requestMaxRefreshRate()
    }

    override fun onResume() {
        super.onResume()
        // Некоторые прошивки сбрасывают режим при возврате из фона.
        requestMaxRefreshRate()
    }

    /**
     * Многие телефоны (Samsung, Xiaomi, OnePlus...) по умолчанию держат приложения
     * на 60 Гц, пока те явно не попросят больше. Выбираем режим дисплея с
     * максимальной частотой при текущем разрешении (120/144 Гц, если есть).
     */
    private fun requestMaxRefreshRate() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
        @Suppress("DEPRECATION")
        val display = (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) display else windowManager.defaultDisplay)
            ?: return
        val current = display.mode
        val best = display.supportedModes
            .filter { it.physicalWidth == current.physicalWidth && it.physicalHeight == current.physicalHeight }
            .maxByOrNull { it.refreshRate } ?: return
        val params = window.attributes
        if (params.preferredDisplayModeId != best.modeId) {
            params.preferredDisplayModeId = best.modeId
            params.preferredRefreshRate = best.refreshRate
            window.attributes = params
        }
    }
}
