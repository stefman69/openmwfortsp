# Install script for directory: /root/sdl2-2.30.12-src

# Set the install prefix
if(NOT DEFINED CMAKE_INSTALL_PREFIX)
  set(CMAKE_INSTALL_PREFIX "/root/sdl2-2.30.12-install")
endif()
string(REGEX REPLACE "/$" "" CMAKE_INSTALL_PREFIX "${CMAKE_INSTALL_PREFIX}")

# Set the install configuration name.
if(NOT DEFINED CMAKE_INSTALL_CONFIG_NAME)
  if(BUILD_TYPE)
    string(REGEX REPLACE "^[^A-Za-z0-9_]+" ""
           CMAKE_INSTALL_CONFIG_NAME "${BUILD_TYPE}")
  else()
    set(CMAKE_INSTALL_CONFIG_NAME "Release")
  endif()
  message(STATUS "Install configuration: \"${CMAKE_INSTALL_CONFIG_NAME}\"")
endif()

# Set the component getting installed.
if(NOT CMAKE_INSTALL_COMPONENT)
  if(COMPONENT)
    message(STATUS "Install component: \"${COMPONENT}\"")
    set(CMAKE_INSTALL_COMPONENT "${COMPONENT}")
  else()
    set(CMAKE_INSTALL_COMPONENT)
  endif()
endif()

# Install shared libraries without execute permission?
if(NOT DEFINED CMAKE_INSTALL_SO_NO_EXE)
  set(CMAKE_INSTALL_SO_NO_EXE "1")
endif()

# Is this installation the result of a crosscompile?
if(NOT DEFINED CMAKE_CROSSCOMPILING)
  set(CMAKE_CROSSCOMPILING "FALSE")
endif()

