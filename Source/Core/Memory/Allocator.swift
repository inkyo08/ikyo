import Foundation

public protocol RawAllocator: AnyObject, Sendable {
func allocate(size: Int, alignment: Int) -> UnsafeMutableRawPointer?
func deallocate(_ p: UnsafeMutableRawPointer, size: Int)
}

public enum IkyoAlloc {
public static let global: RawAllocator = BinnedAllocator.shared
// You can switch to LargeAllocator.shared for testing large-only.
}

#if swift(>=5.9)
public struct EngineBuffer<Element>: ~Copyable {
private var ptr: UnsafeMutableRawPointer
private var count: Int
private unowned var alloc: RawAllocator

public init?(count: Int, alignment: Int = MemoryLayout<Element>.alignment, allocator: RawAllocator = IkyoAlloc.global) {
    guard count > 0 else { return nil }
    let bytes = count * MemoryLayout<Element>.stride
    guard let p = allocator.allocate(size: bytes, alignment: alignment) else { return nil }
    self.ptr = p
    self.count = count
    self.alloc = allocator
}

public var bufferPointer: UnsafeMutablePointer<Element> {
    return ptr.bindMemory(to: Element.self, capacity: count)
}

public subscript(i: Int) -> Element {
    get { bufferPointer.advanced(by: i).pointee }
    set { bufferPointer.advanced(by: i).pointee = newValue }
}

deinit {
    alloc.deallocate(ptr, size: count * MemoryLayout<Element>.stride)
}

}
#else
// Fallback for older Swift: class wrapper to avoid accidental copying
public final class EngineBuffer<Element> {
private var ptr: UnsafeMutableRawPointer
public let count: Int
private unowned var alloc: RawAllocator

public init?(count: Int, alignment: Int = MemoryLayout<Element>.alignment, allocator: RawAllocator = IkyoAlloc.global) {
    guard count > 0 else { return nil }
    let bytes = count * MemoryLayout<Element>.stride
    guard let p = allocator.allocate(size: bytes, alignment: alignment) else { return nil }
    self.ptr = p
    self.count = count
    self.alloc = allocator
}

public var bufferPointer: UnsafeMutablePointer<Element> {
    return ptr.bindMemory(to: Element.self, capacity: count)
}

public subscript(i: Int) -> Element {
    get { bufferPointer.advanced(by: i).pointee }
    set { bufferPointer.advanced(by: i).pointee = newValue }
}

deinit {
    alloc.deallocate(ptr, size: count * MemoryLayout<Element>.stride)
}

}
#endif