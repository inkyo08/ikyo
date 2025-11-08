#ifndef IKYO_LOG_H
#define IKYO_LOG_H

#include <stdio.h>
#include <stdarg.h>

#if DEBUG
static inline void IkyoLog(const char* format, ...)
{
  va_list args;
  va_start(args, format);
  vprintf(format, args);
  va_end(args);
}
#endif

#if EDITOR
// UI 시스템 미구현
static inline void IkyoLog(const char* format, ...) { (void)format; }
#endif

#if RELEASE
static inline void IkyoLog(const char* format, ...) { (void)format; }
#endif

#endif