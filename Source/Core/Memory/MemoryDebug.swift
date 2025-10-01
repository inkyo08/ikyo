import Foundation
import Atomics

// Debug layer: canary, quarantine, double-free detection, leak tagging, and simple profiling.
// Most features are only active in DEBUG builds; release builds may leave stubs/sampling.

public enum MemoryDebug {
    #if DEBUG
    private static let canary1: UInt8 = 0xFE
    private static let canary2: UInt8 = 0xDD
    private static let doubleFreeMagic: UInt64 = 0xDEADBEEFDEADBEEF

    // Quarantine (dead list): keep recent N frees per class size (v1 single pool)
    private static let quarantineCapacity = 256

    // State encapsulation for strict concurrency
    private final class State: @unchecked Sendable {
        static let shared = State()
        var quarantine: [(ptr: UnsafeMutableRawPointer, classSize: Int)] = [] // Store (ptr, classSize) to ensure correct free routing on eviction
        let quarantineLock = NSLock()
        var liveSet: Set<UInt> = []
        let liveLock = NSLock()
        var leakMap: [UInt: (size: Int, file: StaticString, line: UInt, function: StaticString)] = [:]
        let leakLock = NSLock()
        private init() {}
    }

    // Profiling counters
    public static let allocCount = ManagedAtomic<Int>(0)
    public static let freeCount = ManagedAtomic<Int>(0)
    public static let commitCount = ManagedAtomic<Int>(0)
    public static let decommitCount = ManagedAtomic<Int>(0)
    #endif

    // Canary fill for small bins
    public static func poison(ptr: UnsafeMutableRawPointer, size: Int) {
        #if DEBUG
        memset(ptr, Int32(MemoryDebug.canary1), size)
        #endif
    }

    public static func checkCanaryOnAlloc(ptr: UnsafeMutableRawPointer, size: Int) {
        #if DEBUG
        // On allocation, ensure not filled with double-free magic; weak check
        let v = ptr.load(as: UInt8.self)
        if v == canary2 {
            assertionFailure("MemoryDebug: canary indicates potential UAF")
        }
        // Remove from liveSet to avoid false double-free on reallocation
        let key = UInt(bitPattern: ptr)
        let s = State.shared
        s.liveLock.lock()
        _ = s.liveSet.remove(key)
        s.liveLock.unlock()

        allocCount.wrappingIncrement(ordering: .relaxed)
        #endif
    }

    // [FIX: quarantine leak & classSize] Now properly frees oldest pointer with correct classSize
    // Returns true if ptr is quarantined (caller should skip free), false if caller should proceed with free
    public static func quarantinePush(ptr: UnsafeMutableRawPointer, classSize: Int) -> Bool {
        #if DEBUG
        let s = State.shared
        s.quarantineLock.lock()
        // Evict if at capacity; use stored classSize to avoid misrouting
        if s.quarantine.count >= quarantineCapacity {
            let oldest = s.quarantine.removeFirst()
            s.quarantineLock.unlock()
            // Free evicted pointer outside lock to avoid lock inversion with allocator
            BinnedAllocator.shared.freeFromQuarantine(oldest.ptr, binSize: oldest.classSize)
        } else {
            s.quarantineLock.unlock()
        }

        // Append current (ptr, classSize)
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

    public static func tagAlloc(ptr: UnsafeMutableRawPointer, size: Int, file: StaticString = #fileID, line: UInt = #line, function: StaticString = #function) {
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
                print(String(format: "  ptr=0x%llx size=%d at %s:%llu %s",
                             k, v.size, "\(v.file)", v.line, "\(v.function)"))
            }
        }
        s.leakLock.unlock()
        #endif
    }
}
