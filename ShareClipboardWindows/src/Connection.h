#pragma once

#include "Protocol.h"

#include <atomic>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace sc {

class Connection : public std::enable_shared_from_this<Connection> {
public:
    using MessageHandler = std::function<void(const Message&)>;
    using CloseHandler = std::function<void()>;

    using HelloHandler = std::function<void(const std::string& peerId, const std::string& platform)>;

    Connection(uintptr_t socket, MessageHandler onMessage, HelloHandler onHello, CloseHandler onClose);
    ~Connection();

    void Start();
    void Close();
    bool Send(const Message& message);
    std::string PeerId() const;

    void SetPeerId(std::string peerId);
    void SetPlatform(std::string platform);
    std::string Platform() const;

private:
    void ReadLoop();
    void ProcessBuffer();
    bool WriteAll(const std::vector<uint8_t>& data);
    void NotifyClosed();
    void ShutdownLocked(bool fromReader);

    uintptr_t socket_;
    MessageHandler onMessage_;
    HelloHandler onHello_;
    CloseHandler onClose_;
    std::thread reader_;
    std::mutex writeMutex_;
    std::vector<uint8_t> readBuffer_;
    std::atomic<bool> running_{false};
    std::atomic<bool> closeNotified_{false};
    std::string peerId_;
    std::string platform_;
};

}  // namespace sc
