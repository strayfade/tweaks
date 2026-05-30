#include "Protocol.h"

#include <Windows.h>
#include <bcrypt.h>
#include <wincrypt.h>

#include <array>
#include <chrono>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <random>
#include <sstream>

#pragma comment(lib, "bcrypt.lib")
#pragma comment(lib, "crypt32.lib")

namespace sc {
namespace {

std::filesystem::path ConfigDirectory() {
    wchar_t* appData = nullptr;
    size_t length = 0;
    if (_wdupenv_s(&appData, &length, L"APPDATA") != 0 || !appData) {
        return std::filesystem::temp_directory_path() / "ShareClipboard";
    }
    std::filesystem::path path = std::filesystem::path(appData) / "ShareClipboard";
    free(appData);
    return path;
}

std::string ReadFileText(const std::filesystem::path& path) {
    std::ifstream input(path, std::ios::binary);
    if (!input) {
        return {};
    }
    return std::string((std::istreambuf_iterator<char>(input)), std::istreambuf_iterator<char>());
}

void WriteFileText(const std::filesystem::path& path, const std::string& text) {
    std::error_code ec;
    std::filesystem::create_directories(path.parent_path(), ec);
    std::ofstream output(path, std::ios::binary | std::ios::trunc);
    output << text;
}

std::string GenerateUuid() {
    std::random_device random;
    std::mt19937_64 generator(random());
    std::uniform_int_distribution<uint64_t> distribution;
    const uint64_t high = distribution(generator);
    const uint64_t low = distribution(generator);

    char buffer[37];
    std::snprintf(buffer,
                  sizeof(buffer),
                  "%08x-%04x-%04x-%04x-%012llx",
                  static_cast<unsigned>((high >> 32) & 0xFFFFFFFFu),
                  static_cast<unsigned>((high >> 16) & 0xFFFFu),
                  static_cast<unsigned>((high & 0x0FFFu) | 0x4000u),
                  static_cast<unsigned>(((low >> 48) & 0x3FFFu) | 0x8000u),
                  static_cast<unsigned long long>(low & 0xFFFFFFFFFFFFull));
    return buffer;
}

std::string EscapeJsonString(const std::string& value) {
    std::string escaped;
    escaped.reserve(value.size() + 8);
    for (unsigned char ch : value) {
        switch (ch) {
            case '\\':
                escaped += "\\\\";
                break;
            case '"':
                escaped += "\\\"";
                break;
            case '\b':
                escaped += "\\b";
                break;
            case '\f':
                escaped += "\\f";
                break;
            case '\n':
                escaped += "\\n";
                break;
            case '\r':
                escaped += "\\r";
                break;
            case '\t':
                escaped += "\\t";
                break;
            default:
                if (ch < 0x20) {
                    char hex[7];
                    std::snprintf(hex, sizeof(hex), "\\u%04x", ch);
                    escaped += hex;
                } else {
                    escaped.push_back(static_cast<char>(ch));
                }
                break;
        }
    }
    return escaped;
}

void SkipWhitespace(const std::string& json, std::size_t& index) {
    while (index < json.size() && std::isspace(static_cast<unsigned char>(json[index]))) {
        ++index;
    }
}

bool MatchLiteral(const std::string& json, std::size_t& index, char literal) {
    SkipWhitespace(json, index);
    if (index >= json.size() || json[index] != literal) {
        return false;
    }
    ++index;
    return true;
}

std::optional<std::string> ParseJsonString(const std::string& json, std::size_t& index) {
    SkipWhitespace(json, index);
    if (index >= json.size() || json[index] != '"') {
        return std::nullopt;
    }
    ++index;

    std::string value;
    while (index < json.size()) {
        char ch = json[index++];
        if (ch == '"') {
            return value;
        }
        if (ch != '\\') {
            value.push_back(ch);
            continue;
        }
        if (index >= json.size()) {
            return std::nullopt;
        }
        char escaped = json[index++];
        switch (escaped) {
            case '"':
            case '\\':
            case '/':
                value.push_back(escaped);
                break;
            case 'b':
                value.push_back('\b');
                break;
            case 'f':
                value.push_back('\f');
                break;
            case 'n':
                value.push_back('\n');
                break;
            case 'r':
                value.push_back('\r');
                break;
            case 't':
                value.push_back('\t');
                break;
            case 'u': {
                if (index + 4 > json.size()) {
                    return std::nullopt;
                }
                unsigned codePoint = 0;
                for (int digit = 0; digit < 4; ++digit) {
                    char hex = json[index++];
                    codePoint <<= 4;
                    if (hex >= '0' && hex <= '9') {
                        codePoint |= static_cast<unsigned>(hex - '0');
                    } else if (hex >= 'a' && hex <= 'f') {
                        codePoint |= static_cast<unsigned>(hex - 'a' + 10);
                    } else if (hex >= 'A' && hex <= 'F') {
                        codePoint |= static_cast<unsigned>(hex - 'A' + 10);
                    } else {
                        return std::nullopt;
                    }
                }
                if (codePoint <= 0x7F) {
                    value.push_back(static_cast<char>(codePoint));
                } else if (codePoint <= 0x7FF) {
                    value.push_back(static_cast<char>(0xC0 | ((codePoint >> 6) & 0x1F)));
                    value.push_back(static_cast<char>(0x80 | (codePoint & 0x3F)));
                } else {
                    value.push_back(static_cast<char>(0xE0 | ((codePoint >> 12) & 0x0F)));
                    value.push_back(static_cast<char>(0x80 | ((codePoint >> 6) & 0x3F)));
                    value.push_back(static_cast<char>(0x80 | (codePoint & 0x3F)));
                }
                break;
            }
            default:
                return std::nullopt;
        }
    }
    return std::nullopt;
}

std::optional<int64_t> ParseJsonNumber(const std::string& json, std::size_t& index) {
    SkipWhitespace(json, index);
    std::size_t start = index;
    if (index < json.size() && (json[index] == '-' || json[index] == '+')) {
        ++index;
    }
    while (index < json.size() && std::isdigit(static_cast<unsigned char>(json[index]))) {
        ++index;
    }
    if (start == index) {
        return std::nullopt;
    }
    try {
        return std::stoll(json.substr(start, index - start));
    } catch (...) {
        return std::nullopt;
    }
}

std::optional<std::string> ExtractStringField(const std::string& json, const std::string& key) {
    const std::string needle = "\"" + key + "\"";
    std::size_t keyIndex = json.find(needle);
    if (keyIndex == std::string::npos) {
        return std::nullopt;
    }
    std::size_t index = keyIndex + needle.size();
    if (!MatchLiteral(json, index, ':')) {
        return std::nullopt;
    }
    return ParseJsonString(json, index);
}

std::optional<int64_t> ExtractNumberField(const std::string& json, const std::string& key) {
    const std::string needle = "\"" + key + "\"";
    std::size_t keyIndex = json.find(needle);
    if (keyIndex == std::string::npos) {
        return std::nullopt;
    }
    std::size_t index = keyIndex + needle.size();
    if (!MatchLiteral(json, index, ':')) {
        return std::nullopt;
    }
    return ParseJsonNumber(json, index);
}

}  // namespace

std::string DeviceId() {
    static std::string cached = [] {
        const auto path = ConfigDirectory() / "device_id.txt";
        std::string existing = ReadFileText(path);
        if (!existing.empty()) {
            return existing;
        }
        const std::string generated = GenerateUuid();
        WriteFileText(path, generated);
        return generated;
    }();
    return cached;
}

std::string SanitizedServiceName() {
    wchar_t computerName[MAX_COMPUTERNAME_LENGTH + 1];
    DWORD size = MAX_COMPUTERNAME_LENGTH + 1;
    std::wstring raw = L"ShareClipboard-PC";
    if (GetComputerNameW(computerName, &size)) {
        raw = computerName;
    }

    std::string sanitized;
    sanitized.reserve(raw.size());
    for (wchar_t ch : raw) {
        if (ch == L' ' || ch == L'_') {
            sanitized.push_back('-');
            continue;
        }
        if ((ch >= L'a' && ch <= L'z') || (ch >= L'A' && ch <= L'Z') || (ch >= L'0' && ch <= L'9') || ch == L'-') {
            sanitized.push_back(static_cast<char>(ch));
        }
    }
    if (sanitized.empty()) {
        return "ShareClipboard-PC";
    }
    if (sanitized.size() > 63) {
        sanitized.resize(63);
    }
    return sanitized;
}

std::string ContentFingerprint(const std::string& type, const std::vector<uint8_t>& bytes) {
    if (bytes.empty()) {
        return {};
    }

    BCRYPT_ALG_HANDLE algorithm = nullptr;
    if (BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM, nullptr, 0) != 0) {
        return {};
    }

