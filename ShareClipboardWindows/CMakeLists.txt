cmake_minimum_required(VERSION 3.20)

project(ShareClipboardWindows LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_executable(ShareClipboard WIN32
    src/main.cpp
    src/Protocol.cpp
    src/Connection.cpp
    src/Clipboard.cpp
    src/SyncEngine.cpp
    src/Log.cpp
    src/TrayIcon.cpp
    src/Startup.cpp
)

target_include_directories(ShareClipboard PRIVATE src)

target_compile_definitions(ShareClipboard PRIVATE UNICODE _UNICODE NOMINMAX WIN32_LEAN_AND_MEAN)

target_link_libraries(ShareClipboard PRIVATE
    Crypt32
    Ws2_32
    Dnsapi
    Bcrypt
    Gdiplus
    Shlwapi
    Shell32
    User32
    Ole32
)

if(MSVC)
    target_compile_options(ShareClipboard PRIVATE /W4 /permissive-)
else()
    target_compile_options(ShareClipboard PRIVATE -Wall -Wextra)
endif()

add_custom_command(TARGET ShareClipboard POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E make_directory "$<TARGET_FILE_DIR:ShareClipboard>"
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        "${CMAKE_CURRENT_SOURCE_DIR}/resources/icon.png"
        "$<TARGET_FILE_DIR:ShareClipboard>/icon.png"
    COMMENT "Copying tray icon beside ShareClipboard.exe"
)
