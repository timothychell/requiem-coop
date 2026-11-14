// Requiem Co-op network plugin (REFramework plugin DLL)
//
// Replaces the Python relay. Moves the in-game script's state between two players over
//   * Steam (friends-only lobby + invites + ISteamNetworkingMessages P2P), or
//   * direct UDP (host / join by IP), or
//   * local echo (solo test).
//
// File interface with requiem_coop.lua (all in reframework/data):
//   coop_out.json   written by Lua: our state           -> sent to partner
//   coop_in.json    written here : partner's state      -> read by Lua
//   coop_cmd.json   written by Lua: {"id":N,"cmd":"...","arg":"..."}  (UI buttons)
//   coop_link.json  written here : connection status for the UI
//
// Build: see build.bat (MSVC, x64).

#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <compressapi.h>

#include <atomic>
#include <cstdint>
#include <cstdio>
#include <mutex>
#include <string>
#include <vector>

#include "include/reframework/API.h"
#include "third_party/lua/lua.hpp"   // the exact Lua 5.4.3 sources REFramework is built with
#include "save_transfer.h"

#pragma comment(lib, "ws2_32.lib")
#pragma comment(lib, "Cabinet.lib")

static const int PROTO = 5;  // v5: binary state, in-memory Lua bridge
static const uint16_t DEFAULT_PORT = 27777;

// ---------------------------------------------------------------------------
// utils
// ---------------------------------------------------------------------------
static std::string g_dir;  // ...\reframework\data\  (trailing slash)
static std::string g_save_dir;  // ...\Steam\userdata\<acct>\<appid>\remote\win64_save (with trailing slash)
static std::string g_dir_for_restore() { return g_dir; }
static std::mutex g_log_mtx;

static void logf(const char* fmt, ...) {
    std::lock_guard<std::mutex> lk(g_log_mtx);
    FILE* f = nullptr;
    if (fopen_s(&f, (g_dir + "coop_net_log.txt").c_str(), "a") != 0 || !f) return;
    SYSTEMTIME st; GetLocalTime(&st);
    fprintf(f, "[%02d:%02d:%02d.%03d] ", st.wHour, st.wMinute, st.wSecond, st.wMilliseconds);
    va_list ap; va_start(ap, fmt); vfprintf(f, fmt, ap); va_end(ap);
    fputc('\n', f);
    fclose(f);
}

static double now_s() {
    static LARGE_INTEGER freq = [] { LARGE_INTEGER f; QueryPerformanceFrequency(&f); return f; }();
    LARGE_INTEGER c; QueryPerformanceCounter(&c);
    return double(c.QuadPart) / double(freq.QuadPart);
}

static bool read_file(const std::string& path, std::string& out) {
    HANDLE h = CreateFileA(path.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                           nullptr, OPEN_EXISTING, 0, nullptr);
    if (h == INVALID_HANDLE_VALUE) return false;
    LARGE_INTEGER sz; GetFileSizeEx(h, &sz);
    out.resize((size_t)sz.QuadPart);
    DWORD rd = 0;
    bool ok = sz.QuadPart == 0 || ReadFile(h, out.data(), (DWORD)out.size(), &rd, nullptr);
    CloseHandle(h);
    out.resize(rd);
    return ok;
}

static uint64_t file_stamp(const std::string& path) {
    WIN32_FILE_ATTRIBUTE_DATA a;
    if (!GetFileAttributesExA(path.c_str(), GetFileExInfoStandard, &a)) return 0;
    return (uint64_t(a.ftLastWriteTime.dwHighDateTime) << 32 | a.ftLastWriteTime.dwLowDateTime) ^ a.nFileSizeLow;
}

static bool write_atomic(const std::string& path, const std::string& data) {
    std::string tmp = path + ".tmp";
    HANDLE h = CreateFileA(tmp.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, 0, nullptr);
    if (h == INVALID_HANDLE_VALUE) return false;
    DWORD wr = 0;
    WriteFile(h, data.data(), (DWORD)data.size(), &wr, nullptr);
    CloseHandle(h);
    for (int i = 0; i < 10; ++i) {
        if (MoveFileExA(tmp.c_str(), path.c_str(), MOVEFILE_REPLACE_EXISTING)) return true;
        Sleep(1);  // the game is reading it right now
    }
    return false;
}

static std::string slot_file(int id) {
    char b[64];
    if (id == 0) sprintf_s(b, "data000.bin");          // the first autosave has no "Slot" suffix
    else sprintf_s(b, "data%03dSlot.bin", id);
    return b;
}

// joiner: we temporarily replace one of our slot files with the host's. coop_restore.json remembers
// what to put back, so even a crash mid-load gets repaired the next time the game starts.
static std::string g_dir_for_restore();
static void restore_swapped_slot(const std::string& save_dir) {
    std::string marker = g_dir_for_restore() + "coop_restore.json", m;
    if (!read_file(marker, m)) return;
    size_t a = m.find("\"file\":\""), b;
    if (a == std::string::npos) { DeleteFileA(marker.c_str()); return; }
    a += 8; b = m.find('"', a);
    std::string file = m.substr(a, b - a);
    bool had = m.find("\"had\":1") != std::string::npos;
    std::string path = save_dir + file, bak = path + ".coopbak";
    if (had) MoveFileExA(bak.c_str(), path.c_str(), MOVEFILE_REPLACE_EXISTING);
    else DeleteFileA(path.c_str());
    DeleteFileA(marker.c_str());
}

static std::string json_escape(const char* s) {
    std::string o;
    for (; s && *s; ++s) {
        unsigned char c = (unsigned char)*s;
        if (c == '"' || c == '\\') { o += '\\'; o += (char)c; }
        else if (c < 0x20) { char b[8]; sprintf_s(b, "\\u%04x", c); o += b; }
        else o += (char)c;
    }
    return o;
}

// tiny extractor for flat JSON objects written by Lua: "key": "str" | number
static bool json_get(const std::string& j, const char* key, std::string& out) {
    std::string k = std::string("\"") + key + "\"";
    size_t p = j.find(k);
    if (p == std::string::npos) return false;
    p = j.find(':', p + k.size());
    if (p == std::string::npos) return false;
    ++p;
    while (p < j.size() && (j[p] == ' ' || j[p] == '\t' || j[p] == '\n' || j[p] == '\r')) ++p;
    if (p >= j.size()) return false;
    out.clear();
    if (j[p] == '"') {
        for (++p; p < j.size() && j[p] != '"'; ++p) {
            if (j[p] == '\\' && p + 1 < j.size()) ++p;
            out += j[p];
        }
        return true;
    }
    while (p < j.size() && j[p] != ',' && j[p] != '}' && j[p] != ' ' && j[p] != '\n' && j[p] != '\r') out += j[p++];
    return !out.empty();
}

