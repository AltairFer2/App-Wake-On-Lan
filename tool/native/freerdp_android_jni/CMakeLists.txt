# Compila libfreerdp-android.so (la capa JNI del cliente Android de FreeRDP)
# contra las librerías de FreeRDP ya instaladas por build_freerdp_android.ps1.
# Sustituye al CMakeLists de freeRDPCore, que además descarga y compila todas
# las dependencias con ExternalProject (solo funciona en Linux/macOS).
cmake_minimum_required(VERSION 3.13)
project(freerdp-android LANGUAGES C)

if(NOT FREERDP_SOURCE_DIR OR NOT FREERDP_INSTALL_DIR)
  message(FATAL_ERROR "Faltan FREERDP_SOURCE_DIR o FREERDP_INSTALL_DIR")
endif()
# Rutas de Windows: las barras invertidas romperían las cadenas de CMake.
file(TO_CMAKE_PATH "${FREERDP_SOURCE_DIR}" FREERDP_SOURCE_DIR)
file(TO_CMAKE_PATH "${FREERDP_INSTALL_DIR}" FREERDP_INSTALL_DIR)

set(JNI_DIR "${FREERDP_SOURCE_DIR}/client/Android/Studio/freeRDPCore/src/main/cpp")

add_library(
  freerdp-android SHARED
  ${JNI_DIR}/android_cliprdr.c
  ${JNI_DIR}/android_disp.c
  ${JNI_DIR}/android_event.c
  ${JNI_DIR}/android_freerdp.c
  ${JNI_DIR}/android_jni_utils.c
  ${JNI_DIR}/android_jni_callback.c
  ${JNI_DIR}/android_rail.c
  # Extensión propia: disposición de monitores.
  ${CMAKE_CURRENT_SOURCE_DIR}/lwu_monitors.c
)

target_include_directories(
  freerdp-android PRIVATE ${JNI_DIR} ${FREERDP_INSTALL_DIR}/include/freerdp3
                          ${FREERDP_INSTALL_DIR}/include/winpr3
)

foreach(lib freerdp-client3 freerdp3 winpr3)
  add_library(${lib} SHARED IMPORTED)
  set_target_properties(${lib} PROPERTIES IMPORTED_LOCATION "${FREERDP_INSTALL_DIR}/lib/lib${lib}.so")
endforeach()

find_library(log-lib log)
find_library(jnigraphics-lib jnigraphics)

target_link_libraries(freerdp-android PRIVATE freerdp-client3 freerdp3 winpr3 ${log-lib} ${jnigraphics-lib})
# Android 15+ exige páginas de 16 KB en las librerías nativas.
target_link_options(freerdp-android PRIVATE "-Wl,-z,max-page-size=16384")
