#include "VirtualMemory.h"

#include <assert.h>

#if _WIN32

#include <Windows.h>
#include <sysinfoapi.h>

const size_t systemPageSize = 4 * 1024;

void VM_Initialize()
{
  SYSTEM_INFO si;
  GetSystemInfo(&si);
  assert(systemPageSize == si.dwPageSize);
}

void * VM_Reserve(size_t reserveSize, const size_t alignment) {
  assert((systemPageSize & (systemPageSize - 1)) == 0);
  reserveSize = (reserveSize + (systemPageSize - 1)) & ~(systemPageSize - 1);
  uintptr_t addr;

  do
  {
    addr = (uintptr_t)VirtualAlloc(NULL, reserveSize, MEM_RESERVE, PAGE_READWRITE);
    if (!addr)
      break;

    const uintptr_t alignedAddr = alignment == 0 ? addr :
    ((addr + (alignment - 1)) & ~(alignment - 1));

    if ((alignedAddr - addr) > 0)
    {
      VirtualFree((void*)addr, 0, MEM_RELEASE);
      addr = (uintptr_t)VirtualAlloc((void*)alignedAddr, reserveSize, MEM_RESERVE, PAGE_READWRITE);
    }
  } while (!addr);

  return (void*)addr;
}

void VM_Unreserve(void *base, size_t reservedSize, size_t alignment) {
  VirtualFree(base, 0, MEM_RELEASE);
}

void VM_MapPages(void *base, const size_t size) {
  VirtualAlloc(base, size, MEM_COMMIT, PAGE_READWRITE);
}

void VM_UnmapPages(void *base, const size_t size) {
  VirtualFree(base, size, MEM_DECOMMIT);
}


#elif __APPLE__ || __linux__

#include <sys/mman.h>
#include <unistd.h>

#ifdef NDEBUG
#  define VM_ASSERT_SUCCESS(expr) expr
#else
#  define VM_ASSERT_SUCCESS(expr) \
do { \
  int ret = (expr); \
  assert(ret == 0); \
} while(0)
#endif

const size_t systemPageSize = 4 * 1024;

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

  // mmap은 요청된 정렬 주소에 무조건 할당되는 게 아니라서 수동으로 조정해야 함

  const size_t paddedReserveSize = reserveSize + alignment;
  void* ptr = mmap(NULL, paddedReserveSize, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
  if (ptr == MAP_FAILED) return NULL;
  const uintptr_t addr = (uintptr_t)ptr;

  const uintptr_t upAlignedAddr = (addr + alignment) & ~(alignment - 1);
  const size_t diff = upAlignedAddr - addr;

  // mmap으로 할당받은 실제 메모리 주소를 저장하기 위해, 이 저장용 영역은 읽기와 쓰기 권한이 있어야 함
  VM_ASSERT_SUCCESS(mprotect((void*)addr, diff, PROT_READ | PROT_WRITE));

  // Store the address
  size_t* adjustment = ((size_t*)upAlignedAddr) - 1;
  *adjustment = diff;
  // Revert to read only.
  VM_ASSERT_SUCCESS(mprotect((void*)addr, diff, PROT_READ));

  return (void*)upAlignedAddr;
}

void VM_Unreserve(void* base, size_t reservedSize, const size_t alignment)
{
  assert((systemPageSize & (systemPageSize - 1)) == 0);
  reservedSize = (reservedSize + (systemPageSize - 1)) & ~(systemPageSize - 1);
  if (alignment <= systemPageSize) VM_ASSERT_SUCCESS(munmap(base, reservedSize));
  else
  {
    const size_t paddedReserveSize = reservedSize + alignment;
    const size_t* adjustment = ((size_t*)base) - 1;
    uintptr_t baseAddr = (uintptr_t)base;
    baseAddr -= *adjustment;
    VM_ASSERT_SUCCESS(munmap((void*)baseAddr, paddedReserveSize));
  }
}

void VM_MapPages(void* base, const size_t size)
{
  const uintptr_t baseAddr = (uintptr_t)base & ~(systemPageSize - 1);
  assert((systemPageSize & (systemPageSize - 1)) == 0);
  const uintptr_t endAddr = (((uintptr_t)base + size) + (systemPageSize - 1)) & ~(systemPageSize - 1);
  VM_ASSERT_SUCCESS(mprotect((void*)baseAddr, endAddr - baseAddr, PROT_READ | PROT_WRITE));
}

void VM_UnmapPages(void* base, const size_t size)
{
  const uintptr_t baseAddr = (uintptr_t)base & ~(systemPageSize - 1);
  assert((systemPageSize & (systemPageSize - 1)) == 0);
  const uintptr_t endAddr = (((uintptr_t)base + size) + (systemPageSize - 1)) & ~(systemPageSize - 1);
  VM_ASSERT_SUCCESS(mprotect((void*)baseAddr, endAddr - baseAddr, PROT_NONE));
}

#endif
