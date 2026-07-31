/* Host stand-in for the X816 block device, backed by a file. */
#ifndef X816_SD_H
#define X816_SD_H
#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>
extern FILE *g_img; extern uint8_t g_buf[512]; extern uint16_t g_ptr; extern bool g_err;
extern uint8_t g_cmd_sink;
/* A write of RESET to SD_CMD rewinds the window; emulate that lazily on the
   next read, since a plain variable has no side effect on assignment. */
static inline uint8_t sd_data_read(void){
    if (g_cmd_sink == 4) { g_ptr = 0; g_cmd_sink = 0; }
    uint8_t v=g_buf[g_ptr]; g_ptr=(g_ptr+1)&511; return v; }
#define SD_DATA   sd_data_read()
#define SD_CMD    g_cmd_sink
#define SD_CMD_RESET 4u
static inline bool sd_present(void){ return g_img!=NULL; }
static inline bool sd_read_buf(uint32_t lba){
    if(!g_img) return false;
    if(fseek(g_img,(long)lba*512,SEEK_SET)!=0) return false;
    if(fread(g_buf,1,512,g_img)!=512) return false;
    g_ptr=0; g_cmd_sink=0; return true; }
static inline bool sd_read_dma(uint32_t lba,uint32_t d,uint8_t c){(void)lba;(void)d;(void)c;return false;}
#endif
