#include "Startup.h"

#include <Windows.h>

#include <string>

namespace sc {
namespace {

constexpr wchar_t kRunKeyPath[] = L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";

bool OpenRunKey(REGSAM access, HKEY* key) {
    return RegOpenKeyExW(HKEY_CURRENT_USER, kRunKeyPath, 0, access, key) == ERROR_SUCCESS;
}

std::wstring CurrentExecutableCommandLine() {
    wchar_t modulePath[MAX_PATH]{};
    const DWORD length = GetModuleFileNameW(nullptr, modulePath, MAX_PATH);
    if (length == 0 || length >= MAX_PATH) {
        return L"";
    }
    return L"\"" + std::wstring(modulePath) + L"\"";
}

}  // namespace

bool IsRunOnBootEnabled() {
    HKEY key = nullptr;
    if (!OpenRunKey(KEY_READ, &key)) {
        return false;
    }

    wchar_t buffer[MAX_PATH]{};
    DWORD bufferSize = sizeof(buffer);
    const LONG result = RegQueryValueExW(key, kStartupRegistryName, nullptr, nullptr,
                                         reinterpret_cast<LPBYTE>(buffer), &bufferSize);
    RegCloseKey(key);
    return result == ERROR_SUCCESS;
}

void SetRunOnBoot(bool enabled) {
    HKEY key = nullptr;
    if (!OpenRunKey(KEY_SET_VALUE, &key)) {
        return;
    }

    if (enabled) {
        const std::wstring commandLine = CurrentExecutableCommandLine();
        if (!commandLine.empty()) {
            const DWORD byteCount = static_cast<DWORD>((commandLine.size() + 1) * sizeof(wchar_t));
            RegSetValueExW(key, kStartupRegistryName, 0, REG_SZ,
                           reinterpret_cast<const BYTE*>(commandLine.c_str()), byteCount);
        }
    } else {
        RegDeleteValueW(key, kStartupRegistryName);
    }

    RegCloseKey(key);
}

void EnsureDefaultRunOnBoot() {
    if (!IsRunOnBootEnabled()) {
        SetRunOnBoot(true);
    }
}

}  // namespace sc
