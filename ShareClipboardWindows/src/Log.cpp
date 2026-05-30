#include "Log.h"

#include <Windows.h>

#include <cstdarg>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <mutex>

namespace sc {
namespace {

std::mutex gLogMutex;

std::filesystem::path LogPath() {
    wchar_t* appData = nullptr;
    size_t length = 0;
    if (_wdupenv_s(&appData, &length, L"APPDATA") != 0 || !appData) {
        return std::filesystem::temp_directory_path() / "ShareClipboard.log";
    }
    std::filesystem::path path = std::filesystem::path(appData) / "ShareClipboard" / "shareclipboard.log";
    free(appData);
    return path;
}

}  // namespace

void Log(const std::string& message) {
    SYSTEMTIME time{};
    GetLocalTime(&time);

    char timestamp[32];
    std::snprintf(timestamp,
                  sizeof(timestamp),
                  "%04u-%02u-%02u %02u:%02u:%02u",
                  time.wYear,
                  time.wMonth,
                  time.wDay,
                  time.wHour,
                  time.wMinute,
                  time.wSecond);

    const std::string line = std::string("[") + timestamp + "] " + message + "\n";

    OutputDebugStringA(line.c_str());

    std::lock_guard<std::mutex> lock(gLogMutex);
    std::error_code ec;
    std::filesystem::create_directories(LogPath().parent_path(), ec);
    std::ofstream output(LogPath(), std::ios::app);
    output << line;
}

void Logf(const char* format, ...) {
    char buffer[1024];
    va_list args;
    va_start(args, format);
    std::vsnprintf(buffer, sizeof(buffer), format, args);
    va_end(args);
    Log(buffer);
}

}  // namespace sc
