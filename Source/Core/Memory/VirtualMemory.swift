import Foundation

#if os(Windows)
  import WinSDK
#elseif canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

public struct VMRegion {
  public var base: UnsafeMutableRawPointer?
  public var size: Int
  public var pageSize: Int
  public var reserved: Bool
  public init(base: UnsafeMutableRawPointer?, size: Int, pageSize: Int, reserved: Bool) {
    self.base = base
    self.size = size
    self.pageSize = pageSize
    self.reserved = reserved
  }
}

public enum VMError: Error {
  case reserveFailed
  case commitFailed
  case protectFailed
  case releaseFailed
  case invalidParameters
}

public enum VMProtect {
  case noAccess
  case read
  case readWrite
}

public enum VM {
  public static func pageSize() -> Int {
    #if os(Windows)
      var si = SYSTEM_INFO()
      GetSystemInfo(&si)
      return Int(si.dwPageSize)
    #elseif canImport(Darwin)
      return Int(getpagesize())
    #else
      let s = sysconf(Int32(_SC_PAGESIZE))
      return s > 0 ? Int(s) : 4096
    #endif
  }

  public static func allocationGranularity() -> Int {
    #if os(Windows)
      var si = SYSTEM_INFO()
      GetSystemInfo(&si)
      return Int(si.dwAllocationGranularity)
    #else
      // POSIX에서는 mmap이 페이지 단위로 예약할 수 있음
      return pageSize()
    #endif
  }

  @inline(__always)
  static func alignUp(_ x: Int, to alignment: Int) -> Int {
    let a = max(1, alignment)
    return (x + (a - 1)) & ~(a - 1)
  }

  @inline(__always)
  static func alignDown(_ x: Int, to alignment: Int) -> Int {
    let a = max(1, alignment)
    return x & ~(a - 1)
  }

}

// 주소 공간을 예약하며, 가능하면 할당 단위 또는 그보다 큰 값으로 정렬
// 간단함과 이식성을 위해 할당 단위로의 정렬을 보장함
// 할당 단위를 초과하는 정렬의 경우, POSIX에서는 과잉 예약으로 최선을 다하며, Windows에서는 할당 단위를 유지함
public func vmReserve(size: Int, alignment: Int) throws -> VMRegion {
  precondition(size > 0)
  let pg = VM.pageSize()
  let gran = VM.allocationGranularity()
  let reserveSize = VM.alignUp(size, to: pg)
  #if os(Windows)
    // Windows: VirtualAlloc은 할당 단위로 정렬함
    let base = VirtualAlloc(nil, reserveSize, DWORD(MEM_RESERVE), DWORD(PAGE_NOACCESS))
    guard let b = base else { throw VMError.reserveFailed }
    return VMRegion(base: b, size: reserveSize, pageSize: pg, reserved: true)
  #else
    // POSIX: 페이지 크기보다 큰 경우 정렬을 준수하기 위해 과잉 예약 시도
    let al = max(gran, alignment)
    let over = al > pg ? reserveSize + al : reserveSize
    let p = mmap(nil, over, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0)
    if p == MAP_FAILED {
      throw VMError.reserveFailed
    }
    var base = p!.assumingMemoryBound(to: UInt8.self)
    var finalSize = reserveSize
    if al > pg {
      // base를 'al'로 앞쪽 정렬
      let addr = UInt(bitPattern: base)
      let aligned = VM.alignUp(Int(addr), to: al)
      let pre = aligned - Int(addr)
      let post = (over - pre) - reserveSize
      if pre > 0 {
        munmap(base, pre)
      }
      if post > 0 {
        let tail = UnsafeMutableRawPointer(bitPattern: aligned + reserveSize)!
        munmap(tail, post)
      }
      base = UnsafeMutableRawPointer(bitPattern: aligned)!.assumingMemoryBound(to: UInt8.self)
      finalSize = reserveSize
    }
    return VMRegion(
      base: UnsafeMutableRawPointer(base), size: finalSize, pageSize: pg, reserved: true)
  #endif
}

