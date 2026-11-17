#include "SMCBridge.h"
#include <IOKit/IOKitLib.h>
#include <mach/mach.h>
#include <string.h>
#include <math.h>
#include <stddef.h>
#include <signal.h>
static volatile sig_atomic_t stopping = 0;
static void handle_signal(int number) { (void)number; stopping = 1; }
void fw_signals_install(void) {
    struct sigaction action = {0}; action.sa_handler = handle_signal;
    sigemptyset(&action.sa_mask);
    sigaction(SIGTERM, &action, NULL); sigaction(SIGINT, &action, NULL); sigaction(SIGHUP, &action, NULL);
}
int fw_stopping(void) { return stopping != 0; }

typedef struct { uint8_t major, minor, build, reserved; uint16_t release; } Version;
typedef struct { uint16_t version, length; uint32_t cpu, gpu, memory; } Limits;
typedef struct { uint32_t size, type; uint8_t attributes; } KeyInfo;
typedef struct {
    uint32_t key; Version version; Limits limits; KeyInfo info;
    uint8_t result, status, command; uint32_t index; uint8_t bytes[32];
} Packet;
_Static_assert(sizeof(Packet) == 80, "SMC packet ABI");
_Static_assert(offsetof(Packet, bytes) == 48, "SMC bytes ABI");
static uint32_t code(const char *s) {
    return ((uint32_t)(uint8_t)s[0]<<24)|((uint32_t)(uint8_t)s[1]<<16)|((uint32_t)(uint8_t)s[2]<<8)|(uint8_t)s[3];
}
static int call(uint32_t c, Packet *input, Packet *output) {
    size_t size = sizeof(*output);
    memset(output, 0, size);
    kern_return_t r = IOConnectCallStructMethod(c, 2, input, sizeof(*input), output, &size);
    if (r) return r;
    if (size != sizeof(*output)) return -1;
    return output->result ? (int)output->result : 0;
}
static int info(uint32_t c, const char *key, KeyInfo *result) {
    if (!key || strlen(key)!=4) return -2;
    Packet in = {0}, out;
    in.key=code(key); in.command=9;
    int r=call(c,&in,&out);
    if (!r) *result=out.info;
    return r;
}
int fw_open(uint32_t *connection) {
    io_service_t s=IOServiceGetMatchingService(kIOMainPortDefault,IOServiceMatching("AppleSMC"));
    if (!s) return -3;
    kern_return_t r=IOServiceOpen(s,mach_task_self(),0,connection);
    IOObjectRelease(s); return r;
}
void fw_close(uint32_t c) { if(c) IOServiceClose(c); }
static int decode(KeyInfo k, const uint8_t *b, double *v) {
    if(k.type==code("flt ") && k.size==4) { float f; memcpy(&f,b,4); *v=f; }
    else if(k.type==code("fpe2") && k.size==2) *v=((b[0]<<8)|b[1])/4.0;
    else if(k.type==code("sp78") && k.size==2) *v=(int16_t)((b[0]<<8)|b[1])/256.0;
    else if(k.type==code("ui8 ") && k.size==1) *v=b[0];
    else if(k.type==code("ui16") && k.size==2) *v=(b[0]<<8)|b[1];
    else if(k.type==code("ui32") && k.size==4) *v=((uint32_t)b[0]<<24)|((uint32_t)b[1]<<16)|(b[2]<<8)|b[3];
    else return -4;
    return isfinite(*v) ? 0 : -5;
}
int fw_number(uint32_t c,const char *key,double *v) {
    KeyInfo k; int r=info(c,key,&k); if(r) return r;
    if(!k.size || k.size>32) return -4;
    Packet in={0},out; in.key=code(key); in.command=5; in.info.size=k.size;
    r=call(c,&in,&out); return r ? r : decode(k,out.bytes,v);
}
int fw_write(uint32_t c,const char *key,double v) {
    if(!isfinite(v)||v<0) return -5;
    KeyInfo k; int r=info(c,key,&k); if(r) return r;
    Packet in={0},out; in.key=code(key); in.command=6; in.info.size=k.size;
    if(k.type==code("flt ") && k.size==4) {float f=(float)v; memcpy(in.bytes,&f,4);}
    else if(k.type==code("fpe2") && k.size==2 && v<=16383) {uint16_t n=(uint16_t)round(v*4); in.bytes[0]=n>>8;in.bytes[1]=n&255;}
    else if(k.type==code("ui8 ") && k.size==1 && v<=255) in.bytes[0]=(uint8_t)v;
    else return -4;
    return call(c,&in,&out);
}
int fw_key_at(uint32_t c,uint32_t index,char key[5]) {
    Packet in={0},out;in.command=8;in.index=index;
    int r=call(c,&in,&out); if(r) return r;
    for(int i=0;i<4;i++) key[i]=(char)(out.key>>(24-i*8));key[4]=0;return 0;
}
int fw_codec_test(void) {
    double value; uint8_t b[4]={0x13,0x88,0,0};
    KeyInfo k={2,0,0}; k.type=code("fpe2");
    if(decode(k,b,&value)||value!=1250) return 1;
    b[0]=0xff;b[1]=0x80;k.type=code("sp78");
    if(decode(k,b,&value)||value!=-0.5) return 2;
    float f=1296.5;memcpy(b,&f,4);k.size=4;k.type=code("flt ");
    if(decode(k,b,&value)||value!=1296.5) return 3;
    f=NAN;memcpy(b,&f,4);if(!decode(k,b,&value)) return 4;
    return 0;
}
