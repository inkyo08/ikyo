@usableFromInline
internal struct Entity {
  @usableFromInline var raw: UInt32

  @inlinable
  init(index: Int, generation: UInt8) {
    precondition(index >= 0 && index < (1 << 24), "Entity index overflow 24-bit budget")
    self.raw = UInt32(index & 0x00FF_FFFF) | (UInt32(generation) << 24)
  }
}

@inlinable @inline(__always)
func entityIndex(_ e: Entity) -> Int {
  Int(e.raw & 0x00FF_FFFF)
}

@inlinable @inline(__always)
func entityGen(_ e: Entity) -> UInt8 {
  UInt8((e.raw >> 24) & 0xFF)
}

final class EntityManager {
  private var generations: EngineBuffer<UInt8>
  private var freeList: [UInt32] = []
  private(set) var capacity: Int
  private var nextIndex: Int = 0

  init(initial: Int = 8192) {
    self.capacity = initial
    // 기본 할당자를 통해 EngineBuffer로 세대 버퍼 할당
    // UInt8 * 8192 = 8KB는 BinnedAllocator를 사용 (할당당 < 4KB 임계값, 점진적으로 증가)
    guard let genBuf = EngineBuffer<UInt8>(
      count: initial,
      alignment: max(MemoryLayout<UInt8>.alignment, 16),  // 최소 16바이트 정렬 보장
      allocator: IkyoAlloc.global
    ) else {
      fatalError("EntityManager: Failed to allocate generations buffer")
    }
    self.generations = genBuf

    // ARC 재할당을 줄이기 위해 freelist 용량 예약
    self.freeList.reserveCapacity(initial)

    // 모든 세대를 0으로 초기화
    let ptr = generations.bufferPointer
    ptr.initialize(repeating: 0, count: initial)
  }

  func create() -> Entity {
    let index: Int
    let generation: UInt8

    if let reusedIndex = freeList.popLast() {
      // 여유 목록에서 재사용
      index = Int(reusedIndex)
      generation = generations[index]
    } else {
      // 새 인덱스 할당
      if nextIndex >= (1 << 24) {
        fatalError("Entity index exceeded 24-bit ID space; increase ID format or reduce entities")
      }
      if nextIndex >= capacity {
        // 확장 필요
        grow()
      }
      index = nextIndex
      generation = generations[index]
      nextIndex &+= 1
    }

    return Entity(index: index, generation: generation)
  }

  func destroy(_ e: Entity) {
    let index = entityIndex(e)
    guard index < capacity else { return }
    guard alive(e) else { return }

    // 이 엔티티를 무효화하기 위해 세대를 증가
    let oldGen = generations[index]
    let newGen = oldGen &+ 1  // 세대 오버플로를 위한 래핑 덧셈
    generations[index] = newGen

    // 재사용을 위해 여유 목록에 인덱스 추가
    freeList.append(UInt32(index))
  }

  @inline(__always)
  func alive(_ e: Entity) -> Bool {
    let index = entityIndex(e)
    guard index < capacity else { return false }
    return generations[index] == entityGen(e)
  }

  private func grow() {
    let newCapacity = capacity &<< 1

    // 새 버퍼 할당
    guard let newGenBuf = EngineBuffer<UInt8>(
      count: newCapacity,
      alignment: max(MemoryLayout<UInt8>.alignment, 16),
      allocator: IkyoAlloc.global
    ) else {
      fatalError("EntityManager: Failed to grow generations buffer")
    }

    // 기존 데이터를 대량 복사하고 새 항목 초기화 (요소별 루프보다 빠름)
    let oldPtr = generations.bufferPointer
    let newPtr = newGenBuf.bufferPointer
    newPtr.initialize(from: oldPtr, count: capacity)

    // 새 항목들을 0으로 대량 초기화
    let tailCount = newCapacity &- capacity
    if tailCount > 0 {
      newPtr.advanced(by: capacity).initialize(repeating: 0, count: tailCount)
    }

    // 기존 버퍼 교체 (~Copyable 이동 시맨틱; 기존 버퍼 자동 할당 해제)
    generations = newGenBuf
    capacity = newCapacity
  }
}
