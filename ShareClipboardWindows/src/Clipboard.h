#pragma once

#include "Protocol.h"

#include <Windows.h>

#include <functional>
#include <optional>

namespace sc {

class Clipboard {
public:
    using ChangeHandler = std::function<void()>;
    using AppliedHandler = std::function<void(const std::string& fingerprint)>;

    explicit Clipboard(HWND ownerWindow);
    ~Clipboard();

    void SetChangeHandler(ChangeHandler handler);
    void SetAppliedHandler(AppliedHandler handler);
    std::optional<ClipboardPayload> ReadLocalPayload();
    bool ApplyRemoteText(const std::string& text);
    bool ApplyRemoteImage(const std::vector<uint8_t>& pngBytes);
    bool ApplyRemoteTextSync(const std::string& text);
    bool ApplyRemoteImageSync(const std::vector<uint8_t>& pngBytes);

    bool applyingRemote() const { return applyingRemote_; }

    static constexpr UINT kApplyTextMessage = WM_APP + 2;
    static constexpr UINT kApplyImageMessage = WM_APP + 3;

private:
    std::optional<std::vector<uint8_t>> ReadPngFromClipboard();
    std::optional<std::vector<uint8_t>> ConvertDibToPng(const void* dibData);
    bool WritePngToClipboard(const std::vector<uint8_t>& pngBytes);

    HWND ownerWindow_ = nullptr;
    ChangeHandler changeHandler_;
    AppliedHandler appliedHandler_;
    bool applyingRemote_ = false;
};

}  // namespace sc