// ---------------------------------------------------------------------------
// compression (Windows Compression API, MSZIP)
// ---------------------------------------------------------------------------
static COMPRESSOR_HANDLE g_comp = nullptr;
static DECOMPRESSOR_HANDLE g_decomp = nullptr;

static bool compress_buf(const std::string& in, std::string& out) {
    if (!g_comp && !CreateCompressor(COMPRESS_ALGORITHM_MSZIP, nullptr, &g_comp)) return false;
    out.resize(in.size() + 1024);
    SIZE_T n = 0;
    if (!Compress(g_comp, in.data(), in.size(), out.data(), out.size(), &n)) return false;
    out.resize(n);
    return true;
}

static bool decompress_buf(const char* in, size_t len, std::string& out) {
    if (!g_decomp && !CreateDecompressor(COMPRESS_ALGORITHM_MSZIP, nullptr, &g_decomp)) return false;
    SIZE_T need = 0;
    Decompress(g_decomp, in, len, nullptr, 0, &need);
    if (need == 0 || need > (16u << 20)) return false;
    out.resize(need);
    SIZE_T n = 0;
    if (!Decompress(g_decomp, in, len, out.data(), out.size(), &n)) return false;
    out.resize(n);
    return true;
}

// ---------------------------------------------------------------------------
// Steam flat API (loaded from the game's steam_api64.dll)
// ---------------------------------------------------------------------------
typedef uint64_t SteamAPICall_t;

// Must match Valve's CCallbackBase layout (MSVC, same declaration order).
class CCallbackBase {
public:
    virtual void Run(void* pvParam) = 0;
    virtual void Run(void* pvParam, bool bIOFailure, SteamAPICall_t hSteamAPICall) = 0;
    virtual int GetCallbackSizeBytes() = 0;
    uint8_t m_nCallbackFlags = 0;
    int m_iCallback = 0;
};

#pragma pack(push, 8)
struct LobbyCreated_t { int m_eResult; uint64_t m_ulSteamIDLobby; };                     // 513
struct LobbyEnter_t { uint64_t m_ulSteamIDLobby; uint32_t m_rgfChatPermissions; bool m_bLocked; uint32_t m_EChatRoomEnterResponse; }; // 504
struct GameLobbyJoinRequested_t { uint64_t m_steamIDLobby; uint64_t m_steamIDFriend; };  // 333
struct FriendGameInfo_t { uint64_t m_gameID; uint32_t m_unGameIP; uint16_t m_usGamePort; uint16_t m_usQueryPort; uint64_t m_steamIDLobby; };
struct SteamNetworkingIdentity { int m_eType; int m_cbSize; union { uint64_t m_steamID64; char m_reserved[128]; }; };
struct SteamNetworkingMessage_t {
    void* m_pData; int m_cbSize; uint32_t m_conn; SteamNetworkingIdentity m_identityPeer;
    int64_t m_nConnUserData; int64_t m_usecTimeReceived; int64_t m_nMessageNumber;
    void* m_pfnFreeData; void* m_pfnRelease; int m_nChannel; int m_nFlags; int64_t m_nUserData; uint16_t m_idxLane;
};
struct SessionRequest_t { SteamNetworkingIdentity m_identityRemote; };                    // 1251
#pragma pack(pop)

struct Steam {
    bool ok = false;
    void *mm = nullptr, *fr = nullptr, *user = nullptr, *utils = nullptr, *msgs = nullptr;
    uint64_t me = 0;
    uint32_t appid = 0;

    SteamAPICall_t (*CreateLobby)(void*, int, int);
    SteamAPICall_t (*JoinLobby)(void*, uint64_t);
    void (*LeaveLobby)(void*, uint64_t);
    bool (*SetLobbyData)(void*, uint64_t, const char*, const char*);
    int (*GetNumLobbyMembers)(void*, uint64_t);
    uint64_t (*GetLobbyMemberByIndex)(void*, uint64_t, int);
    uint64_t (*GetLobbyOwner)(void*, uint64_t);
    const char* (*GetPersonaName)(void*);
    int (*GetFriendCount)(void*, int);
    uint64_t (*GetFriendByIndex)(void*, int, int);
    bool (*GetFriendGamePlayed)(void*, uint64_t, FriendGameInfo_t*);
    const char* (*GetFriendPersonaName)(void*, uint64_t);
    void (*ActivateGameOverlayInviteDialog)(void*, uint64_t);
    bool (*IsAPICallCompleted)(void*, SteamAPICall_t, bool*);
    bool (*GetAPICallResult)(void*, SteamAPICall_t, void*, int, int, bool*);
    uint32_t (*GetAppID)(void*);
    uint64_t (*GetSteamID)(void*);
    bool (*GetUserDataFolder)(void*, char*, int);
    int (*SendMessageToUser)(void*, const SteamNetworkingIdentity*, const void*, uint32_t, int, int);
    int (*ReceiveMessagesOnChannel)(void*, int, SteamNetworkingMessage_t**, int);
    bool (*AcceptSessionWithUser)(void*, const SteamNetworkingIdentity*);
    bool (*CloseSessionWithUser)(void*, const SteamNetworkingIdentity*);
    void (*IdClear)(SteamNetworkingIdentity*);
    void (*IdSetSteamID64)(SteamNetworkingIdentity*, uint64_t);
    void (*MsgRelease)(SteamNetworkingMessage_t*);
    void (*RegisterCallResult)(CCallbackBase*, SteamAPICall_t);
    void (*UnregisterCallResult)(CCallbackBase*, SteamAPICall_t);
    void (*RegisterCallback)(CCallbackBase*, int);
} S;

template <class T> static bool load_fn(HMODULE m, const char* name, T& fn) {
    fn = (T)GetProcAddress(m, name);
    if (!fn) logf("missing steam export %s", name);
    return fn != nullptr;
}

