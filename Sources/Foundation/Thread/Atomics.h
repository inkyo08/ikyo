#pragma once

#include <type_traits>

namespace Ikyo::Foundation::Atomics {
  template <typename T>
  concept AtomicsCompatible = 
    (std::is_integral_v <T> || std::is_pointer_v <T>) &&
    (sizeof (T) == 1 || sizeof (T) == 2 || sizeof (T) == 4 || sizeof (T) == 8);
} /* namespace Ikyo::Foundation::Atomics */

#if defined (__APPLE__) || defined (__linux__)

namespace Ikyo::Foundation::Atomics
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

  inline bool compare_exchange (volatile __int128_t *ptr, __int128_t *expected, __int128_t desired)
    { return __atomic_compare_exchange_n (ptr, expected, desired, false, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST); }

  template <AtomicsCompatible T>
  inline T fetch_add (volatile T *ptr, T value) { return __atomic_fetch_add (ptr, value, __ATOMIC_SEQ_CST); }

  template <AtomicsCompatible T>
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
} /* namespace Ikyo::Foundation::Atomics */

#elif defined (_WIN32)
#endif
