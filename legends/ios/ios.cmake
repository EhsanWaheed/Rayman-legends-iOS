# iOS / iPadOS app bundle for rayman_legends. Included from CMakeLists.txt when
# CMAKE_SYSTEM_NAME is iOS. Everything is compiled ahead of time (no JIT), so
# the app runs sideloaded under LiveContainer or SideStore.
#
#   cmake -S legends -B legends/out/build/ios -G Ninja -DCMAKE_SYSTEM_NAME=iOS \
#         -DCMAKE_OSX_SYSROOT=iphoneos -DCMAKE_OSX_ARCHITECTURES=arm64 \
#         -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 -DCMAKE_BUILD_TYPE=Release
#
# RL_IOS_BUNDLE_GAME: a folder with the extracted disc (default.xex and the
# .ipk files) to copy into the app as game/ (the owner's own IPA). Empty for
# the "no game files" IPA, whose launcher imports the game on first start.

set(RL_IOS_DIR "${CMAKE_CURRENT_SOURCE_DIR}/ios")
set(RL_IOS_BUNDLE_ID "com.E5N97.raymanlegends" CACHE STRING "iOS bundle identifier")
set(RL_IOS_APP_VERSION "0.1" CACHE STRING "CFBundleShortVersionString")
set(RL_IOS_BUNDLE_GAME "" CACHE PATH "Folder with the extracted game to put in the app; empty: none")

execute_process(COMMAND git rev-list --count HEAD WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
                OUTPUT_VARIABLE RL_IOS_APP_BUILD OUTPUT_STRIP_TRAILING_WHITESPACE ERROR_QUIET)
if(NOT RL_IOS_APP_BUILD)
    set(RL_IOS_APP_BUILD "1")
endif()
set(RL_IOS_EXE rayman_legends)
configure_file("${RL_IOS_DIR}/Info.plist.in" "${CMAKE_BINARY_DIR}/ios/Info.plist" @ONLY)
set_target_properties(rayman_legends PROPERTIES
    MACOSX_BUNDLE ON
    MACOSX_BUNDLE_INFO_PLIST "${CMAKE_BINARY_DIR}/ios/Info.plist"
    XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER "${RL_IOS_BUNDLE_ID}"
    XCODE_ATTRIBUTE_TARGETED_DEVICE_FAMILY "1,2"
    BUILD_RPATH "@executable_path/Frameworks"
    INSTALL_RPATH "@executable_path/Frameworks")

# The launcher (cover art, game check and import), before the game's window, and
# the settings panel over the game (ios_overlay.mm).
set(_rl_ios_sources "${RL_IOS_DIR}/ios_launcher.mm" "${RL_IOS_DIR}/ios_game.mm" "${RL_IOS_DIR}/ios_overlay.mm")
target_sources(rayman_legends PRIVATE ${_rl_ios_sources} "${RL_IOS_DIR}/third_party/miniz/miniz.c")
target_include_directories(rayman_legends PRIVATE "${RL_IOS_DIR}" "${RL_IOS_DIR}/third_party/miniz")
set_source_files_properties(${_rl_ios_sources} PROPERTIES COMPILE_OPTIONS "-fobjc-arc"
                            SKIP_PRECOMPILE_HEADERS ON)
set_source_files_properties("${RL_IOS_DIR}/third_party/miniz/miniz.c" PROPERTIES COMPILE_OPTIONS "-w")

target_link_libraries(rayman_legends PRIVATE
    "-framework UIKit" "-framework Foundation" "-framework GameController"
    "-framework Metal" "-framework QuartzCore" "-framework AVFoundation"
    "-framework CoreHaptics" "-framework UniformTypeIdentifiers")

