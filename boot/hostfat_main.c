#include <stdio.h>
#include <string.h>
#include "fat32.h"
FILE *g_img; uint8_t g_buf[512]; uint16_t g_ptr; bool g_err; uint8_t g_cmd_sink;
int main(int argc,char**argv){
  g_img=fopen(argv[1],"rb");
  printf("mount: %d  root=%lu clusbytes=%u\n", fat32_mount(),
         (unsigned long)fat32_root_cluster(), fat32_bytes_per_cluster());
  fat32_file f; char b[64];
  const char *paths[]={"/HELLO.TXT","/SUB/NESTED.TXT","/BIG.BIN","/NOPE.XXX"};
  for(int i=0;i<4;i++){
    char p[32]; strcpy(p,paths[i]);
    if(fat32_open(p,&f)){ int n=fat32_read(&f,(uint8_t*)b,60); b[n<60?n:59]=0;
      printf("  %-16s size=%lu first=%lu  [%.20s]\n",p,(unsigned long)f.size,(unsigned long)f.first_cluster,b); }
    else printf("  %-16s OPEN FAILED\n",p);
  }
  return 0; }
