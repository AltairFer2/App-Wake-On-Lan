/*
 * Extensión propia de la capa JNI de FreeRDP para Lazy Wake Up.
 *
 * El cliente Android de FreeRDP no detecta monitores: siempre pide uno solo.
 * Esta función define la disposición de monitores que se anuncia al PC (la
 * misma que tiene físicamente), para que la sesión muestre todas sus
 * pantallas. Debe llamarse después de freerdp_parse_arguments y antes de
 * freerdp_connect.
 */
#include <jni.h>

#include <freerdp/freerdp.h>
#include <freerdp/settings.h>

/* Cada monitor ocupa 4 enteros: x, y, ancho, alto. El primero es el principal
 * y debe estar en (0, 0); el resto, relativo a él (puede ser negativo). */
#define VALUES_PER_MONITOR 4
#define MAX_MONITORS 16

JNIEXPORT jboolean JNICALL
Java_com_freerdp_freerdpcore_services_LibFreeRDP_lwu_1set_1monitor_1layout(JNIEnv* env, jclass cls,
                                                                           jlong instance,
                                                                           jintArray layout)
{
	WINPR_UNUSED(cls);
	freerdp* inst = (freerdp*)instance;
	if (!inst || !inst->context || !inst->context->settings || !layout)
		return JNI_FALSE;

	const jsize length = (*env)->GetArrayLength(env, layout);
	if (length < VALUES_PER_MONITOR || (length % VALUES_PER_MONITOR) != 0)
		return JNI_FALSE;

	const size_t count = (size_t)length / VALUES_PER_MONITOR;
	if (count > MAX_MONITORS)
		return JNI_FALSE;

	jint* values = (*env)->GetIntArrayElements(env, layout, NULL);
	if (!values)
		return JNI_FALSE;

	rdpSettings* settings = inst->context->settings;
	BOOL ok = freerdp_settings_set_pointer_len(settings, FreeRDP_MonitorDefArray, NULL, count);
	INT32 left = 0;
	INT32 top = 0;
	INT32 right = 0;
	INT32 bottom = 0;

	for (size_t i = 0; ok && (i < count); i++)
	{
		rdpMonitor monitor = { 0 };
		monitor.x = values[i * VALUES_PER_MONITOR];
		monitor.y = values[i * VALUES_PER_MONITOR + 1];
		monitor.width = values[i * VALUES_PER_MONITOR + 2];
		monitor.height = values[i * VALUES_PER_MONITOR + 3];
		monitor.is_primary = (i == 0) ? TRUE : FALSE;
		monitor.orig_screen = (UINT32)i;

		if ((monitor.width <= 0) || (monitor.height <= 0) ||
		    ((i == 0) && ((monitor.x != 0) || (monitor.y != 0))))
		{
			ok = FALSE;
			break;
		}

		left = MIN(left, monitor.x);
		top = MIN(top, monitor.y);
		right = MAX(right, monitor.x + monitor.width);
		bottom = MAX(bottom, monitor.y + monitor.height);
		ok = freerdp_settings_set_pointer_array(settings, FreeRDP_MonitorDefArray, i, &monitor);
	}

	(*env)->ReleaseIntArrayElements(env, layout, values, JNI_ABORT);

	ok = ok && freerdp_settings_set_uint32(settings, FreeRDP_MonitorCount, (UINT32)count) &&
	     freerdp_settings_set_bool(settings, FreeRDP_UseMultimon, count > 1) &&
	     freerdp_settings_set_bool(settings, FreeRDP_SpanMonitors, FALSE) &&
	     freerdp_settings_set_uint32(settings, FreeRDP_DesktopWidth, (UINT32)(right - left)) &&
	     freerdp_settings_set_uint32(settings, FreeRDP_DesktopHeight, (UINT32)(bottom - top));

	return ok ? JNI_TRUE : JNI_FALSE;
}
