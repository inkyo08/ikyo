import Atomics
import Foundation

#if canImport(Darwin)
  import Darwin
#elseif os(Windows)
  import WinSDK
#else
  import Glibc
#endif

// Small binned allocator v2:
// - v2 adds: O(1) size->class LUT (flagged), exhausted flag with exponential backoff (flagged),
//             optional block bitmap + partial/full/empty lists (flagged, default off),
//             TLS destructor support via TLSMagazine changes.
// VM blocks are committed in 256KB chunks by default. Metadata is intentionally minimal in v1 paths.
// Debug canary and quarantine are integrated via MemoryDebug.

public final class BinnedAllocator: RawAllocator {
  public static let shared = BinnedAllocator()

  // v1 scope: up to 4KB
  static let maxSmallSize = 4 * 1024
  static let blockSizeDefault = 256 * 1024

  // v2 feature flags (safe defaults per requirements)
  // [v2] Make flags configurable (internal) but default as requested
  internal let enableLUT: Bool = true
  internal let enableExhaustedBackoff: Bool = true
  internal let enableBlockLists: Bool = false  // default off per spec

  // Optional memory pressure notification callback
  // [v2] Called when commit fails or allocator marks class exhausted
  public var memoryPressureHandler: (() -> Void)?

  // Size class table; index -> bin size
  private let classes: [Int]
  private let classCount: Int

  // [v2] Optional O(1) LUT: size (bytes) -> class index, -1 if not small
  private var sizeToClassLUT: [Int] = []

  // [FIX: quarantine leak] Reverse map for binSize -> class index
  private var binSizeToClassIndex: [Int: Int] = [:]

  // Per-size-class global state
  final class ClassState {
    let binSize: Int
    // Lock-free free list head (stack of free bins)
    let freeHead: ManagedAtomic<UInt> = ManagedAtomic<UInt>(0)
    // Slow path lock for block growth & (when enabled) metadata updates
    let growLock: ManagedAtomic<Int> = ManagedAtomic<Int>(0)
    // Track number of blocks and free bins (profiling)
    let freeCount: ManagedAtomic<Int> = ManagedAtomic<Int>(0)

    // [v2] Exhausted + backoff state
    let exhausted: ManagedAtomic<Int> = ManagedAtomic<Int>(0)  // 0=false, 1=true
    let backoffExp: ManagedAtomic<Int> = ManagedAtomic<Int>(0)  // exponential factor
    let nextGrowAfterNanos: ManagedAtomic<UInt64> = ManagedAtomic<UInt64>(0)

    // [v2] Block lists (enabled via allocator flag only)
    var blocks: [Block] = []
    var partialBlocks: [Int] = []  // indices into blocks
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

    // [v2] When block-list tracking is enabled:
    // occupancy bitmap: 1 = allocated, 0 = free
    // stored as array of UInt64 words (only used when enableBlockLists)
    var bitmapWords: [UInt64]? = nil
  }

  private var states: [ClassState] = []

  private init() {
    var table: [Int] = []
    // 16..256 step 16
    var s = 16
    while s <= 256 {
      table.append(s)
      s += 16
    }
    // 288..512 step 32
    s = 288
    while s <= 512 {
      table.append(s)
      s += 32
    }
    // 576..4096 step 64
    s = 576
    while s <= 4096 {
      table.append(s)
      s += 64
    }
    self.classes = table
    self.classCount = table.count
    self.states = table.map { ClassState(binSize: $0) }

    // [FIX: quarantine leak] Build reverse map binSize -> index
    for (i, sz) in table.enumerated() {
      binSizeToClassIndex[sz] = i
    }

    // [v2] Initialize LUT if enabled
    if enableLUT {
      self.sizeToClassLUT = Self.buildLUT(classes: table)
    }

    // [v2] Ensure TLSMagazine capacity matches classCount (prevents OOB)
    TLSMagazine.shared.configure(maxClasses: self.classCount, cap: 32)
  }

