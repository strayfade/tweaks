#include "SyncEngine.h"
#include "Log.h"

#include <WinSock2.h>
#include <WS2tcpip.h>

#include <algorithm>
#include <sstream>

#pragma comment(lib, "Ws2_32.lib")
#pragma comment(lib, "Dnsapi.lib")

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

Message ClipboardPayloadToMessage(const ClipboardPayload& payload) {
    Message message;
    message.type = payload.type;
    message.id = NewMessageId();
    message.timestamp = CurrentTimestampMs();
    message.mime = payload.mime;
    message.data = payload.data;
    return message;
}

std::string PeerIdFromInstance(const DNS_SERVICE_INSTANCE* instance) {
    if (!instance || instance->dwPropertyCount == 0 || !instance->keys || !instance->values) {
        return {};
    }
    for (DWORD index = 0; index < instance->dwPropertyCount; ++index) {
        if (instance->keys[index] && wcscmp(instance->keys[index], L"id") == 0 && instance->values[index]) {
            return WideToUtf8(instance->values[index]);
        }
    }
    return {};
}

std::wstring LocalMdnsHostName() {
    wchar_t computerName[MAX_COMPUTERNAME_LENGTH + 1];
    DWORD size = MAX_COMPUTERNAME_LENGTH + 1;
    if (!GetComputerNameW(computerName, &size)) {
        return L"shareclipboard-pc.local";
    }

    std::wstring host;
    host.reserve(size + 7);
    for (DWORD index = 0; index < size; ++index) {
        wchar_t ch = computerName[index];
        if (ch == L' ' || ch == L'_') {
            host.push_back(L'-');
        } else if (iswalnum(ch) || ch == L'-') {
            host.push_back(ch);
        }
    }
    if (host.empty()) {
        host = L"shareclipboard-pc";
    }
    if (host.size() > 63) {
        host.resize(63);
    }
    host += L".local";
    return host;
}

}  // namespace

SyncEngine::SyncEngine() {
    WSADATA wsaData{};
    WSAStartup(MAKEWORD(2, 2), &wsaData);
}

SyncEngine::~SyncEngine() {
    Stop();
    WSACleanup();
}

void SyncEngine::Start() {
    Enqueue({WorkItem::Type::Start});
}

void SyncEngine::Stop() {
    Enqueue({WorkItem::Type::Stop});
    workerRunning_.store(false);
    cv_.notify_all();
    if (worker_.joinable()) {
        worker_.join();
    }
}

void SyncEngine::SetClipboard(Clipboard* clipboard) {
    std::lock_guard<std::mutex> lock(mutex_);
    clipboard_ = clipboard;
    if (clipboard_) {
        clipboard_->SetAppliedHandler([this](const std::string& fingerprint) {
            NoteAppliedFingerprint(fingerprint);
        });
    }
}

void SyncEngine::NoteAppliedFingerprint(const std::string& fingerprint) {
    std::lock_guard<std::mutex> lock(mutex_);
    lastAppliedFingerprint_ = fingerprint;
}

void SyncEngine::ScheduleClipboardSync() {
    Enqueue({WorkItem::Type::ClipboardSync});
}

std::size_t SyncEngine::ConnectedPeerCount() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return connections_.size();
}

bool SyncEngine::HasConnectedIosPeer() const {
    std::lock_guard<std::mutex> lock(mutex_);
    for (const auto& [peerId, connection] : connections_) {
        if (peerId.rfind("pending-", 0) == 0) {
            continue;
        }
        if (connection && connection->Platform() == "ios") {
            return true;
        }
    }
    return false;
}

void SyncEngine::WorkerLoop() {
    while (workerRunning_.load()) {
        WorkItem item;
        {
            std::unique_lock<std::mutex> lock(mutex_);
            cv_.wait(lock, [this] { return !work_.empty() || !workerRunning_.load(); });
            if (!workerRunning_.load() && work_.empty()) {
                break;
            }
            if (work_.empty()) {
                continue;
            }
            item = std::move(work_.front());
            work_.pop();
        }
        HandleWork(item);
    }
}

void SyncEngine::Enqueue(WorkItem item) {
    {
        std::lock_guard<std::mutex> lock(mutex_);
        const bool starting = item.type == WorkItem::Type::Start && !workerRunning_.load();
        work_.push(std::move(item));
        if (starting) {
            workerRunning_.store(true);
            worker_ = std::thread([this] { WorkerLoop(); });
        }
    }
    cv_.notify_one();
}