static bool steam_init() {
    HMODULE m = GetModuleHandleA("steam_api64.dll");
    if (!m) return false;
    void* (*getMM)() = nullptr; void* (*getFR)() = nullptr; void* (*getUser)() = nullptr;
    void* (*getUtils)() = nullptr; void* (*getMsgs)() = nullptr;
    bool ok = load_fn(m, "SteamAPI_SteamMatchmaking_v009", getMM) && load_fn(m, "SteamAPI_SteamFriends_v017", getFR) &&
              load_fn(m, "SteamAPI_SteamUser_v021", getUser) && load_fn(m, "SteamAPI_SteamUtils_v010", getUtils) &&
              load_fn(m, "SteamAPI_SteamNetworkingMessages_SteamAPI_v002", getMsgs);
    ok = ok && load_fn(m, "SteamAPI_ISteamMatchmaking_CreateLobby", S.CreateLobby) &&
         load_fn(m, "SteamAPI_ISteamMatchmaking_JoinLobby", S.JoinLobby) &&
         load_fn(m, "SteamAPI_ISteamMatchmaking_LeaveLobby", S.LeaveLobby) &&
         load_fn(m, "SteamAPI_ISteamMatchmaking_SetLobbyData", S.SetLobbyData) &&
         load_fn(m, "SteamAPI_ISteamMatchmaking_GetNumLobbyMembers", S.GetNumLobbyMembers) &&
         load_fn(m, "SteamAPI_ISteamMatchmaking_GetLobbyMemberByIndex", S.GetLobbyMemberByIndex) &&
         load_fn(m, "SteamAPI_ISteamMatchmaking_GetLobbyOwner", S.GetLobbyOwner) &&
         load_fn(m, "SteamAPI_ISteamFriends_GetPersonaName", S.GetPersonaName) &&
         load_fn(m, "SteamAPI_ISteamFriends_GetFriendCount", S.GetFriendCount) &&
         load_fn(m, "SteamAPI_ISteamFriends_GetFriendByIndex", S.GetFriendByIndex) &&
         load_fn(m, "SteamAPI_ISteamFriends_GetFriendGamePlayed", S.GetFriendGamePlayed) &&
         load_fn(m, "SteamAPI_ISteamFriends_GetFriendPersonaName", S.GetFriendPersonaName) &&
         load_fn(m, "SteamAPI_ISteamFriends_ActivateGameOverlayInviteDialog", S.ActivateGameOverlayInviteDialog) &&
         load_fn(m, "SteamAPI_ISteamUtils_IsAPICallCompleted", S.IsAPICallCompleted) &&
         load_fn(m, "SteamAPI_ISteamUtils_GetAPICallResult", S.GetAPICallResult) &&
         load_fn(m, "SteamAPI_ISteamUtils_GetAppID", S.GetAppID) &&
         load_fn(m, "SteamAPI_ISteamUser_GetSteamID", S.GetSteamID) &&
         load_fn(m, "SteamAPI_ISteamUser_GetUserDataFolder", S.GetUserDataFolder) &&
         load_fn(m, "SteamAPI_ISteamNetworkingMessages_SendMessageToUser", S.SendMessageToUser) &&
         load_fn(m, "SteamAPI_ISteamNetworkingMessages_ReceiveMessagesOnChannel", S.ReceiveMessagesOnChannel) &&
         load_fn(m, "SteamAPI_ISteamNetworkingMessages_AcceptSessionWithUser", S.AcceptSessionWithUser) &&
         load_fn(m, "SteamAPI_ISteamNetworkingMessages_CloseSessionWithUser", S.CloseSessionWithUser) &&
         load_fn(m, "SteamAPI_SteamNetworkingIdentity_Clear", S.IdClear) &&
         load_fn(m, "SteamAPI_SteamNetworkingIdentity_SetSteamID64", S.IdSetSteamID64) &&
         load_fn(m, "SteamAPI_SteamNetworkingMessage_t_Release", S.MsgRelease) &&
         load_fn(m, "SteamAPI_RegisterCallResult", S.RegisterCallResult) &&
         load_fn(m, "SteamAPI_UnregisterCallResult", S.UnregisterCallResult) &&
         load_fn(m, "SteamAPI_RegisterCallback", S.RegisterCallback);
    if (!ok) return false;
    S.mm = getMM(); S.fr = getFR(); S.user = getUser(); S.utils = getUtils(); S.msgs = getMsgs();
    if (!S.mm || !S.fr || !S.user || !S.utils || !S.msgs) return false;
    S.me = S.GetSteamID(S.user);
    S.appid = S.GetAppID(S.utils);
    S.ok = S.me != 0;
    char ud[MAX_PATH] = {};
    if (S.ok && S.GetUserDataFolder(S.user, ud, sizeof(ud))) {
        // <steam>/userdata/<account>/<appid>/local  ->  .../remote/win64_save/
        std::string u = ud;
        while (!u.empty() && (u.back() == '\\' || u.back() == '/')) u.pop_back();
        u = u.substr(0, u.find_last_of("\\/") + 1);
        g_save_dir = u + "remote\\win64_save\\";
        logf("save dir: %s", g_save_dir.c_str());
    }
    return S.ok;
}

static SteamNetworkingIdentity make_id(uint64_t sid) {
    SteamNetworkingIdentity id;
    S.IdClear(&id);
    S.IdSetSteamID64(&id, sid);
    return id;
}

// ---------------------------------------------------------------------------
// session state
// ---------------------------------------------------------------------------
enum class Mode { None, SteamHost, SteamJoin, UdpHost, UdpJoin, Echo };
static const char* mode_name(Mode m) {
    switch (m) {
    case Mode::SteamHost: return "steam_host"; case Mode::SteamJoin: return "steam_join";
    case Mode::UdpHost: return "udp_host"; case Mode::UdpJoin: return "udp_join";
    case Mode::Echo: return "echo"; default: return "none";
    }
}

static std::mutex g_mtx;  // guards everything below (Steam callbacks arrive on the game thread)
static std::atomic<Mode> g_mode{Mode::None};
static std::string g_state = "idle";
static std::string g_error;
static uint64_t g_lobby = 0;
static std::atomic<uint64_t> g_partner{0};
static std::atomic<uint64_t> g_pending_join{0};  // lobby requested via invite, handled on our thread

static SOCKET g_sock = INVALID_SOCKET;
static sockaddr_in g_peer{};
static bool g_has_peer = false;

static double g_last_rx = -100, g_last_hello = 0;

// save transfer: any save slot, swapped into the SAME slot on the joiner (saves are tied to their slot)
static const uint32_t CHUNK = 192 * 1024;
static int g_save_cat = 0, g_save_ofs = 0, g_save_id = 0, g_save_auto = 0;
static int g_save_req_seq = 0;      // host: partner asked for our save this many times
static int g_save_rx_seq = 0;       // joiner: completed transfers
static std::string g_save_seed;     // joiner: Steam ID that encrypted the received save
static std::string g_save_state;    // human readable transfer status
static CoopSaveTransfer g_save_transfer;

// small text events between the two scripts ("ready:1", "newgame:ID0010", ...), newest last
struct Event { int seq; std::string text; };
static std::vector<Event> g_events;
static int g_event_seq = 0;

// packets waiting for the Lua script (read with coopnet.poll())
struct Incoming { char kind; bool echo; std::string data; };
static std::mutex g_inbox_mtx;
static std::vector<Incoming> g_inbox;

static void inbox_push(char kind, bool echo, const char* d, size_t n) {
    std::lock_guard<std::mutex> lk(g_inbox_mtx);
    if (g_inbox.size() > 512) g_inbox.erase(g_inbox.begin(), g_inbox.begin() + 256);  // script not polling
    g_inbox.push_back({ kind, echo, std::string(d, n) });
}
static int g_rx_count = 0, g_tx_count = 0, g_rx_rate = 0, g_tx_rate = 0;

