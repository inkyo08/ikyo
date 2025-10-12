import Foundation

#if canImport(Darwin)
  import Darwin
#elseif os(Windows)
  import WinSDK
#else
  import Glibc
#endif

#if DEBUG
  let LargeGuardPagesEnabledDefault = true
#else
  let LargeGuardPagesEnabledDefault = false
#endif

public final class LargeAllocator {
  public static let shared = LargeAllocator()

  // 내부 상수를 직접 노출하지 않고 공개 기본값을 노출합니다.
  public static var defaultGuardPagesEnabled: Bool { LargeGuardPagesEnabledDefault }

  private let pageSize: Int
  private init() {
    self.pageSize = VM.pageSize()
  }

  private struct Header {
    // 정렬이 오프셋을 요구하거나 가드 페이지가 사용되는 경우 반환된 포인터 바로 앞에 저장됩니다.
    var base: UnsafeMutableRawPointer
    var totalSize: Int
    var userSize: Int
    var guardPages: Int8
    var offsetFromBase: Int32
    var magic: UInt64
  }

  private static let headerMagic: UInt64 = 0x1A2B_3C4D_5E6F_7788

  public func allocate(
    size: Int, alignment: Int = 16, debugGuardPages: Bool = LargeAllocator.defaultGuardPagesEnabled
  ) -> UnsafeMutableRawPointer? {
    guard size > 0 else { return nil }
    let pg = pageSize
    let guardPages = debugGuardPages ? 1 : 0
    let guardBytes = guardPages * pg

    // 페이지 정렬된 상태로 직접 예약 + 커밋합니다
    // alignment > pg인 경우, 과다 할당하고 내부에서 정렬합니다
    let needHeader = max(MemoryLayout<Header>.size, alignment)
    let over = alignment > pg ? alignment + needHeader : needHeader

    let total = VM.alignUp(size + over + 2 * guardBytes, to: pg)

    do {
      var region = try vmReserve(size: total, alignment: pg)
      // [FIX: region leak] 실패 시 해제를 보장하기 위해 protect/commit을 내부 do-catch로 감쌉니다
      do {
        // 가드를 보호합니다
        if debugGuardPages && guardPages > 0 {
          try vmProtect(region, offset: 0, size: guardBytes, prot: .noAccess)
          try vmProtect(region, offset: total - guardBytes, size: guardBytes, prot: .noAccess)
        }
        // 사용자 범위를 커밋합니다
        let commitStart = guardBytes
        let commitSize = total - 2 * guardBytes
        _ = try vmCommit(&region, offset: commitStart, size: commitSize)
      } catch {
        try? vmRelease(&region)
        throw error
      }

      let baseAddr = UInt(bitPattern: region.base!)
      var userPtrRaw = baseAddr + UInt(guardBytes) + UInt(MemoryLayout<Header>.size)
      let align = max(16, alignment)
      userPtrRaw = UInt(VM.alignUp(Int(userPtrRaw), to: align))
      let headerPtrRaw = userPtrRaw - UInt(MemoryLayout<Header>.size)
      let headerPtr = UnsafeMutableRawPointer(bitPattern: headerPtrRaw)!
      let header = headerPtr.assumingMemoryBound(to: Header.self)
      header.pointee = Header(
        base: region.base!, totalSize: total, userSize: size, guardPages: Int8(guardPages),
        offsetFromBase: Int32(Int(userPtrRaw) - Int(baseAddr)), magic: LargeAllocator.headerMagic)
      
      // 사용자 포인터를 반환합니다
      let userPtr = UnsafeMutableRawPointer(bitPattern: userPtrRaw)!
      
      // [FIX: debug] 누수 추적에 추가
      #if DEBUG
        MemoryDebug.tagAlloc(ptr: userPtr, size: size)
      #endif
      
      return userPtr
    } catch {
      return nil
    }
  }

  public func deallocate(_ p: UnsafeMutableRawPointer?, size: Int) {
    guard let p else { return }
    
    // [FIX: double-free] DEBUG에서 이중 해제 체크
    #if DEBUG
      MemoryDebug.checkDoubleFree(ptr: p)
    #endif
    
    // 헤더를 읽고 영역을 해제합니다
    let headerPtr = p.advanced(by: -MemoryLayout<Header>.size)
    let h = headerPtr.assumingMemoryBound(to: Header.self).pointee
    if h.magic != LargeAllocator.headerMagic {
      // 알 수 없는 포인터; 디버그에서 무시하거나 트랩합니다
      assertionFailure("LargeAllocator: invalid header magic (double-free or foreign pointer?)")
      return
    }
    var region = VMRegion(base: h.base, size: h.totalSize, pageSize: VM.pageSize(), reserved: true)
    // 사용자 범위를 디커밋(선택 사항)한 다음 해제합니다
    vmDecommit(
      &region, offset: Int(h.guardPages) * region.pageSize,
      size: h.totalSize - 2 * Int(h.guardPages) * region.pageSize)
    do {
      try vmRelease(&region)
    } catch {
      assertionFailure("LargeAllocator: vmRelease failed")
    }
    
    // [FIX: debug] 누수 추적에서 제거
    #if DEBUG
      MemoryDebug.tagFree(ptr: p)
    #endif
  }

  // maybeDeallocate: 헤더 매직을 확인하여 Large 할당을 감지하려고 시도합니다.
  // LargeAllocator에 의해 할당 해제된 경우 true를 반환하고, 그렇지 않으면 false를 반환합니다.
  // 안전 장치: 작은 first-bin 포인터에서 오류를 방지하기 위해 페이지 경계를 넘어 읽는 것을 피합니다.
  public func maybeDeallocate(_ p: UnsafeMutableRawPointer) -> Bool {
    let headerSize = MemoryLayout<Header>.size
    let pg = VM.pageSize()
    let addr = UInt(bitPattern: p)
    // 포인터가 페이지 시작 부분에 너무 가까우면 헤더를 읽을 때 페이지 경계를 넘을 수 있으므로 중단합니다.
    if Int(addr % UInt(pg)) < headerSize {
      return false
    }
    let headerPtr = p.advanced(by: -headerSize)
    let h = headerPtr.assumingMemoryBound(to: Header.self).pointee
    if h.magic != LargeAllocator.headerMagic {
      return false
    }
    // 정확성을 위해 저장된 userSize를 사용하여 표준 deallocate에 위임합니다
    self.deallocate(p, size: Int(h.userSize))
    return true
  }
}

extension LargeAllocator: @unchecked Sendable {}