void SyncEngine::HandleWork(const WorkItem& item) {
    switch (item.type) {
        case WorkItem::Type::Start:
            StartLocked();
            break;
        case WorkItem::Type::Stop:
            StopLocked();
            break;
        case WorkItem::Type::ClipboardSync:
            PublishLocalClipboardLocked();
            break;
        case WorkItem::Type::ConnectPeer:
            ConnectToPeer(item.peerId, item.hostName, item.port);
            break;
        case WorkItem::Type::RemovePeer:
            if (connections_.count(item.peerId)) {
                connections_[item.peerId]->Close();
                connections_.erase(item.peerId);
            }
            connectingPeers_.erase(item.peerId);
            break;
        case WorkItem::Type::ConnectionClosed:
            RemoveConnection(item.connection);
            break;
    }
}

bool SyncEngine::StartLocked() {
    if (running_.load()) {
        return true;
    }
    if (!StartListenerLocked()) {
        return false;
    }
    if (!StartDiscoveryLocked()) {
        closesocket(listenSocket_);
        listenSocket_ = INVALID_SOCKET;
        return false;
    }

    acceptThread_ = std::thread([this] { AcceptLoop(); });
    running_.store(true);
    Logf("Sync engine started on port %u", listenPort_);
    return true;
}

void SyncEngine::StopLocked() {
    if (!running_.load()) {
        return;
    }

    running_.store(false);
    StopDiscoveryLocked();

    if (listenSocket_ != INVALID_SOCKET) {
        closesocket(listenSocket_);
        listenSocket_ = INVALID_SOCKET;
    }

    if (acceptThread_.joinable()) {
        acceptThread_.join();
    }

    for (auto& entry : connections_) {
        entry.second->Close();
    }
    connections_.clear();
    connectingPeers_.clear();
}

bool SyncEngine::StartListenerLocked() {
    listenSocket_ = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (listenSocket_ == INVALID_SOCKET) {
        return false;
    }

    BOOL yes = TRUE;
    setsockopt(listenSocket_, SOL_SOCKET, SO_REUSEADDR, reinterpret_cast<const char*>(&yes), sizeof(yes));

    sockaddr_in address{};
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_ANY);
    address.sin_port = 0;

    if (bind(listenSocket_, reinterpret_cast<sockaddr*>(&address), sizeof(address)) == SOCKET_ERROR ||
        listen(listenSocket_, SOMAXCONN) == SOCKET_ERROR) {
        closesocket(listenSocket_);
        listenSocket_ = INVALID_SOCKET;
        return false;
    }

    int addressLength = sizeof(address);
    if (getsockname(listenSocket_, reinterpret_cast<sockaddr*>(&address), &addressLength) == SOCKET_ERROR) {
        closesocket(listenSocket_);
        listenSocket_ = INVALID_SOCKET;
        return false;
    }

    listenPort_ = ntohs(address.sin_port);
    return true;
}

void SyncEngine::AcceptLoop() {
    while (running_.load()) {
        sockaddr_in clientAddress{};
        int clientLength = sizeof(clientAddress);
        SOCKET clientSocket = accept(listenSocket_, reinterpret_cast<sockaddr*>(&clientAddress), &clientLength);
        if (clientSocket == INVALID_SOCKET) {
            break;
        }

        if (connections_.size() >= kMaxConnections) {
            closesocket(clientSocket);
            continue;
        }

        auto weakHolder = std::make_shared<std::weak_ptr<Connection>>();
        auto connection = std::make_shared<Connection>(
            static_cast<uintptr_t>(clientSocket),
            [this](const Message& message) { HandleIncomingMessage(message); },
            [this, weakHolder](const std::string& peerId, const std::string& platform) {
                if (auto locked = weakHolder->lock()) {
                    locked->SetPlatform(platform);
                }
                if (peerId.empty() || peerId == DeviceId()) {
                    if (auto locked = weakHolder->lock()) {
                        locked->Close();
                    }
                    return;
                }
                if (auto locked = weakHolder->lock()) {
                    TrackConnection(peerId, locked);
                    Logf("Inbound peer identified: %s", peerId.c_str());
                }
            },
            [this, weakHolder]() {
                if (auto locked = weakHolder->lock()) {
                    Enqueue({WorkItem::Type::ConnectionClosed, {}, {}, 0, locked});
                }
            });

        *weakHolder = connection;
        connection->Start();
        TrackConnection("pending-" + std::to_string(reinterpret_cast<uintptr_t>(connection.get())), connection);
        Log("Accepted inbound TCP connection.");
    }
}