// call results ---------------------------------------------------------------
struct LobbyCreatedCR : CCallbackBase {
    SteamAPICall_t h = 0; double t = 0; std::atomic<bool> done{false};
    LobbyCreated_t r{};
    void Run(void* p) override { Run(p, false, h); }
    void Run(void* p, bool io, SteamAPICall_t) override { if (!io) r = *(LobbyCreated_t*)p; else r.m_eResult = -1; done = true; }
    int GetCallbackSizeBytes() override { return sizeof(LobbyCreated_t); }
} g_cr_create;

struct LobbyEnterCR : CCallbackBase {
    SteamAPICall_t h = 0; double t = 0; std::atomic<bool> done{false};
    LobbyEnter_t r{};
    void Run(void* p) override { Run(p, false, h); }
    void Run(void* p, bool io, SteamAPICall_t) override { if (!io) r = *(LobbyEnter_t*)p; else r.m_EChatRoomEnterResponse = 0; done = true; }
    int GetCallbackSizeBytes() override { return sizeof(LobbyEnter_t); }
} g_cr_enter;

// callbacks ------------------------------------------------------------------
struct JoinRequestedCB : CCallbackBase {
    void Run(void* p) override {
        auto* r = (GameLobbyJoinRequested_t*)p;
        g_pending_join = r->m_steamIDLobby;  // never block the game thread
    }
    void Run(void* p, bool, SteamAPICall_t) override { Run(p); }
    int GetCallbackSizeBytes() override { return sizeof(GameLobbyJoinRequested_t); }
} g_cb_join;

struct SessionRequestCB : CCallbackBase {
    void Run(void* p) override {
        auto* r = (SessionRequest_t*)p;
        uint64_t who = r->m_identityRemote.m_steamID64;
        bool accept = (g_partner == who) || (g_mode == Mode::SteamHost && g_partner == 0);
        if (accept) S.AcceptSessionWithUser(S.msgs, &r->m_identityRemote);
        logf("session request from %llu -> %s", (unsigned long long)who, accept ? "accepted" : "ignored");
    }
    void Run(void* p, bool, SteamAPICall_t) override { Run(p); }
    int GetCallbackSizeBytes() override { return sizeof(SessionRequest_t); }
} g_cb_session;

template <class CR, class R> static bool poll_call(CR& cr, int cb_id) {
    // normally the game's SteamAPI_RunCallbacks delivers it; if it doesn't, fetch it ourselves
    if (cr.done) return true;
    if (!cr.h) return false;
    if (now_s() - cr.t > 2.0) {
        bool failed = false;
        if (S.IsAPICallCompleted(S.utils, cr.h, &failed)) {
            R r{};
            bool got = S.GetAPICallResult(S.utils, cr.h, &r, sizeof(R), cb_id, &failed);
            S.UnregisterCallResult(&cr, cr.h);
            if (got && !failed) cr.r = r;
            cr.done = true;
            logf("call result %d fetched by polling (ok=%d)", cb_id, got && !failed);
            return true;
        }
    }
    return false;
}

// ---------------------------------------------------------------------------
// session control
// ---------------------------------------------------------------------------
static void close_udp() {
    if (g_sock != INVALID_SOCKET) closesocket(g_sock);
    g_sock = INVALID_SOCKET;
    g_has_peer = false;
}

static void leave_all() {
    g_save_transfer.clear();
    if (g_lobby && S.ok) S.LeaveLobby(S.mm, g_lobby);
    if (g_partner && S.ok) { auto id = make_id(g_partner); S.CloseSessionWithUser(S.msgs, &id); }
    close_udp();
    g_lobby = g_partner = 0;
    g_cr_create.h = g_cr_enter.h = 0;
    g_mode = Mode::None;
    g_state = "idle";
}

static bool open_udp(uint16_t port) {
    close_udp();
    g_sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (g_sock == INVALID_SOCKET) return false;
    u_long nb = 1; ioctlsocket(g_sock, FIONBIO, &nb);
    BOOL no = FALSE; DWORD br = 0;  // stop ICMP "port unreachable" from breaking recvfrom
    WSAIoctl(g_sock, _WSAIOW(IOC_VENDOR, 12), &no, sizeof(no), nullptr, 0, &br, nullptr, nullptr);
    int rcv = 1 << 20; setsockopt(g_sock, SOL_SOCKET, SO_RCVBUF, (char*)&rcv, sizeof(rcv));
    sockaddr_in a{}; a.sin_family = AF_INET; a.sin_port = htons(port); a.sin_addr.s_addr = INADDR_ANY;
    if (bind(g_sock, (sockaddr*)&a, sizeof(a)) != 0) { close_udp(); return false; }
    return true;
}

static void start_steam_join(uint64_t lobby) {
    leave_all();
    g_cr_enter.done = false;
    g_cr_enter.m_iCallback = 504;
    g_cr_enter.h = S.JoinLobby(S.mm, lobby);
    g_cr_enter.t = now_s();
    S.RegisterCallResult(&g_cr_enter, g_cr_enter.h);
    g_mode = Mode::SteamJoin;
    g_state = "joining lobby";
    logf("joining lobby %llu", (unsigned long long)lobby);
}

static void send_save_slot(const std::string& arg);
static void send_event_text(const std::string& text);
static void send_reliable(const std::string& pkt);
static std::string make_packet(char type, const std::string& payload);