// 예약된 영역 내에서 범위를 커밋: offset과 size는 페이지 정렬되거나 내림/올림 정렬됨
@discardableResult
public func vmCommit(_ region: inout VMRegion, offset: Int, size: Int) throws -> Bool {
  guard let base = region.base else { throw VMError.invalidParameters }
  let offA = VM.alignDown(offset, to: region.pageSize)
  let sizeA = VM.alignUp(size, to: region.pageSize)
  guard offA >= 0, sizeA > 0, offA + sizeA <= region.size else { throw VMError.invalidParameters }

  #if os(Windows)
    let p = UnsafeMutableRawPointer(bitPattern: UInt(bitPattern: base) + UInt(offA))
    let res = VirtualAlloc(p, sizeA, DWORD(MEM_COMMIT), DWORD(PAGE_READWRITE))
    if res == nil { throw VMError.commitFailed }
    return true
  #else
    let p = UnsafeMutableRawPointer(bitPattern: UInt(bitPattern: base) + UInt(offA))!
    // "커밋"하기 위해 보호를 RW로 전환
    if mprotect(p, sizeA, PROT_READ | PROT_WRITE) != 0 {
      throw VMError.commitFailed
    }
    // 선택적으로 다른 곳에서 페이지를 지연 접근
    return true
  #endif

}

// 커밋된 범위를 해제: 접근 불가로 설정하고 가능하면 폐기 권고
public func vmDecommit(_ region: inout VMRegion, offset: Int, size: Int) {
  guard let base = region.base else { return }
  let offA = VM.alignDown(offset, to: region.pageSize)
  let sizeA = VM.alignUp(size, to: region.pageSize)
  guard offA >= 0, sizeA > 0, offA + sizeA <= region.size else { return }

  #if os(Windows)
    let p = UnsafeMutableRawPointer(bitPattern: UInt(bitPattern: base) + UInt(offA))
    // MEM_DECOMMIT는 주소 공간을 예약된 상태로 유지함
    _ = VirtualFree(p, SIZE_T(sizeA), DWORD(MEM_DECOMMIT))
  #else
    let p = UnsafeMutableRawPointer(bitPattern: UInt(bitPattern: base) + UInt(offA))!
    _ = mprotect(p, sizeA, PROT_NONE)
    #if canImport(Darwin)
      _ = madvise(p, sizeA, MADV_FREE)
    #else
      _ = madvise(p, sizeA, Int32(MADV_DONTNEED))
    #endif
  #endif

}

@discardableResult
public func vmProtect(_ region: VMRegion, offset: Int, size: Int, prot: VMProtect) throws -> Bool {
  guard let base = region.base else { throw VMError.invalidParameters }
  let offA = VM.alignDown(offset, to: region.pageSize)
  let sizeA = VM.alignUp(size, to: region.pageSize)
  guard offA >= 0, sizeA > 0, offA + sizeA <= region.size else { throw VMError.invalidParameters }

  #if os(Windows)
    let p = UnsafeMutableRawPointer(bitPattern: UInt(bitPattern: base) + UInt(offA))!
    var oldProt: DWORD = 0
    let newProt: DWORD
    switch prot {
    case .noAccess: newProt = DWORD(PAGE_NOACCESS)
    case .read: newProt = DWORD(PAGE_READONLY)
    case .readWrite: newProt = DWORD(PAGE_READWRITE)
    }
    if VirtualProtect(p, SIZE_T(sizeA), newProt, &oldProt) == 0 {
      throw VMError.protectFailed
    }
    return true
  #else
    let p = UnsafeMutableRawPointer(bitPattern: UInt(bitPattern: base) + UInt(offA))!
    let newProt: Int32
    switch prot {
    case .noAccess: newProt = PROT_NONE
    case .read: newProt = PROT_READ
    case .readWrite: newProt = PROT_READ | PROT_WRITE
    }
    if mprotect(p, sizeA, newProt) != 0 { throw VMError.protectFailed }
    return true
  #endif

}

public func vmRelease(_ region: inout VMRegion) throws {
  guard let base = region.base, region.reserved else { return }
  #if os(Windows)
    if VirtualFree(base, 0, DWORD(MEM_RELEASE)) == 0 {
      throw VMError.releaseFailed
    }
  #else
    if munmap(base, region.size) != 0 {
      throw VMError.releaseFailed
    }
  #endif
  region.base = nil
  region.reserved = false
}

// 큰 페이지에 대한 힌트 (최선을 다함)
public func vmAdviseHuge(_ region: VMRegion, enable: Bool) {
  guard let base = region.base else { return }
  #if os(Windows)
    // Windows 큰 페이지는 예약 시점에 MEM_LARGE_PAGES로 할당되어야 하며, 사후에 전환할 수 없음
    _ = base
    _ = enable
  #else
    #if canImport(Darwin)
      // macOS는 madvise(MADV_HUGEPAGE)를 제공하지 않음; 투명 큰 페이지가 노출되지 않음. 최선을 다하는 no-op
      _ = base
      _ = enable
    #else
      let advice = enable ? Int32(MADV_HUGEPAGE) : Int32(MADV_NOHUGEPAGE)
      _ = madvise(base, region.size, advice)
    #endif
  #endif
}
