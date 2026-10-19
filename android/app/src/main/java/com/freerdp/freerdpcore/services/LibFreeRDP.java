package com.freerdp.freerdpcore.services;

import android.content.Context;
import android.graphics.Bitmap;

import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

/**
 * Puente JNI con libfreerdp-android.so (cliente Android de FreeRDP 3).
 *
 * <p>El paquete, el nombre de la clase, el constructor público y las firmas de
 * los métodos son un contrato con el código nativo: lo buscan por nombre
 * ({@code FindClass}/{@code GetStaticMethodID}) y no deben cambiarse. Las
 * reglas de R8 que los conservan están en {@code proguard-rules.pro}.
 *
 * <p>Implementación propia y mínima: solo reenvía los eventos de cada
 * instancia a su {@link Listener}.
 */
public final class LibFreeRDP {
    /** Resultado de la verificación de certificados que espera FreeRDP. */
    public static final int CERTIFICATE_REJECT = 0;
    public static final int CERTIFICATE_ACCEPT_PERMANENTLY = 1;
    public static final int CERTIFICATE_ACCEPT_TEMPORARILY = 2;

    private static final Map<Long, Listener> listeners = new ConcurrentHashMap<>();
    private static final Throwable loadError;

    static {
        Throwable error = null;
        try {
            System.loadLibrary("freerdp-android");
            // Cargar también las dependencias dispara sus JNI_OnLoad.
            System.loadLibrary("freerdp-client3");
            System.loadLibrary("freerdp3");
            System.loadLibrary("winpr3");
        } catch (UnsatisfiedLinkError e) {
            // Por ejemplo, una ABI para la que no se compiló FreeRDP.
            error = e;
        }
        loadError = error;
    }

    /** Lo instancia el código nativo al cargar la librería. */
    public LibFreeRDP() {}

    public static boolean isAvailable() {
        return loadError == null;
    }

    public static String unavailableReason() {
        return loadError == null ? "" : loadError.getMessage();
    }

    public static long newInstance(Context context, Listener listener) {
        long instance = freerdp_new(context);
        if (instance != 0) listeners.put(instance, listener);
        return instance;
    }

    public static void freeInstance(long instance) {
        listeners.remove(instance);
        freerdp_free(instance);
    }

    public static boolean parseArguments(long instance, String[] arguments) {
        return freerdp_parse_arguments(instance, arguments);
    }

    /** Inicia la conexión en un hilo nativo; el resultado llega al Listener. */
    public static boolean connect(long instance) {
        return freerdp_connect(instance);
    }

    public static boolean disconnect(long instance) {
        return freerdp_disconnect(instance);
    }

    /** Copia la región indicada del escritorio remoto al bitmap (ARGB_8888). */
    public static boolean updateGraphics(long instance, Bitmap bitmap, int x, int y, int width, int height) {
        return freerdp_update_graphics(instance, bitmap, x, y, width, height);
    }

    /**
     * Anuncia varios monitores: 4 enteros por monitor (x, y, ancho, alto), el
     * primero es el principal en (0, 0). Llamar tras parseArguments y antes de
     * connect. Implementado en tool/native/freerdp_android_jni/lwu_monitors.c.
     */
    public static boolean setMonitorLayout(long instance, int[] layout) {
        return lwu_set_monitor_layout(instance, layout);
    }

    /** Evento de ratón; flags PTR_FLAGS_* de RDP, coordenadas del escritorio. */
    public static boolean sendCursorEvent(long instance, int x, int y, int flags) {
        return freerdp_send_cursor_event(instance, x, y, flags);
    }

    /** Tecla por código virtual de Windows (VK_*). */
    public static boolean sendKeyEvent(long instance, int virtualKey, boolean down) {
        return freerdp_send_key_event(instance, virtualKey, down);
    }

    /** Carácter Unicode (UTF-16) escrito desde el teclado del teléfono. */
    public static boolean sendUnicodeKeyEvent(long instance, int codeUnit, boolean down) {
        return freerdp_send_unicodekey_event(instance, codeUnit, down);
    }

    public static String lastErrorString(long instance) {
        return freerdp_get_last_error_string(instance);
    }

    public static String version() {
        return freerdp_get_jni_version();
    }

    private static native String freerdp_get_jni_version();

    private static native long freerdp_new(Context context);

    private static native void freerdp_free(long instance);

    private static native boolean freerdp_parse_arguments(long instance, String[] arguments);

    private static native boolean freerdp_connect(long instance);

    private static native boolean freerdp_disconnect(long instance);

    private static native boolean freerdp_update_graphics(
            long instance, Bitmap bitmap, int x, int y, int width, int height);

