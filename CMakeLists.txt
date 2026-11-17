cmake_minimum_required(VERSION 3.20)

# macOS: one "universal" bundle for Apple Silicon and Intel. Must be set before project().
set(CMAKE_OSX_ARCHITECTURES "arm64;x86_64" CACHE STRING "Arquitecturas de macOS")
set(CMAKE_OSX_DEPLOYMENT_TARGET "11.0" CACHE STRING "macOS minimo")

project(ArenaBrowser VERSION 1.0 LANGUAGES CXX)

if(WIN32)
    if(NOT CMAKE_SIZEOF_VOID_P EQUAL 8)
        message(FATAL_ERROR "Resolume Arena 7 es de 64 bits: configura con -A x64.")
    endif()
elseif(APPLE)
    enable_language(OBJCXX)
else()
    message(FATAL_ERROR "Estos plugins se compilan para Windows o macOS.")
endif()

set(FFGL_DIR ${CMAKE_CURRENT_SOURCE_DIR}/third_party/ffgl/lib)
set(GLEW_DIR ${CMAKE_CURRENT_SOURCE_DIR}/third_party/glew-2.1.0)

# Version of this build. The release workflow sets it from the git tag (v1.2.0 -> 1.2.0).
set(PLUGIN_VERSION "1.0.0" CACHE STRING "Version de los plugins (x.y.z)")
# Where installed plugins look for updates. Empty = updates disabled (local test builds).
set(UPDATE_MANIFEST_URL "" CACHE STRING "URL https del latest.json de actualizaciones")

if(NOT PLUGIN_VERSION MATCHES "^([0-9]+)\\.([0-9]+)\\.([0-9]+)$")
    message(FATAL_ERROR "PLUGIN_VERSION debe ser x.y.z, no '${PLUGIN_VERSION}'")
endif()
set(PLUGIN_VERSION_MAJOR ${CMAKE_MATCH_1})
set(PLUGIN_VERSION_MINOR ${CMAKE_MATCH_2})

# Optional: copy the plugins here after every build, e.g.
#   -DRESOLUME_EXTRA_EFFECTS_DIR="C:/Users/<you>/Documents/Resolume Arena/Extra Effects"
set(RESOLUME_EXTRA_EFFECTS_DIR "" CACHE PATH "Carpeta Extra Effects de Resolume donde copiar los plugins")

set(SHARED_SOURCES
    src/Updater.cpp src/Updater.h src/UpdateDialog.h
    src/Platform.h src/PluginIdentity.h
    src/FileLog.cpp src/FileLog.h
)
set(WIN_SHARED_SOURCES src/win/PlatformWin.cpp src/win/UpdateDialogWin.cpp src/win/ScreenCapture.manifest)
set(MAC_SHARED_SOURCES src/mac/PlatformMac.mm src/mac/UpdateDialogMac.mm)