  // [v2] Build O(1) LUT for size->class index mapping
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
    // Any sizes > last class size remain -1 (not small)
    return lut
  }

  // Size to class index (round up)
  private func classIndex(for size: Int) -> Int? {
    if size <= 0 { return nil }
    if size > BinnedAllocator.maxSmallSize { return nil }
    if enableLUT {
      let idx = sizeToClassLUT[size]
      return idx >= 0 ? idx : nil
    } else {
      // v1 fallback: linear scan
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
      // pause
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

  // Push a pointer into global freelist of class
  private func pushFree(_ cs: ClassState, _ p: UnsafeMutableRawPointer) {
    // Store next in the first machine word of bin
    let head = cs.freeHead.load(ordering: .relaxed)
    storeNext(p, next: UnsafeMutableRawPointer(bitPattern: UInt(head)))
    // CAS loop
    var cur = head
    let newHead = UInt(bitPattern: p)
    while true {
      storeNext(p, next: UnsafeMutableRawPointer(bitPattern: UInt(cur)))
      if cs.freeHead.compareExchange(
        expected: cur, desired: newHead, ordering: .acquiringAndReleasing
      ).exchanged {
        cs.freeCount.wrappingIncrement(ordering: .relaxed)
        break
      } else {
        cur = cs.freeHead.load(ordering: .relaxed)
      }
    }
  }

  // Pop from global freelist; returns nil if empty
  // [FIX: nil crash] Changed nil handling to avoid force unwrap of zero pointer
  private func popFree(_ cs: ClassState) -> UnsafeMutableRawPointer? {
    while true {
      let head = cs.freeHead.load(ordering: .acquiring)
      if head == 0 {
        return nil
      }
      let headPtr = UnsafeMutableRawPointer(bitPattern: UInt(head))!
      let next = loadNext(headPtr)
      let desired: UInt = next.map { UInt(bitPattern: $0) } ?? 0
      if cs.freeHead.compareExchange(
        expected: head, desired: desired, ordering: .acquiringAndReleasing
      ).exchanged {
        cs.freeCount.wrappingDecrement(ordering: .relaxed)
        return headPtr
      }
    }
  }

  @inline(__always)
  private func storeNext(_ p: UnsafeMutableRawPointer, next: UnsafeMutableRawPointer?) {
    // store next pointer as UInt
    let addr = UInt(bitPattern: next)
    p.storeBytes(of: addr, as: UInt.self)
  }

  @inline(__always)
  private func loadNext(_ p: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer? {
    let addr = p.load(as: UInt.self)
    if addr == 0 { return nil }
    return UnsafeMutableRawPointer(bitPattern: addr)
  }

  // MARK: - [v2] Exhausted + Backoff helpers

  // Monotonic time in ns
  private func nowNanos() -> UInt64 {
    #if os(Windows)
      // GetTickCount64 returns ms
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

  // Compute exponential backoff delay (ns) from exponent with cap
  private func backoffDelayNanos(exp: Int) -> UInt64 {
    // base 1ms, cap 50ms
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
    // exponential backoff with cap
    let curExp = cs.backoffExp.load(ordering: .relaxed)
    let nextExp = min(curExp + 1, 16)
    cs.backoffExp.store(nextExp, ordering: .relaxed)
    let delay = backoffDelayNanos(exp: nextExp)
    let deadline = nowNanos() &+ delay
    cs.nextGrowAfterNanos.store(deadline, ordering: .releasing)
    // Notify memory pressure
    memoryPressureHandler?()
  }

  private func recordGrowSuccess(_ cs: ClassState) {
    if !enableExhaustedBackoff { return }
    cs.exhausted.store(0, ordering: .releasing)
    cs.backoffExp.store(0, ordering: .relaxed)
    cs.nextGrowAfterNanos.store(0, ordering: .relaxed)
  }

  // MARK: - [v2] Block list helpers (enabled only when flag is on)

  private func initBlockMetadataIfEnabled(_ blockIndex: Int, in cs: ClassState) {
    guard enableBlockLists else { return }
    var blk = cs.blocks[blockIndex]
    let words = (blk.binsTotal + 63) / 64
    blk.bitmapWords = Array(repeating: 0, count: words)
    cs.blocks[blockIndex] = blk
    // Initially empty (all free)
    cs.emptyBlocks.append(blockIndex)
  }

  private func markAllocatedIfEnabled(_ cs: ClassState, ptr: UnsafeMutableRawPointer) {
    guard enableBlockLists else { return }
    // Metadata update under growLock to avoid races (feature is off by default)
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
        // move lists
        updateListsOnAlloc(cs: cs, blockIndex: idx, binsFreeAfter: newFree)
        cs.blocks[idx] = blk
      } else {
        // already allocated; no-op
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
    // Linear search (acceptable since disabled by default). When enabled, correctness over speed.
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
    // If just became full, move from partial/empty to full
    // If still has free, ensure it's in partial
    // Remove from other lists accordingly
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
      // empty
      remove(&cs.partialBlocks, blockIndex)
      remove(&cs.fullBlocks, blockIndex)
      if !cs.emptyBlocks.contains(blockIndex) { cs.emptyBlocks.append(blockIndex) }
    } else if binsFreeAfter == 0 {
      // full (shouldn't happen on free), but handle anyway
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

  // Grow class by committing a new block and pushing its bins into freelist
  private func grow(_ cs: ClassState) -> Bool {
    if !cs.growLock.compareExchange(expected: 0, desired: 1, ordering: .acquiringAndReleasing)
      .exchanged
    {
      // Another thread grows
      return true
    }
    defer { cs.growLock.store(0, ordering: .releasing) }

    let blkSize = max(BinnedAllocator.blockSizeDefault, cs.binSize * 64)
    do {
      var region = try vmReserve(size: blkSize, alignment: VM.allocationGranularity())
      // [FIX: region leak] Ensure region is released if commit fails
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

      // [v2] If block lists enabled, init metadata and empty list
      cs.blocks.append(block)
      let newBlockIndex = cs.blocks.count - 1
      if enableBlockLists {
        initBlockMetadataIfEnabled(newBlockIndex, in: cs)
      }

      // Carve bins and push to freelist
      for i in 0..<bins {
        let ptr = base.advanced(by: i * cs.binSize)
        #if DEBUG
          MemoryDebug.poison(ptr: ptr, size: cs.binSize)
        #endif
        pushFree(cs, ptr)
      }

      // [v2] success clears exhausted/backoff
      recordGrowSuccess(cs)
      return true
    } catch {
      // [v2] Mark exhausted and schedule backoff, notify pressure
      recordGrowFailure(cs)
      return false
    }
  }

  // RawAllocator conformance
  // [FIX: alignment] Small allocator provides natural alignment of bin size (≤16 guaranteed).
  // For larger alignments, route to LargeAllocator.
  public func allocate(size: Int, alignment: Int) -> UnsafeMutableRawPointer? {
    if let idx = classIndex(for: size) {
      let cs = states[idx]
      // Check if bin's natural alignment satisfies request
      // Bin sizes are powers or multiples of 16, so binSize itself is the alignment.
      let binAlign = cs.binSize >= 16 ? 16 : cs.binSize
      if alignment > binAlign {
        // Small allocator cannot guarantee this alignment; use large path
        return LargeAllocator.shared.allocate(size: size, alignment: alignment)
      }
      // TLS magazine fast path
      if let p = TLSMagazine.shared.pop(classIndex: idx) {
        #if DEBUG
          MemoryDebug.checkCanaryOnAlloc(ptr: p, size: cs.binSize)
        #endif
        // [v2] occupancy tracking (optional)
        markAllocatedIfEnabled(cs, ptr: p)
        return p
      }
      // Global freelist
      if let p = popFree(cs) {
        #if DEBUG
          MemoryDebug.checkCanaryOnAlloc(ptr: p, size: cs.binSize)
        #endif
        markAllocatedIfEnabled(cs, ptr: p)
        return p
      }
      // [v2] Backoff gate for grow to prevent cascading failures
      if shouldAttemptGrow(cs) {
        if grow(cs), let p = popFree(cs) {
          #if DEBUG
            MemoryDebug.checkCanaryOnAlloc(ptr: p, size: cs.binSize)
          #endif
          markAllocatedIfEnabled(cs, ptr: p)
          return p
        }
        // grow failed or no free even after grow -> fast return
        return nil
      } else {
        // In backoff window; avoid hammering VM, return quickly
        return nil
      }
    } else {
      return LargeAllocator.shared.allocate(size: size, alignment: alignment)
    }
  }

  public func deallocate(_ p: UnsafeMutableRawPointer, size: Int) {
    // [FIX: alignment routing] First, detect and deallocate Large allocations (including alignment-routed ones)
    if LargeAllocator.shared.maybeDeallocate(p) {
      return
    }

    if let idx = classIndex(for: size) {
      let cs = states[idx]
      #if DEBUG
        MemoryDebug.checkDoubleFree(ptr: p)
        MemoryDebug.poison(ptr: p, size: cs.binSize)
        if MemoryDebug.quarantinePush(ptr: p, classSize: cs.binSize) {
          // Quarantined; tag as freed for leak tracking and exit
          MemoryDebug.tagFree(ptr: p)
          return
        }
      #endif

      // [v2] occupancy tracking first (it's logically free now)
      markFreedIfEnabled(cs, ptr: p)

      if let overflow = TLSMagazine.shared.push(classIndex: idx, ptr: p) {
        // Flush overflow batch to global freelist
        for q in overflow { pushFree(cs, q) }
      }
      #if DEBUG
        MemoryDebug.tagFree(ptr: p)
      #endif
    } else {
      LargeAllocator.shared.deallocate(p, size: size)
    }
  }

  // Flush TLS to global (e.g., at frame boundary)
  public func flushTLS() {
    TLSMagazine.shared.flushAllToGlobal { idx, batch in
      let cs = states[idx]
      for p in batch {
        // [v2] occupancy already marked at deallocation time
        pushFree(cs, p)
      }
    }
  }

  // [v2] Internal hook for TLS destructor to flush arbitrary thread stacks
  // This keeps pushFree encapsulated in allocator.
  internal func tlsFlushHook(_ idx: Int, _ batch: [UnsafeMutableRawPointer]) {
    guard idx >= 0 && idx < states.count else { return }
    let cs = states[idx]
    for p in batch {
      // occupancy already handled at deallocate time
      pushFree(cs, p)
    }
  }

  // [FIX: quarantine leak] Internal bypass for quarantine to free oldest pointer
  // without going through normal deallocate path (avoids recursion and double-checks)
  internal func freeFromQuarantine(_ p: UnsafeMutableRawPointer, binSize: Int) {
    guard let idx = binSizeToClassIndex[binSize] else { return }
    let cs = states[idx]
    // Skip quarantine and debug checks; just push to global
    markFreedIfEnabled(cs, ptr: p)
    pushFree(cs, p)
  }
}

extension BinnedAllocator: @unchecked Sendable {}
