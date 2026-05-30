#include "Connection.h"

#include <WinSock2.h>
#include <WS2tcpip.h>

namespace sc {
namespace {

uint32_t ReadUInt32BE(const uint8_t* bytes) {
    return (static_cast<uint32_t>(bytes[0]) << 24) | (static_cast<uint32_t>(bytes[1]) << 16) |
           (static_cast<uint32_t>(bytes[2]) << 8) | static_cast<uint32_t>(bytes[3]);
}

Message MakeHelloMessage() {
    Message message;
    message.type = "hello";
    message.deviceId = DeviceId();
    message.platform = "windows";
    message.data = "";
    return message;
}

}  // namespace

Connection::Connection(uintptr_t socket, MessageHandler onMessage, HelloHandler onHello, CloseHandler onClose)
    : socket_(socket), onMessage_(std::move(onMessage)), onHello_(std::move(onHello)), onClose_(std::move(onClose)) {}

Connection::~Connection() {
    Close();
}

void Connection::Start() {
    if (running_.exchange(true)) {
        return;
    }
    Send(MakeHelloMessage());
    reader_ = std::thread([self = shared_from_this()] { self->ReadLoop(); });
}

void Connection::Close() {
    running_.store(false);

    SOCKET socket = static_cast<SOCKET>(socket_);
    if (socket != INVALID_SOCKET) {
        shutdown(socket, SD_BOTH);
        closesocket(socket);
        socket_ = static_cast<uintptr_t>(INVALID_SOCKET);
    }

    if (reader_.joinable() && reader_.get_id() != std::this_thread::get_id()) {
        reader_.join();
    }

    NotifyClosed();
}

void Connection::ShutdownLocked(bool fromReader) {
    (void)fromReader;
    running_.store(false);

    SOCKET socket = static_cast<SOCKET>(socket_);
    if (socket != INVALID_SOCKET) {
        shutdown(socket, SD_BOTH);
        closesocket(socket);
        socket_ = static_cast<uintptr_t>(INVALID_SOCKET);
    }
}

void Connection::NotifyClosed() {
    if (closeNotified_.exchange(true)) {
        return;
    }

    CloseHandler handler = std::move(onClose_);
    onClose_ = nullptr;
    if (handler) {
        handler();
    }
}

bool Connection::Send(const Message& message) {
    if (!running_.load()) {
        return false;
    }

    const std::string json = SerializeMessage(message);
    if (json.empty() || json.size() > kMaxPayloadSize) {
        return false;
    }

    const std::vector<uint8_t> frame = EncodeFrame(json);
    if (frame.empty()) {
        return false;
    }

    std::lock_guard<std::mutex> lock(writeMutex_);
    return WriteAll(frame);
}

std::string Connection::PeerId() const {
    return peerId_;
}

void Connection::SetPeerId(std::string peerId) {
    peerId_ = std::move(peerId);
}

void Connection::SetPlatform(std::string platform) {
    platform_ = std::move(platform);
}

std::string Connection::Platform() const {
    return platform_;
}

void Connection::ReadLoop() {
    uint8_t buffer[8192];
    while (running_.load()) {
        SOCKET socket = static_cast<SOCKET>(socket_);
        if (socket == INVALID_SOCKET) {
            break;
        }

        const int received = recv(socket, reinterpret_cast<char*>(buffer), static_cast<int>(sizeof(buffer)), 0);
        if (received <= 0) {
            break;
        }

        readBuffer_.insert(readBuffer_.end(), buffer, buffer + received);
        ProcessBuffer();
    }

    ShutdownLocked(true);
    NotifyClosed();
}

void Connection::ProcessBuffer() {
    while (readBuffer_.size() >= 4) {
        const uint32_t payloadLength = ReadUInt32BE(readBuffer_.data());
        if (payloadLength == 0 || payloadLength > kMaxPayloadSize) {
            running_.store(false);
            break;
        }

        const std::size_t frameLength = 4 + payloadLength;
        if (readBuffer_.size() < frameLength) {
            return;
        }

        const std::string json(reinterpret_cast<const char*>(readBuffer_.data() + 4), payloadLength);
        readBuffer_.erase(readBuffer_.begin(), readBuffer_.begin() + static_cast<std::ptrdiff_t>(frameLength));

        const std::optional<Message> message = ParseMessage(json);
        if (!message) {
            continue;
        }

        if (message->type == "hello") {
            if (!message->deviceId.empty()) {
                peerId_ = message->deviceId;
            }
            platform_ = message->platform.empty() ? "unknown" : message->platform;
            if (onHello_) {
                onHello_(peerId_, platform_);
            }
            continue;
        }

        if (onMessage_) {
            onMessage_(*message);
        }
    }
}

bool Connection::WriteAll(const std::vector<uint8_t>& data) {
    SOCKET socket = static_cast<SOCKET>(socket_);
    if (socket == INVALID_SOCKET) {
        return false;
    }

    std::size_t offset = 0;
    while (offset < data.size()) {
        const int written =
            send(socket, reinterpret_cast<const char*>(data.data() + offset), static_cast<int>(data.size() - offset), 0);
        if (written <= 0) {
            return false;
        }
        offset += static_cast<std::size_t>(written);
    }
    return true;
}

}  // namespace sc
