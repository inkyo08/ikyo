module;

#if _WIN32
#include <Windows.h>
#include <cassert>
#endif

module Memory;

template<typename T>
static inline T Align(T nData, size_t nAlign)
{
  assert((nAlign & (nAlign - 1)) == 0);
  size_t size = ((size_t)nData + (nAlign - 1)) & ~(nAlign - 1);
  return T(size);
}

const size_t systemPageSize = 4 * 1024;

namespace Memory::VirtualMemory {
#if _WIN32

  void* reserve(size_t size, size_t alignment)
  {
    size = Align(size, systemPageSize);
    UINT_PTR addr;

    do
    {
      addr = reinterpret_cast<uintptr_t>(VirtualAlloc(NULL, size, MEM_RESERVE, PAGE_READWRITE));
      if (!addr)
        break;

      UINT_PTR alignedAddr = alignment == 0 ? addr : Align(addr, alignment);

      if ((alignedAddr - addr) > 0)
      {
        VirtualFree(reinterpret_cast<LPVOID>(addr), 0, MEM_RELEASE);
        addr = reinterpret_cast<UINT_PTR>(VirtualAlloc(reinterpret_cast<LPVOID>(alignedAddr), size, MEM_RESERVE, PAGE_READWRITE));
      }
    } while (!addr);

    return reinterpret_cast<void*>(addr);
  }

  void unreserve(void* base, size_t size, size_t alignment) { VirtualFree(base, 0, MEM_RELEASE); }

  void map(void* base, size_t size) { VirtualAlloc(base, size, MEM_COMMIT, PAGE_READWRITE); }

  void unmap(void* base, size_t size) { VirtualFree(base, size, MEM_DECOMMIT); }
#endif
}