    private static native String freerdp_get_last_error_string(long instance);

    private static native boolean freerdp_send_cursor_event(long instance, int x, int y, int flags);

    private static native boolean freerdp_send_key_event(long instance, int keycode, boolean down);

    private static native boolean freerdp_send_unicodekey_event(long instance, int keycode, boolean down);

    private static native boolean lwu_set_monitor_layout(long instance, int[] layout);

    /** Eventos de una sesión. Se invocan desde hilos nativos. */
    public interface Listener {
        void onConnectionSuccess();

        void onConnectionFailure();

        void onDisconnected();

        void onSettingsChanged(int width, int height, int bpp);

        void onGraphicsResize(int width, int height, int bpp);

        void onGraphicsUpdate(int x, int y, int width, int height);

        /** Rellena los StringBuilder y devuelve true para continuar. */
        boolean onAuthenticate(StringBuilder username, StringBuilder domain, StringBuilder password);

        int onVerifyCertificate(String host, long port, String commonName, String subject,
                String issuer, String fingerprint, long flags);

        int onVerifyChangedCertificate(String host, long port, String commonName, String subject,
                String issuer, String fingerprint, String oldSubject, String oldIssuer,
                String oldFingerprint, long flags);
    }

    // ---- Callbacks invocados por el código nativo (firmas fijas) ----

    private static void OnPreConnect(long inst) {}

    private static void OnConnectionSuccess(long inst) {
        Listener l = listeners.get(inst);
        if (l != null) l.onConnectionSuccess();
    }

    private static void OnConnectionFailure(long inst) {
        Listener l = listeners.get(inst);
        if (l != null) l.onConnectionFailure();
    }

    private static void OnDisconnecting(long inst) {}

    private static void OnDisconnected(long inst) {
        Listener l = listeners.get(inst);
        if (l != null) l.onDisconnected();
    }

    private static void OnSettingsChanged(long inst, int width, int height, int bpp) {
        Listener l = listeners.get(inst);
        if (l != null) l.onSettingsChanged(width, height, bpp);
    }

    private static boolean OnAuthenticate(long inst, StringBuilder username, StringBuilder domain,
            StringBuilder password) {
        Listener l = listeners.get(inst);
        return l != null && l.onAuthenticate(username, domain, password);
    }

    private static boolean OnGatewayAuthenticate(long inst, StringBuilder username,
            StringBuilder domain, StringBuilder password) {
        return false; // Sin puerta de enlace RDP.
    }

    private static int OnVerifyCertificateEx(long inst, String host, long port, String commonName,
            String subject, String issuer, String fingerprint, long flags) {
        Listener l = listeners.get(inst);
        return l == null ? CERTIFICATE_REJECT
                : l.onVerifyCertificate(host, port, commonName, subject, issuer, fingerprint, flags);
    }

    private static int OnVerifyChangedCertificateEx(long inst, String host, long port,
            String commonName, String subject, String issuer, String fingerprint,
            String oldSubject, String oldIssuer, String oldFingerprint, long flags) {
        Listener l = listeners.get(inst);
        return l == null ? CERTIFICATE_REJECT
                : l.onVerifyChangedCertificate(host, port, commonName, subject, issuer,
                        fingerprint, oldSubject, oldIssuer, oldFingerprint, flags);
    }

    /** RemoteApp y cámara no se usan: se rechazan. */
    private static boolean OnExperimentalFeature(long inst, int feature) {
        return false;
    }

    private static void OnGraphicsUpdate(long inst, int x, int y, int width, int height) {
        Listener l = listeners.get(inst);
        if (l != null) l.onGraphicsUpdate(x, y, width, height);
    }

    private static void OnGraphicsResize(long inst, int width, int height, int bpp) {
        Listener l = listeners.get(inst);
        if (l != null) l.onGraphicsResize(width, height, bpp);
    }

    private static void OnRemoteClipboardChanged(long inst, String data) {}

    private static void OnRemoteClipboardImageChanged(long inst, byte[] data) {}

    private static void OnPointerSet(long inst, int[] pixels, int width, int height, int hotX, int hotY) {}

    private static void OnPointerSetNull(long inst) {}

    private static void OnPointerSetDefault(long inst) {}

    private static void OnRailWindowUpdate(long inst, long windowId, int width, int height, int[] pixels) {}

    private static void OnRailWindowMove(long inst, long windowId, int x, int y, int w, int h) {}

    private static void OnRailWindowHide(long inst, long windowId) {}

    private static void OnRailWindowDestroy(long inst, long windowId) {}

    private static void OnRailSessionEnd(long inst) {}

    private static void OnRailMonitoredDesktop(long inst, long[] windowIds, long activeWindowId) {}
}
