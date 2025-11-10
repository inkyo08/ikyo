#include "VirtualMemory.h"

#include <assert.h>

#if _WIN32
#elif __APPLE__ || __linux__

#include <sys/mman.h>
#include <unistd.h>

const static size_t systemPageSize = 4 * 1024;

void VM_Initialize() { assert(systemPageSize == sysconf(_SC_PAGESIZE)); }

void* VM_Reserve(size_t reserveSize, const size_t alignment)
{
  assert((systemPageSize & (systemPageSize - 1)) == 0);
  reserveSize = (reserveSize + (systemPageSize - 1)) & ~(systemPageSize - 1);

  if (alignment <= systemPageSize)
  {
    void* ptr = mmap(NULL, reserveSize, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
    if (ptr == MAP_FAILED) return NULL;
    return ptr;
  }

  // mmap은 요청된 정렬 주소에 무조건 할당되는 게 아니라서 수동으로 조정해야 함.

  const size_t paddedReserveSize = reserveSize + alignment;
  void* ptr = mmap(NULL, paddedReserveSize, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
  if (ptr == MAP_FAILED) return NULL;
  const uintptr_t addr = (uintptr_t)ptr;

  const uintptr_t upAlignedAddr = (addr + alignment) & ~(alignment - 1);
  const size_t diff = upAlignedAddr - addr;

  // mmap으로 할당받은 실제 메모리 주소를 저장하기 위해, 이 저장용 영역은 읽기와 쓰기 권한이 있어야 함
  mprotect((void*)addr, diff, PROT_READ | PROT_WRITE);

  // Store the address
  size_t* adjustment = ((size_t*)upAlignedAddr) - 1;
  *adjustment = diff;
  // Revert to read only.
  mprotect((void*)addr, diff, PROT_READ);

  return (void*)upAlignedAddr;
}

void VM_Unreserve(void* base, size_t reservedSize, const size_t alignment)
{
  assert((systemPageSize & (systemPageSize - 1)) == 0);
  reservedSize = (reservedSize + (systemPageSize - 1)) & ~(systemPageSize - 1);
  if (alignment <= systemPageSize) assert(munmap(base, reservedSize) == 0);
  else
  {
    const size_t paddedReserveSize = reservedSize + alignment;
    const size_t* adjustment = ((size_t*)base) - 1;
    uintptr_t baseAddr = (uintptr_t)base;
    baseAddr -= *adjustment;
    assert( munmap((void*)baseAddr, paddedReserveSize) == 0);
  }
}

void VM_MapPages(void* base, const size_t size)
{
  const uintptr_t baseAddr = (uintptr_t)base & ~(systemPageSize - 1);
  assert((systemPageSize & (systemPageSize - 1)) == 0);
  const uintptr_t endAddr = (((uintptr_t)base + size) + (systemPageSize - 1)) & ~(systemPageSize - 1);
  assert( mprotect((void*)baseAddr, endAddr - baseAddr, PROT_READ | PROT_WRITE) == 0 );
}

void VM_UnmapPages(void* base, const size_t size)
{
  const uintptr_t baseAddr = (uintptr_t)base & ~(systemPageSize - 1);
  assert((systemPageSize & (systemPageSize - 1)) == 0);
  const uintptr_t endAddr = (((uintptr_t)base + size) + (systemPageSize - 1)) & ~(systemPageSize - 1);
  assert( mprotect((void*)baseAddr, endAddr - baseAddr, PROT_NONE) == 0 );
}

#endif


