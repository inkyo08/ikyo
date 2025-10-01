import Foundation

public final class MonotonicArena {
  private var region: VMRegion
  private var committed: Int
  private var offset: Int
  private let pageSize: Int

  public init?(reserveSize: Int) {
    do {
      region = try vmReserve(size: reserveSize, alignment: VM.allocationGranularity())
    } catch {
      return nil
    }
    committed = 0
    offset = 0
    pageSize = region.pageSize
  }

  public func alloc(bytes: Int, align: Int = 16) -> UnsafeMutableRawPointer? {
    let alignedOff = VM.alignUp(offset, to: align)
    let end = alignedOff + bytes
    if end > committed {
      // Need to commit more
      let commitTo = VM.alignUp(end, to: pageSize)
      do {
        _ = try vmCommit(&region, offset: committed, size: commitTo - committed)
        committed = commitTo
      } catch {
        return nil
      }
    }
    let p = region.base!.advanced(by: alignedOff)
    offset = end
    return p
  }

  public func reset() {
    // Poison or leave: we keep reservation and decommit committed pages to reduce RSS.
    vmDecommit(&region, offset: 0, size: committed)
    committed = 0
    offset = 0
  }

  deinit {
    try? vmRelease(&region)
  }

}

public final class FrameArena {
  private let arena: MonotonicArena

  public init?(reserveSize: Int) {
    guard let a = MonotonicArena(reserveSize: reserveSize) else { return nil }
    self.arena = a
  }

  public func alloc(bytes: Int, align: Int = 16) -> UnsafeMutableRawPointer? {
    return arena.alloc(bytes: bytes, align: align)
  }

  public func endFrame() {
    arena.reset()
  }

}

public func withFrameArena<T>(reserveSize: Int = 64 * 1024 * 1024, _ body: (FrameArena) -> T) -> T?
{
  guard let fa = FrameArena(reserveSize: reserveSize) else { return nil }
  let result = body(fa)
  fa.endFrame()
  return result
}
