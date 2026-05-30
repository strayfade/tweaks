#include "TrayIcon.h"

#include <objidl.h>
#include <gdiplus.h>
#include <shlwapi.h>

#include <string>
#include <vector>

#pragma comment(lib, "Shlwapi.lib")

namespace sc {
namespace {

std::wstring DirectoryFromPath(const std::wstring& path) {
    const size_t slash = path.find_last_of(L"\\/");
    if (slash == std::wstring::npos) {
        return L"";
    }
    return path.substr(0, slash);
}

std::vector<std::wstring> CandidateIconPaths(HINSTANCE instance) {
    wchar_t modulePath[MAX_PATH]{};
    GetModuleFileNameW(instance, modulePath, MAX_PATH);

    const std::wstring moduleDirectory = DirectoryFromPath(modulePath);
    std::vector<std::wstring> candidates;
    if (!moduleDirectory.empty()) {
        candidates.push_back(moduleDirectory + L"\\icon.png");
        candidates.push_back(moduleDirectory + L"\\resources\\icon.png");
        candidates.push_back(moduleDirectory + L"\\..\\resources\\icon.png");
    }
    return candidates;
}

HICON IconFromBitmap(Gdiplus::Bitmap* bitmap) {
    if (!bitmap || bitmap->GetLastStatus() != Gdiplus::Ok) {
        return nullptr;
    }

    HICON icon = nullptr;
    if (bitmap->GetHICON(&icon) != Gdiplus::Ok) {
        return nullptr;
    }
    return icon;
}

}  // namespace

HICON LoadTrayIcon(HINSTANCE instance) {
    for (const std::wstring& path : CandidateIconPaths(instance)) {
        if (!PathFileExistsW(path.c_str())) {
            continue;
        }

        Gdiplus::Bitmap bitmap(path.c_str());
        if (HICON icon = IconFromBitmap(&bitmap)) {
            return icon;
        }
    }

    return nullptr;
}

void DestroyTrayIcon(HICON icon) {
    if (icon) {
        DestroyIcon(icon);
    }
}

}  // namespace sc
