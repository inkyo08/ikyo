import Atomics
import Foundation

#if canImport(Darwin)
  import Darwin
#elseif os(Windows)
  import WinSDK
#else
  import Glibc
#endif

// 작은 binned 할당자 v2:
// - v2 추가 사항: O(1) 크기->클래스 LUT (플래그), 지수 백오프가 있는 고갈 플래그 (플래그),
//             선택적 블록 비트맵 + partial/full/empty 리스트 (플래그, 기본값 off),
//             TLSMagazine 변경을 통한 TLS 소멸자 지원.
// VM 블록은 기본적으로 256KB 청크로 커밋됩니다. 메타데이터는 v1 경로에서 의도적으로 최소화되었습니다.
// 디버그 카나리아와 quarantine은 MemoryDebug를 통해 통합됩니다.

public final class BinnedAllocator: RawAllocator {
  public static let shared = BinnedAllocator()

  // v1 범위: 최대 4KB
  static let maxSmallSize = 4 * 1024
  static let blockSizeDefault = 256 * 1024

  // v2 기능 플래그 (요구사항에 따른 안전한 기본값)
  // [v2] 플래그를 구성 가능하게 만들되 (내부적으로) 요청된 대로 기본값 설정
  internal let enableLUT: Bool = true
  internal let enableExhaustedBackoff: Bool = true
  internal let enableBlockLists: Bool = false  // 사양에 따라 기본값 off

  // 선택적 메모리 압박 알림 콜백
  // [v2] commit 실패 또는 allocator가 클래스를 고갈로 표시할 때 호출됨
  public var memoryPressureHandler: (() -> Void)?

  // 크기 클래스 테이블; 인덱스 -> bin 크기
  private let classes: [Int]
  private let classCount: Int

  // [v2] 선택적 O(1) LUT: 크기(바이트) -> 클래스 인덱스, small이 아니면 -1
  private var sizeToClassLUT: [Int] = []

  // [FIX: quarantine leak] binSize -> 클래스 인덱스의 역방향 맵
  private var binSizeToClassIndex: [Int: Int] = [:]

  // 크기 클래스별 전역 상태
  final class ClassState {
    let binSize: Int
    // Lock-free 프리 리스트 헤드 (free bin들의 스택)
    let freeHead: ManagedAtomic<UInt> = ManagedAtomic<UInt>(0)
    // 블록 증가 및 (활성화된 경우) 메타데이터 업데이트를 위한 슬로우 패스 락
    let growLock: ManagedAtomic<Int> = ManagedAtomic<Int>(0)
    // 블록 및 free bin 개수 추적 (프로파일링)
    let freeCount: ManagedAtomic<Int> = ManagedAtomic<Int>(0)

    // [v2] 고갈 + 백오프 상태
    let exhausted: ManagedAtomic<Int> = ManagedAtomic<Int>(0)  // 0=false, 1=true
    let backoffExp: ManagedAtomic<Int> = ManagedAtomic<Int>(0)  // 지수 인수
    let nextGrowAfterNanos: ManagedAtomic<UInt64> = ManagedAtomic<UInt64>(0)

    // [v2] 블록 리스트 (allocator 플래그를 통해서만 활성화됨)
    var blocks: [Block] = []
    var partialBlocks: [Int] = []  // blocks로의 인덱스
    var fullBlocks: [Int] = []
    var emptyBlocks: [Int] = []

    init(binSize: Int) { self.binSize = binSize }
  }

  struct Block {
    var region: VMRegion
    var base: UnsafeMutableRawPointer
    var size: Int
    var binSize: Int
    var binsTotal: Int
    var binsFree: ManagedAtomic<Int> = ManagedAtomic<Int>(0)

    // [v2] 블록 리스트 추적이 활성화된 경우:
    // 점유 비트맵: 1 = 할당됨, 0 = free
    // UInt64 워드 배열로 저장됨 (enableBlockLists일 때만 사용됨)
    var bitmapWords: [UInt64]? = nil
  }

