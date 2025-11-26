#if os(Windows)
import Foundation
import WinSDK

// Windows 10 AMD64 환경
let systemPageSize: size_t = 4 * 1024

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
    var addr: UInt

    repeat
    {
      addr = UInt(bitPattern: VirtualAlloc(nil, SIZE_T(newSize), DWORD(MEM_RESERVE), DWORD(PAGE_READWRITE)))
      if addr == 0 { break }

      let alignedAddr = alignment == 0 ? addr : align(addr, to: alignment)

      if (alignedAddr - addr) > 0 {
        VirtualFree(LPVOID(bitPattern: addr), 0, DWORD(MEM_RELEASE))
        addr = UInt(bitPattern: VirtualAlloc(LPVOID(bitPattern: alignedAddr), SIZE_T(newSize), DWORD(MEM_RESERVE), DWORD(PAGE_READWRITE)))
      }
    } while addr == 0;

    return UnsafeMutableRawPointer(bitPattern: addr)
  } // func reserve()

  // base는 이전에 reserve 호출 후 반환된 값만 사용
  // 예약할 때 사용했던 size와 alignment값을 동일하게 전달해야함
  public static func unreserve(base: UnsafeMutableRawPointer, size: size_t, alignment: size_t = 0) {
    VirtualFree(base, 0, DWORD(MEM_RELEASE))
  } // func unreserve()

  // base는 시스템 페이지 크기에 맞춰서 아래쪽으로 정렬되고, 무조건 이전에 예약한 영역 안에 있어야 함
  // base, base + size 범위랑 겹치는 모든 페이지가 매핑 또는 언매핑됨
  public static func map(base: UnsafeMutableRawPointer, size: size_t) { VirtualAlloc(base, SIZE_T(size), DWORD(MEM_COMMIT), DWORD(PAGE_READWRITE)) }
  public static func unmap(base: UnsafeMutableRawPointer, size: size_t) { VirtualFree(base, SIZE_T(size), DWORD(MEM_DECOMMIT)) }
} // enum VirtualMemory

#endif