static void handle_command(const std::string& cmd, const std::string& arg) {
    logf("command: %s %s", cmd.c_str(), arg.c_str());
    std::lock_guard<std::mutex> lk(g_mtx);
    g_error.clear();
    if (cmd == "leave") { leave_all(); return; }
    if (cmd == "steam_host") {
        if (!S.ok) { g_error = "Steam not available"; return; }
        leave_all();
        g_cr_create.done = false;
        g_cr_create.m_iCallback = 513;
        g_cr_create.h = S.CreateLobby(S.mm, 1 /*friends only*/, 2);
        g_cr_create.t = now_s();
        S.RegisterCallResult(&g_cr_create, g_cr_create.h);
        g_mode = Mode::SteamHost;
        g_state = "creating lobby";
        return;
    }
    if (cmd == "steam_join") {
        if (!S.ok) { g_error = "Steam not available"; return; }
        uint64_t lobby = _strtoui64(arg.c_str(), nullptr, 10);
        if (!lobby) { g_error = "bad lobby id"; return; }
        start_steam_join(lobby);
        return;
    }
    if (cmd == "invite") {
        if (S.ok && g_lobby) S.ActivateGameOverlayInviteDialog(S.fr, g_lobby);
        else g_error = "host a session first";
        return;
    }
    if (cmd == "udp_host") {
        leave_all();
        uint16_t port = arg.empty() ? DEFAULT_PORT : (uint16_t)atoi(arg.c_str());
        if (!open_udp(port)) { g_error = "could not open UDP port " + std::to_string(port); return; }
        g_mode = Mode::UdpHost;
        g_state = "waiting for partner";
        return;
    }
    if (cmd == "udp_join") {
        leave_all();
        std::string host = arg; uint16_t port = DEFAULT_PORT;
        size_t c = arg.rfind(':');
        if (c != std::string::npos) { host = arg.substr(0, c); port = (uint16_t)atoi(arg.c_str() + c + 1); }
        addrinfo hints{}, *res = nullptr; hints.ai_family = AF_INET; hints.ai_socktype = SOCK_DGRAM;
        if (getaddrinfo(host.c_str(), nullptr, &hints, &res) != 0 || !res) { g_error = "can't resolve " + host; return; }
        g_peer = *(sockaddr_in*)res->ai_addr; g_peer.sin_port = htons(port);
        freeaddrinfo(res);
        if (!open_udp(0)) { g_error = "could not open UDP socket"; return; }
        g_has_peer = true;
        g_mode = Mode::UdpJoin;
        g_state = "connecting";
        return;
    }
    if (cmd == "echo") { leave_all(); g_mode = Mode::Echo; g_state = "echo test"; return; }
    if (cmd == "request_save") {
        g_save_state = "asking host for their save";
        send_reliable(make_packet('R' /* PK_SAVE_REQ */, ""));
        return;
    }
    if (cmd == "send_slot") { send_save_slot(arg); return; }
    if (cmd == "event") { if (g_mode != Mode::Echo) send_event_text(arg); return; }
    if (cmd == "restore_slot") { restore_swapped_slot(g_save_dir); g_save_state = "restored your own save slot"; return; }
    g_error = "unknown command " + cmd;
}

// ---------------------------------------------------------------------------
// packets: "RQ" + proto byte + type + payload
// ---------------------------------------------------------------------------
enum : char { PK_STATE = 'S', PK_ENEMY = 'N', PK_HELLO = 'H', PK_SAVE_REQ = 'R', PK_SAVE_CHUNK = 'F', PK_EVENT = 'E' };

static std::string make_packet(char type, const std::string& payload) {
    std::string p = "RQ";
    p += (char)PROTO; p += type; p += payload;
    return p;
}

static void on_packet(const char* d, size_t n, bool echo) {
    if (n < 4 || d[0] != 'R' || d[1] != 'Q') return;
    if (d[2] != (char)PROTO) {
        g_error = "partner has a different mod version";
        return;
    }
    if (d[3] == PK_STATE || d[3] == PK_ENEMY) {
        inbox_push(d[3], echo, d + 4, n - 4);
        if (d[3] == PK_STATE) { g_last_rx = now_s(); ++g_rx_count; }
    } else if (d[3] == PK_EVENT) {
        inbox_push('E', echo, d + 4, n - 4);
        if (n - 4 < 200) logf("event from partner: %.*s", (int)(n - 4), d + 4);
    } else if (d[3] == PK_SAVE_REQ) {
        ++g_save_req_seq;
        g_save_state = "partner asked for our save";
        logf("partner requested save (#%d)", g_save_req_seq);
    } else if (d[3] == PK_SAVE_CHUNK && n >= 4 + 36) {
        uint32_t xfer, total, off; uint64_t seed; int32_t cat, ofs, id, flags;
        memcpy(&xfer, d + 4, 4); memcpy(&total, d + 8, 4); memcpy(&off, d + 12, 4); memcpy(&seed, d + 16, 8);
        memcpy(&cat, d + 24, 4); memcpy(&ofs, d + 28, 4); memcpy(&id, d + 32, 4); memcpy(&flags, d + 36, 4);
        const char* data = d + 40; size_t len = n - 40;
        CoopSaveTransfer::Metadata metadata{xfer,total,seed,cat,ofs,id,flags};
        const auto result=g_save_transfer.accept(metadata,off,data,len);
        if (result==CoopSaveTransfer::Result::rejected) return;
        g_save_state = "receiving host's save " + std::to_string((uint64_t)g_save_transfer.received * 100 / total) + "%";
        if (result==CoopSaveTransfer::Result::complete) {
            if (g_save_dir.empty()) { g_error = "can't find this PC's save folder"; return; }
            restore_swapped_slot(g_save_dir);  // put back anything left over from an earlier swap first
            std::string file = slot_file(id), path = g_save_dir + file, bak = path + ".coopbak";
            bool had = GetFileAttributesA(path.c_str()) != INVALID_FILE_ATTRIBUTES;
            if (had && !CopyFileA(path.c_str(), bak.c_str(), FALSE)) { g_error = "couldn't back up your save slot"; return; }
            write_atomic(g_dir + "coop_restore.json", "{\"file\":\"" + file + "\",\"had\":" + (had ? "1" : "0") + "}");
            if (write_atomic(path, g_save_transfer.bytes)) {
                g_save_seed = std::to_string(seed);
                g_save_cat = cat; g_save_ofs = ofs; g_save_id = id; g_save_auto = flags & 1;
                ++g_save_rx_seq;
                g_save_state = "host's save received";
                logf("save received: slot %d (%d,%d) %u bytes, seed %llu, backup=%d", id, cat, ofs, total, (unsigned long long)seed, had);
            } else {
                g_error = "couldn't write the host's save";
                restore_swapped_slot(g_save_dir);
            }
            g_save_transfer.retire();
        }
    }
}

static void send_raw(const std::string& pkt) {
    switch (g_mode) {
    case Mode::SteamHost: case Mode::SteamJoin:
        if (g_partner) {
            auto id = make_id(g_partner);
            S.SendMessageToUser(S.msgs, &id, pkt.data(), (uint32_t)pkt.size(), 1 /*no nagle*/ | 32 /*auto restart*/, 0);
            ++g_tx_count;
        }
        break;
    case Mode::UdpHost: case Mode::UdpJoin:
        if (g_has_peer) { sendto(g_sock, pkt.data(), (int)pkt.size(), 0, (sockaddr*)&g_peer, sizeof(g_peer)); ++g_tx_count; }
        break;
    case Mode::Echo:
        ++g_tx_count;
        on_packet(pkt.data(), pkt.size(), true);
        break;
    default: break;
    }
}

static void send_reliable(const std::string& pkt) {
    if (g_mode == Mode::Echo) { on_packet(pkt.data(), pkt.size(), true); return; }
    if ((g_mode == Mode::SteamHost || g_mode == Mode::SteamJoin) && g_partner) {
        auto id = make_id(g_partner);
        S.SendMessageToUser(S.msgs, &id, pkt.data(), (uint32_t)pkt.size(), 8 /*reliable*/ | 32, 1);
    } else {
        g_error = "save sync needs a Steam session";
    }
}

