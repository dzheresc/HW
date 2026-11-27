// echo10g: flood the FPGA UDP echo (DST:7) and count what comes back. echo10g DST SIZE SECS FLOWS GRO(0/1)
#include <arpa/inet.h>
#include <netinet/udp.h>
#include <sys/socket.h>
#include <unistd.h>
#include <atomic>
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <thread>
#include <vector>
using u64=uint64_t; using u8=uint8_t;
#define CHK(x) do{if(!(x)){perror(#x);_exit(1);}}while(0)
static u64 now(){timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec*1000000000ull+t.tv_nsec;}
struct alignas(64) St{u64 sent=0,rx=0,bad=0,gaps=0,next=1,bufs=0;};
int main(int c,char**v){
  CHK(c==6); const char*dst=v[1]; int n=atoi(v[2]),secs=atoi(v[3]),F=atoi(v[4]),gro=atoi(v[5]); alarm(secs+20);
  std::vector<St> s(F); std::vector<int> fd; std::atomic<bool> stop{false}; std::vector<std::thread> R,T;
  for(int i=0;i<F;i++){int d=socket(AF_INET,SOCK_DGRAM,0);sockaddr_in a{};a.sin_family=AF_INET;a.sin_port=htons(7);inet_pton(AF_INET,dst,&a.sin_addr);
    int b=67108864,one=1;CHK(!setsockopt(d,SOL_SOCKET,SO_RCVBUFFORCE,&b,4));CHK(!connect(d,(sockaddr*)&a,sizeof a));
    timeval t{0,100000};setsockopt(d,SOL_SOCKET,SO_RCVTIMEO,&t,sizeof t);if(gro)CHK(!setsockopt(d,SOL_UDP,UDP_GRO,&one,4));fd.push_back(d);}
  for(int i=0;i<F;i++)R.emplace_back([&,i]{St&x=s[i];const int B=16,SZ=65536;std::vector<u8>b((size_t)B*SZ);mmsghdr m[B]{};iovec io[B];alignas(8)char ct[B][64];
    for(int k=0;k<B;k++){io[k]={b.data()+(size_t)k*SZ,(size_t)SZ};m[k].msg_hdr.msg_iov=&io[k];m[k].msg_hdr.msg_iovlen=1;}
    while(true){bool last=stop;for(int k=0;k<B;k++){m[k].msg_hdr.msg_control=ct[k];m[k].msg_hdr.msg_controllen=64;}
      int r=recvmmsg(fd[i],m,B,MSG_WAITFORONE,nullptr);if(r<=0){if(last)return;continue;}
      for(int k=0;k<r;k++){x.bufs++;int len=m[k].msg_len,seg=len;const u8*p=b.data()+(size_t)k*SZ;
        for(cmsghdr*h=CMSG_FIRSTHDR(&m[k].msg_hdr);h;h=CMSG_NXTHDR(&m[k].msg_hdr,h))if(h->cmsg_level==SOL_UDP&&h->cmsg_type==UDP_GRO)memcpy(&seg,CMSG_DATA(h),4);
        for(int o=0;o<len;o+=seg){int l=len-o<seg?len-o:seg;if(l!=n){x.bad++;continue;}u64 q;memcpy(&q,p+o,8);if(p[o+n-1]!=(u8)q)x.bad++;if(q!=x.next)x.gaps++;x.next=q+1;x.rx++;}}}});
  u64 t0=now(),end=t0+secs*1000000000ull;
  for(int i=0;i<F;i++)T.emplace_back([&,i]{int g=n<=1472?(60*n<65000?60:65000/n):1;CHK(!setsockopt(fd[i],SOL_UDP,UDP_SEGMENT,&n,4));std::vector<u8>b(g*n,0x5a);u64 q=0;
    while(now()<end){for(int k=0;k<g;k++){u64 z=q+k+1;memcpy(&b[k*n],&z,8);b[(k+1)*n-1]=(u8)z;}if(send(fd[i],b.data(),b.size(),0)==(ssize_t)b.size())q+=g;else if(errno!=ENOBUFS&&errno!=EAGAIN&&errno!=ECONNREFUSED){perror("send");_exit(1);}}s[i].sent=q;});
  for(auto&t:T)t.join();double el=(now()-t0)/1e9;usleep(800000);stop=true;for(auto&t:R)t.join();
  St z;for(auto&x:s)z.sent+=x.sent,z.rx+=x.rx,z.bad+=x.bad,z.gaps+=x.gaps,z.bufs+=x.bufs;
  printf("size=%-4d gro=%d sent=%llu app_rx=%llu app_lost=%.2f%% tx=%.3fMpps app=%.3fMpps bad=%llu gaps=%llu pkts/buf=%.1f",n,gro,(unsigned long long)z.sent,(unsigned long long)z.rx,100.0*(double)(z.sent-z.rx)/z.sent,z.sent/el/1e6,z.rx/el/1e6,(unsigned long long)z.bad,(unsigned long long)z.gaps,z.bufs?(double)z.rx/z.bufs:0);
}