bool SyncEngine::StartDiscoveryLocked() {
    hostName_ = LocalMdnsHostName();
    serviceInstanceName_ = Utf8ToWide(SanitizedServiceName() + "._shareclipboard._tcp.local");
    txtValues_[0] = L"1";
    txtValues_[1] = Utf8ToWide(DeviceId());
    txtValues_[2] = L"windows";

    PCWSTR keys[] = {txtKeys_[0].c_str(), txtKeys_[1].c_str(), txtKeys_[2].c_str()};
    PCWSTR values[] = {txtValues_[0].c_str(), txtValues_[1].c_str(), txtValues_[2].c_str()};

    registeredInstance_ = DnsServiceConstructInstance(serviceInstanceName_.c_str(),
                                                      hostName_.c_str(),
                                                      nullptr,
                                                      nullptr,
                                                      listenPort_,
                                                      0,
                                                      0,
                                                      3,
                                                      keys,
                                                      values);
    if (!registeredInstance_) {
        Log("DnsServiceConstructInstance failed.");
        return false;
    }

    DNS_SERVICE_REGISTER_REQUEST registerRequest{};
    registerRequest.Version = DNS_QUERY_REQUEST_VERSION1;
    registerRequest.InterfaceIndex = 0;
    registerRequest.pServiceInstance = registeredInstance_;
    registerRequest.pRegisterCompletionCallback = RegisterCallback;
    registerRequest.pQueryContext = this;
    registerRequest.unicastEnabled = FALSE;

    const DWORD registerStatus = DnsServiceRegister(&registerRequest, &registerCancel_);
    if (registerStatus != ERROR_SUCCESS && registerStatus != DNS_REQUEST_PENDING) {
        Logf("DnsServiceRegister failed: %lu", registerStatus);
        DnsServiceFreeInstance(registeredInstance_);
        registeredInstance_ = nullptr;
        return false;
    }
    registerActive_ = true;
    Logf("Registering mDNS service '%ls' at host '%ls' port %u",
         serviceInstanceName_.c_str(),
         hostName_.c_str(),
         listenPort_);

    DNS_SERVICE_BROWSE_REQUEST browseRequest{};
    browseRequest.Version = DNS_QUERY_REQUEST_VERSION1;
    browseRequest.InterfaceIndex = 0;
    browseRequest.QueryName = L"_shareclipboard._tcp.local";
    browseRequest.pBrowseCallback = BrowseCallback;
    browseRequest.pQueryContext = this;

    const DNS_STATUS browseStatus = DnsServiceBrowse(&browseRequest, &browseCancel_);
    if (browseStatus != ERROR_SUCCESS && browseStatus != DNS_REQUEST_PENDING) {
        Logf("DnsServiceBrowse failed: %lu", browseStatus);
        if (registerActive_) {
            DnsServiceRegisterCancel(&registerCancel_);
            registerActive_ = false;
        }
        return false;
    }
    browseActive_ = true;
    Log("Started browsing for peers.");

    return true;
}

void SyncEngine::StopDiscoveryLocked() {
    if (browseActive_) {
        DnsServiceBrowseCancel(&browseCancel_);
        browseActive_ = false;
    }
    if (registerActive_) {
        DnsServiceRegisterCancel(&registerCancel_);
        registerActive_ = false;
    }
    if (registeredInstance_) {
        DnsServiceFreeInstance(registeredInstance_);
        registeredInstance_ = nullptr;
    }
}

VOID WINAPI SyncEngine::RegisterCallback(DWORD status, PVOID context, PDNS_SERVICE_INSTANCE instance) {
    (void)context;
    (void)instance;
    if (status == ERROR_SUCCESS) {
        Log("mDNS registration completed.");
    } else {
        Logf("mDNS registration callback failed: %lu", status);
    }
}