static void send_event_text(const std::string& text) {
    auto pkt = make_packet(PK_EVENT, text);
    if (g_mode == Mode::Echo) { on_packet(pkt.data(), pkt.size(), true); return; }
    if ((g_mode == Mode::SteamHost || g_mode == Mode::SteamJoin) && g_partner) {
        auto id = make_id(g_partner);
        S.SendMessageToUser(S.msgs, &id, pkt.data(), (uint32_t)pkt.size(), 8 /*reliable*/ | 32, 1);
    } else if (g_has_peer && g_sock != INVALID_SOCKET) {
        sendto(g_sock, pkt.data(), (int)pkt.size(), 0, (sockaddr*)&g_peer, sizeof(g_peer));
    }
}

// arg: "cat,ofs,id,auto"
static void send_save_slot(const std::string& arg) {
    int cat = 0, ofs = 0, id = -1, autoload = 0;
    if (sscanf_s(arg.c_str(), "%d,%d,%d,%d", &cat, &ofs, &id, &autoload) < 3 || id < 0) { g_error = "bad slot " + arg; return; }
    std::string data;
    std::string path = g_save_dir + slot_file(id);
    if (g_save_dir.empty() || !read_file(path, data) || data.empty()) {
        char alt[64]; sprintf_s(alt, "data%03d.bin", id);
        if (!read_file(g_save_dir + alt, data) || data.empty()) { g_error = "save file for slot " + std::to_string(id) + " not found"; return; }
    }
    uint32_t xfer = GetTickCount() | 1, total = (uint32_t)data.size();
    uint64_t seed = S.me;
    int32_t flags = autoload ? 1 : 0;
    for (uint32_t off = 0; off < total; off += CHUNK) {
        uint32_t len = std::min(CHUNK, total - off);
        std::string body(36, '\0');
        memcpy(&body[0], &xfer, 4); memcpy(&body[4], &total, 4); memcpy(&body[8], &off, 4); memcpy(&body[12], &seed, 8);
        memcpy(&body[20], &cat, 4); memcpy(&body[24], &ofs, 4); memcpy(&body[28], &id, 4); memcpy(&body[32], &flags, 4);
        body.append(data, off, len);
        send_reliable(make_packet(PK_SAVE_CHUNK, body));
    }
    g_save_state = "sent save slot " + std::to_string(id) + " (" + std::to_string(total / 1024) + " KB)";
    logf("sent save slot %d (%d,%d) %u bytes", id, cat, ofs, total);
}

// ---------------------------------------------------------------------------
// worker
// ---------------------------------------------------------------------------
static std::string g_friends_json = "[]";

static void refresh_friends() {
    if (!S.ok) return;
    std::string j = "[";
    int n = S.GetFriendCount(S.fr, 4 /*immediate*/);
    for (int i = 0; i < n; ++i) {
        uint64_t f = S.GetFriendByIndex(S.fr, i, 4);
        FriendGameInfo_t gi{};
        if (!S.GetFriendGamePlayed(S.fr, f, &gi)) continue;
        if ((uint32_t)(gi.m_gameID & 0xFFFFFF) != S.appid) continue;
        if (j.size() > 1) j += ",";
        j += "{\"name\":\"" + json_escape(S.GetFriendPersonaName(S.fr, f)) + "\",\"lobby\":\"" +
             std::to_string(gi.m_steamIDLobby) + "\",\"id\":\"" + std::to_string(f) + "\"}";
    }
    g_friends_json = j + "]";
}

static void steam_tick() {
    // lobby creation finished?
    if (g_mode == Mode::SteamHost && g_cr_create.h && poll_call<LobbyCreatedCR, LobbyCreated_t>(g_cr_create, 513)) {
        g_cr_create.h = 0;
        if (g_cr_create.r.m_eResult == 1) {
            g_lobby = g_cr_create.r.m_ulSteamIDLobby;
            S.SetLobbyData(S.mm, g_lobby, "rqcoop", std::to_string(PROTO).c_str());
            g_state = "hosting - invite your partner";
            logf("lobby created %llu", (unsigned long long)g_lobby);
            S.ActivateGameOverlayInviteDialog(S.fr, g_lobby);
        } else {
            g_error = "Steam couldn't create a lobby (result " + std::to_string(g_cr_create.r.m_eResult) + ")";
            g_mode = Mode::None; g_state = "idle";
        }
    }
    // joined?
    if (g_mode == Mode::SteamJoin && g_cr_enter.h && poll_call<LobbyEnterCR, LobbyEnter_t>(g_cr_enter, 504)) {
        g_cr_enter.h = 0;
        if (g_cr_enter.r.m_EChatRoomEnterResponse == 1) {
            g_lobby = g_cr_enter.r.m_ulSteamIDLobby;
            g_state = "in lobby";
            logf("entered lobby %llu", (unsigned long long)g_lobby);
        } else {
            g_error = "couldn't join (response " + std::to_string(g_cr_enter.r.m_EChatRoomEnterResponse) + ")";
            g_mode = Mode::None; g_state = "idle";
        }
    }
    // who's our partner?
    if (g_lobby) {
        uint64_t partner = 0;
        int n = S.GetNumLobbyMembers(S.mm, g_lobby);
        for (int i = 0; i < n; ++i) {
            uint64_t m = S.GetLobbyMemberByIndex(S.mm, g_lobby, i);
            if (m && m != S.me) { partner = m; break; }
        }
        if (partner != g_partner) {
            logf("partner %llu -> %llu", (unsigned long long)g_partner.load(), (unsigned long long)partner);
            g_partner = partner;
            if (partner) { auto id = make_id(partner); S.AcceptSessionWithUser(S.msgs, &id); }
        }
        if (g_mode == Mode::SteamJoin && n > 0 && S.GetLobbyOwner(S.mm, g_lobby) == S.me && !partner) {
            g_error = "host left the session";
            leave_all();
        }
    }
    // receive
    SteamNetworkingMessage_t* msgs[32];
    for (int ch = 0; ch <= 1; ++ch) {
        int got = S.ReceiveMessagesOnChannel(S.msgs, ch, msgs, 32);
        for (int i = 0; i < got; ++i) {
            auto* m = msgs[i];
            if (m->m_identityPeer.m_steamID64 == g_partner) on_packet((const char*)m->m_pData, m->m_cbSize, false);
            S.MsgRelease(m);
        }
    }
}

