const std = @import("std");
const ObjectGuid = @import("./ObjectGuid.zig").ObjectGuid;

pub const Movement = struct {
    pub const Position = struct {
        x: f32,
        y: f32,
        z: f32,

        pub fn format(self: Position, w: *std.Io.Writer) std.Io.Writer.Error!void {
            try w.print("Movement.Position{{ x={d}, y={d}, z={d} }}", .{ self.x, self.y, self.z });
        }
    };

    pub const Direction = packed struct {
        forward: bool = false,
        backward: bool = false,
        strafe_left: bool = false,
        strafe_right: bool = false,
        turn_left: bool = false,
        turn_right: bool = false,

        pub fn format(self: Direction, w: *std.Io.Writer) std.Io.Writer.Error!void {
            try w.print("Movement.Direction{{ forward={}, backward={}, strafe_left={}, strafe_right={}, turn_left={}, turn_right={} }}", .{
                self.forward,
                self.backward,
                self.strafe_left,
                self.strafe_right,
                self.turn_left,
                self.turn_right,
            });
        }
    };

    pub const Locomotion = enum {
        walk,
        run,
        swim,
        fly,
    };

    pub const Posture = enum {
        grounded,
        falling,
    };

    pub const Transport = struct {
        guid: ObjectGuid,
        position: Position,
        orientation: f32,
        time_ms: u32,
        seat: u8,
        interpolated_time_ms: ?u32 = null,

        pub fn format(self: Transport, w: *std.Io.Writer) std.Io.Writer.Error!void {
            try w.print("Movement.Transport{{ guid=0x{X}, position={}, orientation={d}, time_ms={d}, seat={d} }}", .{
                self.guid.valueOf(),
                self.position,
                self.orientation,
                self.time_ms,
                self.seat,
            });
        }
    };

    pub const State = struct {
        position: Position,
        orientation: f32,
        direction: Direction = .{},
        locomotion: Locomotion = .run,
        posture: Posture = .grounded,
        pitch: ?f32 = null,
        transport: ?Transport = null,
        client_time_ms: ?u32 = null,
        server_time_ms: ?u32 = null,

        pub fn format(self: State, w: *std.Io.Writer) std.Io.Writer.Error!void {
            try w.print("Movement.State{{ position={}, orientation={d}, direction={}, locomotion={}, posture={} }}", .{
                self.position,
                self.orientation,
                self.direction,
                self.locomotion,
                self.posture,
            });
        }
    };
};
