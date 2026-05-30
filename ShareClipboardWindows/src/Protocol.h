#pragma once

#include <cstdint>
#include <optional>
#include <string>
#include <vector>

namespace sc {

constexpr uint32_t kProtocolVersion = 1;
constexpr uint32_t kMaxPayloadSize = 10 * 1024 * 1024;
constexpr std::size_t kMaxConnections = 4;
constexpr const char* kServiceType = "_shareclipboard._tcp.local.";

struct ClipboardPayload {
    std::string type;
    std::string mime;
    std::string data;
    std::string fingerprint;
};

struct Message {
    uint32_t version = kProtocolVersion;
    std::string type;
    std::string id;
    int64_t timestamp = 0;
    std::string mime;
    std::string data;
    std::string deviceId;
    std::string platform;
};

std::string DeviceId();
std::string SanitizedServiceName();
std::string ContentFingerprint(const std::string& type, const std::vector<uint8_t>& bytes);
std::string NewMessageId();
int64_t CurrentTimestampMs();

std::string SerializeMessage(const Message& message);
std::optional<Message> ParseMessage(const std::string& json);

std::vector<uint8_t> EncodeFrame(const std::string& json);
std::optional<std::string> Base64Encode(const std::vector<uint8_t>& bytes);
std::optional<std::vector<uint8_t>> Base64Decode(const std::string& encoded);

}  // namespace sc