# The app's dynamic libraries go in Frameworks/: the runtime (linked, found by
# the @rpath above), the Xenos GPU plugin and MoltenVK (both loaded at run time
# from Frameworks/: gpu_plugin_loader.cpp, vulkan_instance.cpp).
add_dependencies(rayman_legends MoltenVK rexgpu-xenos)
set(_rl_frameworks "$<TARGET_BUNDLE_DIR:rayman_legends>/Frameworks")
add_custom_command(TARGET rayman_legends POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E make_directory "${_rl_frameworks}"
    COMMAND ${CMAKE_COMMAND} -E copy_if_different "$<TARGET_FILE:MoltenVK>" "${_rl_frameworks}/libMoltenVK.dylib"
    COMMAND install_name_tool -id @rpath/libMoltenVK.dylib "${_rl_frameworks}/libMoltenVK.dylib"
    COMMAND ${CMAKE_COMMAND} -E copy_if_different "$<TARGET_FILE:rexruntime>" "$<TARGET_FILE:rexgpu-xenos>"
            "${_rl_frameworks}/"
    # rexglue_configure_target stages the plugin beside the executable, as on a desktop.
    COMMAND ${CMAKE_COMMAND} -E rm -f "$<TARGET_BUNDLE_DIR:rayman_legends>/$<TARGET_FILE_NAME:rexgpu-xenos>"
            "$<TARGET_BUNDLE_DIR:rayman_legends>/$<TARGET_FILE_NAME:rexruntime>"
    COMMENT "Embedding the runtime, the GPU plugin and MoltenVK"
    VERBATIM)

# The launcher's cover art, when there is one (ios/LauncherArt.png, the owner's
# box art, kept out of git); the app icon is made from it too (a square from
# its top), in the sizes Info.plist names.
if(EXISTS "${RL_IOS_DIR}/LauncherArt.png")
    set(_rl_icon_src "${CMAKE_BINARY_DIR}/ios/icons/source.png")
    add_custom_command(OUTPUT "${_rl_icon_src}"
        COMMAND ${CMAKE_COMMAND} -E make_directory "${CMAKE_BINARY_DIR}/ios/icons"
        COMMAND xcrun swift "${RL_IOS_DIR}/square_icon.swift"
                "${RL_IOS_DIR}/LauncherArt.png" "${_rl_icon_src}"
        DEPENDS "${RL_IOS_DIR}/LauncherArt.png" "${RL_IOS_DIR}/square_icon.swift"
        VERBATIM)
    set(_rl_icons "")
    foreach(_icon "Icon-60@2x:120" "Icon-60@3x:180" "Icon-76@2x:152" "Icon-83.5@2x:167" "Icon-40@2x:80"
                  "Icon-40@3x:120" "Icon-29@2x:58" "Icon-29@3x:87")
        string(REPLACE ":" ";" _parts "${_icon}")
        list(GET _parts 0 _name)
        list(GET _parts 1 _px)
        set(_out "${CMAKE_BINARY_DIR}/ios/icons/${_name}.png")
        add_custom_command(OUTPUT "${_out}"
            COMMAND sips -s format png -z ${_px} ${_px} "${_rl_icon_src}" --out "${_out}"
            DEPENDS "${_rl_icon_src}"
            VERBATIM)
        list(APPEND _rl_icons "${_out}")
    endforeach()
    add_custom_target(rl-ios-icons DEPENDS ${_rl_icons})
    add_dependencies(rayman_legends rl-ios-icons)
    add_custom_command(TARGET rayman_legends POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_if_different ${_rl_icons} "${RL_IOS_DIR}/LauncherArt.png"
                "$<TARGET_BUNDLE_DIR:rayman_legends>/"
        VERBATIM)
endif()


# The owner's IPA: the game inside the app (game/).
if(RL_IOS_BUNDLE_GAME)
    add_custom_command(TARGET rayman_legends POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_directory "${RL_IOS_BUNDLE_GAME}"
                "$<TARGET_BUNDLE_DIR:rayman_legends>/game"
        COMMENT "Bundling the game into the app (game/)"
        VERBATIM)
endif()

# Outside Xcode nothing signs the bundle: sign it ad hoc (a sideloader
# re-signs it for a device).
if(NOT CMAKE_GENERATOR STREQUAL "Xcode")
    add_custom_command(TARGET rayman_legends POST_BUILD
        COMMAND codesign --force --sign - --timestamp=none
                "$<TARGET_BUNDLE_DIR:rayman_legends>/Frameworks/libMoltenVK.dylib"
                "$<TARGET_BUNDLE_DIR:rayman_legends>/Frameworks/$<TARGET_FILE_NAME:rexruntime>"
                "$<TARGET_BUNDLE_DIR:rayman_legends>/Frameworks/$<TARGET_FILE_NAME:rexgpu-xenos>"
        COMMAND codesign --force --sign - --timestamp=none "$<TARGET_BUNDLE_DIR:rayman_legends>"
        COMMENT "Signing the app ad hoc"
        VERBATIM)
endif()