# Set path to fallback-tool for dependency-resolution.
if(NOT DEFINED CMAKE_OBJDUMP)
  set(CMAKE_OBJDUMP "/usr/bin/objdump")
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "Unspecified" OR NOT CMAKE_INSTALL_COMPONENT)
  file(INSTALL DESTINATION "${CMAKE_INSTALL_PREFIX}/lib" TYPE SHARED_LIBRARY FILES
    "/root/sdl2-2.30.12-build/libSDL2-2.0.so.0.3000.12"
    "/root/sdl2-2.30.12-build/libSDL2-2.0.so.0"
    )
  foreach(file
      "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/libSDL2-2.0.so.0.3000.12"
      "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/libSDL2-2.0.so.0"
      )
    if(EXISTS "${file}" AND
       NOT IS_SYMLINK "${file}")
      if(CMAKE_INSTALL_DO_STRIP)
        execute_process(COMMAND "/usr/bin/strip" "${file}")
      endif()
    endif()
  endforeach()
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "Unspecified" OR NOT CMAKE_INSTALL_COMPONENT)
  file(INSTALL DESTINATION "${CMAKE_INSTALL_PREFIX}/lib" TYPE SHARED_LIBRARY FILES "/root/sdl2-2.30.12-build/libSDL2-2.0.so")
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "Unspecified" OR NOT CMAKE_INSTALL_COMPONENT)
  file(INSTALL DESTINATION "${CMAKE_INSTALL_PREFIX}/lib" TYPE STATIC_LIBRARY FILES "/root/sdl2-2.30.12-build/libSDL2main.a")
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "Unspecified" OR NOT CMAKE_INSTALL_COMPONENT)
  if(EXISTS "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/cmake/SDL2/SDL2Targets.cmake")
    file(DIFFERENT _cmake_export_file_changed FILES
         "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/cmake/SDL2/SDL2Targets.cmake"
         "/root/sdl2-2.30.12-build/CMakeFiles/Export/f084604df1a27ef5b4fef7c7544737d1/SDL2Targets.cmake")
    if(_cmake_export_file_changed)
      file(GLOB _cmake_old_config_files "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/cmake/SDL2/SDL2Targets-*.cmake")
      if(_cmake_old_config_files)
        string(REPLACE ";" ", " _cmake_old_config_files_text "${_cmake_old_config_files}")
        message(STATUS "Old export file \"$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/cmake/SDL2/SDL2Targets.cmake\" will be replaced.  Removing files [${_cmake_old_config_files_text}].")
        unset(_cmake_old_config_files_text)
        file(REMOVE ${_cmake_old_config_files})
      endif()
      unset(_cmake_old_config_files)
    endif()
    unset(_cmake_export_file_changed)
  endif()
  file(INSTALL DESTINATION "${CMAKE_INSTALL_PREFIX}/lib/cmake/SDL2" TYPE FILE FILES "/root/sdl2-2.30.12-build/CMakeFiles/Export/f084604df1a27ef5b4fef7c7544737d1/SDL2Targets.cmake")
  if(CMAKE_INSTALL_CONFIG_NAME MATCHES "^([Rr][Ee][Ll][Ee][Aa][Ss][Ee])$")
    file(INSTALL DESTINATION "${CMAKE_INSTALL_PREFIX}/lib/cmake/SDL2" TYPE FILE FILES "/root/sdl2-2.30.12-build/CMakeFiles/Export/f084604df1a27ef5b4fef7c7544737d1/SDL2Targets-release.cmake")
  endif()
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "Unspecified" OR NOT CMAKE_INSTALL_COMPONENT)
  if(EXISTS "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/cmake/SDL2/SDL2mainTargets.cmake")
    file(DIFFERENT _cmake_export_file_changed FILES
         "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/cmake/SDL2/SDL2mainTargets.cmake"
         "/root/sdl2-2.30.12-build/CMakeFiles/Export/f084604df1a27ef5b4fef7c7544737d1/SDL2mainTargets.cmake")
    if(_cmake_export_file_changed)
      file(GLOB _cmake_old_config_files "$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/cmake/SDL2/SDL2mainTargets-*.cmake")
      if(_cmake_old_config_files)
        string(REPLACE ";" ", " _cmake_old_config_files_text "${_cmake_old_config_files}")
        message(STATUS "Old export file \"$ENV{DESTDIR}${CMAKE_INSTALL_PREFIX}/lib/cmake/SDL2/SDL2mainTargets.cmake\" will be replaced.  Removing files [${_cmake_old_config_files_text}].")
        unset(_cmake_old_config_files_text)
        file(REMOVE ${_cmake_old_config_files})
      endif()
      unset(_cmake_old_config_files)
    endif()
    unset(_cmake_export_file_changed)
  endif()
  file(INSTALL DESTINATION "${CMAKE_INSTALL_PREFIX}/lib/cmake/SDL2" TYPE FILE FILES "/root/sdl2-2.30.12-build/CMakeFiles/Export/f084604df1a27ef5b4fef7c7544737d1/SDL2mainTargets.cmake")
  if(CMAKE_INSTALL_CONFIG_NAME MATCHES "^([Rr][Ee][Ll][Ee][Aa][Ss][Ee])$")
    file(INSTALL DESTINATION "${CMAKE_INSTALL_PREFIX}/lib/cmake/SDL2" TYPE FILE FILES "/root/sdl2-2.30.12-build/CMakeFiles/Export/f084604df1a27ef5b4fef7c7544737d1/SDL2mainTargets-release.cmake")
  endif()
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "Devel" OR NOT CMAKE_INSTALL_COMPONENT)
  file(INSTALL DESTINATION "${CMAKE_INSTALL_PREFIX}/lib/cmake/SDL2" TYPE FILE FILES
    "/root/sdl2-2.30.12-build/SDL2Config.cmake"
    "/root/sdl2-2.30.12-build/SDL2ConfigVersion.cmake"
    "/root/sdl2-2.30.12-src/cmake/sdlfind.cmake"
    )
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "Unspecified" OR NOT CMAKE_INSTALL_COMPONENT)
  file(INSTALL DESTINATION "${CMAKE_INSTALL_PREFIX}/include/SDL2" TYPE FILE FILES
    "/root/sdl2-2.30.12-src/include/SDL.h"
    "/root/sdl2-2.30.12-src/include/SDL_assert.h"
    "/root/sdl2-2.30.12-src/include/SDL_atomic.h"
    "/root/sdl2-2.30.12-src/include/SDL_audio.h"
    "/root/sdl2-2.30.12-src/include/SDL_bits.h"
    "/root/sdl2-2.30.12-src/include/SDL_blendmode.h"
    "/root/sdl2-2.30.12-src/include/SDL_clipboard.h"
    "/root/sdl2-2.30.12-src/include/SDL_copying.h"
    "/root/sdl2-2.30.12-src/include/SDL_cpuinfo.h"
    "/root/sdl2-2.30.12-src/include/SDL_egl.h"
    "/root/sdl2-2.30.12-src/include/SDL_endian.h"
    "/root/sdl2-2.30.12-src/include/SDL_error.h"
    "/root/sdl2-2.30.12-src/include/SDL_events.h"
    "/root/sdl2-2.30.12-src/include/SDL_filesystem.h"
    "/root/sdl2-2.30.12-src/include/SDL_gamecontroller.h"
    "/root/sdl2-2.30.12-src/include/SDL_gesture.h"
    "/root/sdl2-2.30.12-src/include/SDL_guid.h"
    "/root/sdl2-2.30.12-src/include/SDL_haptic.h"
    "/root/sdl2-2.30.12-src/include/SDL_hidapi.h"
    "/root/sdl2-2.30.12-src/include/SDL_hints.h"
    "/root/sdl2-2.30.12-src/include/SDL_joystick.h"
    "/root/sdl2-2.30.12-src/include/SDL_keyboard.h"
    "/root/sdl2-2.30.12-src/include/SDL_keycode.h"
    "/root/sdl2-2.30.12-src/include/SDL_loadso.h"
    "/root/sdl2-2.30.12-src/include/SDL_locale.h"
    "/root/sdl2-2.30.12-src/include/SDL_log.h"
    "/root/sdl2-2.30.12-src/include/SDL_main.h"
    "/root/sdl2-2.30.12-src/include/SDL_messagebox.h"
    "/root/sdl2-2.30.12-src/include/SDL_metal.h"
    "/root/sdl2-2.30.12-src/include/SDL_misc.h"
    "/root/sdl2-2.30.12-src/include/SDL_mouse.h"
    "/root/sdl2-2.30.12-src/include/SDL_mutex.h"
    "/root/sdl2-2.30.12-src/include/SDL_name.h"
    "/root/sdl2-2.30.12-src/include/SDL_opengl.h"
    "/root/sdl2-2.30.12-src/include/SDL_opengl_glext.h"
    "/root/sdl2-2.30.12-src/include/SDL_opengles.h"
    "/root/sdl2-2.30.12-src/include/SDL_opengles2.h"
    "/root/sdl2-2.30.12-src/include/SDL_opengles2_gl2.h"
    "/root/sdl2-2.30.12-src/include/SDL_opengles2_gl2ext.h"
    "/root/sdl2-2.30.12-src/include/SDL_opengles2_gl2platform.h"
    "/root/sdl2-2.30.12-src/include/SDL_opengles2_khrplatform.h"
    "/root/sdl2-2.30.12-src/include/SDL_pixels.h"
    "/root/sdl2-2.30.12-src/include/SDL_platform.h"
    "/root/sdl2-2.30.12-src/include/SDL_power.h"
    "/root/sdl2-2.30.12-src/include/SDL_quit.h"
    "/root/sdl2-2.30.12-src/include/SDL_rect.h"
    "/root/sdl2-2.30.12-src/include/SDL_render.h"
    "/root/sdl2-2.30.12-src/include/SDL_rwops.h"
    "/root/sdl2-2.30.12-src/include/SDL_scancode.h"
    "/root/sdl2-2.30.12-src/include/SDL_sensor.h"
    "/root/sdl2-2.30.12-src/include/SDL_shape.h"
    "/root/sdl2-2.30.12-src/include/SDL_stdinc.h"
    "/root/sdl2-2.30.12-src/include/SDL_surface.h"
    "/root/sdl2-2.30.12-src/include/SDL_system.h"
    "/root/sdl2-2.30.12-src/include/SDL_syswm.h"
    "/root/sdl2-2.30.12-src/include/SDL_test.h"
    "/root/sdl2-2.30.12-src/include/SDL_test_assert.h"
    "/root/sdl2-2.30.12-src/include/SDL_test_common.h"
    "/root/sdl2-2.30.12-src/include/SDL_test_compare.h"
    "/root/sdl2-2.30.12-src/include/SDL_test_crc32.h"
    "/root/sdl2-2.30.12-src/include/SDL_test_font.h"
    "/root/sdl2-2.30.12-src/include/SDL_test_fuzzer.h"
    "/root/sdl2-2.30.12-src/include/SDL_test_harness.h"
    "/root/sdl2-2.30.12-src/include/SDL_test_images.h"
    "/root/sdl2-2.30.12-src/include/SDL_test_log.h"
    "/root/sdl2-2.30.12-src/include/SDL_test_md5.h"
    "/root/sdl2-2.30.12-src/include/SDL_test_memory.h"
    "/root/sdl2-2.30.12-src/include/SDL_test_random.h"
    "/root/sdl2-2.30.12-src/include/SDL_thread.h"
    "/root/sdl2-2.30.12-src/include/SDL_timer.h"
    "/root/sdl2-2.30.12-src/include/SDL_touch.h"
    "/root/sdl2-2.30.12-src/include/SDL_types.h"
    "/root/sdl2-2.30.12-src/include/SDL_version.h"
    "/root/sdl2-2.30.12-src/include/SDL_video.h"
    "/root/sdl2-2.30.12-src/include/SDL_vulkan.h"
    "/root/sdl2-2.30.12-src/include/begin_code.h"
    "/root/sdl2-2.30.12-src/include/close_code.h"
    "/root/sdl2-2.30.12-build/include/SDL2/SDL_revision.h"
    "/root/sdl2-2.30.12-build/include-config-release/SDL2/SDL_config.h"
    )
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "Unspecified" OR NOT CMAKE_INSTALL_COMPONENT)
  file(INSTALL DESTINATION "${CMAKE_INSTALL_PREFIX}/share/licenses/SDL2" TYPE FILE FILES "/root/sdl2-2.30.12-src/LICENSE.txt")
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "Unspecified" OR NOT CMAKE_INSTALL_COMPONENT)
  file(INSTALL DESTINATION "${CMAKE_INSTALL_PREFIX}/lib/pkgconfig" TYPE FILE FILES "/root/sdl2-2.30.12-build/sdl2.pc")
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "Unspecified" OR NOT CMAKE_INSTALL_COMPONENT)
  
            execute_process(COMMAND /usr/local/lib/python3.8/dist-packages/cmake/data/bin/cmake -E create_symlink
              "libSDL2-2.0.so" "libSDL2.so"
              WORKING_DIRECTORY "/root/sdl2-2.30.12-build")
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "Unspecified" OR NOT CMAKE_INSTALL_COMPONENT)
  file(INSTALL DESTINATION "${CMAKE_INSTALL_PREFIX}/lib" TYPE FILE FILES "/root/sdl2-2.30.12-build/libSDL2.so")
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "Unspecified" OR NOT CMAKE_INSTALL_COMPONENT)
  file(INSTALL DESTINATION "${CMAKE_INSTALL_PREFIX}/bin" TYPE PROGRAM FILES "/root/sdl2-2.30.12-build/sdl2-config")
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "Unspecified" OR NOT CMAKE_INSTALL_COMPONENT)
  file(INSTALL DESTINATION "${CMAKE_INSTALL_PREFIX}/share/aclocal" TYPE FILE FILES "/root/sdl2-2.30.12-src/sdl2.m4")
