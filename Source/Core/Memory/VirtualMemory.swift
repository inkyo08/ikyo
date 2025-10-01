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
      // On POSIX mmap can reserve at page granularity
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

// Reserve address space, optionally aligned to allocation granularity or larger if possible.
// For simplicity and portability, we guarantee alignment to allocation granularity.
// For alignments above granularity, we best-effort with over-reserve on POSIX; on Windows we stick to granularity.
public func vmReserve(size: Int, alignment: Int) throws -> VMRegion {
  precondition(size > 0)
  let pg = VM.pageSize()
  let gran = VM.allocationGranularity()
  let reserveSize = VM.alignUp(size, to: pg)
  #if os(Windows)
    // Windows: VirtualAlloc aligns to allocation granularity.
    let base = VirtualAlloc(nil, reserveSize, DWORD(MEM_RESERVE), DWORD(PAGE_NOACCESS))
    guard let b = base else { throw VMError.reserveFailed }
    return VMRegion(base: b, size: reserveSize, pageSize: pg, reserved: true)
  #else
    // POSIX: Try to over-reserve to honor alignment if larger than page size.
    let al = max(gran, alignment)
    let over = al > pg ? reserveSize + al : reserveSize
    let p = mmap(nil, over, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0)
    if p == MAP_FAILED {
      throw VMError.reserveFailed
    }
    var base = p!.assumingMemoryBound(to: UInt8.self)
    var finalSize = reserveSize
    if al > pg {
      // Align base forward to 'al'
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

// Commit a range within a reserved region: offset and size are page-aligned or will be aligned down/up.
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
    // Switch protection to RW to "commit"
    if mprotect(p, sizeA, PROT_READ | PROT_WRITE) != 0 {
      throw VMError.commitFailed
    }
    // Optionally touch pages lazily elsewhere
    return true
  #endif

}

// Decommit a committed range: set to no access and advise discard if available.
public func vmDecommit(_ region: inout VMRegion, offset: Int, size: Int) {
  guard let base = region.base else { return }
  let offA = VM.alignDown(offset, to: region.pageSize)
  let sizeA = VM.alignUp(size, to: region.pageSize)
  guard offA >= 0, sizeA > 0, offA + sizeA <= region.size else { return }

  #if os(Windows)
    let p = UnsafeMutableRawPointer(bitPattern: UInt(bitPattern: base) + UInt(offA))
    // MEM_DECOMMIT leaves address space reserved
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

// Hint for huge pages (best effort).
public func vmAdviseHuge(_ region: VMRegion, enable: Bool) {
  guard let base = region.base else { return }
  #if os(Windows)
    // Windows large pages must be allocated with MEM_LARGE_PAGES at reserve-time; cannot switch post-hoc.
    _ = base
    _ = enable
  #else
    #if canImport(Darwin)
      // macOS does not offer madvise(MADV_HUGEPAGE); transparent huge pages not exposed. Best effort no-op.
      _ = base
      _ = enable
    #else
      let advice = enable ? Int32(MADV_HUGEPAGE) : Int32(MADV_NOHUGEPAGE)
      _ = madvise(base, region.size, advice)
    #endif
  #endif
}