# One Resolume Arena 7 (FFGL 2) plugin: a .dll on Windows, a universal .bundle on macOS.
#
#   add_ffgl_plugin(<target>
#       DISPLAY_NAME    "Shown in update windows and notifications"
#       SETTINGS_PREFIX "Prefix for its saved update choices"
#       LOG_FILE        "Log file name in Documents"
#       UPDATE_FIELD    "latest.json field suffix: url<suffix> (Windows), url<suffix>_mac (macOS)"
#       BUNDLE_ID       "macOS bundle identifier"
#       SOURCES / WIN_SOURCES / MAC_SOURCES ...
#       WIN_LIBRARIES / MAC_FRAMEWORKS ...)
function(add_ffgl_plugin target)
    cmake_parse_arguments(PLUGIN ""
        "DISPLAY_NAME;SETTINGS_PREFIX;LOG_FILE;UPDATE_FIELD;BUNDLE_ID"
        "SOURCES;WIN_SOURCES;MAC_SOURCES;WIN_LIBRARIES;MAC_FRAMEWORKS" ${ARGN})

    add_library(${target} MODULE ${PLUGIN_SOURCES} ${SHARED_SOURCES} ${FFGL_DIR}/FFGLSDK.cpp)
    target_compile_features(${target} PRIVATE cxx_std_17)
    target_include_directories(${target} PRIVATE ${FFGL_DIR})
    target_compile_definitions(${target} PRIVATE
        PLUGIN_VERSION_STRING="${PLUGIN_VERSION}"
        PLUGIN_VERSION_MAJOR=${PLUGIN_VERSION_MAJOR}
        PLUGIN_VERSION_MINOR=${PLUGIN_VERSION_MINOR}
        UPDATE_MANIFEST_URL="${UPDATE_MANIFEST_URL}"
        PLUGIN_DISPLAY_NAME="${PLUGIN_DISPLAY_NAME}"
        PLUGIN_SETTINGS_PREFIX="${PLUGIN_SETTINGS_PREFIX}"
        LOG_FILE_NAME="${PLUGIN_LOG_FILE}"
    )

    if(WIN32)
        target_sources(${target} PRIVATE ${WIN_SHARED_SOURCES} ${PLUGIN_WIN_SOURCES})
        target_include_directories(${target} PRIVATE ${GLEW_DIR}/include)
        target_compile_definitions(${target} PRIVATE
            GLEW_STATIC NOMINMAX _CRT_SECURE_NO_WARNINGS
            UPDATE_URL_FIELD="url${PLUGIN_UPDATE_FIELD}"
            UPDATE_SHA256_FIELD="sha256${PLUGIN_UPDATE_FIELD}"
        )
        target_compile_options(${target} PRIVATE /EHsc /utf-8 /bigobj /MP)
        # The bundled glew32s.lib was built against the static CRT; we use the dll CRT like FFGL.
        target_link_options(${target} PRIVATE /NODEFAULTLIB:LIBCMT)
        target_link_libraries(${target} PRIVATE
            opengl32 winhttp bcrypt shell32 user32 gdi32 ${PLUGIN_WIN_LIBRARIES}
            ${GLEW_DIR}/lib/Release/x64/glew32s.lib
        )
        if(RESOLUME_EXTRA_EFFECTS_DIR)
            add_custom_command(TARGET ${target} POST_BUILD
                COMMAND ${CMAKE_COMMAND} -E make_directory "${RESOLUME_EXTRA_EFFECTS_DIR}"
                COMMAND ${CMAKE_COMMAND} -E copy_if_different $<TARGET_FILE:${target}> "${RESOLUME_EXTRA_EFFECTS_DIR}"
                COMMENT "Copiando ${target}.dll a ${RESOLUME_EXTRA_EFFECTS_DIR}"
            )
        endif()
    else()
        target_sources(${target} PRIVATE ${MAC_SHARED_SOURCES} ${PLUGIN_MAC_SOURCES})
        target_compile_definitions(${target} PRIVATE
            GL_SILENCE_DEPRECATION
            UPDATE_URL_FIELD="url${PLUGIN_UPDATE_FIELD}_mac"
            UPDATE_SHA256_FIELD="sha256${PLUGIN_UPDATE_FIELD}_mac"
        )
        target_compile_options(${target} PRIVATE $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>)
        set_target_properties(${target} PROPERTIES
            BUNDLE TRUE
            BUNDLE_EXTENSION bundle
            MACOSX_BUNDLE_INFO_PLIST ${CMAKE_CURRENT_SOURCE_DIR}/src/mac/Info.plist.in
            MACOSX_BUNDLE_GUI_IDENTIFIER ${PLUGIN_BUNDLE_ID}
            MACOSX_BUNDLE_BUNDLE_NAME "${PLUGIN_DISPLAY_NAME}"
            MACOSX_BUNDLE_BUNDLE_VERSION ${PLUGIN_VERSION}
            MACOSX_BUNDLE_SHORT_VERSION_STRING ${PLUGIN_VERSION}
        )
        set(frameworks)
        foreach(framework OpenGL AppKit CoreGraphics Foundation ${PLUGIN_MAC_FRAMEWORKS})
            list(APPEND frameworks "-framework ${framework}")
        endforeach()
        target_link_libraries(${target} PRIVATE ${frameworks})
        if(RESOLUME_EXTRA_EFFECTS_DIR)
            add_custom_command(TARGET ${target} POST_BUILD
                COMMAND ${CMAKE_COMMAND} -E copy_directory $<TARGET_BUNDLE_DIR:${target}> "${RESOLUME_EXTRA_EFFECTS_DIR}/${target}.bundle"
                COMMENT "Copiando ${target}.bundle a ${RESOLUME_EXTRA_EFFECTS_DIR}"
            )
        endif()
    endif()
endfunction()

# ---------------------------------------------------------------------------------------------
# Browser: embedded WebKit page rendered as an Arena source, with a separate interaction window.
if(APPLE)
    add_ffgl_plugin(BrowserSource
        DISPLAY_NAME    "Браузер"
        LOG_FILE        "BrowserSource-log.txt"
        BUNDLE_ID       com.local.resolume-browser-source
        SOURCES
            src/browser/BrowserSource.cpp src/browser/BrowserSource.h
            src/browser/BrowserEngine.h src/browser/BrowserThumbnail.cpp
            src/browser/BrowserAudioOutput.h
        MAC_SOURCES
            src/browser/BrowserEngineMac.mm
            src/browser/BrowserAudioOutputMac.mm
        MAC_FRAMEWORKS WebKit CoreAudio AudioToolbox
    )
endif()
