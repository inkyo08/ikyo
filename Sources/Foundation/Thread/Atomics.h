#pragma once

#include <type_traits>

namespace Atomics {
  template <typename T>
  concept AtomicsCompatible = 
    (std::is_integral_v <T> || std::is_pointer_v <T>) &&
    (sizeof (T) == 1 || sizeof (T) == 2 || sizeof (T) == 4 || sizeof (T) == 8);
} /* namespace ::Atomics */

#if defined (__APPLE__) || defined (__linux__)

namespace Atomics
{
  template <AtomicsCompatible T>
  inline T load (const volatile T *ptr) { return __atomic_load_n (ptr, __ATOMIC_SEQ_CST); }

  template <AtomicsCompatible T>
  inline void store (volatile T *ptr, T value) { __atomic_store_n (ptr, value, __ATOMIC_SEQ_CST); }

  template <AtomicsCompatible T>
  inline T exchange (volatile T *ptr, T value) { return __atomic_exchange_n (ptr, value, __ATOMIC_SEQ_CST); }

  template <AtomicsCompatible T>
  inline bool compare_exchange (volatile T *ptr, T *expected, T desired)
    { return __atomic_compare_exchange_n (ptr, expected, desired, false, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST); }

  template <AtomicsCompatible T>
  requires std::is_integral_v <T>
  inline T fetch_add (volatile T *ptr, T value) { return __atomic_fetch_add (ptr, value, __ATOMIC_SEQ_CST); }

  template <AtomicsCompatible T>
  requires std::is_integral_v <T>
  inline T fetch_sub (volatile T *ptr, T value) { return __atomic_fetch_sub (ptr, value, __ATOMIC_SEQ_CST); }

  template <AtomicsCompatible T>
  requires std::is_integral_v <T>
  inline T fetch_or (volatile T *ptr, T value) { return __atomic_fetch_or (ptr, value, __ATOMIC_SEQ_CST); }

  template <AtomicsCompatible T>
  requires std::is_integral_v <T>
  inline T fetch_and (volatile T *ptr, T value) { return __atomic_fetch_and (ptr, value, __ATOMIC_SEQ_CST); }

  template <AtomicsCompatible T>
  requires std::is_integral_v <T>
  inline T fetch_xor (volatile T *ptr, T value) { return __atomic_fetch_xor (ptr, value, __ATOMIC_SEQ_CST); }
} /* namespace Atomics */

#elif defined (_WIN32)
#include <Windows.h>
#include <intrin.h>

namespace Atomics
{
  template <AtomicsCompatible T>
  inline T load (const volatile T *ptr)
  {
    T value = *ptr;
    _ReadWriteBarrier ();
    return value;
  }

  template <AtomicsCompatible T>
  inline void store (volatile T *ptr, T value)
  {
    if constexpr (sizeof (T) == 1)
      _InterlockedExchange8 ((volatile char *) ptr, (char) value);
    else if constexpr (sizeof (T) == 2)
      _InterlockedExchange16 ((volatile short *) ptr, (short) value);
    else if constexpr (sizeof (T) == 4)
      _InterlockedExchange ((volatile long *) ptr, (long) value);
    else if constexpr (sizeof (T) == 8)
      _InterlockedExchange64 ((volatile long long *) ptr, (long long) value);
  }

  template <AtomicsCompatible T>
  inline T exchange (volatile T *ptr, T value)
  {
    if constexpr (sizeof (T) == 1)
      return (T) _InterlockedExchange8 ((volatile char *) ptr, (char) value);
    else if constexpr (sizeof (T) == 2)
      return (T) _InterlockedExchange16 ((volatile short *) ptr, (short) value);
    else if constexpr (sizeof (T) == 4)
      return (T) _InterlockedExchange ((volatile long *) ptr, (long) value);
    else if constexpr (sizeof (T) == 8)
      return (T) _InterlockedExchange64 ((volatile long long *) ptr, (long long) value);
  }

  template <AtomicsCompatible T>
  inline bool compare_exchange (volatile T *ptr, T *expected, T desired)
  {
    T old;
    if constexpr (sizeof (T) == 1)
      old = (T) _InterlockedCompareExchange8 ((volatile char *) ptr, (char) desired, (char) *expected);
    else if constexpr (sizeof (T) == 2)
      old = (T) _InterlockedCompareExchange16 ((volatile short *) ptr, (short) desired, (short) *expected);
    else if constexpr (sizeof (T) == 4)
      old = (T) _InterlockedCompareExchange ((volatile long *) ptr, (long) desired, (long) *expected);
    else if constexpr (sizeof (T) == 8)
      old = (T) _InterlockedCompareExchange64 ((volatile long long *) ptr, (long long) desired, (long long) *expected);

    if (old == *expected)
      return true;
    *expected = old;
    return false;
  }

  template <AtomicsCompatible T>
  requires std::is_integral_v <T>
  inline T fetch_add (volatile T *ptr, T value)
  {
    if constexpr (sizeof (T) == 4)
      return (T) _InterlockedExchangeAdd ((volatile long *) ptr, (long) value);
    else if constexpr (sizeof (T) == 8)
      return (T) _InterlockedExchangeAdd64 ((volatile long long *) ptr, (long long) value);
    else
    {
      T expected = load (ptr);
      while (!compare_exchange (ptr, &expected, expected + value))
        ;
      return expected;
    }
  }

  template <AtomicsCompatible T>
  requires std::is_integral_v <T>
  inline T fetch_sub (volatile T *ptr, T value)
  {
    return fetch_add (ptr, -value);
  }

  template <AtomicsCompatible T>
  requires std::is_integral_v <T>
  inline T fetch_or (volatile T *ptr, T value)
  {
    if constexpr (sizeof (T) == 1)
      return (T) _InterlockedOr8 ((volatile char *) ptr, (char) value);
    else if constexpr (sizeof (T) == 2)
      return (T) _InterlockedOr16 ((volatile short *) ptr, (short) value);
    else if constexpr (sizeof (T) == 4)
      return (T) _InterlockedOr ((volatile long *) ptr, (long) value);
    else if constexpr (sizeof (T) == 8)
      return (T) _InterlockedOr64 ((volatile long long *) ptr, (long long) value);
  }

  template <AtomicsCompatible T>
  requires std::is_integral_v <T>
  inline T fetch_and (volatile T *ptr, T value)
  {
    if constexpr (sizeof (T) == 1)
      return (T) _InterlockedAnd8 ((volatile char *) ptr, (char) value);
    else if constexpr (sizeof (T) == 2)
      return (T) _InterlockedAnd16 ((volatile short *) ptr, (short) value);
    else if constexpr (sizeof (T) == 4)
      return (T) _InterlockedAnd ((volatile long *) ptr, (long) value);
    else if constexpr (sizeof (T) == 8)
      return (T) _InterlockedAnd64 ((volatile long long *) ptr, (long long) value);
  }

  template <AtomicsCompatible T>
  requires std::is_integral_v <T>
  inline T fetch_xor (volatile T *ptr, T value)
  {
    if constexpr (sizeof (T) == 1)
      return (T) _InterlockedXor8 ((volatile char *) ptr, (char) value);
    else if constexpr (sizeof (T) == 2)
      return (T) _InterlockedXor16 ((volatile short *) ptr, (short) value);
    else if constexpr (sizeof (T) == 4)
      return (T) _InterlockedXor ((volatile long *) ptr, (long) value);
    else if constexpr (sizeof (T) == 8)
      return (T) _InterlockedXor64 ((volatile long long *) ptr, (long long) value);
  }
} /* namespace Atomics */

#endif