    BCRYPT_HASH_HANDLE hash = nullptr;
    if (BCryptCreateHash(algorithm, &hash, nullptr, 0, nullptr, 0, 0) != 0) {
        BCryptCloseAlgorithmProvider(algorithm, 0);
        return {};
    }

    BCryptHashData(hash, const_cast<PUCHAR>(bytes.data()), static_cast<ULONG>(bytes.size()), 0);

    std::array<uint8_t, 32> digest{};
    BCryptFinishHash(hash, digest.data(), static_cast<ULONG>(digest.size()), 0);
    BCryptDestroyHash(hash);
    BCryptCloseAlgorithmProvider(algorithm, 0);

    std::ostringstream stream;
    stream << type << ':';
    for (uint8_t byte : digest) {
        stream << std::hex << std::setw(2) << std::setfill('0') << static_cast<int>(byte);
    }
    return stream.str();
}

std::string NewMessageId() {
    return GenerateUuid();
}

int64_t CurrentTimestampMs() {
    return std::chrono::duration_cast<std::chrono::milliseconds>(
               std::chrono::system_clock::now().time_since_epoch())
        .count();
}

std::string SerializeMessage(const Message& message) {
    std::ostringstream json;
    json << '{';
    json << "\"v\":" << message.version << ',';
    json << "\"type\":\"" << EscapeJsonString(message.type) << "\",";
    if (!message.id.empty()) {
        json << "\"id\":\"" << EscapeJsonString(message.id) << "\",";
    }
    if (message.timestamp != 0) {
        json << "\"ts\":" << message.timestamp << ',';
    }
    if (!message.mime.empty()) {
        json << "\"mime\":\"" << EscapeJsonString(message.mime) << "\",";
    }
    if (!message.deviceId.empty()) {
        json << "\"deviceId\":\"" << EscapeJsonString(message.deviceId) << "\",";
    }
    if (!message.platform.empty()) {
        json << "\"platform\":\"" << EscapeJsonString(message.platform) << "\",";
    }
    json << "\"data\":\"" << EscapeJsonString(message.data) << '"';
    json << '}';
    return json.str();
}

