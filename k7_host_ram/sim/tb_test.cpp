// hr_test end to end: registers, write/read passes, corruption, out-of-range, window limit
#include "Vhr_test.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <random>
#include <unordered_map>
#include <vector>
using u64=uint64_t; using u32=uint32_t; static std::mt19937 R(5); static u32 bs(u32 x){return __builtin_bswap32(x);}
Vhr_test*d; std::unordered_map<u64,u64> host; std::vector<u64> tl; std::deque<std::pair<u64,std::vector<u64>>> q; std::deque<u64> cur; u64 cyc=0; int infl=0,maxinfl=0,half=0; u64 LAT=250; bool stall=false;
#define F(m) do{printf("FAIL %s line %d\n",m,__LINE__);exit(1);}while(0)
void tick(){ d->tx_ready=!stall||R()%4; d->rx_valid=0; if(cur.empty()&&!q.empty()&&q.front().first<=cyc){cur.assign(q.front().second.begin(),q.front().second.end());q.pop_front();}
  if(!cur.empty()){d->rx_valid=1;d->rx_data=cur.front();d->rx_last=cur.size()==1;}
  d->clk=0;d->eval(); bool ta=d->tx_valid&&d->tx_ready; u64 td=d->tx_data; int tk=d->tx_keep; bool last=d->tx_last; bool xa=d->rx_valid; d->clk=1;d->eval();cyc++;
  if(xa){cur.pop_front(); if(cur.empty()&&(++half&1)==0)infl--;}
  if(ta){tl.push_back(td);if(last){u32 h0=tl[0];bool w4=h0>>29&1,hd=h0>>30&1;u64 a=w4?((u64)(u32)tl[1]<<32|tl[1]>>32):(u32)tl[1];std::vector<u32>x;for(auto b:tl){x.push_back(b);x.push_back(b>>32);}int h=w4?4:3;int tag=(tl[0]>>40)&0xff;
    if(hd)for(int i=0;i<16;i++)host[a+8*i]=(u64)bs(x[h+2*i])|(u64)bs(x[h+2*i+1])<<32;
    else{infl++;if(infl>maxinfl)maxinfl=infl;for(int s=0;s<16;s+=8){std::vector<u32>y{0x4A000010u,(u32)(128-8*s),0x02000000u|(u32)tag<<8};for(int i=0;i<8;i++){u64 v=host[a+8*(s+i)];y.push_back(bs(v));y.push_back(bs(v>>32));}y.push_back(0);std::vector<u64>b;for(size_t i=0;i<y.size();i+=2)b.push_back((u64)y[i]|(u64)y[i+1]<<32);q.push_back({cyc+LAT,b});}}
    tl.clear();(void)tk;}}}
void wr(int a,u32 v){d->req=1;d->we=1;d->addr=a;d->wdata=v;tick();d->req=0;d->we=0;tick();}
u32 rd(int a){d->req=1;d->we=0;d->addr=a;tick();d->req=0;u32 v=d->rdata;tick();return v;}
void run(int wrt,int rnd,int span,u32 base,u32 cnt,u32 seed,int win){wr(6,span);wr(7,base);wr(8,cnt);wr(9,seed);wr(10,win);wr(0,1|wrt<<1|rnd<<2);u64 t=cyc;while(rd(1)&1)if(cyc-t>3000000)F("hang");}
int main(){d=new Vhr_test;d->rst=1;d->cfg_bme=1;d->cfg_id=0x200;for(int i=0;i<5;i++)tick();d->rst=0;tick();
  u64 pg[4]={0x12340ull<<21,0x77ull<<21,0x9999ull<<21,0x40ull<<21};wr(3,0);for(int i=0;i<4;i++){wr(4,(u32)pg[i]);wr(5,pg[i]>>32);}wr(2,4);wr(0,0);
  for(int s=0;s<2;s++)for(int r=0;r<2;r++){stall=s;host.clear();u32 sd=0xabc0+r;run(1,r,12,16384-2048,4096,sd,16);if(host.size()!=4096*16)F("write coverage");run(0,r,12,16384-2048,4096,sd,16);if(rd(11)||rd(12)||rd(0x19)!=4096)F("clean read");run(0,!r,12,16384-2048,4096,sd,16);if(rd(11))F("cross order");}
  stall=false; host[(pg[0])+(16384-100)*128ull+24]^=1; run(0,1,12,16384-2048,4096,0xabc1,16); if(rd(11)!=1||rd(0x18)!=16384-100)F("corruption not found");
  run(0,0,12,16384-2048,4096,0xdead,16); if(rd(11)!=4096*16)F("wrong seed");
  size_t n=host.size(); run(1,1,10,4*16384,1024,1,16); if(host.size()!=n||rd(0x15)!=1024)F("refuse write"); run(0,0,10,4*16384,1024,1,16); if(rd(12)!=1024)F("refuse read");
  for(int w:{1,4,16,32}){maxinfl=0;run(0,1,12,0,2000,1,w);if(maxinfl>w)F("window");printf("window %2d: max in flight %2d, %.2f B/cycle, latency min %u max %u avg %.0f\n",w,maxinfl,2000*128.0/rd(13),rd(15),rd(16),rd(17)/2000.0);}
  d->cfg_bme=0; run(0,0,10,0,64,1,16); if(rd(12)!=64)F("bme"); puts("PASS hr_test");}
