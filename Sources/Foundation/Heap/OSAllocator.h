#pragma once

#include <cstddef>
#include <cstdlib>
#include <cassert>

#if __APPLE__ || __aarch64__
#define SYSTEM_PAGE_SIZE (16 << 10)
#else
#define SYSTEM_PAGE_SIZE (4  << 10)
#endif

class OSAllocator
{
  void *base;
  size_t reserved_size;
  size_t page_size;
  size_t alignment;

public:
  explicit OSAllocator (size_t reserve_size, size_t page_size = SYSTEM_PAGE_SIZE, size_t alignment = 0);
  ~OSAllocator();
  void map (size_t size);
  void unmap (size_t size);
};

/* ============ 구현 ============ */
namespace Detail
{
  template <typename T>
  T align_to(T data, const size_t align)
  {
    assert ((align & (align - 1)) == 0);
    size_t size = (static_cast <size_t> (data) + (align - 1)) & ~(align - 1);
    return T (size);
  }
}

#if _WIN32
#elif __APPLE__ || __linux__

#include <sys/mman.h>

inline OSAllocator::OSAllocator (const size_t reserve_size, const size_t page_size, const size_t alignment)
{
  const size_t aligned_reserve_size = Detail::align_to (reserve_size, page_size);

  if (alignment <= page_size)
  {
    void *ptr = mmap (nullptr, aligned_reserve_size, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
    if (ptr == MAP_FAILED) abort ();
    this->base = ptr;
    this->reserved_size = reserve_size;
    this->page_size = page_size;
    this->alignment = alignment;
    return;
  }

  const size_t padded_reserve_size = aligned_reserve_size + alignment;
  const auto ptr = mmap (nullptr, padded_reserve_size, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
  if (ptr == MAP_FAILED) abort ();

  const auto addr = reinterpret_cast <uintptr_t> (ptr);
  const uintptr_t up_aligned_addr = ((addr + alignment) & ~(alignment - 1));
  const size_t diff = up_aligned_addr - addr;

  if (mprotect (reinterpret_cast<void*>(addr), diff, PROT_READ | PROT_WRITE)) abort ();

  size_t *adjustment = reinterpret_cast <size_t *> (up_aligned_addr) - 1;
  *adjustment = diff;

  if (mprotect (reinterpret_cast <void *> (addr), diff, PROT_READ)) abort ();

  this->base = reinterpret_cast <void *> (up_aligned_addr);
  this->reserved_size = reserve_size;
  this->page_size = page_size;
  this->alignment = alignment;
}

inline OSAllocator::~OSAllocator()
{
  const size_t aligned_reserved_size = Detail::align_to (reserved_size, page_size);
  if (alignment <= page_size)
  {
    if (munmap (base, aligned_reserved_size)) abort ();
  }
  else
  {
    const size_t padded_reserved_size = aligned_reserved_size + alignment;
    const size_t *adjustment = static_cast <size_t *> (base) - 1;
    const uintptr_t base_addr = reinterpret_cast <uintptr_t> (base) - *adjustment;
    if (munmap (reinterpret_cast <void *> (base_addr), padded_reserved_size)) abort ();
  }
}

inline void OSAllocator::map(const size_t size)
{
  const uintptr_t base_addr = reinterpret_cast <uintptr_t> (base) & ~(page_size - 1);
  const uintptr_t end_addr = Detail::align_to (reinterpret_cast <uintptr_t> (base) + size, page_size);
  if (mprotect (reinterpret_cast <void *> (base_addr), end_addr - base_addr, PROT_READ | PROT_WRITE)) abort ();
}

inline void OSAllocator::unmap(const size_t size)
{
  const uintptr_t base_addr = reinterpret_cast <uintptr_t> (base) & ~(page_size - 1);
  const uintptr_t end_addr = Detail::align_to (reinterpret_cast <uintptr_t> (base) + size, page_size);
  if (mprotect (reinterpret_cast <void *> (base_addr), end_addr - base_addr, PROT_NONE)) abort ();
}

#endif