  private var states: [ClassState] = []

  private init() {
    var table: [Int] = []
    // 16..256, 16씩 증가
    var s = 16
    while s <= 256 {
      table.append(s)
      s += 16
    }
    // 288..512, 32씩 증가
    s = 288
    while s <= 512 {
      table.append(s)
      s += 32
    }
    // 576..4096, 64씩 증가
    s = 576
    while s <= 4096 {
      table.append(s)
      s += 64
    }
    self.classes = table
    self.classCount = table.count
    self.states = table.map { ClassState(binSize: $0) }

    // [FIX: quarantine leak] binSize -> 인덱스의 역방향 맵 구축
    for (i, sz) in table.enumerated() {
      binSizeToClassIndex[sz] = i
    }

    // [v2] 활성화된 경우 LUT 초기화
    if enableLUT {
      self.sizeToClassLUT = Self.buildLUT(classes: table)
    }

    // [v2] TLSMagazine 용량이 classCount와 일치하도록 보장 (OOB 방지)
    TLSMagazine.shared.configure(maxClasses: self.classCount, cap: 32)
  }

  // [v2] 크기->클래스 인덱스 매핑을 위한 O(1) LUT 구축
  private static func buildLUT(classes: [Int]) -> [Int] {
    var lut = [Int](repeating: -1, count: maxSmallSize + 1)
    var currentClass = 0
    var prevSize = 1
    while currentClass < classes.count {
      let clsSize = classes[currentClass]
      let upper = min(maxSmallSize, clsSize)
      if prevSize <= upper {
        for sz in prevSize...upper {
          lut[sz] = currentClass
        }
      }
      prevSize = clsSize + 1
      currentClass += 1
    }
    // 마지막 클래스 크기보다 큰 크기는 -1로 유지 (small이 아님)
    return lut
  }

  // 크기를 클래스 인덱스로 변환 (올림)
  private func classIndex(for size: Int) -> Int? {
    if size <= 0 { return nil }
    if size > BinnedAllocator.maxSmallSize { return nil }
    if enableLUT {
      let idx = sizeToClassLUT[size]
      return idx >= 0 ? idx : nil
    } else {
      // v1 폴백: 선형 탐색
      for (i, s) in classes.enumerated() {
        if size <= s { return i }
      }
      return nil
    }
  }

  private func spinLock(_ lock: ManagedAtomic<Int>) {
    while true {
      if lock.compareExchange(expected: 0, desired: 1, ordering: .acquiringAndReleasing)
        .exchanged
      {
        return
      }
      // 일시정지
      #if os(Windows)
        _ = Sleep(0)
      #else
        sched_yield()
      #endif
    }
  }

  private func spinUnlock(_ lock: ManagedAtomic<Int>) {
    lock.store(0, ordering: .releasing)
  }

  // 클래스의 전역 freelist에 포인터를 push
  // [FIX: ABA] growLock으로 보호하여 ABA 문제 방지
  private func pushFree(_ cs: ClassState, _ p: UnsafeMutableRawPointer) {
    spinLock(cs.growLock)
    defer { spinUnlock(cs.growLock) }
    
    let head = cs.freeHead.load(ordering: .relaxed)
    storeNext(p, next: UnsafeMutableRawPointer(bitPattern: UInt(head)))
    cs.freeHead.store(UInt(bitPattern: p), ordering: .relaxed)
    cs.freeCount.wrappingIncrement(ordering: .relaxed)
  }

  // 전역 freelist에서 pop; 비어있으면 nil 반환
  // [FIX: ABA] growLock으로 보호하여 ABA 문제 방지
  private func popFree(_ cs: ClassState) -> UnsafeMutableRawPointer? {
    spinLock(cs.growLock)
    defer { spinUnlock(cs.growLock) }
    
    let head = cs.freeHead.load(ordering: .relaxed)
    if head == 0 {
      return nil
    }
    let headPtr = UnsafeMutableRawPointer(bitPattern: UInt(head))!
    let next = loadNext(headPtr)
    let desired: UInt = next.map { UInt(bitPattern: $0) } ?? 0
    cs.freeHead.store(desired, ordering: .relaxed)
    cs.freeCount.wrappingDecrement(ordering: .relaxed)
    return headPtr
  }

