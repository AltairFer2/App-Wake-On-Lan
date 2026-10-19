package com.altair.altair_wake

import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import com.altair.altair_wake.rdp.RdpChannel
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        RdpChannel(applicationContext, flutterEngine).register()
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, REMOTE_DESKTOP_CHANNEL)
            .setMethodCallHandler { call, result ->
                val link = call.argument<String>("link")
                val clientPackage = call.argument<String>("package")
                when {
                    call.method != "open" -> result.notImplemented()
                    link == null || clientPackage == null ->
                        result.error("invalid_arguments", "Faltan link o package.", null)
                    else -> result.success(openRemoteDesktop(link, clientPackage))
                }
            }
    }

    /**
     * Prueba en orden: el enlace rdp:// (abre la conexión), la app cliente y
     * su ficha en Google Play. Devuelve el nombre de RemoteDesktopLaunch.
     */
    private fun openRemoteDesktop(link: String, clientPackage: String): String {
        if (tryStart(Intent(Intent.ACTION_VIEW, Uri.parse(link)))) return "connection"
        val launch = packageManager.getLaunchIntentForPackage(clientPackage)
        if (launch != null && tryStart(launch)) return "clientApp"
        val store = Intent(Intent.ACTION_VIEW, Uri.parse("market://details?id=$clientPackage"))
        if (tryStart(store)) return "store"
        return "unavailable"
    }

    private fun tryStart(intent: Intent): Boolean =
        try {
            startActivity(intent)
            true
        } catch (e: ActivityNotFoundException) {
            false
        }

    private companion object {
        const val REMOTE_DESKTOP_CHANNEL = "lazy_wake_up/remote_desktop"
    }
}