std::optional<Message> ParseMessage(const std::string& json) {
    Message message;
    if (auto version = ExtractNumberField(json, "v")) {
        message.version = static_cast<uint32_t>(*version);
    } else {
        return std::nullopt;
    }
    if (auto type = ExtractStringField(json, "type")) {
        message.type = *type;
    } else {
        return std::nullopt;
    }
    if (auto id = ExtractStringField(json, "id")) {
        message.id = *id;
    }
    if (auto timestamp = ExtractNumberField(json, "ts")) {
        message.timestamp = *timestamp;
    }
    if (auto mime = ExtractStringField(json, "mime")) {
        message.mime = *mime;
    }
    if (auto deviceId = ExtractStringField(json, "deviceId")) {
        message.deviceId = *deviceId;
    }
    if (auto platform = ExtractStringField(json, "platform")) {
        message.platform = *platform;
    }
    if (auto data = ExtractStringField(json, "data")) {
        message.data = *data;
    }
    return message;
}

std::vector<uint8_t> EncodeFrame(const std::string& json) {
    const uint32_t length = static_cast<uint32_t>(json.size());
    if (length > kMaxPayloadSize) {
        return {};
    }
    std::vector<uint8_t> frame(4 + json.size());
    frame[0] = static_cast<uint8_t>((length >> 24) & 0xFF);
    frame[1] = static_cast<uint8_t>((length >> 16) & 0xFF);
    frame[2] = static_cast<uint8_t>((length >> 8) & 0xFF);
    frame[3] = static_cast<uint8_t>(length & 0xFF);
    std::copy(json.begin(), json.end(), frame.begin() + 4);
    return frame;
}

std::optional<std::string> Base64Encode(const std::vector<uint8_t>& bytes) {
    if (bytes.empty()) {
        return std::string();
    }
    DWORD encodedLength = 0;
    if (!CryptBinaryToStringA(bytes.data(),
                              static_cast<DWORD>(bytes.size()),
                              CRYPT_STRING_BASE64 | CRYPT_STRING_NOCRLF,
                              nullptr,
                              &encodedLength)) {
        return std::nullopt;
    }
    std::string encoded(encodedLength, '\0');
    if (!CryptBinaryToStringA(bytes.data(),
                              static_cast<DWORD>(bytes.size()),
                              CRYPT_STRING_BASE64 | CRYPT_STRING_NOCRLF,
                              encoded.data(),
                              &encodedLength)) {
        return std::nullopt;
    }
    while (!encoded.empty() && (encoded.back() == '\0' || encoded.back() == '\r' || encoded.back() == '\n')) {
        encoded.pop_back();
    }
    return encoded;
}

std::optional<std::vector<uint8_t>> Base64Decode(const std::string& encoded) {
    if (encoded.empty()) {
        return std::vector<uint8_t>{};
    }
    DWORD decodedLength = 0;
    if (!CryptStringToBinaryA(encoded.c_str(),
                              static_cast<DWORD>(encoded.size()),
                              CRYPT_STRING_BASE64,
                              nullptr,
                              &decodedLength,
                              nullptr,
                              nullptr)) {
        return std::nullopt;
    }
    std::vector<uint8_t> decoded(decodedLength);
    if (!CryptStringToBinaryA(encoded.c_str(),
                              static_cast<DWORD>(encoded.size()),
                              CRYPT_STRING_BASE64,
                              decoded.data(),
                              &decodedLength,
                              nullptr,
                              nullptr)) {
        return std::nullopt;
    }
    decoded.resize(decodedLength);
    return decoded;
}

}  // namespace sc
