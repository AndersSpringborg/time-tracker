/// Interface for getting WiFi network information.
/// Implementations: CoreWlanWifiProvider (Swift), MockWifiProvider (testing)
pub const WifiProvider = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    const VTable = struct {
        getSSID: *const fn (*anyopaque) ?[]const u8,
    };

    /// Get the current WiFi SSID, or null if not connected.
    /// The returned string is valid until the next call to getSSID().
    pub fn getSSID(self: WifiProvider) ?[]const u8 {
        return self.vtable.getSSID(self.ptr);
    }

    /// Create a WifiProvider from any type that implements the required methods.
    pub fn init(impl: anytype) WifiProvider {
        const Impl = @TypeOf(impl);
        const impl_ptr = if (@typeInfo(Impl) == .pointer) impl else @as(*@TypeOf(impl.*), @ptrCast(@constCast(&impl)));

        const gen = struct {
            fn getSSID(ptr: *anyopaque) ?[]const u8 {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.getSSID();
            }
        };

        return .{
            .ptr = impl_ptr,
            .vtable = &.{
                .getSSID = gen.getSSID,
            },
        };
    }
};
