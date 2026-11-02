#ifndef KIRA_ISLAND_BRIDGE_H
#define KIRA_ISLAND_BRIDGE_H
#include <stdint.h>
#include <stdbool.h>
#ifdef __cplusplus
extern "C" {
#endif
void KiraIslandStart(int32_t taskID, const char *fileNameUTF8);
void KiraIslandProgress(int32_t taskID, int64_t bytesReceived, int64_t bytesExpected, double bytesPerSecond);
void KiraIslandFinish(int32_t taskID, bool succeeded, int64_t bytesReceived, int64_t bytesExpected);
#ifdef __cplusplus
}
#endif
#endif
