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

    // Expose a public default without exposing the internal constant directly.
    public static var defaultGuardPagesEnabled: Bool { LargeGuardPagesEnabledDefault }

    private let pageSize: Int
    private init() {
        self.pageSize = VM.pageSize()
    }

    private struct Header {
        // Stored just before returned pointer if alignment requires offsetting or guard pages are used.
        var base: UnsafeMutableRawPointer
        var totalSize: Int
        var userSize: Int
        var guardPages: Int8
        var offsetFromBase: Int32
        var magic: UInt64
    }

    private static let headerMagic: UInt64 = 0x1A2B3C4D5E6F7788

    public func allocate(size: Int, alignment: Int = 16, debugGuardPages: Bool = LargeAllocator.defaultGuardPagesEnabled) -> UnsafeMutableRawPointer? {
        guard size > 0 else { return nil }
        let pg = pageSize
        let guardPages = debugGuardPages ? 1 : 0
        let guardBytes = guardPages * pg

        // We reserve + commit directly, page-aligned
        // If alignment > pg, over-allocate and align inside
        let needHeader = max(MemoryLayout<Header>.size, alignment)
        let over = alignment > pg ? alignment + needHeader : needHeader

        let total = VM.alignUp(size + over + 2*guardBytes, to: pg)

        do {
            var region = try vmReserve(size: total, alignment: pg)
            // [FIX: region leak] Wrap protect/commit in inner do-catch to ensure release on failure
            do {
                // protect guards
                if debugGuardPages && guardPages > 0 {
                    try vmProtect(region, offset: 0, size: guardBytes, prot: .noAccess)
                    try vmProtect(region, offset: total - guardBytes, size: guardBytes, prot: .noAccess)
                }
                // Commit user range
                let commitStart = guardBytes
                let commitSize = total - 2*guardBytes
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
            header.pointee = Header(base: region.base!, totalSize: total, userSize: size, guardPages: Int8(guardPages), offsetFromBase: Int32(Int(userPtrRaw) - Int(baseAddr)), magic: LargeAllocator.headerMagic)
            // Return user pointer
            return UnsafeMutableRawPointer(bitPattern: userPtrRaw)
        } catch {
            return nil
        }
    }

    public func deallocate(_ p: UnsafeMutableRawPointer?, size: Int) {
        guard let p else { return }
        // Read header and release region
        let headerPtr = p.advanced(by: -MemoryLayout<Header>.size)
        let h = headerPtr.assumingMemoryBound(to: Header.self).pointee
        if h.magic != LargeAllocator.headerMagic {
            // Unknown pointer; ignore or trap in debug
            assertionFailure("LargeAllocator: invalid header magic (double-free or foreign pointer?)")
            return
        }
        var region = VMRegion(base: h.base, size: h.totalSize, pageSize: VM.pageSize(), reserved: true)
        // Decommit user range (optional) then release
        vmDecommit(&region, offset: Int(h.guardPages) * region.pageSize, size: h.totalSize - 2*Int(h.guardPages) * region.pageSize)
        do {
            try vmRelease(&region)
        } catch {
            assertionFailure("LargeAllocator: vmRelease failed")
        }
    }

    // maybeDeallocate: attempts to detect a Large allocation by checking header magic.
    // Returns true if deallocated by LargeAllocator, false otherwise.
    // Safe-guard: avoid reading past a page boundary to prevent faults on small first-bin pointers.
    public func maybeDeallocate(_ p: UnsafeMutableRawPointer) -> Bool {
        let headerSize = MemoryLayout<Header>.size
        let pg = VM.pageSize()
        let addr = UInt(bitPattern: p)
        // If the pointer is too close to the start of the page, reading header may cross page boundary; bail out.
        if Int(addr % UInt(pg)) < headerSize {
            return false
        }
        let headerPtr = p.advanced(by: -headerSize)
        let h = headerPtr.assumingMemoryBound(to: Header.self).pointee
        if h.magic != LargeAllocator.headerMagic {
            return false
        }
        // Delegate to standard deallocate, using stored userSize for accuracy
        self.deallocate(p, size: Int(h.userSize))
        return true
    }
}

extension LargeAllocator: @unchecked Sendable {}
