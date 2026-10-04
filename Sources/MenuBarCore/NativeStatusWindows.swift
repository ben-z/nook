import CoreGraphics
import Darwin

// macOS 26 keeps inactive status-item replicas in the public window list.
// This read-only enumeration identifies the actual menu-bar surfaces.
enum NativeStatusWindows {
    private struct Functions:@unchecked Sendable {
        let connection:@convention(c) () -> Int32
        let count:@convention(c) (Int32,Int32,UnsafeMutablePointer<Int32>) -> Int32
        let list:@convention(c) (Int32,Int32,Int32,UnsafeMutablePointer<CGWindowID>,UnsafeMutablePointer<Int32>) -> Int32
        init() {
            guard let library = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",RTLD_NOW),
                  let connection = dlsym(library,"CGSMainConnectionID"),
                  let count = dlsym(library,"CGSGetWindowCount"),
                  let list = dlsym(library,"CGSGetProcessMenuBarWindowList") else {
                preconditionFailure("This macOS release does not expose the required native menu-bar enumeration")
            }
            self.connection = unsafeBitCast(connection,to:(@convention(c) () -> Int32).self)
            self.count = unsafeBitCast(count,to:(@convention(c) (Int32,Int32,UnsafeMutablePointer<Int32>) -> Int32).self)
            self.list = unsafeBitCast(list,to:(@convention(c) (Int32,Int32,Int32,UnsafeMutablePointer<CGWindowID>,UnsafeMutablePointer<Int32>) -> Int32).self)
        }
    }
    private static let functions = Functions()
    static func identifiers() throws -> Set<CGWindowID> {
        let connection = functions.connection()
        var capacity:Int32 = 0
        let counted = functions.count(connection,0,&capacity)
        try require(counted == 0 && capacity > 0,"Cannot obtain native window-list capacity: \(counted)")
        var result = [CGWindowID](repeating:0,count:Int(capacity))
        var count:Int32 = 0
        let status = functions.list(connection,0,capacity,&result,&count)
        try require(status == 0,"Native menu-bar enumeration failed: \(status)")
        try require(count > 0 && count <= capacity,"Native menu-bar enumeration returned an invalid count")
        return Set(result.prefix(Int(count)))
    }
}