static void udp_tick() {
    if (g_sock == INVALID_SOCKET) return;
    char buf[65536];
    for (;;) {
        sockaddr_in from{}; int fl = sizeof(from);
        int n = recvfrom(g_sock, buf, sizeof(buf), 0, (sockaddr*)&from, &fl);
        if (n <= 0) break;
        if (n >= 4 && buf[0] == 'R' && buf[1] == 'Q') {
            if (g_mode == Mode::UdpHost && (!g_has_peer || g_peer.sin_addr.s_addr != from.sin_addr.s_addr || g_peer.sin_port != from.sin_port)) {
                g_peer = from; g_has_peer = true;
                char ip[64]; inet_ntop(AF_INET, &from.sin_addr, ip, sizeof(ip));
                logf("udp partner %s:%d", ip, ntohs(from.sin_port));
            }
            if (buf[3] == PK_HELLO) {
                if (g_mode == Mode::UdpHost) { auto h = make_packet(PK_HELLO, ""); sendto(g_sock, h.data(), (int)h.size(), 0, (sockaddr*)&from, fl); }
                g_last_rx = now_s();
                continue;
            }
            on_packet(buf, (size_t)n, false);
        }
    }
    double t = now_s();
    if (g_mode == Mode::UdpJoin && t - g_last_hello > 1.0 && t - g_last_rx > 2.0) {
        g_last_hello = t;
        auto h = make_packet(PK_HELLO, "");
        sendto(g_sock, h.data(), (int)h.size(), 0, (sockaddr*)&g_peer, sizeof(g_peer));
    }
}

static void write_link() {
    double t = now_s();
    bool connected = (t - g_last_rx) < 3.0;
    std::string state = g_state;
    if (g_mode != Mode::None && g_mode != Mode::Echo) {
        if (connected) state = "connected";
        else if ((g_mode == Mode::SteamHost || g_mode == Mode::SteamJoin) && g_lobby && g_partner) state = "partner in lobby, waiting for data";
    } else if (g_mode == Mode::Echo && connected) state = "connected";

    std::string peer;
    if (g_partner && S.ok) peer = S.GetFriendPersonaName(S.fr, g_partner);
    else if (g_has_peer) { char ip[64]; inet_ntop(AF_INET, &g_peer.sin_addr, ip, sizeof(ip)); peer = std::string(ip) + ":" + std::to_string(ntohs(g_peer.sin_port)); }

    std::string j = "{";
    j += "\"plugin\":true,\"proto\":" + std::to_string(PROTO);
    j += ",\"mode\":\"" + std::string(mode_name(g_mode.load())) + "\"";
    j += ",\"state\":\"" + json_escape(state.c_str()) + "\"";
    j += ",\"connected\":" + std::string(connected ? "true" : "false");
    j += ",\"error\":\"" + json_escape(g_error.c_str()) + "\"";
    j += ",\"peer\":\"" + json_escape(peer.c_str()) + "\"";
    j += ",\"steam\":" + std::string(S.ok ? "true" : "false");
    j += ",\"me\":\"" + json_escape(S.ok ? S.GetPersonaName(S.fr) : "") + "\"";
    j += ",\"lobby\":\"" + (g_lobby ? std::to_string(g_lobby) : std::string()) + "\"";
    j += ",\"rx_rate\":" + std::to_string(g_rx_rate) + ",\"tx_rate\":" + std::to_string(g_tx_rate);
    j += ",\"friends\":" + g_friends_json;
    j += ",\"events\":[";
    for (size_t i = 0; i < g_events.size(); ++i) {
        if (i) j += ",";
        j += "{\"s\":" + std::to_string(g_events[i].seq) + ",\"e\":\"" + json_escape(g_events[i].text.c_str()) + "\"}";
    }
    j += "]";
    j += ",\"save_req_seq\":" + std::to_string(g_save_req_seq);
    j += ",\"save_rx_seq\":" + std::to_string(g_save_rx_seq);
    j += ",\"save_seed\":\"" + g_save_seed + "\"";
    j += ",\"save_cat\":" + std::to_string(g_save_cat) + ",\"save_ofs\":" + std::to_string(g_save_ofs);
    j += ",\"save_id\":" + std::to_string(g_save_id) + ",\"save_auto\":" + std::to_string(g_save_auto);
    j += ",\"save_state\":\"" + json_escape(g_save_state.c_str()) + "\"";
    // File writes run on the game thread (and may be scanned by antivirus), so an
    // unchanged status is only rewritten as a 1 s heartbeat for the Lua liveness check.
    static std::string last_body;
    static double last_write = -100;
    if (j == last_body && t - last_write < 1.0) return;
    last_body = j; last_write = t;
    j += ",\"updated\":" + std::to_string((long long)time(nullptr));
    j += "}";
    write_atomic(g_dir + "coop_link.json", j);
}

// ---------------------------------------------------------------------------
// per-frame tick (runs on the game thread via REFramework; never on a thread of our own,
// because REFramework suspends all threads while installing hooks and a suspended worker
// holding the heap/CRT lock deadlocks the game)
// ---------------------------------------------------------------------------
static std::string g_last_cmd_id;
static uint64_t g_out_stamp = 0, g_cmd_stamp = 0;
static double g_next_steam_try = 0, g_next_link = 0, g_next_rate = 0, g_next_friends = 0;
static bool g_cb_registered = false;

static void tick() {
    double t = now_s();
    if (!S.ok && t >= g_next_steam_try) {
        g_next_steam_try = t + 2.0;
        if (steam_init()) {
            logf("steam ready: user %llu app %u", (unsigned long long)S.me, S.appid);
            if (!g_save_dir.empty()) restore_swapped_slot(g_save_dir);  // repair an interrupted co-op load
            // Steam starts connections at a low send rate and throttles above it; pose + enemy updates need more.
            HMODULE sm = GetModuleHandleA("steam_api64.dll");
            auto getUtils = (void* (*)())GetProcAddress(sm, "SteamAPI_SteamNetworkingUtils_SteamAPI_v004");
            auto setInt = (bool (*)(void*, int, int))GetProcAddress(sm, "SteamAPI_ISteamNetworkingUtils_SetGlobalConfigValueInt32");
            if (getUtils && setInt) {
                void* nu = getUtils();
                bool a = nu && setInt(nu, 10 /*SendRateMin*/, 1024 * 1024);
                bool b = nu && setInt(nu, 11 /*SendRateMax*/, 8 * 1024 * 1024);
                bool c = nu && setInt(nu, 9 /*SendBufferSize*/, 2 * 1024 * 1024);
                logf("steam send rate raised: %d %d %d", a, b, c);
            }
            if (!g_cb_registered) {
                g_cb_registered = true;
                S.RegisterCallback(&g_cb_join, 333);
                S.RegisterCallback(&g_cb_session, 1251);
            }
        }
    }

    // UI commands (polled at 10 Hz: a file stat per frame is wasted work on the game thread)
    static double next_cmd_poll = 0;
    uint64_t cs = 0;
    if (t >= next_cmd_poll) { next_cmd_poll = t + 0.1; cs = file_stamp(g_dir + "coop_cmd.json"); }
    if (cs && cs != g_cmd_stamp) {
        g_cmd_stamp = cs;
        std::string c, id, cmd, arg;
        if (read_file(g_dir + "coop_cmd.json", c) && json_get(c, "id", id) && id != g_last_cmd_id && json_get(c, "cmd", cmd)) {
            g_last_cmd_id = id;
            json_get(c, "arg", arg);
            if (cmd == "refresh_friends") refresh_friends();
            else handle_command(cmd, arg);
        }
    }

    std::lock_guard<std::mutex> lk(g_mtx);
    // accepted a Steam invite (or "Join game" in the friends list)
    if (g_pending_join && S.ok) {
        uint64_t l = g_pending_join.exchange(0);
        if (l != g_lobby) start_steam_join(l);
    }
    if (S.ok) steam_tick();
    udp_tick();


    if (t >= g_next_rate) { g_next_rate = t + 1; g_rx_rate = g_rx_count; g_tx_rate = g_tx_count; g_rx_count = g_tx_count = 0; }
    if (t >= g_next_friends) { g_next_friends = t + 5; refresh_friends(); }
    if (t >= g_next_link) { g_next_link = t + 0.25; write_link(); }
}

