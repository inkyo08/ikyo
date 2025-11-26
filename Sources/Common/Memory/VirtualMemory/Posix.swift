#if os(macOS) || os(Linux)
import Foundation

// M2 macOS arm64 환경
// 환경에 따라 변경
let systemPageSize: size_t = 16 * 1024

#if RELEASE
@inline(__always)
fileprivate func ASSERT_POSIX_SUCCESS(_ expr: @autoclosure () -> Int32) {
  _ = expr()
}
#else
@inline(__always)
fileprivate func ASSERT_POSIX_SUCCESS(_ expr: @autoclosure () -> Int32) {
  let returnVal = expr()
  assert(returnVal == 0)
}
#endif

@inline(__always)
fileprivate func align<T: BinaryInteger>(_ value: T, to alignment: size_t) -> T {
  precondition((alignment & (alignment - 1)) == 0)
  let size = (size_t(value) + (alignment - 1)) & ~(alignment - 1)
  return T(size)
}

public enum VirtualMemory {
  // size는 시스템 페이지 크기에 맞춰 올림 처리
  // 반환되는 범위는 항상 시스템 페이지 크기에 따라 정렬되므로, alignment를 별도로 설정해야하는 경우는 거의 없음
  public static func reserve(size: size_t, alignment: size_t = 0) -> UnsafeMutableRawPointer! {
    let newSize = align(size, to: systemPageSize)
    
    if alignment <= systemPageSize {
      let ptr = mmap(nil, newSize, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0)
      if ptr == MAP_FAILED { return nil }
      return ptr
    }
    
    // mmap은 요청한 정렬 주소에 반드시 할당하지 않음
    // 그래서 수동으로 조정
    
    let paddedReserveSize: size_t = newSize + alignment
    let addr = UInt(bitPattern: mmap(nil, paddedReserveSize, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0))
    if addr == UInt(bitPattern: MAP_FAILED) { return nil }
    
    let upAlignedAddr: UInt = (addr + UInt(alignment)) & ~(UInt(alignment) - 1)
    let diff = size_t(upAlignedAddr - addr)
    
    // mmap이 할당한 실제 주소를 저장할 수 있도록 해당 영역에 읽기 및 쓰기 권한을 부여
    mprotect(UnsafeMutableRawPointer(bitPattern: addr), diff, PROT_READ | PROT_WRITE)
    
    // 주소 저장
    let adjustment = UnsafeMutablePointer<size_t>(bitPattern: upAlignedAddr)! - 1
    adjustment.pointee = diff
    // read only로 변경
    mprotect(UnsafeMutableRawPointer(bitPattern: addr), diff, PROT_READ)
    
    return UnsafeMutableRawPointer(bitPattern: upAlignedAddr)
  } // func reserve()
  
  // base는 이전에 reserve 호출 후 반환된 값만 사용
  // 예약할 때 사용했던 size와 alignment값을 동일하게 전달해야함
  public static func unreserve(base: UnsafeMutableRawPointer, size: size_t, alignment: size_t = 0) {
    let newSize = align(size, to: systemPageSize)
    if alignment <= systemPageSize { ASSERT_POSIX_SUCCESS( munmap(base, newSize) ) }
    else {
      let paddedReserveSize = newSize + alignment
      let adjustment = UnsafePointer<size_t>(OpaquePointer(base)) - 1
      let baseAddr = UInt(bitPattern: base) - UInt(adjustment.pointee)
      ASSERT_POSIX_SUCCESS( munmap(UnsafeMutableRawPointer(bitPattern: baseAddr), paddedReserveSize) )
    }
  } // func unreserve()
  
  // base는 시스템 페이지 크기에 맞춰서 아래쪽으로 정렬되고, 무조건 이전에 예약한 영역 안에 있어야 함
  // base, base + size 범위랑 겹치는 모든 페이지가 매핑 또는 언매핑됨
  
  public static func map(base: UnsafeMutableRawPointer, size: size_t) {
    let baseAddr = UInt(bitPattern: base) & ~(UInt(systemPageSize) - 1)
    let endAddr = align(UInt(bitPattern: base) + UInt(size), to: systemPageSize)
    ASSERT_POSIX_SUCCESS( mprotect(UnsafeMutableRawPointer(bitPattern: baseAddr), size_t(endAddr - baseAddr), PROT_READ | PROT_WRITE) )
  } // func map()
  
  public static func unmap(base: UnsafeMutableRawPointer, size: size_t) {
    let baseAddr = UInt(bitPattern: base) & ~(UInt(systemPageSize) - 1)
    let endAddr = align(UInt(bitPattern: base) + UInt(size), to: systemPageSize)
    ASSERT_POSIX_SUCCESS( mprotect(UnsafeMutableRawPointer(bitPattern: baseAddr), size_t(endAddr - baseAddr), PROT_NONE) )
  } // func unmap()
} // enum VirtualMemory

#endif
