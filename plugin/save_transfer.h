#pragma once
#include <algorithm>
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

// Pure assembly only: no save files or engine calls. Exact chunk coverage is
// required before a caller may write a received save.
struct CoopSaveTransfer {
    static constexpr uint32_t chunk_size = 192 * 1024;
    struct Metadata {
        uint32_t xfer = 0, total = 0;
        uint64_t seed = 0;
        int32_t category = 0, offset = 0, slot = -1, flags = 0;
        bool operator==(const Metadata& b) const {
            return xfer==b.xfer && total==b.total && seed==b.seed && category==b.category
                && offset==b.offset && slot==b.slot && flags==b.flags;
        }
    } metadata;
    enum class Result { rejected, partial, complete };
    std::string bytes;
    std::vector<uint8_t> seen;
    std::vector<uint32_t> retired;
    uint32_t received = 0;
    bool active = false;

    void clear() { *this = CoopSaveTransfer{}; }
    void retire() {
        if (metadata.xfer) {
            retired.push_back(metadata.xfer);
            if (retired.size()>64) retired.erase(retired.begin());
        }
        active=false;bytes.clear();bytes.shrink_to_fit();seen.clear();
    }
    Result accept(const Metadata& m, uint32_t off, const char* data, size_t length) {
        if (!m.xfer || !m.total || m.total>(32u<<20) || m.slot<0 || m.category<0 || m.offset<0
            || (m.flags&~1) || off>=m.total || off%chunk_size
            || length!=std::min(chunk_size,m.total-off)) return Result::rejected;
        if (std::find(retired.begin(),retired.end(),m.xfer)!=retired.end()) return Result::rejected;
        if (!active || metadata.xfer!=m.xfer) {
            if (active) retire();
            metadata=m;received=0;bytes.assign(m.total,'\0');seen.assign((m.total+chunk_size-1)/chunk_size,0);active=true;
        } else if (!(metadata==m)) return Result::rejected;
        const auto index=off/chunk_size;
        if (seen[index]) {
            // Repeated chunks never increase the received-byte count.
            return std::memcmp(bytes.data()+off,data,length)==0 ? Result::partial : Result::rejected;
        }
        std::memcpy(&bytes[off],data,length);seen[index]=1;received+=static_cast<uint32_t>(length);
        return received==metadata.total ? Result::complete : Result::partial;
    }
};
