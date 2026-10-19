package com.altair.altair_wake.rdp

import android.content.Context
import android.graphics.Bitmap
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.util.Log
import com.freerdp.freerdpcore.services.LibFreeRDP
import io.flutter.view.TextureRegistry
import java.util.concurrent.CompletableFuture
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/** Credenciales y tamaño solicitados para una sesión. */
data class RdpConnectRequest(
    val host: String,
    val port: Int,
    val username: String,
    val password: String,
    val width: Int,
    val height: Int,
    /** x, y, ancho, alto por monitor (el primero, principal). Vacío: uno solo. */
    val monitorLayout: IntArray = IntArray(0),
)

/**
 * Una sesión RDP de FreeRDP dibujada en una textura de Flutter.
 *
 * Hilos: FreeRDP invoca el Listener desde su hilo de red; el dibujo ocurre en
 * [renderThread] y los eventos hacia Flutter los entrega [emit] (que debe
 * pasarlos al hilo principal). El bitmap se protege con [frameLock].
 */
class RdpSession(
    private val context: Context,
    private val producer: TextureRegistry.SurfaceProducer,
    private val emit: (Map<String, Any?>) -> Unit,
) : LibFreeRDP.Listener {

    val textureId: Long get() = producer.id()

    private val mainHandler = Handler(Looper.getMainLooper())
    private val renderThread = HandlerThread("rdp-render").apply { start() }
    private val renderHandler = Handler(renderThread.looper)
    private val renderPending = AtomicBoolean(false)
    private val frameLock = Any()
    private var bitmap: Bitmap? = null

    private val pendingCertificates = mutableMapOf<Int, CompletableFuture<Boolean>>()
    private val nextCertificateId = AtomicInteger(1)
    private val ended = CountDownLatch(1)
    private var instance = 0L
    private var started = false
    private var credentials: RdpConnectRequest? = null
    private var inputFailureLogged = false

    init {
        producer.setCallback(object : TextureRegistry.SurfaceProducer.Callback {
            // Flutter recrea la superficie al volver del segundo plano.
            override fun onSurfaceAvailable() = requestRender()
        })
    }

    /** Devuelve un mensaje de error, o null si la conexión arrancó. */
    fun connect(request: RdpConnectRequest): String? {
        credentials = request
        instance = LibFreeRDP.newInstance(context, this)
        if (instance == 0L) return "No se pudo crear la sesión de FreeRDP."
        if (!LibFreeRDP.parseArguments(instance, arguments(request))) {
            return "Parámetros de conexión no válidos."
        }
        if (request.monitorLayout.size > MONITOR_VALUES &&
            !LibFreeRDP.setMonitorLayout(instance, request.monitorLayout)
        ) {
            return "Disposición de monitores no válida."
        }
        if (!LibFreeRDP.connect(instance)) return "No se pudo iniciar la conexión."
        started = true
        return null
    }

    fun sendPointer(x: Int, y: Int, flags: Int) {
        if (instance == 0L) return
        checkInput(LibFreeRDP.sendCursorEvent(instance, x, y, flags), "ratón")
    }

    fun sendKey(virtualKey: Int, down: Boolean) {
        if (instance == 0L) return
        checkInput(LibFreeRDP.sendKeyEvent(instance, virtualKey, down), "tecla")
    }

    /** Pulsa y suelta un carácter Unicode (una unidad UTF-16). */
    fun sendText(text: String) {
        if (instance == 0L) return
        for (unit in text) {
            checkInput(LibFreeRDP.sendUnicodeKeyEvent(instance, unit.code, true), "texto")
            checkInput(LibFreeRDP.sendUnicodeKeyEvent(instance, unit.code, false), "texto")
        }
    }

    /** Registra (una vez por sesión) que FreeRDP no aceptó un evento. */
    private fun checkInput(accepted: Boolean, kind: String) {
        if (accepted || inputFailureLogged) return
        inputFailureLogged = true
        Log.w(TAG, "FreeRDP no aceptó un evento de $kind")
    }

    /** Responde a una solicitud de confirmación de certificado. */
    fun answerCertificate(requestId: Int, accept: Boolean) {
        synchronized(pendingCertificates) { pendingCertificates.remove(requestId) }
            ?.complete(accept)
    }

    /**
     * Desconecta, espera a que termine el hilo de FreeRDP y libera todo.
     * Bloquea: llamar fuera del hilo principal.
     */
    fun close() {
        synchronized(pendingCertificates) {
            pendingCertificates.values.forEach { it.complete(false) }
            pendingCertificates.clear()
        }
        if (instance != 0L) {
            if (started) {
                LibFreeRDP.disconnect(instance)
                // Liberar la instancia con su hilo vivo provocaría un fallo nativo.
                ended.await(CLOSE_TIMEOUT_SECONDS, TimeUnit.SECONDS)
            }
            LibFreeRDP.freeInstance(instance)
            instance = 0L
        }
        renderThread.quitSafely()
        renderThread.join(RENDER_JOIN_MILLIS)
        // La textura de Flutter solo admite llamadas desde el hilo principal.
        mainHandler.post { producer.release() }
        synchronized(frameLock) {
            bitmap?.recycle()
            bitmap = null
        }
    }

    private fun arguments(request: RdpConnectRequest): Array<String> = buildList {
        add("LazyWakeUp")
        add("/gdi:sw")
        add("/v:${request.host}")
        add("/port:${request.port}")
        add("/size:${request.width}x${request.height}")
        add("/bpp:32")
        add("/gfx")
        add("/network:auto")
        add("/client-hostname:LazyWakeUp")
        add("/audio-mode:2") // sin audio
        add("-wallpaper")
        add("+fonts")
        add("/kbd:unicode:on")
        add("/log-level:WARN")
        if (request.username.isNotEmpty()) add("/u:${request.username}")
        if (request.password.isNotEmpty()) add("/p:${request.password}")
    }.toTypedArray()

    // ---- LibFreeRDP.Listener (hilos de FreeRDP) ----

    override fun onConnectionSuccess() = emit(mapOf("type" to "connected"))

    override fun onConnectionFailure() {
        val reason = LibFreeRDP.lastErrorString(instance)
        emit(mapOf("type" to "failed", "message" to reason))
        ended.countDown()
    }

    override fun onDisconnected() {
        emit(mapOf("type" to "disconnected"))
        ended.countDown()
    }

    override fun onSettingsChanged(width: Int, height: Int, bpp: Int) = resize(width, height)

    override fun onGraphicsResize(width: Int, height: Int, bpp: Int) = resize(width, height)

    override fun onGraphicsUpdate(x: Int, y: Int, width: Int, height: Int) {
        synchronized(frameLock) {
            val target = bitmap ?: return
            LibFreeRDP.updateGraphics(instance, target, x, y, width, height)
        }
        requestRender()
    }

    override fun onAuthenticate(
        username: StringBuilder,
        domain: StringBuilder,
        password: StringBuilder,
    ): Boolean {
        val request = credentials ?: return false
        if (username.isEmpty()) username.append(request.username)
        password.setLength(0)
        password.append(request.password)
        return true
    }

    override fun onVerifyCertificate(
        host: String, port: Long, commonName: String, subject: String,
        issuer: String, fingerprint: String, flags: Long,
    ): Int = askCertificate(
        mapOf(
            "host" to host, "port" to port, "subject" to subject,
            "issuer" to issuer, "fingerprint" to fingerprint, "changed" to false,
        ),
    )

    override fun onVerifyChangedCertificate(
        host: String, port: Long, commonName: String, subject: String, issuer: String,
        fingerprint: String, oldSubject: String, oldIssuer: String, oldFingerprint: String,
        flags: Long,
    ): Int = askCertificate(
        mapOf(
            "host" to host, "port" to port, "subject" to subject, "issuer" to issuer,
            "fingerprint" to fingerprint, "changed" to true, "oldFingerprint" to oldFingerprint,
        ),
    )

    /**
     * Pregunta a la app y bloquea el hilo de FreeRDP hasta la respuesta.
     * Aceptar lo guarda en el almacén de FreeRDP (confianza en el primer uso):
     * la próxima vez solo se pregunta si el certificado cambia.
     */
    private fun askCertificate(details: Map<String, Any?>): Int {
        val id = nextCertificateId.getAndIncrement()
        val answer = CompletableFuture<Boolean>()
        synchronized(pendingCertificates) { pendingCertificates[id] = answer }
        emit(details + mapOf("type" to "certificate", "requestId" to id))
        val accepted = try {
            answer.get(CERTIFICATE_TIMEOUT_SECONDS, TimeUnit.SECONDS)
        } catch (e: TimeoutException) {
            false
        } finally {
            synchronized(pendingCertificates) { pendingCertificates.remove(id) }
        }
        return if (accepted) LibFreeRDP.CERTIFICATE_ACCEPT_PERMANENTLY else LibFreeRDP.CERTIFICATE_REJECT
    }

    // ---- Dibujo ----

    private fun resize(width: Int, height: Int) {
        synchronized(frameLock) {
            val current = bitmap
            if (current != null && current.width == width && current.height == height) return
            current?.recycle()
            bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        }
        mainHandler.post {
            producer.setSize(width, height)
            requestRender()
        }
        emit(mapOf("type" to "resize", "width" to width, "height" to height))
    }

    /** Agrupa las actualizaciones: como mucho un cuadro pendiente a la vez. */
    private fun requestRender() {
        if (renderPending.compareAndSet(false, true)) renderHandler.post(::render)
    }

    private fun render() {
        renderPending.set(false)
        val surface = producer.surface ?: return
        if (!surface.isValid) return
        synchronized(frameLock) {
            val frame = bitmap ?: return
            val canvas = try {
                surface.lockHardwareCanvas()
            } catch (e: IllegalStateException) {
                return // superficie liberada mientras la app está en segundo plano
            }
            try {
                canvas.drawBitmap(frame, 0f, 0f, null)
            } finally {
                surface.unlockCanvasAndPost(canvas)
            }
        }
    }

    private companion object {
        const val TAG = "LazyWakeUpRdp"
        const val MONITOR_VALUES = 4
        const val CERTIFICATE_TIMEOUT_SECONDS = 120L
        const val CLOSE_TIMEOUT_SECONDS = 10L
        const val RENDER_JOIN_MILLIS = 1000L
    }
}
