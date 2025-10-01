import Foundation

#if os(Windows)
import WinSDK
#elseif canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// Thread-local per-class stack of free pointers used by the small allocator fast path.
// v2:
// - Windows switches to FlsAlloc with destructor for automatic cleanup (fallback to TlsAlloc).
// - POSIX destructor now flushes to allocator then releases.
// - Dynamic class-count configuration to match allocator classes safely.
// - Safe resizing of per-thread stacks to avoid OOB when class count grows.
public final class TLSMagazine {
    public static let shared = TLSMagazine()

    public private(set) var maxClasses: Int
    public private(set) var stackCapacityPerClass: Int

    // Internal per-thread structure
    final class PerThread {
        var stacks: [[UnsafeMutableRawPointer]]
        init(classes: Int, cap: Int) {
            stacks = Array(repeating: [], count: classes)
            for i in 0..<classes {
                stacks[i].reserveCapacity(cap)
            }
        }
    }

    // Current configuration (can be widened via configure())
    private var classes: Int
    private var cap: Int

    #if os(Windows)
    private var useFls: Bool = false
    private var flsIndex: DWORD = DWORD(bitPattern: -1)
    private var tlsIndexFallback: DWORD = DWORD(bitPattern: -1)
    #else
    private var tlsKey = pthread_key_t()
    #endif

    // [v2] constructor with safe initial guesses; will be reconfigured by allocator
    private init(classes: Int = 80, cap: Int = 32) {
        self.classes = max(1, classes)
        self.cap = max(1, cap)
        self.maxClasses = self.classes
        self.stackCapacityPerClass = self.cap

        #if os(Windows)
        // Try FLS (with destructor). If it fails, fall back to TLS.
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
            // POSIX destructor: flush then release
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

    // [v2] Allow allocator to widen class count and optionally adjust cap
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

    // [v2] Ensure per-thread stacks can index provided classIndex
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

    // Fast path pop; returns nil if empty
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

    // Fast path push; returns overflow batch if full
    // For simplicity we return at most capacity/2 items to flush
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

    // Batch pop for refill (not used in v1)
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

    // Global trim hook for frame boundaries or memory pressure
    public func flushAllToGlobal(flusher: (Int, [UnsafeMutableRawPointer]) -> Void) {
        let t = getThread()
        flushAllToGlobal(of: t, flusher: flusher)
    }

    // [v2] Flush arbitrary PerThread instance (for destructors)
    internal func flushAllToGlobal(of t: PerThread, flusher: (Int, [UnsafeMutableRawPointer]) -> Void) {
        let count = t.stacks.count
        for i in 0..<count {
            let batch = t.stacks[i]
            if !batch.isEmpty {
                flusher(i, batch)
                t.stacks[i].removeAll(keepingCapacity: true)
            }
        }
    }

    // [v2] Windows FLS destructor entry
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
