#include "Clipboard.h"
#include "Log.h"
#include "Protocol.h"
#include "Startup.h"
#include "SyncEngine.h"
#include "TrayIcon.h"

#include <Windows.h>
#include <objidl.h>

#include <gdiplus.h>
#include <shellapi.h>

#include <memory>
#include <string>
#include <vector>

#pragma comment(lib, "gdiplus.lib")

namespace {

constexpr UINT kTrayIconMessage = WM_APP + 1;
constexpr UINT kTrayAppIconId = 1;
constexpr UINT kTrayStatusCommand = 1000;
constexpr UINT kTrayRunOnBootCommand = 1001;
constexpr UINT kTrayExitCommand = 1002;

sc::SyncEngine* gSyncEngine = nullptr;
sc::Clipboard* gClipboard = nullptr;
HICON gTrayIcon = nullptr;
bool gTrayIconOwned = false;

void ShowTrayContextMenu(HWND hwnd) {
    POINT cursor{};
    GetCursorPos(&cursor);

    const bool iosConnected = gSyncEngine && gSyncEngine->HasConnectedIosPeer();
    const bool runOnBoot = sc::IsRunOnBootEnabled();

    HMENU menu = CreatePopupMenu();
    AppendMenuW(menu, MF_STRING | MF_DISABLED | MF_GRAYED, kTrayStatusCommand,
                iosConnected ? L"iOS: Connected" : L"iOS: Not connected");
    AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(menu, MF_STRING | (runOnBoot ? MF_CHECKED : 0), kTrayRunOnBootCommand, L"Run on startup");
    AppendMenuW(menu, MF_STRING, kTrayExitCommand, L"Exit");

    SetForegroundWindow(hwnd);
    TrackPopupMenu(menu, TPM_BOTTOMALIGN | TPM_LEFTALIGN, cursor.x, cursor.y, 0, hwnd, nullptr);
    DestroyMenu(menu);
}

LRESULT CALLBACK WindowProc(HWND hwnd, UINT message, WPARAM wParam, LPARAM lParam) {
    switch (message) {
        case sc::Clipboard::kApplyTextMessage: {
            std::unique_ptr<std::string> payload(reinterpret_cast<std::string*>(lParam));
            if (gClipboard && payload) {
                gClipboard->ApplyRemoteTextSync(*payload);
            }
            return 0;
        }
        case sc::Clipboard::kApplyImageMessage: {
            std::unique_ptr<std::vector<uint8_t>> payload(reinterpret_cast<std::vector<uint8_t>*>(lParam));
            if (gClipboard && payload) {
                gClipboard->ApplyRemoteImageSync(*payload);
            }
            return 0;
        }
        case WM_CLIPBOARDUPDATE:
            if (gSyncEngine) {
                gSyncEngine->ScheduleClipboardSync();
            }
            return 0;
        case kTrayIconMessage:
            if (lParam == WM_RBUTTONUP || lParam == WM_CONTEXTMENU) {
                ShowTrayContextMenu(hwnd);
            }
            return 0;
        case WM_COMMAND:
            switch (LOWORD(wParam)) {
                case kTrayRunOnBootCommand:
                    sc::SetRunOnBoot(!sc::IsRunOnBootEnabled());
                    break;
                case kTrayExitCommand:
                    DestroyWindow(hwnd);
                    break;
                default:
                    break;
            }
            return 0;
        case WM_DESTROY: {
            NOTIFYICONDATAW removeIcon{};
            removeIcon.cbSize = sizeof(NOTIFYICONDATAW);
            removeIcon.hWnd = hwnd;
            removeIcon.uID = kTrayAppIconId;
            Shell_NotifyIconW(NIM_DELETE, &removeIcon);
            if (gTrayIconOwned && gTrayIcon) {
                sc::DestroyTrayIcon(gTrayIcon);
                gTrayIcon = nullptr;
                gTrayIconOwned = false;
            }
            PostQuitMessage(0);
            return 0;
        }
        default:
            break;
    }
    return DefWindowProcW(hwnd, message, wParam, lParam);
}

bool EnsureSingleInstance() {
    HANDLE mutex = CreateMutexW(nullptr, TRUE, L"com.strayfade.shareclipboard.windows");
    if (!mutex || GetLastError() == ERROR_ALREADY_EXISTS) {
        MessageBoxW(nullptr,
                    L"ShareClipboard is already running in the system tray.",
                    L"ShareClipboard",
                    MB_ICONINFORMATION | MB_OK);
        return false;
    }
    return true;
}

}  // namespace

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE, PWSTR, int) {
    if (!EnsureSingleInstance()) {
        return 0;
    }

    Gdiplus::GdiplusStartupInput gdiplusStartupInput;
    ULONG_PTR gdiplusToken = 0;
    if (Gdiplus::GdiplusStartup(&gdiplusToken, &gdiplusStartupInput, nullptr) != Gdiplus::Ok) {
        MessageBoxW(nullptr, L"Failed to initialize GDI+.", L"ShareClipboard", MB_ICONERROR | MB_OK);
        return 1;
    }

    sc::EnsureDefaultRunOnBoot();

    const wchar_t* className = L"ShareClipboardHiddenWindow";
    WNDCLASSEXW windowClass{};
    windowClass.cbSize = sizeof(WNDCLASSEXW);
    windowClass.lpfnWndProc = WindowProc;
    windowClass.hInstance = instance;
    windowClass.lpszClassName = className;
    RegisterClassExW(&windowClass);

    HWND hwnd = CreateWindowExW(0, className, L"ShareClipboard", 0, 0, 0, 0, 0, HWND_MESSAGE, nullptr, instance, nullptr);
    if (!hwnd) {
        Gdiplus::GdiplusShutdown(gdiplusToken);
        return 1;
    }

    if (!AddClipboardFormatListener(hwnd)) {
        MessageBoxW(nullptr, L"Failed to monitor the clipboard.", L"ShareClipboard", MB_ICONERROR | MB_OK);
        DestroyWindow(hwnd);
        Gdiplus::GdiplusShutdown(gdiplusToken);
        return 1;
    }

    gTrayIcon = sc::LoadTrayIcon(instance);
    gTrayIconOwned = gTrayIcon != nullptr;
    if (!gTrayIcon) {
        gTrayIcon = LoadIconW(nullptr, IDI_APPLICATION);
    }

    NOTIFYICONDATAW trayData{};
    trayData.cbSize = sizeof(NOTIFYICONDATAW);
    trayData.hWnd = hwnd;
    trayData.uID = kTrayAppIconId;
    trayData.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
    trayData.uCallbackMessage = kTrayIconMessage;
    trayData.hIcon = gTrayIcon;
    wcscpy_s(trayData.szTip, L"ShareClipboard");
    Shell_NotifyIconW(NIM_ADD, &trayData);

    sc::Clipboard clipboard(hwnd);
    sc::SyncEngine syncEngine;
    gClipboard = &clipboard;
    gSyncEngine = &syncEngine;
    syncEngine.SetClipboard(&clipboard);
    syncEngine.Start();

    wchar_t* appData = nullptr;
    size_t appDataLength = 0;
    std::wstring logHint = L"%APPDATA%\\ShareClipboard\\shareclipboard.log";
    if (_wdupenv_s(&appData, &appDataLength, L"APPDATA") == 0 && appData) {
        logHint = std::wstring(appData) + L"\\ShareClipboard\\shareclipboard.log";
        free(appData);
    }
    sc::Logf("ShareClipboard running. Device id: %s", sc::DeviceId().c_str());
    sc::Logf("Log file: %ls", logHint.c_str());

    MSG message{};
    while (GetMessageW(&message, nullptr, 0, 0) > 0) {
        TranslateMessage(&message);
        DispatchMessageW(&message);
    }

    gSyncEngine = nullptr;
    gClipboard = nullptr;
    syncEngine.Stop();
    RemoveClipboardFormatListener(hwnd);
    DestroyWindow(hwnd);
    UnregisterClassW(className, instance);
    Gdiplus::GdiplusShutdown(gdiplusToken);
    return static_cast<int>(message.wParam);
}