static void on_late_update() {
    __try { tick(); } __except (EXCEPTION_EXECUTE_HANDLER) { logf("tick crashed (exception %08lx)", GetExceptionCode()); }
}

// ---------------------------------------------------------------------------
// Lua bridge: a global table "coopnet" in REFramework's Lua state.
// These never raise Lua errors (bad input just returns nil/false).
// ---------------------------------------------------------------------------
static bool lua_arg_bytes(lua_State* L, int idx, std::string& out) {
    if (lua_type(L, idx) != LUA_TSTRING) return false;
    size_t n = 0;
    const char* p = lua_tolstring(L, idx, &n);
    out.assign(p, n);
    return true;
}

static int l_send_state(lua_State* L) {
    std::string b;
    if (!lua_arg_bytes(L, 1, b)) { lua_pushboolean(L, 0); return 1; }
    std::lock_guard<std::mutex> lk(g_mtx);
    if (g_mode == Mode::None) { lua_pushboolean(L, 0); return 1; }
    send_raw(make_packet(PK_STATE, b));
    lua_pushboolean(L, 1);
    return 1;
}

static int l_send_enemy(lua_State* L) {
    std::string b;
    if (!lua_arg_bytes(L, 1, b)) { lua_pushboolean(L, 0); return 1; }
    std::lock_guard<std::mutex> lk(g_mtx);
    if (g_mode == Mode::None || g_mode == Mode::Echo) { lua_pushboolean(L, 0); return 1; }
    send_raw(make_packet(PK_ENEMY, b));
    lua_pushboolean(L, 1);
    return 1;
}

static int l_send_event(lua_State* L) {
    std::string b;
    if (!lua_arg_bytes(L, 1, b)) { lua_pushboolean(L, 0); return 1; }
    std::lock_guard<std::mutex> lk(g_mtx);
    if (g_mode == Mode::None || g_mode == Mode::Echo) { lua_pushboolean(L, 0); return 1; }
    send_event_text(b);
    lua_pushboolean(L, 1);
    return 1;
}

// returns an array of { k = "S"|"N"|"E", e = echo(bool), d = bytes }
static int l_poll(lua_State* L) {
    std::vector<Incoming> items;
    {
        std::lock_guard<std::mutex> lk(g_inbox_mtx);
        items.swap(g_inbox);
    }
    lua_createtable(L, (int)items.size(), 0);
    int i = 0;
    for (auto& it : items) {
        lua_createtable(L, 0, 3);
        char k[2] = { it.kind, 0 };
        lua_pushstring(L, k); lua_setfield(L, -2, "k");
        lua_pushboolean(L, it.echo ? 1 : 0); lua_setfield(L, -2, "e");
        lua_pushlstring(L, it.data.data(), it.data.size()); lua_setfield(L, -2, "d");
        lua_rawseti(L, -2, ++i);
    }
    return 1;
}

static int l_version(lua_State* L) { lua_pushinteger(L, PROTO); return 1; }

static void on_lua_state_created(lua_State* L) {
    lua_createtable(L, 0, 5);
    lua_pushcfunction(L, l_send_state); lua_setfield(L, -2, "send_state");
    lua_pushcfunction(L, l_send_enemy); lua_setfield(L, -2, "send_enemy");
    lua_pushcfunction(L, l_send_event); lua_setfield(L, -2, "send_event");
    lua_pushcfunction(L, l_poll);       lua_setfield(L, -2, "poll");
    lua_pushcfunction(L, l_version);    lua_setfield(L, -2, "version");
    lua_setglobal(L, "coopnet");
    logf("coopnet registered in Lua state %p", (void*)L);
}

static void on_lua_state_destroyed(lua_State*) {
    std::lock_guard<std::mutex> lk(g_inbox_mtx);
    g_inbox.clear();
}

// ---------------------------------------------------------------------------
// entry points
// ---------------------------------------------------------------------------
extern "C" __declspec(dllexport) void reframework_plugin_required_version(REFrameworkPluginVersion* v) {
    v->major = REFRAMEWORK_PLUGIN_VERSION_MAJOR;
    v->minor = REFRAMEWORK_PLUGIN_VERSION_MINOR;
    v->patch = REFRAMEWORK_PLUGIN_VERSION_PATCH;
}

extern "C" __declspec(dllexport) bool reframework_plugin_initialize(const REFrameworkPluginInitializeParam* param) {
    char exe[MAX_PATH]; GetModuleFileNameA(nullptr, exe, MAX_PATH);
    std::string d = exe; d = d.substr(0, d.find_last_of("\\/") + 1);
    g_dir = d + "reframework\\data\\";
    CreateDirectoryA(g_dir.c_str(), nullptr);

    WSADATA wsa; WSAStartup(MAKEWORD(2, 2), &wsa);
    logf("plugin started (proto %d)", PROTO);
    DeleteFileA((g_dir + "coop_in.json").c_str());  // stale partner data from a previous session
    {   // don't replay the last UI command from a previous run
        std::string c; if (read_file(g_dir + "coop_cmd.json", c)) json_get(c, "id", g_last_cmd_id);
    }
    g_next_rate = now_s() + 1;

    if (param && param->functions) {
        param->functions->on_lua_state_created(on_lua_state_created);
        param->functions->on_lua_state_destroyed(on_lua_state_destroyed);
    }
    if (!param || !param->functions || !param->functions->on_pre_application_entry("LateUpdateBehavior", on_late_update)) {
        logf("could not register the frame callback");
        return false;
    }
    return true;
}