void SyncEngine::PublishLocalClipboardLocked() {
    if (!running_.load() || !clipboard_) {
        return;
    }
    if (clipboard_->applyingRemote()) {
        return;
    }

    const auto now = std::chrono::steady_clock::now();
    if (now < nextClipboardSync_) {
        return;
    }
    nextClipboardSync_ = now + std::chrono::milliseconds(250);

    const std::optional<ClipboardPayload> payload = clipboard_->ReadLocalPayload();
    if (!payload) {
        return;
    }
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!payload->fingerprint.empty() && payload->fingerprint == lastAppliedFingerprint_) {
            return;
        }
        if (!payload->fingerprint.empty() && payload->fingerprint == lastSentFingerprint_) {
            return;
        }
        lastSentFingerprint_ = payload->fingerprint;
    }

    BroadcastMessage(ClipboardPayloadToMessage(*payload));
}

void SyncEngine::BroadcastMessage(const Message& message) {
    std::size_t sent = 0;
    for (const auto& entry : connections_) {
        if (entry.first.rfind("pending-", 0) == 0) {
            continue;
        }
        if (entry.second->Send(message)) {
            ++sent;
        }
    }
    if (sent == 0) {
        Log("No peers connected; clipboard update not sent.");
    }
}

void SyncEngine::HandleIncomingMessage(const Message& message) {
    if (!running_.load()) {
        return;
    }
    if (message.version != kProtocolVersion) {
        return;
    }

    if (message.type == "hello") {
        return;
    }

    if (message.type == "text") {
        const std::vector<uint8_t> bytes(message.data.begin(), message.data.end());
        const std::string fingerprint = ContentFingerprint("text", bytes);
        if (fingerprint == lastAppliedFingerprint_) {
            return;
        }
        if (clipboard_) {
            clipboard_->ApplyRemoteText(message.data);
            Log("Applied remote text from peer.");
        }
        return;
    }

    if (message.type == "image") {
        const std::optional<std::vector<uint8_t>> pngBytes = Base64Decode(message.data);
        if (!pngBytes || pngBytes->empty() || pngBytes->size() > kMaxPayloadSize) {
            return;
        }
        const std::string fingerprint = ContentFingerprint("image", *pngBytes);
        if (fingerprint == lastAppliedFingerprint_) {
            return;
        }
        if (clipboard_) {
            clipboard_->ApplyRemoteImage(*pngBytes);
            Log("Applied remote image from peer.");
        }
    }
}

void SyncEngine::ConnectToPeer(const std::string& peerId, const std::string& hostName, uint16_t port) {
    if (!running_.load() || peerId.empty() || hostName.empty() || port == 0) {
        return;
    }
    if (connections_.count(peerId) || connectingPeers_.count(peerId) || connections_.size() >= kMaxConnections) {
        return;
    }
    connectingPeers_.insert(peerId);

    addrinfo hints{};
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_protocol = IPPROTO_TCP;

    addrinfo* result = nullptr;
    const std::string portString = std::to_string(port);
    if (getaddrinfo(hostName.c_str(), portString.c_str(), &hints, &result) != 0 || !result) {
        Logf("getaddrinfo failed for %s:%u", hostName.c_str(), port);
        connectingPeers_.erase(peerId);
        return;
    }

    SOCKET socketHandle = INVALID_SOCKET;
    for (addrinfo* current = result; current; current = current->ai_next) {
        socketHandle = socket(current->ai_family, current->ai_socktype, current->ai_protocol);
        if (socketHandle == INVALID_SOCKET) {
            continue;
        }
        if (connect(socketHandle, current->ai_addr, static_cast<int>(current->ai_addrlen)) == SOCKET_ERROR) {
            closesocket(socketHandle);
            socketHandle = INVALID_SOCKET;
            continue;
        }
        break;
    }
    freeaddrinfo(result);

    if (socketHandle == INVALID_SOCKET) {
        Logf("TCP connect failed for peer %s", peerId.c_str());
        connectingPeers_.erase(peerId);
        return;
    }

    Logf("Connected to peer %s", peerId.c_str());

    auto weakHolder = std::make_shared<std::weak_ptr<Connection>>();
    auto connection = std::make_shared<Connection>(
        static_cast<uintptr_t>(socketHandle),
        [this](const Message& message) { HandleIncomingMessage(message); },
        [weakHolder](const std::string&, const std::string& platform) {
            if (auto locked = weakHolder->lock()) {
                locked->SetPlatform(platform);
            }
        },
        [this, weakHolder, peerId]() {
            if (auto locked = weakHolder->lock()) {
                Enqueue({WorkItem::Type::ConnectionClosed, {}, {}, 0, locked});
            }
            connectingPeers_.erase(peerId);
        });

    *weakHolder = connection;
    connection->SetPeerId(peerId);
    TrackConnection(peerId, connection);
    connection->Start();
    connectingPeers_.erase(peerId);
}

