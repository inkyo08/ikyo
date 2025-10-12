import Foundation

#if os(Windows)
  import WinSDK
#elseif canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

// 작은 할당자의 빠른 경로에서 사용되는 클래스별 스레드-로컬 해제 포인터 스택.
// v2:
// - Windows는 자동 정리를 위한 소멸자와 함께 FlsAlloc으로 전환 (TlsAlloc으로 대체).
// - POSIX 소멸자는 이제 할당자로 플러시한 후 해제.
// - 할당자 클래스와 안전하게 일치시키기 위한 동적 클래스 수 구성.
// - 클래스 수가 증가할 때 OOB를 방지하기 위한 스레드별 스택의 안전한 크기 조정.
public final class TLSMagazine {
  public static let shared = TLSMagazine()

  public private(set) var maxClasses: Int
  public private(set) var stackCapacityPerClass: Int

  // 내부 스레드별 구조체
  final class PerThread {
    var stacks: [[UnsafeMutableRawPointer]]
    init(classes: Int, cap: Int) {
      stacks = Array(repeating: [], count: classes)
      for i in 0..<classes {
        stacks[i].reserveCapacity(cap)
      }
    }
  }

  // 현재 구성 (configure()를 통해 확장 가능)
  private var classes: Int
  private var cap: Int

  #if os(Windows)
    private var useFls: Bool = false
    private var flsIndex: DWORD = DWORD(bitPattern: -1)
    private var tlsIndexFallback: DWORD = DWORD(bitPattern: -1)
  #else
    private var tlsKey = pthread_key_t()
  #endif

  // [v2] 안전한 초기 추측값을 가진 생성자; 할당자에 의해 재구성될 예정
  private init(classes: Int = 80, cap: Int = 32) {
    self.classes = max(1, classes)
    self.cap = max(1, cap)
    self.maxClasses = self.classes
    self.stackCapacityPerClass = self.cap

    #if os(Windows)
      // FLS (소멸자 포함) 시도. 실패 시 TLS로 대체.
      let destructor: @convention(c) (UnsafeMutableRawPointer?) -> Void = { ptr in
        TLSMagazine.flsDestructor(ptr)
      }
      let idx = FlsAlloc(destructor)
      if idx != FLS_OUT_OF_INDEXES {
        self.useFls = true
        self.flsIndex = idx
      } else {
        self.useFls = false
        self.tlsIndexFallback = TlsAlloc()
        if self.tlsIndexFallback == TLS_OUT_OF_INDEXES {
          fatalError("TLSMagazine: TLS allocation failed")
        }
      }
    #else
      let destructor: @convention(c) (UnsafeMutableRawPointer) -> Void = { raw in
        // POSIX 소멸자: 플러시한 후 해제
        let unmanaged = Unmanaged<PerThread>.fromOpaque(raw)
        let threadObj = unmanaged.takeUnretainedValue()
        TLSMagazine.shared.flushAllToGlobal(of: threadObj) { idx, batch in
          BinnedAllocator.shared.tlsFlushHook(idx, batch)
        }
        unmanaged.release()
      }
      var key = pthread_key_t()
      let res = pthread_key_create(&key, destructor)
      if res != 0 {
        fatalError("TLSMagazine: pthread_key_create failed")
      }
      self.tlsKey = key
    #endif
  }

  // [v2] 할당자가 클래스 수를 확장하고 선택적으로 용량을 조정하도록 허용
  public func configure(maxClasses newClasses: Int, cap newCap: Int? = nil) {
    if newClasses > self.classes {
      self.classes = newClasses
      self.maxClasses = newClasses
    }
    if let nc = newCap, nc > self.cap {
      self.cap = nc
      self.stackCapacityPerClass = nc
    }
  }

