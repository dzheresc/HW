// Host side: expose a buffer for RDMA READ by a raw-frame (FPGA) requester. No CM, RTR only.
// responder DEV GIDIDX PEER_IPV4 [secs]   prints "key value" lines, then "READY"
#include <infiniband/verbs.h>
#include <arpa/inet.h>
#include <sys/mman.h>
#include <unistd.h>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cerrno>
#define CHK(x) do{if(!(x)){fprintf(stderr,"%s:%d %s (%s)\n",__FILE__,__LINE__,#x,strerror(errno));exit(1);}}while(0)
static const size_t LEN=65536; static const uint32_t PEER_QPN[2]={0x11,0x12}, PSN0=0x123456;
int main(int c,char**v){
  CHK(c>=4); int gi=atoi(v[2]),secs=c>4?atoi(v[4]):120,k; ibv_context*x=0; auto l=ibv_get_device_list(&k); CHK(l);
  for(int i=0;i<k;i++) if(!strcmp(v[1],ibv_get_device_name(l[i]))) x=ibv_open_device(l[i]);
  CHK(x); ibv_pd*pd=ibv_alloc_pd(x); CHK(pd); ibv_cq*cq=ibv_create_cq(x,16,0,0,0); CHK(cq);
  uint8_t*b=(uint8_t*)mmap(0,LEN,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANONYMOUS|MAP_POPULATE,-1,0); CHK(b!=MAP_FAILED);
  for(size_t i=0;i<LEN/4;i++){uint32_t w=(uint32_t)i*2654435761u^0xA5A50000u; memcpy(b+4*i,&w,4);}   // little-endian words
  ibv_mr*mr=ibv_reg_mr(pd,b,LEN,IBV_ACCESS_LOCAL_WRITE|IBV_ACCESS_REMOTE_READ); CHK(mr);
  in_addr pa; CHK(inet_pton(AF_INET,v[3],&pa)==1);
  printf("addr %llu\nrkey %u\nlen %zu\npsn %u\n",(unsigned long long)(uintptr_t)b,mr->rkey,LEN,PSN0);
  for(int i=0;i<2;i++){
    ibv_qp_init_attr a{}; a.send_cq=a.recv_cq=cq; a.qp_type=IBV_QPT_RC; a.cap.max_send_wr=a.cap.max_recv_wr=1; a.cap.max_send_sge=a.cap.max_recv_sge=1;
    ibv_qp*q=ibv_create_qp(pd,&a); CHK(q);
    ibv_qp_attr t{}; t.qp_state=IBV_QPS_INIT; t.port_num=1; t.qp_access_flags=IBV_ACCESS_REMOTE_READ;
    CHK(!ibv_modify_qp(q,&t,IBV_QP_STATE|IBV_QP_PKEY_INDEX|IBV_QP_PORT|IBV_QP_ACCESS_FLAGS));
    ibv_qp_attr r{}; r.qp_state=IBV_QPS_RTR; r.path_mtu=IBV_MTU_1024; r.dest_qp_num=PEER_QPN[i]; r.rq_psn=PSN0; r.max_dest_rd_atomic=16; r.min_rnr_timer=12;
    r.ah_attr.is_global=1; r.ah_attr.port_num=1; r.ah_attr.grh.sgid_index=gi; r.ah_attr.grh.hop_limit=64;
    r.ah_attr.grh.dgid.raw[10]=r.ah_attr.grh.dgid.raw[11]=0xff; memcpy(&r.ah_attr.grh.dgid.raw[12],&pa,4);
    CHK(!ibv_modify_qp(q,&r,IBV_QP_STATE|IBV_QP_AV|IBV_QP_PATH_MTU|IBV_QP_DEST_QPN|IBV_QP_RQ_PSN|IBV_QP_MAX_DEST_RD_ATOMIC|IBV_QP_MIN_RNR_TIMER));
    printf("qpn%d %u\npeer_qpn%d %u\n",i,q->qp_num,i,PEER_QPN[i]);
  }
  puts("READY"); fflush(stdout); alarm(secs); pause();
}