void SyncEngine::TrackConnection(const std::string& peerId, const std::shared_ptr<Connection>& connection) {
    for (auto it = connections_.begin(); it != connections_.end();) {
        if (it->second == connection && it->first != peerId) {
            it = connections_.erase(it);
        } else {
            ++it;
        }
    }
    if (auto existing = connections_.find(peerId); existing != connections_.end() && existing->second != connection) {
        existing->second->Close();
    }
    connections_[peerId] = connection;
}

void SyncEngine::RemoveConnection(const std::shared_ptr<Connection>& connection) {
    if (!connection) {
        return;
    }
    for (auto it = connections_.begin(); it != connections_.end();) {
        if (it->second == connection) {
            connectingPeers_.erase(it->first);
            it = connections_.erase(it);
        } else {
            ++it;
        }
    }
}

std::string SyncEngine::PeerIdFromTxt(const std::vector<std::string>& txtRecords) {
    for (const std::string& entry : txtRecords) {
        if (entry.rfind("id=", 0) == 0) {
            return entry.substr(3);
        }
    }
    return {};
}

VOID WINAPI SyncEngine::BrowseCallback(DWORD status, PVOID context, PDNS_RECORD record) {
    auto* engine = static_cast<SyncEngine*>(context);
    if (!engine || !record) {
        if (record) {
            DnsRecordListFree(record, DnsFreeRecordList);
        }
        return;
    }

    if (status != ERROR_SUCCESS) {
        Logf("Browse callback status %lu", status);
        DnsRecordListFree(record, DnsFreeRecordList);
        return;
    }

    for (PDNS_RECORD current = record; current; current = current->pNext) {
        if (current->wType != DNS_TYPE_PTR || !current->Data.PTR.pNameHost) {
            continue;
        }

        const std::wstring instanceName = current->Data.PTR.pNameHost;
        Logf("Discovered service: %ls", instanceName.c_str());

        DNS_SERVICE_RESOLVE_REQUEST resolveRequest{};
        resolveRequest.Version = DNS_QUERY_REQUEST_VERSION1;
        resolveRequest.InterfaceIndex = 0;
        resolveRequest.QueryName = const_cast<PWSTR>(instanceName.c_str());
        resolveRequest.pResolveCompletionCallback = ResolveCallback;
        resolveRequest.pQueryContext = engine;

        DNS_SERVICE_CANCEL cancelHandle{};
        DnsServiceResolve(&resolveRequest, &cancelHandle);
    }

    DnsRecordListFree(record, DnsFreeRecordList);
}

VOID WINAPI SyncEngine::ResolveCallback(DWORD status, PVOID context, PDNS_SERVICE_INSTANCE instance) {
    auto* engine = static_cast<SyncEngine*>(context);
    if (!engine || status != ERROR_SUCCESS || !instance) {
        if (instance) {
            DnsServiceFreeInstance(instance);
        }
        if (status != ERROR_SUCCESS) {
            Logf("Resolve failed with status %lu", status);
        }
        return;
    }

    const std::string peerId = PeerIdFromInstance(instance);
    if (peerId.empty() || peerId == DeviceId()) {
        DnsServiceFreeInstance(instance);
        return;
    }

    const std::string localId = DeviceId();
    if (localId >= peerId) {
        Logf("Peer %s will connect to us (we are not the initiator).", peerId.c_str());
        DnsServiceFreeInstance(instance);
        return;
    }

    if (!instance->pszHostName || instance->wPort == 0) {
        Log("Resolve returned no hostname or port.");
        DnsServiceFreeInstance(instance);
        return;
    }

    Logf("Connecting to peer %s at %ls:%u", peerId.c_str(), instance->pszHostName, instance->wPort);

    WorkItem item;
    item.type = WorkItem::Type::ConnectPeer;
    item.peerId = peerId;
    item.hostName = WideToUtf8(instance->pszHostName);
    item.port = instance->wPort;
    engine->Enqueue(std::move(item));

    DnsServiceFreeInstance(instance);
}

}  // namespace sc
