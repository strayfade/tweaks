#pragma once

#include "Clipboard.h"
#include "Connection.h"

#include <WinSock2.h>
#include <Windows.h>
#include <windns.h>

#include <array>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <memory>
#include <mutex>
#include <queue>
#include <string>
#include <thread>
#include <unordered_map>
#include <unordered_set>
#include <vector>

namespace sc {

class SyncEngine {
public:
    SyncEngine();
    ~SyncEngine();

    void Start();
    void Stop();
    void SetClipboard(Clipboard* clipboard);
    void ScheduleClipboardSync();
    void NoteAppliedFingerprint(const std::string& fingerprint);

    std::size_t ConnectedPeerCount() const;
    bool HasConnectedIosPeer() const;

private:
    struct WorkItem {
        enum class Type { Start, Stop, ClipboardSync, ConnectPeer, RemovePeer, ConnectionClosed };
        Type type = Type::ClipboardSync;
        std::string peerId;
        std::string hostName;
        uint16_t port = 0;
        std::shared_ptr<Connection> connection;
    };

    void WorkerLoop();
    void Enqueue(WorkItem item);
    void HandleWork(const WorkItem& item);

    bool StartLocked();
    void StopLocked();
    bool StartListenerLocked();
    void AcceptLoop();
    bool StartDiscoveryLocked();
    void StopDiscoveryLocked();
    void PublishLocalClipboardLocked();
    void BroadcastMessage(const Message& message);
    void HandleIncomingMessage(const Message& message);
    void ConnectToPeer(const std::string& peerId, const std::string& hostName, uint16_t port);
    void TrackConnection(const std::string& peerId, const std::shared_ptr<Connection>& connection);
    void RemoveConnection(const std::shared_ptr<Connection>& connection);
    static std::string PeerIdFromTxt(const std::vector<std::string>& txtRecords);

    static VOID WINAPI BrowseCallback(DWORD status, PVOID context, PDNS_RECORD record);
    static VOID WINAPI ResolveCallback(DWORD status, PVOID context, PDNS_SERVICE_INSTANCE instance);
    static VOID WINAPI RegisterCallback(DWORD status, PVOID context, PDNS_SERVICE_INSTANCE instance);

    Clipboard* clipboard_ = nullptr;
    std::thread worker_;
    std::thread acceptThread_;
    mutable std::mutex mutex_;
    std::condition_variable cv_;
    std::queue<WorkItem> work_;
    std::atomic<bool> running_{false};
    std::atomic<bool> workerRunning_{false};

    SOCKET listenSocket_ = INVALID_SOCKET;
    uint16_t listenPort_ = 0;
    DNS_SERVICE_CANCEL browseCancel_{};
    DNS_SERVICE_CANCEL registerCancel_{};
    bool browseActive_ = false;
    bool registerActive_ = false;
    PDNS_SERVICE_INSTANCE registeredInstance_ = nullptr;
    std::wstring serviceInstanceName_;
    std::wstring hostName_;
    std::array<std::wstring, 3> txtKeys_{L"v", L"id", L"platform"};
    std::array<std::wstring, 3> txtValues_{};

    std::unordered_map<std::string, std::shared_ptr<Connection>> connections_;
    std::unordered_set<std::string> connectingPeers_;

    std::string lastSentFingerprint_;
    std::string lastAppliedFingerprint_;
    std::chrono::steady_clock::time_point nextClipboardSync_{};
};

}  // namespace sc
