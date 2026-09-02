pub const Session = @import("domain").Session;
pub const WorldServerConnection = @import("WorldServerConnection.zig").WorldServerConnection;
pub const character = @import("Character.zig");
pub const movement = @import("Movement.zig");
pub const chat = @import("Chat.zig");
pub const login = @import("Login.zig");

test "world handler modules" {
    _ = Session;
    _ = WorldServerConnection;
    _ = character;
    _ = movement;
    _ = chat;
    _ = login;
}
