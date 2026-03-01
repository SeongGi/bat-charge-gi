#ifndef smcc_h
#define smcc_h

#include <stdint.h>
#include <CoreFoundation/CoreFoundation.h>

#ifdef __cplusplus
extern "C" {
#endif

// SMC Key 조작 기본 구조체 및 함수 선언
typedef struct {
    unsigned char    data[32];
    uint32_t         dataSize;
    uint32_t         dataType;
    uint8_t          dataAttributes;
} SMCBytes_t;

// BCLM (Battery Charge Level Max) 값을 시스템에 적용하는 기본 C 함수
int set_bclm_value(int limit);
int get_bclm_value(void);

#ifdef __cplusplus
}
#endif

#endif /* smcc_h */
