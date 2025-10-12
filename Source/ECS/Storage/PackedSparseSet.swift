import Foundation

// Swift 5.9+ only: struct is noncopyable to match EngineBuffer
struct PackedSparseSet<T>: ~Copyable {
  // SoA buffers (internal for direct pointer access in query builders)
  @usableFromInline internal var values: EngineBuffer<T>
  @usableFromInline internal var entities: EngineBuffer<Entity>
  @usableFromInline internal var sparse: EngineBuffer<Int32>

  // Size/capacity
  @usableFromInline internal var count: Int = 0
  @usableFromInline internal var denseCapacity: Int
  @usableFromInline internal var sparseCapacity: Int
  
  // Custom allocator (must outlive this instance)
  @usableFromInline internal unowned let allocator: RawAllocator

  // Init with sensible defaults (dense small, sparse tracks entities by index)
  @inlinable @inline(__always)
  init(initialDense: Int = 64, initialSparse: Int = 8192, allocator: RawAllocator = IkyoAlloc.global) {
    let denseCap = max(1, initialDense)
    let sparseCap = max(1, initialSparse)

    guard let vals = EngineBuffer<T>(count: denseCap, alignment: max(64, MemoryLayout<T>.alignment), allocator: allocator) else {
      fatalError("PackedSparseSet: Failed to allocate values buffer")
    }
    guard let ents = EngineBuffer<Entity>(count: denseCap, alignment: 64, allocator: allocator) else {
      fatalError("PackedSparseSet: Failed to allocate entities buffer")
    }
    guard let sp = EngineBuffer<Int32>(count: sparseCap, alignment: 64, allocator: allocator) else {
      fatalError("PackedSparseSet: Failed to allocate sparse buffer")
    }

    self.values = vals
    self.entities = ents
    self.sparse = sp
    self.denseCapacity = denseCap
    self.sparseCapacity = sparseCap
    self.allocator = allocator

    // Initialize sparse to -1 (absent)
    let spPtr = self.sparse.bufferPointer
    spPtr.initialize(repeating: -1, count: sparseCap)
  }

  // Default init()
  @inlinable @inline(__always)
  init() {
    self.init(initialDense: 64, initialSparse: 8192, allocator: IkyoAlloc.global)
  }

  // Ensure dense and sparse capacities (minDense is number of elements to fit, minSparse is entity index+1 to address)
  @inlinable @inline(__always)
  mutating func ensureCapacity(minDense: Int, minSparse: Int) {
    if minDense > denseCapacity {
      growDense(toAtLeast: minDense)
    }
    if minSparse > sparseCapacity {
      growSparse(toAtLeast: minSparse)
    }
  }

  // Helper: get dense index with generation validation
  @inlinable @inline(__always)
  func denseIndex(for e: Entity) -> Int {
    let ei = entityIndex(e)
    if ei >= sparseCapacity { return -1 }
    let sp = Int(sparse.bufferPointer.advanced(by: ei).pointee)
    if sp < 0 { return -1 }
    // Generation check: prevent stale entity handles
    if entities.bufferPointer.advanced(by: sp).pointee.raw != e.raw { return -1 }
    return sp
  }

  // Presence check
  @inlinable @inline(__always)
  func has(_ e: Entity) -> Bool {
    return denseIndex(for: e) >= 0
  }

  // Unsafe pointer to value (nil if absent)
  @inlinable @inline(__always)
  func getPtr(_ e: Entity) -> UnsafeMutablePointer<T>? {
    let d = denseIndex(for: e)
    if d < 0 { return nil }
    return values.bufferPointer.advanced(by: d)
  }

