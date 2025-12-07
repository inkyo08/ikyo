import Foundation

public enum SystemMemory: ~Copyable {
  public struct Region {
    let base: UnsafeMutableRawPointer!
    let size: size_t
    let pageSize: size_t
    let alignment: size_t
  }
}

// 헬퍼 함수
@inline(__always)
fileprivate func align<T: BinaryInteger>(_ value: T, to alignment: size_t) -> T {
  precondition((alignment & (alignment - 1)) == 0)
  let size = (size_t(value) + (alignment - 1)) & ~(alignment - 1)
  return T(size)
}

#if os(Linux) || os(macOS)
public extension SystemMemory {
  // size는 pageSize에 맞춰 올림 처리
  // 반환되는 범위는 항상 pageSize에 따라 정렬되므로, alignment를 별도로 설정해야하는 경우는 거의 없음
  // pageSize의 기본값은 시스템 페이지 사이즈
  static func reserve(_ size: size_t, pageSize: size_t, alignment: size_t = 0) -> Region {
    let newSize = align(size, to: pageSize)
    
    if alignment <= pageSize {
      let ptr = mmap(nil, newSize, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0)
      assert(ptr != MAP_FAILED)
      return Region(base: ptr, size: newSize, pageSize: pageSize, alignment: alignment)
    }
    
    // mmap은 요청한 정렬 주소에 반드시 할당하지 않음
    // 그래서 수동으로 조정
    
    let paddedReserveSize: size_t = newSize + alignment
    let addr = UInt(bitPattern: mmap(nil, paddedReserveSize, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0))
    assert(addr != UInt(bitPattern: MAP_FAILED))
    
    let upAlignedAddr: UInt = (addr + UInt(alignment)) & ~(UInt(alignment) - 1)
    let diff = size_t(upAlignedAddr - addr)
    
    // mmap이 할당한 실제 주소를 저장할 수 있도록 해당 영역에 읽기 및 쓰기 권한을 부여
    mprotect(UnsafeMutableRawPointer(bitPattern: addr), diff, PROT_READ | PROT_WRITE)
    
    // 주소 저장
    let adjustment = UnsafeMutablePointer<size_t>(bitPattern: upAlignedAddr)! - 1
    adjustment.pointee = diff
    // read only로 변경
    mprotect(UnsafeMutableRawPointer(bitPattern: addr), diff, PROT_READ)
    
    return Region(base: UnsafeMutableRawPointer(bitPattern: upAlignedAddr), size: newSize, pageSize: pageSize, alignment: alignment)
  }
  
  // Region은 이전에 reserve 호출 후 반환된 값만 사용
  static func unreserve(_ region: borrowing Region) {
    let newSize = align(region.size, to: region.pageSize)
    if region.alignment <= region.pageSize {
      #if DEBUG
      if munmap(region.base, newSize) != 0 { fatalError() }
      #else
      munmap(region.base, newSize)
      #endif
    } else {
      let paddedReserveSize = newSize + region.alignment
      let adjustment = UnsafePointer<size_t>(OpaquePointer(region.base)) - 1
      let baseAddr = UInt(bitPattern: region.base) - UInt(adjustment.pointee)
      #if DEBUG
      if munmap(UnsafeMutableRawPointer(bitPattern: baseAddr), paddedReserveSize) != 0 { fatalError() }
      #else
      munmap(UnsafeMutableRawPointer(bitPattern: baseAddr), paddedReserveSize)
      #endif
    }
  }
  
  // Region의 base는 시스템 페이지 크기에 맞춰서 아래쪽으로 정렬되고, 무조건 이전에 예약한 영역 안에 있어야 함
  // base, base + size 범위랑 겹치는 모든 페이지가 매핑 또는 언매핑됨
  
  static func map(_ region: borrowing Region, _ mapSize: size_t) {
    let baseAddr = UInt(bitPattern: region.base) & ~(UInt(region.pageSize) - 1)
    let endAddr = align(UInt(bitPattern: region.base) + UInt(mapSize), to: region.pageSize)
    #if DEBUG
    if mprotect(UnsafeMutableRawPointer(bitPattern: baseAddr), size_t(endAddr - baseAddr), PROT_READ | PROT_WRITE) != 0 { fatalError() }
    #else
    mprotect(UnsafeMutableRawPointer(bitPattern: baseAddr), size_t(endAddr - baseAddr), PROT_READ | PROT_WRITE)
    #endif
  }
  
  static func unmap(_ region: borrowing Region, _ mappedSize: size_t) {
    let baseAddr = UInt(bitPattern: region.base) & ~(UInt(region.pageSize) - 1)
    let endAddr = align(UInt(bitPattern: region.base) + UInt(mappedSize), to: region.pageSize)
    #if DEBUG
    if mprotect(UnsafeMutableRawPointer(bitPattern: baseAddr), size_t(endAddr - baseAddr), PROT_NONE) != 0 { fatalError() }
    #else
    mprotect(UnsafeMutableRawPointer(bitPattern: baseAddr), size_t(endAddr - baseAddr), PROT_NONE)
    #endif
  }
}
#endif
