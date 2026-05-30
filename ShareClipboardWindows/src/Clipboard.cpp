#include "Clipboard.h"

#include <Windows.h>
#include <objidl.h>

#include <gdiplus.h>
#include <shlwapi.h>

#include <vector>

#pragma comment(lib, "gdiplus.lib")
#pragma comment(lib, "shlwapi.lib")

namespace sc {
namespace {

std::wstring Utf8ToWide(const std::string& text) {
    if (text.empty()) {
        return {};
    }
    const int length = MultiByteToWideChar(CP_UTF8, 0, text.c_str(), static_cast<int>(text.size()), nullptr, 0);
    if (length <= 0) {
        return {};
    }
    std::wstring wide(static_cast<std::size_t>(length), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, text.c_str(), static_cast<int>(text.size()), wide.data(), length);
    return wide;
}

std::string WideToUtf8(const std::wstring& text) {
    if (text.empty()) {
        return {};
    }
    const int length =
        WideCharToMultiByte(CP_UTF8, 0, text.c_str(), static_cast<int>(text.size()), nullptr, 0, nullptr, nullptr);
    if (length <= 0) {
        return {};
    }
    std::string utf8(static_cast<std::size_t>(length), '\0');
    WideCharToMultiByte(CP_UTF8, 0, text.c_str(), static_cast<int>(text.size()), utf8.data(), length, nullptr, nullptr);
    return utf8;
}

int GetEncoderClsid(const WCHAR* format, CLSID* clsid) {
    UINT count = 0;
    UINT size = 0;
    Gdiplus::GetImageEncodersSize(&count, &size);
    if (size == 0) {
        return -1;
    }

    std::vector<uint8_t> buffer(size);
    auto* codecs = reinterpret_cast<Gdiplus::ImageCodecInfo*>(buffer.data());
    Gdiplus::GetImageEncoders(count, size, codecs);
    for (UINT index = 0; index < count; ++index) {
        if (wcscmp(codecs[index].MimeType, format) == 0) {
            *clsid = codecs[index].Clsid;
            return static_cast<int>(index);
        }
    }
    return -1;
}

}  // namespace

Clipboard::Clipboard(HWND ownerWindow) : ownerWindow_(ownerWindow) {}

Clipboard::~Clipboard() = default;

void Clipboard::SetChangeHandler(ChangeHandler handler) {
    changeHandler_ = std::move(handler);
}

void Clipboard::SetAppliedHandler(AppliedHandler handler) {
    appliedHandler_ = std::move(handler);
}

std::optional<ClipboardPayload> Clipboard::ReadLocalPayload() {
    if (!OpenClipboard(ownerWindow_)) {
        return std::nullopt;
    }

    std::optional<ClipboardPayload> payload;
    if (IsClipboardFormatAvailable(CF_DIB) || IsClipboardFormatAvailable(CF_BITMAP)) {
        if (auto pngBytes = ReadPngFromClipboard()) {
            if (!pngBytes->empty() && pngBytes->size() <= kMaxPayloadSize) {
                if (auto encoded = Base64Encode(*pngBytes)) {
                    ClipboardPayload imagePayload;
                    imagePayload.type = "image";
                    imagePayload.mime = "image/png";
                    imagePayload.data = *encoded;
                    imagePayload.fingerprint = ContentFingerprint("image", *pngBytes);
                    payload = std::move(imagePayload);
                }
            }
        }
    }

    if (!payload && IsClipboardFormatAvailable(CF_UNICODETEXT)) {
        HANDLE data = GetClipboardData(CF_UNICODETEXT);
        if (data) {
            const wchar_t* text = static_cast<const wchar_t*>(GlobalLock(data));
            if (text) {
                const std::string utf8 = WideToUtf8(text);
                GlobalUnlock(data);
                if (!utf8.empty()) {
                    const std::vector<uint8_t> bytes(utf8.begin(), utf8.end());
                    if (bytes.size() <= kMaxPayloadSize) {
                        ClipboardPayload textPayload;
                        textPayload.type = "text";
                        textPayload.mime = "text/plain; charset=utf-8";
                        textPayload.data = utf8;
                        textPayload.fingerprint = ContentFingerprint("text", bytes);
                        payload = std::move(textPayload);
                    }
                }
            }
        }
    }

    CloseClipboard();
    return payload;
}

bool Clipboard::ApplyRemoteText(const std::string& text) {
    if (!ownerWindow_) {
        return false;
    }
    auto* payload = new std::string(text);
    if (!PostMessage(ownerWindow_, kApplyTextMessage, 0, reinterpret_cast<LPARAM>(payload))) {
        delete payload;
        return false;
    }
    return true;
}

bool Clipboard::ApplyRemoteImage(const std::vector<uint8_t>& pngBytes) {
    if (!ownerWindow_) {
        return false;
    }
    auto* payload = new std::vector<uint8_t>(pngBytes);
    if (!PostMessage(ownerWindow_, kApplyImageMessage, 0, reinterpret_cast<LPARAM>(payload))) {
        delete payload;
        return false;
    }
    return true;
}

bool Clipboard::ApplyRemoteTextSync(const std::string& text) {
    const std::wstring wide = Utf8ToWide(text);
    if (wide.empty()) {
        return false;
    }

    const std::size_t byteCount = (wide.size() + 1) * sizeof(wchar_t);
    HGLOBAL memory = GlobalAlloc(GMEM_MOVEABLE, byteCount);
    if (!memory) {
        return false;
    }

    void* locked = GlobalLock(memory);
    if (!locked) {
        GlobalFree(memory);
        return false;
    }
    memcpy(locked, wide.c_str(), byteCount);
    GlobalUnlock(memory);

    applyingRemote_ = true;
    bool success = false;
    if (OpenClipboard(ownerWindow_)) {
        EmptyClipboard();
        success = SetClipboardData(CF_UNICODETEXT, memory) != nullptr;
        CloseClipboard();
    }
    if (!success) {
        GlobalFree(memory);
    }
    applyingRemote_ = false;
    if (success && appliedHandler_) {
        const std::vector<uint8_t> bytes(text.begin(), text.end());
        appliedHandler_(ContentFingerprint("text", bytes));
    }
    return success;
}

bool Clipboard::ApplyRemoteImageSync(const std::vector<uint8_t>& pngBytes) {
    applyingRemote_ = true;
    const bool success = WritePngToClipboard(pngBytes);
    applyingRemote_ = false;
    if (success && appliedHandler_) {
        appliedHandler_(ContentFingerprint("image", pngBytes));
    }
    return success;
}

std::optional<std::vector<uint8_t>> Clipboard::ReadPngFromClipboard() {
    std::optional<std::vector<uint8_t>> pngBytes;

    if (IsClipboardFormatAvailable(CF_DIB)) {
        HANDLE data = GetClipboardData(CF_DIB);
        if (data) {
            const void* dib = GlobalLock(data);
            if (dib) {
                pngBytes = ConvertDibToPng(dib);
                GlobalUnlock(data);
            }
        }
    } else if (IsClipboardFormatAvailable(CF_BITMAP)) {
        HANDLE data = GetClipboardData(CF_BITMAP);
        if (data) {
            HBITMAP bitmap = static_cast<HBITMAP>(data);
            BITMAP info{};
            if (GetObject(bitmap, sizeof(info), &info) != 0) {
                BITMAPINFOHEADER header{};
                header.biSize = sizeof(BITMAPINFOHEADER);
                header.biWidth = info.bmWidth;
                header.biHeight = info.bmHeight;
                header.biPlanes = 1;
                header.biBitCount = 32;
                header.biCompression = BI_RGB;
                const std::size_t imageSize =
                    static_cast<std::size_t>(info.bmWidth) * static_cast<std::size_t>(info.bmHeight) * 4;
                std::vector<uint8_t> dib(sizeof(BITMAPINFOHEADER) + imageSize);
                auto* bitmapInfo = reinterpret_cast<BITMAPINFO*>(dib.data());
                bitmapInfo->bmiHeader = header;
                HDC dc = GetDC(nullptr);
                if (GetDIBits(dc,
                              bitmap,
                              0,
                              static_cast<UINT>(info.bmHeight),
                              dib.data() + sizeof(BITMAPINFOHEADER),
                              bitmapInfo,
                              DIB_RGB_COLORS)) {
                    pngBytes = ConvertDibToPng(dib.data());
                }
                ReleaseDC(nullptr, dc);
            }
        }
    }

    return pngBytes;
}

std::optional<std::vector<uint8_t>> Clipboard::ConvertDibToPng(const void* dibData) {
    const auto* header = reinterpret_cast<const BITMAPINFOHEADER*>(dibData);
    if (header->biSize < sizeof(BITMAPINFOHEADER)) {
        return std::nullopt;
    }

    Gdiplus::Bitmap bitmap(const_cast<BITMAPINFO*>(reinterpret_cast<const BITMAPINFO*>(dibData)),
                           const_cast<void*>(dibData));
    if (bitmap.GetLastStatus() != Gdiplus::Ok) {
        return std::nullopt;
    }

    IStream* stream = SHCreateMemStream(nullptr, 0);
    if (!stream) {
        return std::nullopt;
    }

    CLSID pngClsid{};
    if (GetEncoderClsid(L"image/png", &pngClsid) < 0) {
        stream->Release();
        return std::nullopt;
    }

    if (bitmap.Save(stream, &pngClsid, nullptr) != Gdiplus::Ok) {
        stream->Release();
        return std::nullopt;
    }

    STATSTG stats{};
    if (stream->Stat(&stats, STATFLAG_NONAME) != S_OK) {
        stream->Release();
        return std::nullopt;
    }

    const ULONG size = static_cast<ULONG>(stats.cbSize.QuadPart);
    std::vector<uint8_t> pngBytes(size);
    LARGE_INTEGER zero{};
    stream->Seek(zero, STREAM_SEEK_SET, nullptr);
    ULONG read = 0;
    if (stream->Read(pngBytes.data(), size, &read) != S_OK || read != size) {
        stream->Release();
        return std::nullopt;
    }

    stream->Release();
    return pngBytes;
}

bool Clipboard::WritePngToClipboard(const std::vector<uint8_t>& pngBytes) {
    if (pngBytes.empty() || pngBytes.size() > kMaxPayloadSize) {
        return false;
    }

    IStream* stream = SHCreateMemStream(pngBytes.data(), static_cast<UINT>(pngBytes.size()));
    if (!stream) {
        return false;
    }

    Gdiplus::Bitmap bitmap(stream);
    if (bitmap.GetLastStatus() != Gdiplus::Ok) {
        stream->Release();
        return false;
    }

    Gdiplus::Bitmap converted(bitmap.GetWidth(), bitmap.GetHeight(), PixelFormat32bppPARGB);
    Gdiplus::Graphics graphics(&converted);
    graphics.DrawImage(&bitmap, 0, 0);
    stream->Release();

    HBITMAP handle = nullptr;
    if (converted.GetHBITMAP(Gdiplus::Color(0, 0, 0, 0), &handle) != Gdiplus::Ok || !handle) {
        return false;
    }

    BITMAP info{};
    GetObject(handle, sizeof(info), &info);

    BITMAPINFOHEADER header{};
    header.biSize = sizeof(BITMAPINFOHEADER);
    header.biWidth = info.bmWidth;
    header.biHeight = info.bmHeight;
    header.biPlanes = 1;
    header.biBitCount = 32;
    header.biCompression = BI_RGB;

    const std::size_t imageSize = static_cast<std::size_t>(info.bmWidth) * static_cast<std::size_t>(info.bmHeight) * 4;
    const std::size_t totalSize = sizeof(BITMAPINFOHEADER) + imageSize;
    HGLOBAL memory = GlobalAlloc(GMEM_MOVEABLE, totalSize);
    if (!memory) {
        DeleteObject(handle);
        return false;
    }

    void* locked = GlobalLock(memory);
    if (!locked) {
        GlobalFree(memory);
        DeleteObject(handle);
        return false;
    }

    auto* bitmapInfo = reinterpret_cast<BITMAPINFO*>(locked);
    bitmapInfo->bmiHeader = header;
    HDC dc = GetDC(nullptr);
    GetDIBits(dc,
              handle,
              0,
              static_cast<UINT>(info.bmHeight),
              reinterpret_cast<uint8_t*>(locked) + sizeof(BITMAPINFOHEADER),
              bitmapInfo,
              DIB_RGB_COLORS);
    ReleaseDC(nullptr, dc);
    DeleteObject(handle);
    GlobalUnlock(memory);

    bool success = false;
    if (OpenClipboard(ownerWindow_)) {
        EmptyClipboard();
        success = SetClipboardData(CF_DIB, memory) != nullptr;
        CloseClipboard();
    }
    if (!success) {
        GlobalFree(memory);
    }
    return success;
}

}  // namespace sc