  // Add or update component
  @inlinable @inline(__always)
  mutating func add(_ e: Entity, _ v: T) {
    let d = denseIndex(for: e)
    if d >= 0 {
      // Update in place (entity already has component with correct generation)
      values.bufferPointer.advanced(by: d).pointee = v
      return
    }

    // Append path
    let ei = entityIndex(e)
    
    // Ensure sparse addressable
    if ei >= sparseCapacity {
      growSparse(toAtLeast: ei &+ 1)
    }

    if count >= denseCapacity {
      growDense(toAtLeast: count &+ 1)
    }

    let idx = count
    // Write value and entity
    values.bufferPointer.advanced(by: idx).pointee = v
    entities.bufferPointer.advanced(by: idx).pointee = e
    // Map sparse
    sparse.bufferPointer.advanced(by: ei).pointee = Int32(idx)
    count &+= 1
  }

  // Remove if present; returns true on removal
  @inlinable @inline(__always)
  @discardableResult
  mutating func remove(_ e: Entity) -> Bool {
    let d = denseIndex(for: e)
    if d < 0 { return false }

    let ei = entityIndex(e)
    let last = count &- 1
    let valPtr = values.bufferPointer
    let entPtr = entities.bufferPointer
    let spPtr = sparse.bufferPointer

    if d != last {
      // Move last dense element into d
      valPtr.advanced(by: d).pointee = valPtr.advanced(by: last).pointee
      let movedE = entPtr.advanced(by: last).pointee
      entPtr.advanced(by: d).pointee = movedE
      // Update sparse of moved entity
      let mi = entityIndex(movedE)
      spPtr.advanced(by: mi).pointee = Int32(d)
    }
    // Clear mapping and shrink count
    spPtr.advanced(by: ei).pointee = -1
    count = last
    return true
  }

  // High-throughput iteration: body(valuesPtr, entitiesPtr, count)
  @inlinable @inline(__always)
  func forEach(_ body: (UnsafeMutablePointer<T>, UnsafeMutablePointer<Entity>, Int) -> Void) {
    body(values.bufferPointer, entities.bufferPointer, count)
  }

  // Expose count
  @inlinable @inline(__always)
  func size() -> Int { count }

  // MARK: - Private grow helpers

  @usableFromInline @inline(__always)
  mutating func growDense(toAtLeast required: Int) {
    var newCap = denseCapacity
    repeat { newCap &<<= 1 } while newCap < required
    // Allocate new buffers
    guard let newVals = EngineBuffer<T>(count: newCap, alignment: max(64, MemoryLayout<T>.alignment), allocator: allocator) else {
      fatalError("PackedSparseSet: Failed to grow values buffer")
    }
    guard let newEnts = EngineBuffer<Entity>(count: newCap, alignment: 64, allocator: allocator) else {
      fatalError("PackedSparseSet: Failed to grow entities buffer")
    }
    // Bulk copy current elements
    let oldVal = values.bufferPointer
    let oldEnt = entities.bufferPointer
    let nv = newVals.bufferPointer
    let ne = newEnts.bufferPointer
    if count > 0 {
      nv.initialize(from: oldVal, count: count)
      ne.initialize(from: oldEnt, count: count)
    }
    values = newVals
    entities = newEnts
    denseCapacity = newCap
  }

  @usableFromInline @inline(__always)
  mutating func growSparse(toAtLeast required: Int) {
    var newCap = sparseCapacity
    repeat { newCap &<<= 1 } while newCap < required
    guard let newSp = EngineBuffer<Int32>(count: newCap, alignment: 64, allocator: allocator) else {
      fatalError("PackedSparseSet: Failed to grow sparse buffer")
    }
    let oldSp = sparse.bufferPointer
    let ns = newSp.bufferPointer
    // Copy old and initialize tail to -1
    if sparseCapacity > 0 {
      ns.initialize(from: oldSp, count: sparseCapacity)
    }
    let tail = newCap &- sparseCapacity
    if tail > 0 {
      ns.advanced(by: sparseCapacity).initialize(repeating: -1, count: tail)
    }
    sparse = newSp
    sparseCapacity = newCap
  }
}
