# El código nativo de FreeRDP busca esta clase, su constructor y sus métodos
# por nombre (JNI): R8 no debe renombrarlos ni eliminarlos.
-keep class com.freerdp.freerdpcore.services.LibFreeRDP { *; }
