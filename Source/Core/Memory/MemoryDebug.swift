import Atomics
import Foundation

// 디버그 레이어: 카나리, 격리, 이중 해제 감지, 누수 태깅 및 간단한 프로파일링.
// 대부분의 기능은 DEBUG 빌드에서만 활성화되며, 릴리스 빌드에서는 스텁/샘플링만 남을 수 있습니다.

public enum MemoryDebug {
  #if DEBUG
    private static let canary1: UInt8 = 0xFE
    private static let canary2: UInt8 = 0xDD
    private static let doubleFreeMagic: UInt64 = 0xDEAD_BEEF_DEAD_BEEF

    // 격리 (데드 리스트): 클래스 크기당 최근 N개의 해제 유지 (v1 단일 풀)
    private static let quarantineCapacity = 256

    // 엄격한 동시성을 위한 상태 캡슐화
    private final class State: @unchecked Sendable {
      static let shared = State()
      var quarantine: [(ptr: UnsafeMutableRawPointer, classSize: Int)] = []  // 제거 시 올바른 해제 라우팅을 보장하기 위해 (ptr, classSize) 저장
      let quarantineLock = NSLock()
      var liveSet: Set<UInt> = []
      let liveLock = NSLock()
      var leakMap: [UInt: (size: Int, file: StaticString, line: UInt, function: StaticString)] = [:]
      let leakLock = NSLock()
      private init() {}
    }

    // 프로파일링 카운터
    public static let allocCount = ManagedAtomic<Int>(0)
    public static let freeCount = ManagedAtomic<Int>(0)
    public static let commitCount = ManagedAtomic<Int>(0)
    public static let decommitCount = ManagedAtomic<Int>(0)
  #endif

  // 작은 빈을 위한 카나리 채우기
  public static func poison(ptr: UnsafeMutableRawPointer, size: Int) {
    #if DEBUG
      memset(ptr, Int32(MemoryDebug.canary1), size)
    #endif
  }

  public static func checkCanaryOnAlloc(ptr: UnsafeMutableRawPointer, size: Int) {
    #if DEBUG
      // 할당 시 이중 해제 매직으로 채워지지 않았는지 확인; 약한 검사
      let v = ptr.load(as: UInt8.self)
      if v == canary2 {
        assertionFailure("MemoryDebug: canary indicates potential UAF")
      }
      // 재할당 시 잘못된 이중 해제를 방지하기 위해 liveSet에서 제거
      let key = UInt(bitPattern: ptr)
      let s = State.shared
      s.liveLock.lock()
      _ = s.liveSet.remove(key)
      s.liveLock.unlock()

      allocCount.wrappingIncrement(ordering: .relaxed)
    #endif
  }

  // [FIX: quarantine leak & classSize] 이제 올바른 classSize로 가장 오래된 포인터를 적절히 해제
  // ptr이 격리되면 true 반환 (호출자는 해제를 건너뛰어야 함), 호출자가 해제를 진행해야 하면 false 반환
  public static func quarantinePush(ptr: UnsafeMutableRawPointer, classSize: Int) -> Bool {
    #if DEBUG
      let s = State.shared
      s.quarantineLock.lock()
      // 용량이 가득 차면 제거; 잘못된 라우팅을 방지하기 위해 저장된 classSize 사용
      if s.quarantine.count >= quarantineCapacity {
        let oldest = s.quarantine.removeFirst()
        s.quarantineLock.unlock()
        // 할당자와의 락 역전을 방지하기 위해 락 외부에서 제거된 포인터 해제
        BinnedAllocator.shared.freeFromQuarantine(oldest.ptr, binSize: oldest.classSize)
      } else {
        s.quarantineLock.unlock()
      }

      // 현재 (ptr, classSize) 추가
      s.quarantineLock.lock()
      s.quarantine.append((ptr: ptr, classSize: classSize))
      s.quarantineLock.unlock()
      return true
    #else
      return false
    #endif
  }

  public static func checkDoubleFree(ptr: UnsafeMutableRawPointer) {
    #if DEBUG
      let key = UInt(bitPattern: ptr)
      let s = State.shared
      s.liveLock.lock()
      if !s.liveSet.insert(key).inserted {
        assertionFailure("MemoryDebug: double-free detected at \(ptr)")
      }
      s.liveLock.unlock()
    #endif
  }

  public static func tagAlloc(
    ptr: UnsafeMutableRawPointer, size: Int, file: StaticString = #fileID, line: UInt = #line,
    function: StaticString = #function
  ) {
    #if DEBUG
      let key = UInt(bitPattern: ptr)
      let s = State.shared
      s.leakLock.lock()
      s.leakMap[key] = (size, file, line, function)
      s.leakLock.unlock()
    #endif
  }

  public static func tagFree(ptr: UnsafeMutableRawPointer) {
    #if DEBUG
      let key = UInt(bitPattern: ptr)
      let s = State.shared
      s.leakLock.lock()
      s.leakMap.removeValue(forKey: key)
      s.leakLock.unlock()
      freeCount.wrappingIncrement(ordering: .relaxed)
    #endif
  }

  public static func dumpLeaks() {
    #if DEBUG
      let s = State.shared
      s.leakLock.lock()
      if s.leakMap.isEmpty {
        print("[Ikyo] No leaks detected.")
      } else {
        print("[Ikyo] Potential leaks:")
        for (k, v) in s.leakMap {
          print(
            String(
              format: "  ptr=0x%llx size=%d at %s:%llu %s",
              k, v.size, "\(v.file)", v.line, "\(v.function)"))
        }
      }
      s.leakLock.unlock()
    #endif
  }
}