endif()

string(REPLACE ";" "\n" CMAKE_INSTALL_MANIFEST_CONTENT
       "${CMAKE_INSTALL_MANIFEST_FILES}")
if(CMAKE_INSTALL_LOCAL_ONLY)
  file(WRITE "/root/sdl2-2.30.12-build/install_local_manifest.txt"
     "${CMAKE_INSTALL_MANIFEST_CONTENT}")
endif()
if(CMAKE_INSTALL_COMPONENT)
  if(CMAKE_INSTALL_COMPONENT MATCHES "^[a-zA-Z0-9_.+-]+$")
    set(CMAKE_INSTALL_MANIFEST "install_manifest_${CMAKE_INSTALL_COMPONENT}.txt")
  else()
    string(MD5 CMAKE_INST_COMP_HASH "${CMAKE_INSTALL_COMPONENT}")
    set(CMAKE_INSTALL_MANIFEST "install_manifest_${CMAKE_INST_COMP_HASH}.txt")
    unset(CMAKE_INST_COMP_HASH)
  endif()
else()
  set(CMAKE_INSTALL_MANIFEST "install_manifest.txt")
endif()

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  file(WRITE "/root/sdl2-2.30.12-build/${CMAKE_INSTALL_MANIFEST}"
     "${CMAKE_INSTALL_MANIFEST_CONTENT}")
endif()