  private func getThread() -> PerThread {
    #if os(Windows)
      if useFls {
        if let raw = FlsGetValue(flsIndex) {
          return Unmanaged<PerThread>.fromOpaque(raw).takeUnretainedValue()
        }
        let obj = PerThread(classes: classes, cap: cap)
        _ = FlsSetValue(flsIndex, Unmanaged.passRetained(obj).toOpaque())
        return obj
      } else {
        if let raw = TlsGetValue(tlsIndexFallback) {
          return Unmanaged<PerThread>.fromOpaque(raw).takeUnretainedValue()
        }
        let obj = PerThread(classes: classes, cap: cap)
        _ = TlsSetValue(tlsIndexFallback, Unmanaged.passRetained(obj).toOpaque())
        return obj
      }
    #else
      if let raw = pthread_getspecific(tlsKey) {
        return Unmanaged<PerThread>.fromOpaque(raw).takeUnretainedValue()
      }
      let obj = PerThread(classes: classes, cap: cap)
      pthread_setspecific(tlsKey, Unmanaged.passRetained(obj).toOpaque())
      return obj
    #endif
  }

  // [v2] 스레드별 스택이 제공된 classIndex를 인덱싱할 수 있도록 보장
  @inline(__always)
  private func ensureCapacity(_ t: PerThread, for classIndex: Int) {
    if classIndex < t.stacks.count { return }
    let target = max(classIndex + 1, self.classes)
    let toAdd = target - t.stacks.count
    if toAdd > 0 {
      for _ in 0..<toAdd {
        var arr: [UnsafeMutableRawPointer] = []
        arr.reserveCapacity(self.cap)
        t.stacks.append(arr)
      }
    }
  }

  // 빠른 경로 pop; 비어있으면 nil 반환
  public func pop(classIndex: Int) -> UnsafeMutableRawPointer? {
    let t = getThread()
    ensureCapacity(t, for: classIndex)
    var s = t.stacks[classIndex]
    if let p = s.popLast() {
      t.stacks[classIndex] = s
      return p
    }
    return nil
  }

  // 빠른 경로 push; 가득 차면 오버플로우 배치 반환
  // 단순화를 위해 최대 capacity/2 항목을 플러시하도록 반환
  public func push(classIndex: Int, ptr: UnsafeMutableRawPointer) -> [UnsafeMutableRawPointer]? {
    let t = getThread()
    ensureCapacity(t, for: classIndex)
    var s = t.stacks[classIndex]
    s.append(ptr)
    var overflow: [UnsafeMutableRawPointer]? = nil
    if s.count > cap {
      let half = max(1, cap / 2)
      overflow = Array(s.prefix(half))
      s.removeFirst(half)
    }
    t.stacks[classIndex] = s
    return overflow
  }

  // 재충전을 위한 배치 pop (v1에서는 사용 안 함)
  public func tryPopMany(classIndex: Int, max: Int) -> [UnsafeMutableRawPointer] {
    let t = getThread()
    ensureCapacity(t, for: classIndex)
    var s = t.stacks[classIndex]
    let n = Swift.min(max, s.count)
    if n == 0 { return [] }
    let tail = Array(s.suffix(n))
    s.removeLast(n)
    t.stacks[classIndex] = s
    return tail
  }

  // 프레임 경계 또는 메모리 압력을 위한 전역 트림 훅
  public func flushAllToGlobal(flusher: (Int, [UnsafeMutableRawPointer]) -> Void) {
    let t = getThread()
    flushAllToGlobal(of: t, flusher: flusher)
  }

  // [v2] 임의의 PerThread 인스턴스 플러시 (소멸자용)
  internal func flushAllToGlobal(of t: PerThread, flusher: (Int, [UnsafeMutableRawPointer]) -> Void)
  {
    let count = t.stacks.count
    for i in 0..<count {
      let batch = t.stacks[i]
      if !batch.isEmpty {
        flusher(i, batch)
        t.stacks[i].removeAll(keepingCapacity: true)
      }
    }
  }

  // [v2] Windows FLS 소멸자 진입점
  #if os(Windows)
    private static func flsDestructor(_ ptr: UnsafeMutableRawPointer?) {
      guard let raw = ptr else { return }
      let unmanaged = Unmanaged<PerThread>.fromOpaque(raw)
      let threadObj = unmanaged.takeUnretainedValue()
      TLSMagazine.shared.flushAllToGlobal(of: threadObj) { idx, batch in
        BinnedAllocator.shared.tlsFlushHook(idx, batch)
      }
      unmanaged.release()
    }
  #endif
}

extension TLSMagazine: @unchecked Sendable {}
