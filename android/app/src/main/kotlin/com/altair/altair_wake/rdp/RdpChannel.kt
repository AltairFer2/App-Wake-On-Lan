package com.altair.altair_wake.rdp

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.freerdp.freerdpcore.services.LibFreeRDP
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * Canales entre Flutter y FreeRDP. Admite una sola sesión a la vez.
 *
 * Métodos (lazy_wake_up/rdp): isSupported, connect, pointer, key, text,
 * answerCertificate, disconnect. Eventos (lazy_wake_up/rdp/events): mapas
 * con "type".
 */
class RdpChannel(private val context: Context, private val engine: FlutterEngine) {
    private val mainHandler = Handler(Looper.getMainLooper())
    // close() bloquea mientras FreeRDP termina: nunca en el hilo principal.
    private val worker = Executors.newSingleThreadExecutor()
    private var events: EventChannel.EventSink? = null
    private var session: RdpSession? = null

    fun register() {
        val messenger = engine.dartExecutor.binaryMessenger
        MethodChannel(messenger, METHOD_CHANNEL).setMethodCallHandler(::onMethodCall)
        EventChannel(messenger, EVENT_CHANNEL).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
                events = sink
            }

            override fun onCancel(arguments: Any?) {
                events = null
            }
        })
    }

    private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isSupported" -> result.success(LibFreeRDP.isAvailable())
            "connect" -> connect(call, result)
            "pointer" -> {
                session?.sendPointer(
                    call.argument<Int>("x") ?: 0,
                    call.argument<Int>("y") ?: 0,
                    call.argument<Int>("flags") ?: 0,
                )
                result.success(null)
            }
            "key" -> {
                session?.sendKey(
                    call.argument<Int>("virtualKey") ?: 0,
                    call.argument<Boolean>("down") ?: false,
                )
                result.success(null)
            }
            "text" -> {
                session?.sendText(call.argument<String>("text") ?: "")
                result.success(null)
            }
            "answerCertificate" -> {
                session?.answerCertificate(
                    call.argument<Int>("requestId") ?: -1,
                    call.argument<Boolean>("accept") ?: false,
                )
                result.success(null)
            }
            "disconnect" -> {
                val current = session
                session = null
                if (current == null) {
                    result.success(null)
                } else {
                    worker.execute {
                        current.close()
                        mainHandler.post { result.success(null) }
                    }
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun connect(call: MethodCall, result: MethodChannel.Result) {
        if (!LibFreeRDP.isAvailable()) {
            result.error("unsupported", LibFreeRDP.unavailableReason(), null)
            return
        }
        if (session != null) {
            result.error("busy", "Ya hay una sesión de escritorio remoto abierta.", null)
            return
        }
        val request = RdpConnectRequest(
            host = call.argument<String>("host") ?: "",
            port = call.argument<Int>("port") ?: 0,
            username = call.argument<String>("username") ?: "",
            password = call.argument<String>("password") ?: "",
            width = call.argument<Int>("width") ?: 0,
            height = call.argument<Int>("height") ?: 0,
            monitorLayout = (call.argument<List<Int>>("monitorLayout") ?: emptyList()).toIntArray(),
        )
        if (request.host.isEmpty() || request.port !in 1..65535 || request.width <= 0 || request.height <= 0) {
            result.error("invalid_arguments", "Host, puerto o tamaño no válidos.", null)
            return
        }
        val producer = engine.renderer.createSurfaceProducer()
        val created = RdpSession(context, producer) { event -> mainHandler.post { events?.success(event) } }
        val error = created.connect(request)
        if (error != null) {
            worker.execute { created.close() }
            result.error("connect_failed", error, null)
            return
        }
        session = created
        result.success(created.textureId)
    }

    private companion object {
        const val METHOD_CHANNEL = "lazy_wake_up/rdp"
        const val EVENT_CHANNEL = "lazy_wake_up/rdp/events"
    }
}
