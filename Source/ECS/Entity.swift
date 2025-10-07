
struct Entity { var raw: UInt32 } // 24-bit index, 8-bit gen
@inline(__always) func entityIndex( e: Entity) -> Int { Int(e.raw & 0x00FF_FFFF) }
@inline(__always) func entityGen( e: Entity) -> UInt8 { UInt8((e.raw >> 24) & 0xFF) }
