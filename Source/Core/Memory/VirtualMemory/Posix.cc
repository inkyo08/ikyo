module;

#if __APPLE__ || __linux__
#include <unistd.h>
#include <sys/mman.h>
#include <cassert>
#endif

module Memory;

#if __APPLE__ || __linux__

#define MAP_FAILED_ADDR (reinterpret_cast<uintptr_t>(MAP_FAILED))

#ifdef RELEASE
#	define ASSERT_POSIX_SUCCESS(EXPR) EXPR
#else
#	define ASSERT_POSIX_SUCCESS(EXPR) \
{ \
int returnVal = EXPR; \
assert(returnVal == 0); \
}
#endif

template<typename T>
static T Align(T nData, size_t nAlign)
{
  assert((nAlign & (nAlign - 1)) == 0);
  size_t size = (static_cast<size_t>(nData) + (nAlign - 1)) & ~(nAlign - 1);
  return T(size);
}

// M2 macOS arm64 환경
// 환경에 따라 변경
constexpr size_t systemPageSize = 16 * 1024;

namespace Memory::VirtualMemory
{
  void* reserve(size_t size, const size_t alignment)
  {
    size = Align(size, systemPageSize);

    if (alignment <= systemPageSize)
    {
      void* ptr = mmap(nullptr, size, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
      if(ptr == MAP_FAILED) return nullptr;
      return ptr;
    }

    // mmap은 요청한 정렬 주소에 반드시 할당하지 않음
    // 그래서 수동으로 조정

    const size_t paddedReserveSize = size + alignment;
    const auto addr = reinterpret_cast<uintptr_t>(mmap(nullptr, paddedReserveSize, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0));
    if (addr == MAP_FAILED_ADDR) return nullptr;

    const uintptr_t upAlignedAddr = (addr + alignment) & ~(alignment - 1);
    const size_t diff = upAlignedAddr - addr;

    // mmap이 할당한 실제 주소를 저장할 수 있도록 해당 영역에 읽기 및 쓰기 권한을 부여
    mprotect(reinterpret_cast<void*>(addr), diff, PROT_READ | PROT_WRITE);

    // 주소 저장
    size_t* adjustment = reinterpret_cast<size_t*>(upAlignedAddr) - 1;
    *adjustment = diff;
    // read only로 변경
    mprotect(reinterpret_cast<void*>(addr), diff, PROT_READ);

    return reinterpret_cast<void*>(upAlignedAddr);
  }

  void unreserve(void* base, size_t size, const size_t alignment)
  {
    size = Align(size, systemPageSize);
    if (alignment <= systemPageSize) { ASSERT_POSIX_SUCCESS( munmap(base, size) ); }
    else
    {
      const size_t paddedReserveSize = size + alignment;
      const size_t* adjustment = static_cast<size_t*>(base) - 1;
      auto baseAddr = reinterpret_cast<uintptr_t>(base);
      baseAddr -= *adjustment;
      ASSERT_POSIX_SUCCESS( munmap(reinterpret_cast<void*>(baseAddr), paddedReserveSize) );
    }
  }

  void map(void* base, const size_t size)
  {
    const uintptr_t baseAddr = reinterpret_cast<uintptr_t>(base) & ~(systemPageSize - 1);
    const uintptr_t endAddr = Align(reinterpret_cast<uintptr_t>(base) + size, systemPageSize);
    ASSERT_POSIX_SUCCESS( mprotect(reinterpret_cast<void*>(baseAddr), endAddr - baseAddr, PROT_READ | PROT_WRITE) );
  }

  void unmap(void* base, const size_t size)
  {
    const uintptr_t baseAddr = reinterpret_cast<uintptr_t>(base) & ~(systemPageSize - 1);
    const uintptr_t endAddr = Align(reinterpret_cast<uintptr_t>(base) + size, systemPageSize);
    ASSERT_POSIX_SUCCESS( mprotect(reinterpret_cast<void*>(baseAddr), endAddr - baseAddr, PROT_NONE) );
  }
}

#endif