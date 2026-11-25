// Host model: page map above/below 4 GB, split (RCB 64) and out-of-order completions, random stalls, foreign RX TLPs.
#include "Vhr_core.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <map>
#include <random>
#include <unordered_map>
#include <vector>
using u64=uint64_t; using u32=uint32_t;
static std::mt19937_64 R; static u64 rnd(u64 n){return R()%n;}
static u32 bs(u32 x){return __builtin_bswap32(x);}
static void fail(const char*m,u64 a=0,u64 b=0){printf("FAIL %s %llx %llx\n",m,(unsigned long long)a,(unsigned long long)b);exit(1);}
struct Cpl{std::vector<u64> beats;int tag;};
int main(int argc,char**argv){
  int seed=argc>1?atoi(argv[1]):1; long N=argc>2?atol(argv[2]):20000; int mode=argc>3?atoi(argv[3]):0; R.seed(seed);
  auto*d=new Vhr_core; std::unordered_map<u64,u64> host; std::map<u64,bool> legal; const int NP=8;
  std::vector<u64> page(NP); for(int i=0;i<NP;i++){page[i]=(i&1)?(0x100000000ull+((u64)(rnd(6000))<<21)):((u64)(64+i*37)<<21); legal[page[i]]=1;}
  u64 cyc=0; auto tick=[&]{d->clk=0;d->eval();d->clk=1;d->eval();cyc++;};
  d->rst=1;d->cfg_id=0x0200;d->cfg_bme=1;d->npages=NP;d->rx_valid=0;d->tx_ready=0;d->rd_ready=0;d->cmd_valid=0;d->wd_valid=0;d->tbl_we=0;
  for(int i=0;i<4;i++)tick(); d->rst=0;
  for(int i=0;i<512;i++){d->tbl_we=1;d->tbl_idx=i;d->tbl_page=(i<NP?page[i]:0xdead00000000ull)>>21;tick();} d->tbl_we=0;
  std::unordered_map<u64,u64> ref;                                  // key: line*16+w
  struct Exp{u64 v[16];bool err;}; std::deque<Exp> exp; std::deque<u64> wq; std::map<int,std::deque<Cpl>> pend; std::deque<u64> cur; bool curv=false;
  std::vector<u64> tlp; std::vector<int> kp; long issued=0,wr=0,rd=0,refused=0,got=0,errs=0; int w=0; bool cv=false,cwe=false; u32 cl=0; u64 idle=0; bool lost=false,late=false;std::deque<Cpl> held;int heldtag=0; long pois=0,foreign=0,split=0,ooo=0,urs=0; std::deque<int> order;
  std::unordered_map<int,bool> outst; std::deque<int> expbad;       // reads chosen to fail, by issue order
  u64 t0=0,t1=0,tw=1; bool full=mode==1;
  while(true){
    if(!cv&&issued<N&&(full||rnd(3))){cv=true;cwe=mode==2?1:mode==1?0:rnd(2);cl=(u32)(rnd(NP)*16384+rnd(mode==1?64:24)*(1+rnd(600))); cl&=0x7fffff; if(cl>=NP*16384)cl=NP*16384-1; if(mode==0&&rnd(50)==0)cl=(u32)(NP+rnd(512-NP))*16384+rnd(16384);}
    d->cmd_valid=cv;d->cmd_we=cwe;d->cmd_line=cl; d->wd_valid=!wq.empty()&&(full||mode==2||rnd(4)); d->wd_data=wq.empty()?0:wq.front();
    d->tx_ready=full||mode==2||rnd(4)!=0; d->rd_ready=full||rnd(4)!=0;
    if(lost&&!late&&d->fatal){late=true;pend[heldtag]=held;order.push_back(heldtag);}   // late completion must be ignored
    d->rx_valid=0; if(!curv){
      std::vector<int> av; for(auto&p:pend) if(!p.second.empty()) av.push_back(p.first);
      if(!full&&rnd(20)==0){cur={0x0000000f40000001ull|((u64)0x1234<<48),0xdeadbeeff7e00010ull};curv=true;foreign++;}   // host MMIO write TLP
      else if(!av.empty()&&(full||rnd(2))){int t=full?order.front():av[rnd(av.size())]; if(t!=order.front())ooo++; auto&q=pend[t]; cur.assign(q.front().beats.begin(),q.front().beats.end()); q.pop_front(); if(q.empty()){pend.erase(t); for(auto it=order.begin();it!=order.end();++it)if(*it==t){order.erase(it);break;}} curv=true;}
    }
    if(curv&&(full||rnd(5))){d->rx_valid=1;d->rx_data=cur.front();d->rx_last=cur.size()==1;}
    d->clk=0;d->eval();
    bool ca=d->cmd_valid&&d->cmd_ready, wa=d->wd_valid&&d->wd_ready, ta=d->tx_valid&&d->tx_ready, ra=d->rd_valid&&d->rd_ready, xa=d->rx_valid;
    u64 td=d->tx_data; int tk=d->tx_keep; bool tl=d->tx_last; u64 rdv=d->rd_data; bool rl=d->rd_last,re=d->rd_err;
    d->clk=1;d->eval();cyc++; idle++;
    if(ca){issued++;idle=0;cv=false;bool bad=(cl>>14)>=(u32)NP; if(issued==1)t0=cyc; if(bad)refused++;
      if(cwe){wr++;for(int i=0;i<16;i++){u64 v=R();wq.push_back(v);if(!bad)ref[(u64)cl*16+i]=v;}}
      else{rd++;Exp e;e.err=bad;for(int i=0;i<16;i++){auto it=ref.find((u64)cl*16+i);e.v[i]=bad?0:(it==ref.end()?((u64)cl*16+i)*0x9E3779B97F4A7C15ull:it->second);}exp.push_back(e);}}
    if(wa){wq.pop_front();idle=0;}
    if(xa){cur.pop_front();if(cur.empty())curv=false;idle=0;}
    if(ra){idle=0;if(exp.empty())fail("unexpected data");Exp&e=exp.front(); if(re){errs++; if(rdv)fail("err data");} else {if(e.err)fail("missing err"); if(rdv!=e.v[w])fail("data",rdv,e.v[w]);} if(e.err&&!re)fail("err flag"); if(rl!=(w==15))fail("last"); if(++w==16){w=0;exp.pop_front();got++;t1=cyc;}}
    if(ta){idle=0;tlp.push_back(td);kp.push_back(tk); if(!tl&&tk!=0xff)fail("keep mid"); if(tl){
      u32 h0=tlp[0],h1=tlp[0]>>32; bool w4=(h0>>29)&1,hd=(h0>>30)&1; int len=h0&0x3ff; if(len!=32||(h0>>31)||((h0>>24)&0x1f))fail("hdr",h0); if((h1&0xff)!=0xff||(h1>>16)!=0x200)fail("h1",h1);
      u64 a=w4?((u64)(u32)tlp[1]<<32|(tlp[1]>>32)):(u32)tlp[1]; if(w4&&a<0x100000000ull)fail("4DW below 4G",a); if(a&127)fail("align",a); if(!legal.count(a&~0x1fffffull))fail("ILLEGAL ADDRESS",a);
      std::vector<u32> dw; for(size_t i=0;i<tlp.size();i++){dw.push_back(tlp[i]);if(kp[i]==0xff)dw.push_back(tlp[i]>>32);else if(kp[i]!=0x0f)fail("keep");}
      size_t hl=w4?4:3; if(dw.size()!=hl+(hd?32:0))fail("tlp len",dw.size());
      u64 line=0; for(int i=0;i<NP;i++)if(page[i]==(a&~0x1fffffull))line=(u64)i*16384+((a&0x1fffff)>>7);
      if(hd){tw=cyc;for(int i=0;i<16;i++)host[a+8*i]=(u64)bs(dw[hl+2*i])|(u64)bs(dw[hl+2*i+1])<<32;}
      else{int tag=(h1>>8)&0xff; if(tag>31||outst.count(tag)&&pend.count(tag))fail("tag",tag); std::deque<Cpl> q; u64 v[16]; for(int i=0;i<16;i++){auto it=host.find(a+8*i);v[i]=it==host.end()?(line*16+i)*0x9E3779B97F4A7C15ull:it->second;}
        if(mode==3&&rnd(30)==0){urs++;Cpl c;c.tag=tag;c.beats={(u64)(0x00000000u|1u<<13|128)<<32|0x0A000000u,(u64)(0x0200u<<16|tag<<8)};q.push_back(c);}
        else{int s=0;bool sp=full||rnd(3);if(sp)split++; bool poi=mode==3&&rnd(30)==0; if(poi)pois++; int pf=sp&&rnd(2)?8:0; if(!sp)pf=0; bool sterr=mode==3&&!poi&&!sp&&rnd(40)==0; if(sterr)urs++; while(s<16){int n=sp?8:16;Cpl c;c.tag=tag;u32 p0=0x4A000000u|(2*n)|((poi&&s==pf)?0x4000u:0),p1=(128-8*s)|(sterr?(4u<<13):0);u32 p2=0x0200u<<16|tag<<8|((a+8*s)&0x7f);std::vector<u32> x{p0,p1,p2};for(int i=0;i<n;i++){x.push_back(bs((u32)v[s+i]));x.push_back(bs((u32)(v[s+i]>>32)));}
          if(x.size()&1)x.push_back(0);for(size_t i=0;i<x.size();i+=2)c.beats.push_back((u64)x[i]|(u64)x[i+1]<<32);q.push_back(c);s+=n;}}
        outst[tag]=1; if(mode==4&&!lost&&rd>500){lost=true;held=q;heldtag=tag;}else{pend[tag]=q;order.push_back(tag);}}
      tlp.clear();kp.clear();}}
    if(issued==N&&exp.empty()&&wq.empty()&&tlp.empty()&&idle>200)break; if(idle>20000)fail("hang",issued,exp.size());
  }
  if(mode==4){if(!late||!d->fatal)fail("no timeout");printf("PASS seed %d mode 4: lost completion, fatal, %ld of %ld reads errored, late data ignored\n",seed,errs/16,rd);return 0;}
  if(mode!=3&&errs!=16*0&&refused==0)fail("errs"); if(mode==3&&errs!=16*(urs+pois))fail("ur errs",errs,urs);
  if(d->c_refused!=refused)fail("refused ctr",d->c_refused,refused); if(d->c_unexp)fail("unexp",d->c_unexp); if((long)d->c_badcpl!=urs+pois)fail("badcpl",d->c_badcpl,urs);
  for(auto&k:ref){u64 line=k.first/16;u64 a=page[line>>14]+((line&16383)<<7)+8*(k.first&15);auto it=host.find(a);if(it==host.end()||it->second!=k.second)fail("final mem");}
  printf("PASS seed %d mode %d: %ld wr %ld rd, %ld refused, %ld UR/CA %ld poisoned, %ld split %ld out-of-order %ld foreign TLPs; %.2f B/cycle\n",seed,mode,wr,rd,refused,urs,pois,split,ooo,foreign,mode==1?(double)got*128/(t1-t0):(double)wr*128/(tw-t0));
}
