#pragma once

#include <cstdlib>

#if _WIN32
#include <Windows.h>
#include <process.h>
#elif __APPLE__ || __linux__
#include <pthread.h>
using HANDLE = pthread_t;
#endif

namespace Ikyo::Foundation
{
  class Thread {
  public:
    Thread () : handle (nullptr), joinable (false) {}
    ~Thread () { if (joinable) abort (); }

    Thread (const Thread &) = delete;
    Thread (Thread &&) = delete;

    Thread &operator= (const Thread &) = delete;
    Thread &operator= (Thread &&) = delete;

    void create (void *(*func)(void *), void *arg);
    void join ();

  private:
    HANDLE handle;
    bool joinable;
  };
} /* namespace Ikyo::Foundation */

/* ============ 구현 ============ */
#if _WIN32

namespace Ikyo::Foundation
{

} /* namespace Ikyo::Foundation */

#elif __APPLE__ || __linux__

namespace Ikyo::Foundation
{
  inline void Thread::create (void *(*func)(void *), void *arg)
  {
    if (joinable || pthread_create (&handle, nullptr, func, arg)) abort ();
    joinable = true;
  }
  inline void Thread::join ()
  {
    if (!joinable || pthread_join (handle, nullptr)) abort ();
    joinable = false;
  }
} /* namespace Ikyo::Foundation */

#endif
