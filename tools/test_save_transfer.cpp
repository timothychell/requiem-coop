#include "../plugin/save_transfer.h"
#include <iostream>
#include <stdexcept>
static int passed=0;
static void check(bool ok,const char* why) { ++passed;if(!ok)throw std::runtime_error(why); }
int main() {
    using T=CoopSaveTransfer;using R=T::Result;
    for(uint32_t size : {1u,1024u,T::chunk_size,T::chunk_size+1,3*T::chunk_size+77}) {
        std::string payload(size,'x');for(uint32_t i=0;i<size;i++)payload[i]=char(i%251);
        T t;T::Metadata m{31,size,123,0,0,1,1};
        // Last chunk first; repeated chunks cannot complete a transfer early.
        for(uint32_t index=(size-1)/T::chunk_size+1;index-->0;) {
            auto off=index*T::chunk_size;auto len=std::min(T::chunk_size,size-off);
            const auto r=t.accept(m,off,payload.data()+off,len);
            check(r==(index==0?R::complete:R::partial),"out-of-order completion");
            const auto received=t.received;
            check(t.accept(m,off,payload.data()+off,len)==R::partial,"duplicate result");
            check(t.received==received,"duplicate counted twice");
        }
        check(t.bytes==payload,"assembled bytes differ");
        auto changed=m;changed.total++;
        check(t.accept(changed,0,payload.data(),std::min(T::chunk_size,size))==R::rejected,"changed total accepted");
        changed=m;changed.seed++;
        check(t.accept(changed,0,payload.data(),std::min(T::chunk_size,size))==R::rejected,"changed seed accepted");
        t.retire();check(t.bytes.empty(),"completed buffer retained");
        check(t.accept(m,0,payload.data(),std::min(T::chunk_size,size))==R::rejected,"completed transfer replayed");
        t.clear();check(t.accept(m,0,payload.data(),std::min(T::chunk_size,size))!=R::rejected,"session reset failed");
    }
    T t;std::string data(T::chunk_size,'a');T::Metadata m{10,2*T::chunk_size,42,0,0,0,0};
    check(t.accept(m,0,data.data(),data.size())==R::partial,"initial chunk");
    auto bad=data;bad[0]='b';check(t.accept(m,0,bad.data(),bad.size())==R::rejected,"conflicting duplicate");
    check(t.accept(m,1,data.data(),data.size())==R::rejected,"unaligned chunk");
    check(t.accept(m,0,data.data(),data.size()-1)==R::rejected,"short middle chunk");
    check(t.accept(m,m.total,data.data(),0)==R::rejected,"empty trailing chunk");
    check(t.accept(m,0xFFFFFFFF,data.data(),1)==R::rejected,"offset overflow");
    for(int which=0;which<7;which++) {
        auto b=m;
        if(which==0)b.xfer=0;if(which==1)b.total=0;if(which==2)b.total=(32u<<20)+1;
        if(which==3)b.slot=-1;if(which==4)b.category=-1;if(which==5)b.offset=-1;if(which==6)b.flags=2;
        check(t.accept(b,0,data.data(),data.size())==R::rejected,"bad metadata");
    }
    auto newer=m;newer.xfer++;
    check(t.accept(newer,0,data.data(),data.size())==R::partial,"replacement transfer");
    check(t.accept(m,T::chunk_size,data.data(),data.size())==R::rejected,"retired transfer restarted");
    check(t.accept(newer,T::chunk_size,data.data(),data.size())==R::complete,"replacement completion");
    std::cout<<"{\"passed\":"<<passed<<",\"real_save_files_touched\":false}\n";
}