  @inline(__always)
  private func storeNext(_ p: UnsafeMutableRawPointer, next: UnsafeMutableRawPointer?) {
    // next 포인터를 UInt로 저장
    let addr = UInt(bitPattern: next)
    p.storeBytes(of: addr, as: UInt.self)
  }

  @inline(__always)
  private func loadNext(_ p: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer? {
    let addr = p.load(as: UInt.self)
    if addr == 0 { return nil }
    return UnsafeMutableRawPointer(bitPattern: addr)
  }

  // MARK: - [v2] 고갈 + 백오프 헬퍼

  // ns 단위의 단조 시간
  private func nowNanos() -> UInt64 {
    #if os(Windows)
      // GetTickCount64는 ms 단위로 반환
      return UInt64(GetTickCount64()) * 1_000_000
    #else
      var ts = timespec()
      #if canImport(Darwin)
        _ = clock_gettime(CLOCK_MONOTONIC_RAW, &ts)
      #else
        _ = clock_gettime(CLOCK_MONOTONIC, &ts)
      #endif
      return UInt64(ts.tv_sec) &* 1_000_000_000 &+ UInt64(ts.tv_nsec)
    #endif
  }

  // 지수로부터 상한선을 가진 지수 백오프 지연(ns) 계산
  private func backoffDelayNanos(exp: Int) -> UInt64 {
    // 기본 1ms, 상한선 50ms
    let base: UInt64 = 1_000_000  // 1ms
    let maxDelay: UInt64 = 50_000_000  // 50ms
    let raw = base &<< UInt64(max(0, min(exp, 16)))
    return raw > maxDelay ? maxDelay : raw
  }

  private func shouldAttemptGrow(_ cs: ClassState) -> Bool {
    if !enableExhaustedBackoff { return true }
    if cs.exhausted.load(ordering: .relaxed) == 0 { return true }
    let t = nowNanos()
    let deadline = cs.nextGrowAfterNanos.load(ordering: .acquiring)
    return t >= deadline
  }

  private func recordGrowFailure(_ cs: ClassState) {
    if !enableExhaustedBackoff { return }
    cs.exhausted.store(1, ordering: .releasing)
    // 상한선을 가진 지수 백오프
    let curExp = cs.backoffExp.load(ordering: .relaxed)
    let nextExp = min(curExp + 1, 16)
    cs.backoffExp.store(nextExp, ordering: .relaxed)
    let delay = backoffDelayNanos(exp: nextExp)
    let deadline = nowNanos() &+ delay
    cs.nextGrowAfterNanos.store(deadline, ordering: .releasing)
    // 메모리 압박 알림
    memoryPressureHandler?()
  }

  private func recordGrowSuccess(_ cs: ClassState) {
    if !enableExhaustedBackoff { return }
    cs.exhausted.store(0, ordering: .releasing)
    cs.backoffExp.store(0, ordering: .relaxed)
    cs.nextGrowAfterNanos.store(0, ordering: .relaxed)
  }

  // MARK: - [v2] 블록 리스트 헬퍼 (플래그가 켜져있을 때만 활성화됨)

  private func initBlockMetadataIfEnabled(_ blockIndex: Int, in cs: ClassState) {
    guard enableBlockLists else { return }
    var blk = cs.blocks[blockIndex]
    let words = (blk.binsTotal + 63) / 64
    blk.bitmapWords = Array(repeating: 0, count: words)
    cs.blocks[blockIndex] = blk
    // 초기에는 비어있음 (모두 free)
    cs.emptyBlocks.append(blockIndex)
  }

  private func markAllocatedIfEnabled(_ cs: ClassState, ptr: UnsafeMutableRawPointer) {
    guard enableBlockLists else { return }
    // 경쟁을 피하기 위해 growLock 하에서 메타데이터 업데이트 (기능은 기본적으로 off)
    spinLock(cs.growLock)
    defer { spinUnlock(cs.growLock) }

    guard let (idx, bin) = findBlockAndBinIndex(cs, ptr: ptr) else { return }
    var blk = cs.blocks[idx]
    if var words = blk.bitmapWords {
      let w = bin / 64
      let b = UInt64(1) << UInt64(bin % 64)
      if (words[w] & b) == 0 {
        words[w] |= b
        blk.bitmapWords = words
        let newFree = blk.binsFree.wrappingDecrementThenLoad(ordering: .relaxed)
        // 리스트 이동
        updateListsOnAlloc(cs: cs, blockIndex: idx, binsFreeAfter: newFree)
        cs.blocks[idx] = blk
      } else {
        // 이미 할당됨; 아무것도 하지 않음
        cs.blocks[idx] = blk
      }
    }
  }

  private func markFreedIfEnabled(_ cs: ClassState, ptr: UnsafeMutableRawPointer) {
    guard enableBlockLists else { return }
    spinLock(cs.growLock)
    defer { spinUnlock(cs.growLock) }

    guard let (idx, bin) = findBlockAndBinIndex(cs, ptr: ptr) else { return }
    var blk = cs.blocks[idx]
    if var words = blk.bitmapWords {
      let w = bin / 64
      let b = UInt64(1) << UInt64(bin % 64)
      if (words[w] & b) != 0 {
        words[w] &= ~b
        blk.bitmapWords = words
        let newFree = blk.binsFree.wrappingIncrementThenLoad(ordering: .relaxed)
        updateListsOnFree(
          cs: cs, blockIndex: idx, binsFreeAfter: newFree, total: blk.binsTotal)
        cs.blocks[idx] = blk
      } else {
        cs.blocks[idx] = blk
      }
    }
  }

  private func findBlockAndBinIndex(_ cs: ClassState, ptr: UnsafeMutableRawPointer) -> (Int, Int)? {
    // 선형 탐색 (기본적으로 비활성화되므로 허용 가능). 활성화된 경우 속도보다 정확성 우선.
    for (i, blk) in cs.blocks.enumerated() {
      let start = blk.base
      let end = blk.base.advanced(by: blk.size)
      if ptr >= start && ptr < end {
        let off = ptr - blk.base
        let bin = off / blk.binSize
        if bin >= 0 && bin < blk.binsTotal {
          return (i, bin)
        }
      }
    }
    return nil
  }

  private func updateListsOnAlloc(cs: ClassState, blockIndex: Int, binsFreeAfter: Int) {
    // 방금 full이 된 경우, partial/empty에서 full로 이동
    // 여전히 free가 있는 경우, partial에 있도록 보장
    // 그에 따라 다른 리스트에서 제거
    if binsFreeAfter == 0 {
      remove(&cs.partialBlocks, blockIndex)
      remove(&cs.emptyBlocks, blockIndex)
      if !cs.fullBlocks.contains(blockIndex) { cs.fullBlocks.append(blockIndex) }
    } else {
      remove(&cs.fullBlocks, blockIndex)
      remove(&cs.emptyBlocks, blockIndex)
      if !cs.partialBlocks.contains(blockIndex) { cs.partialBlocks.append(blockIndex) }
    }
  }

  private func updateListsOnFree(cs: ClassState, blockIndex: Int, binsFreeAfter: Int, total: Int) {
    if binsFreeAfter == total {
      // 비어있음
      remove(&cs.partialBlocks, blockIndex)
      remove(&cs.fullBlocks, blockIndex)
      if !cs.emptyBlocks.contains(blockIndex) { cs.emptyBlocks.append(blockIndex) }
    } else if binsFreeAfter == 0 {
      // full (free에서는 발생하지 않아야 하지만), 어쨌든 처리
      remove(&cs.partialBlocks, blockIndex)
      remove(&cs.emptyBlocks, blockIndex)
      if !cs.fullBlocks.contains(blockIndex) { cs.fullBlocks.append(blockIndex) }
    } else {
      // partial
      remove(&cs.fullBlocks, blockIndex)
      remove(&cs.emptyBlocks, blockIndex)
      if !cs.partialBlocks.contains(blockIndex) { cs.partialBlocks.append(blockIndex) }
    }
  }

  @inline(__always)
  private func remove(_ arr: inout [Int], _ value: Int) {
    if let i = arr.firstIndex(of: value) { arr.remove(at: i) }
  }

  // 새로운 블록을 커밋하고 그것의 bin들을 freelist에 push하여 클래스 증가
  private func grow(_ cs: ClassState) -> Bool {
    if !cs.growLock.compareExchange(expected: 0, desired: 1, ordering: .acquiringAndReleasing)
      .exchanged
    {
      // 다른 스레드가 증가 중
      return true
    }
    defer { cs.growLock.store(0, ordering: .releasing) }

    let blkSize = max(BinnedAllocator.blockSizeDefault, cs.binSize * 64)
    do {
      var region = try vmReserve(size: blkSize, alignment: VM.allocationGranularity())
      // [FIX: region leak] commit 실패 시 region이 해제되도록 보장
      do {
        _ = try vmCommit(&region, offset: 0, size: blkSize)
      } catch {
        try? vmRelease(&region)
        throw error
      }
      let base = region.base!
      let bins = blkSize / cs.binSize
      let block = Block(
        region: region, base: base, size: blkSize, binSize: cs.binSize, binsTotal: bins)
      block.binsFree.store(bins, ordering: .relaxed)

      // [v2] 블록 리스트가 활성화된 경우, 메타데이터와 empty 리스트 초기화
      cs.blocks.append(block)
      let newBlockIndex = cs.blocks.count - 1
      if enableBlockLists {
        initBlockMetadataIfEnabled(newBlockIndex, in: cs)
      }

      // bin들을 조각내고 freelist에 push
      for i in 0..<bins {
        let ptr = base.advanced(by: i * cs.binSize)
        #if DEBUG
          MemoryDebug.poison(ptr: ptr, size: cs.binSize)
        #endif
        pushFree(cs, ptr)
      }

      // [v2] 성공 시 exhausted/backoff 초기화
      recordGrowSuccess(cs)
      return true
    } catch {
      // [v2] 고갈로 표시하고 백오프 예약, 압박 알림
      recordGrowFailure(cs)
      return false
    }
  }

  // RawAllocator 준수
  // [FIX: alignment] Small allocator는 bin 크기의 자연 정렬을 제공 (≤16 보장됨).
  // 더 큰 정렬의 경우, LargeAllocator로 라우팅.
  public func allocate(size: Int, alignment: Int) -> UnsafeMutableRawPointer? {
    if let idx = classIndex(for: size) {
      let cs = states[idx]
      // bin의 자연 정렬 = binSize의 최대 2의 거듭제곱 인자
      // 예: 64B bin -> 64B 정렬, 576B bin -> 64B 정렬 (576 = 64*9)
      let binPow2Align = 1 << cs.binSize.trailingZeroBitCount
      if alignment > binPow2Align {
        // Small allocator는 이 정렬을 보장할 수 없음; large 경로 사용
        return LargeAllocator.shared.allocate(size: size, alignment: alignment)
      }
      // TLS magazine 빠른 경로
      if let p = TLSMagazine.shared.pop(classIndex: idx) {
        #if DEBUG
          MemoryDebug.checkCanaryOnAlloc(ptr: p, size: cs.binSize)
          MemoryDebug.tagAlloc(ptr: p, size: cs.binSize)
        #endif
        // [v2] 점유 추적 (선택적)
        markAllocatedIfEnabled(cs, ptr: p)
        return p
      }
      // 전역 freelist
      if let p = popFree(cs) {
        #if DEBUG
          MemoryDebug.checkCanaryOnAlloc(ptr: p, size: cs.binSize)
          MemoryDebug.tagAlloc(ptr: p, size: cs.binSize)
        #endif
        markAllocatedIfEnabled(cs, ptr: p)
        return p
      }
      // [v2] 연쇄 실패를 방지하기 위한 grow의 백오프 게이트
      if shouldAttemptGrow(cs) {
        if grow(cs), let p = popFree(cs) {
          #if DEBUG
            MemoryDebug.checkCanaryOnAlloc(ptr: p, size: cs.binSize)
            MemoryDebug.tagAlloc(ptr: p, size: cs.binSize)
          #endif
          markAllocatedIfEnabled(cs, ptr: p)
          return p
        }
        // grow 실패 또는 grow 후에도 free 없음 -> 빠르게 반환
        return nil
      } else {
        // 백오프 윈도우 내; VM을 두드리는 것을 피하고, 빠르게 반환
        return nil
      }
    } else {
      return LargeAllocator.shared.allocate(size: size, alignment: alignment)
    }
  }

  public func deallocate(_ p: UnsafeMutableRawPointer, size: Int) {
    // [FIX: double-free] DEBUG에서 이중 해제 체크를 먼저 수행
    #if DEBUG
      MemoryDebug.checkDoubleFree(ptr: p)
    #endif
    
    // [FIX: alignment routing] 먼저, Large 할당 감지 및 해제 (정렬 라우팅된 것 포함)
    if LargeAllocator.shared.maybeDeallocate(p) {
      return
    }

    if let idx = classIndex(for: size) {
      let cs = states[idx]
      #if DEBUG
        MemoryDebug.poison(ptr: p, size: cs.binSize)
        if MemoryDebug.quarantinePush(ptr: p, classSize: cs.binSize) {
          // Quarantine됨; 누수 추적을 위해 freed로 태그하고 종료
          MemoryDebug.tagFree(ptr: p)
          return
        }
      #endif

      // [v2] 점유 추적을 먼저 (논리적으로 이제 free임)
      markFreedIfEnabled(cs, ptr: p)

      if let overflow = TLSMagazine.shared.push(classIndex: idx, ptr: p) {
        // overflow 배치를 전역 freelist로 flush
        for q in overflow { pushFree(cs, q) }
      }
      #if DEBUG
        MemoryDebug.tagFree(ptr: p)
      #endif
    } else {
      LargeAllocator.shared.deallocate(p, size: size)
    }
  }

  // TLS를 전역으로 flush (예: 프레임 경계에서)
  public func flushTLS() {
    TLSMagazine.shared.flushAllToGlobal { idx, batch in
      let cs = states[idx]
      for p in batch {
        // [v2] 점유는 이미 할당 해제 시점에 표시됨
        pushFree(cs, p)
      }
    }
  }

  // [v2] TLS 소멸자가 임의의 스레드 스택을 flush하기 위한 내부 훅
  // 이것은 pushFree를 allocator에 캡슐화된 상태로 유지함.
  internal func tlsFlushHook(_ idx: Int, _ batch: [UnsafeMutableRawPointer]) {
    guard idx >= 0 && idx < states.count else { return }
    let cs = states[idx]
    for p in batch {
      // 점유는 이미 deallocate 시점에 처리됨
      pushFree(cs, p)
    }
  }

  // [FIX: quarantine leak] quarantine가 가장 오래된 포인터를 해제하기 위한 내부 우회
  // 일반 deallocate 경로를 거치지 않음 (재귀 및 이중 체크 방지)
  internal func freeFromQuarantine(_ p: UnsafeMutableRawPointer, binSize: Int) {
    guard let idx = binSizeToClassIndex[binSize] else { return }
    let cs = states[idx]
    // quarantine 및 디버그 체크 건너뜀; 그냥 전역에 push
    markFreedIfEnabled(cs, ptr: p)
    pushFree(cs, p)
  }
}

extension BinnedAllocator: @unchecked Sendable {}
