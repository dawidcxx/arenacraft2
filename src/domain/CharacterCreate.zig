const std = @import("std");
const MapId = @import("./MapId.zig").MapId;

pub const InstanceIds = struct {
    pub const eastern_kingdoms = "902e5fd8-67da-4ed1-9803-ec6d8ccf8ff4";
    pub const kalimdor = "5046cf90-e61b-4469-9acf-4c3b5600816b";
    pub const outland = "8c9dbf25-121a-4a3f-99d7-32f67cb24114";
    pub const acherus = "da6b4efb-f5ad-4a77-9a54-497c528c2a42";
};

pub const StaticInstance = struct {
    id: []const u8,
    map_id: MapId,
    name: []const u8,
};

pub const static_instances = [_]StaticInstance{
    .{ .id = InstanceIds.eastern_kingdoms, .map_id = MapId.eastern_kingdoms, .name = "Eastern Kingdoms" },
    .{ .id = InstanceIds.kalimdor, .map_id = MapId.kalimdor, .name = "Kalimdor" },
    .{ .id = InstanceIds.outland, .map_id = MapId.outland, .name = "Outland" },
    .{ .id = InstanceIds.acherus, .map_id = MapId.acherus, .name = "Acherus" },
};

pub const Template = struct {
    race_id: u8,
    class_id: u8,
    instance_id: []const u8,
    display_zone_id: u32,
    position_x: f32,
    position_y: f32,
    position_z: f32,
    orientation: f32,
};

pub const templates = [_]Template{
    .{ .race_id = 1, .class_id = 1, .instance_id = InstanceIds.eastern_kingdoms, .display_zone_id = 12, .position_x = -8949.95, .position_y = -132.493, .position_z = 83.5312, .orientation = 0 },
    .{ .race_id = 1, .class_id = 2, .instance_id = InstanceIds.eastern_kingdoms, .display_zone_id = 12, .position_x = -8949.95, .position_y = -132.493, .position_z = 83.5312, .orientation = 0 },
    .{ .race_id = 1, .class_id = 4, .instance_id = InstanceIds.eastern_kingdoms, .display_zone_id = 12, .position_x = -8949.95, .position_y = -132.493, .position_z = 83.5312, .orientation = 0 },
    .{ .race_id = 1, .class_id = 5, .instance_id = InstanceIds.eastern_kingdoms, .display_zone_id = 12, .position_x = -8949.95, .position_y = -132.493, .position_z = 83.5312, .orientation = 0 },
    .{ .race_id = 1, .class_id = 6, .instance_id = InstanceIds.acherus, .display_zone_id = 4298, .position_x = 2355.84, .position_y = -5664.77, .position_z = 426.028, .orientation = 3.65997 },
    .{ .race_id = 1, .class_id = 8, .instance_id = InstanceIds.eastern_kingdoms, .display_zone_id = 12, .position_x = -8949.95, .position_y = -132.493, .position_z = 83.5312, .orientation = 0 },
    .{ .race_id = 1, .class_id = 9, .instance_id = InstanceIds.eastern_kingdoms, .display_zone_id = 12, .position_x = -8949.95, .position_y = -132.493, .position_z = 83.5312, .orientation = 0 },
    .{ .race_id = 2, .class_id = 1, .instance_id = InstanceIds.kalimdor, .display_zone_id = 14, .position_x = -618.518, .position_y = -4251.67, .position_z = 38.718, .orientation = 0 },
    .{ .race_id = 2, .class_id = 3, .instance_id = InstanceIds.kalimdor, .display_zone_id = 14, .position_x = -618.518, .position_y = -4251.67, .position_z = 38.718, .orientation = 0 },
    .{ .race_id = 2, .class_id = 4, .instance_id = InstanceIds.kalimdor, .display_zone_id = 14, .position_x = -618.518, .position_y = -4251.67, .position_z = 38.718, .orientation = 0 },
    .{ .race_id = 2, .class_id = 6, .instance_id = InstanceIds.acherus, .display_zone_id = 4298, .position_x = 2358.44, .position_y = -5666.9, .position_z = 426.023, .orientation = 3.65997 },
    .{ .race_id = 2, .class_id = 7, .instance_id = InstanceIds.kalimdor, .display_zone_id = 14, .position_x = -618.518, .position_y = -4251.67, .position_z = 38.718, .orientation = 0 },
    .{ .race_id = 2, .class_id = 9, .instance_id = InstanceIds.kalimdor, .display_zone_id = 14, .position_x = -618.518, .position_y = -4251.67, .position_z = 38.718, .orientation = 0 },
    .{ .race_id = 3, .class_id = 1, .instance_id = InstanceIds.eastern_kingdoms, .display_zone_id = 1, .position_x = -6240.32, .position_y = 331.033, .position_z = 382.758, .orientation = 6.17716 },
    .{ .race_id = 3, .class_id = 2, .instance_id = InstanceIds.eastern_kingdoms, .display_zone_id = 1, .position_x = -6240.32, .position_y = 331.033, .position_z = 382.758, .orientation = 6.17716 },
    .{ .race_id = 3, .class_id = 3, .instance_id = InstanceIds.eastern_kingdoms, .display_zone_id = 1, .position_x = -6240.32, .position_y = 331.033, .position_z = 382.758, .orientation = 6.17716 },
    .{ .race_id = 3, .class_id = 4, .instance_id = InstanceIds.eastern_kingdoms, .display_zone_id = 1, .position_x = -6240.32, .position_y = 331.033, .position_z = 382.758, .orientation = 6.17716 },
    .{ .race_id = 3, .class_id = 5, .instance_id = InstanceIds.eastern_kingdoms, .display_zone_id = 1, .position_x = -6240.32, .position_y = 331.033, .position_z = 382.758, .orientation = 6.17716 },
    .{ .race_id = 3, .class_id = 6, .instance_id = InstanceIds.acherus, .display_zone_id = 4298, .position_x = 2358.44, .position_y = -5666.9, .position_z = 426.023, .orientation = 3.65997 },
    .{ .race_id = 4, .class_id = 1, .instance_id = InstanceIds.kalimdor, .display_zone_id = 141, .position_x = 10311.3, .position_y = 832.463, .position_z = 1326.41, .orientation = 5.69632 },
    .{ .race_id = 4, .class_id = 3, .instance_id = InstanceIds.kalimdor, .display_zone_id = 141, .position_x = 10311.3, .position_y = 832.463, .position_z = 1326.41, .orientation = 5.69632 },
    .{ .race_id = 4, .class_id = 4, .instance_id = InstanceIds.kalimdor, .display_zone_id = 141, .position_x = 10311.3, .position_y = 832.463, .position_z = 1326.41, .orientation = 5.69632 },
    .{ .race_id = 4, .class_id = 5, .instance_id = InstanceIds.kalimdor, .display_zone_id = 141, .position_x = 10311.3, .position_y = 832.463, .position_z = 1326.41, .orientation = 5.69632 },
    .{ .race_id = 4, .class_id = 6, .instance_id = InstanceIds.acherus, .display_zone_id = 4298, .position_x = 2356.21, .position_y = -5662.21, .position_z = 426.026, .orientation = 3.65997 },
    .{ .race_id = 4, .class_id = 11, .instance_id = InstanceIds.kalimdor, .display_zone_id = 141, .position_x = 10311.3, .position_y = 832.463, .position_z = 1326.41, .orientation = 5.69632 },
    .{ .race_id = 5, .class_id = 1, .instance_id = InstanceIds.eastern_kingdoms, .display_zone_id = 85, .position_x = 1676.71, .position_y = 1678.31, .position_z = 121.67, .orientation = 2.70526 },
    .{ .race_id = 5, .class_id = 4, .instance_id = InstanceIds.eastern_kingdoms, .display_zone_id = 85, .position_x = 1676.71, .position_y = 1678.31, .position_z = 121.67, .orientation = 2.70526 },
    .{ .race_id = 5, .class_id = 5, .instance_id = InstanceIds.eastern_kingdoms, .display_zone_id = 85, .position_x = 1676.71, .position_y = 1678.31, .position_z = 121.67, .orientation = 2.70526 },
    .{ .race_id = 5, .class_id = 6, .instance_id = InstanceIds.acherus, .display_zone_id = 4298, .position_x = 2356.21, .position_y = -5662.21, .position_z = 426.026, .orientation = 3.65997 },
    .{ .race_id = 5, .class_id = 8, .instance_id = InstanceIds.eastern_kingdoms, .display_zone_id = 85, .position_x = 1676.71, .position_y = 1678.31, .position_z = 121.67, .orientation = 2.70526 },
    .{ .race_id = 5, .class_id = 9, .instance_id = InstanceIds.eastern_kingdoms, .display_zone_id = 85, .position_x = 1676.71, .position_y = 1678.31, .position_z = 121.67, .orientation = 2.70526 },
    .{ .race_id = 6, .class_id = 1, .instance_id = InstanceIds.kalimdor, .display_zone_id = 215, .position_x = -2917.58, .position_y = -257.98, .position_z = 52.9968, .orientation = 0 },
    .{ .race_id = 6, .class_id = 3, .instance_id = InstanceIds.kalimdor, .display_zone_id = 215, .position_x = -2917.58, .position_y = -257.98, .position_z = 52.9968, .orientation = 0 },
    .{ .race_id = 6, .class_id = 6, .instance_id = InstanceIds.acherus, .display_zone_id = 4298, .position_x = 2358.17, .position_y = -5663.21, .position_z = 426.027, .orientation = 3.65997 },
    .{ .race_id = 6, .class_id = 7, .instance_id = InstanceIds.kalimdor, .display_zone_id = 215, .position_x = -2917.58, .position_y = -257.98, .position_z = 52.9968, .orientation = 0 },
    .{ .race_id = 6, .class_id = 11, .instance_id = InstanceIds.kalimdor, .display_zone_id = 215, .position_x = -2917.58, .position_y = -257.98, .position_z = 52.9968, .orientation = 0 },
    .{ .race_id = 7, .class_id = 1, .instance_id = InstanceIds.eastern_kingdoms, .display_zone_id = 1, .position_x = -6240.32, .position_y = 331.033, .position_z = 382.758, .orientation = 0 },
    .{ .race_id = 7, .class_id = 4, .instance_id = InstanceIds.eastern_kingdoms, .display_zone_id = 1, .position_x = -6240, .position_y = 331, .position_z = 383, .orientation = 0 },
    .{ .race_id = 7, .class_id = 6, .instance_id = InstanceIds.acherus, .display_zone_id = 4298, .position_x = 2355.05, .position_y = -5661.7, .position_z = 426.026, .orientation = 3.65997 },
    .{ .race_id = 7, .class_id = 8, .instance_id = InstanceIds.eastern_kingdoms, .display_zone_id = 1, .position_x = -6240, .position_y = 331, .position_z = 383, .orientation = 0 },
    .{ .race_id = 7, .class_id = 9, .instance_id = InstanceIds.eastern_kingdoms, .display_zone_id = 1, .position_x = -6240, .position_y = 331, .position_z = 383, .orientation = 0 },
    .{ .race_id = 8, .class_id = 1, .instance_id = InstanceIds.kalimdor, .display_zone_id = 14, .position_x = -618.518, .position_y = -4251.67, .position_z = 38.718, .orientation = 0 },
    .{ .race_id = 8, .class_id = 3, .instance_id = InstanceIds.kalimdor, .display_zone_id = 14, .position_x = -618.518, .position_y = -4251.67, .position_z = 38.718, .orientation = 0 },
    .{ .race_id = 8, .class_id = 4, .instance_id = InstanceIds.kalimdor, .display_zone_id = 14, .position_x = -618.518, .position_y = -4251.67, .position_z = 38.718, .orientation = 0 },
    .{ .race_id = 8, .class_id = 5, .instance_id = InstanceIds.kalimdor, .display_zone_id = 14, .position_x = -618.518, .position_y = -4251.67, .position_z = 38.718, .orientation = 0 },
    .{ .race_id = 8, .class_id = 6, .instance_id = InstanceIds.acherus, .display_zone_id = 4298, .position_x = 2355.05, .position_y = -5661.7, .position_z = 426.026, .orientation = 3.65997 },
    .{ .race_id = 8, .class_id = 7, .instance_id = InstanceIds.kalimdor, .display_zone_id = 14, .position_x = -618.518, .position_y = -4251.67, .position_z = 38.718, .orientation = 0 },
    .{ .race_id = 8, .class_id = 8, .instance_id = InstanceIds.kalimdor, .display_zone_id = 14, .position_x = -618.518, .position_y = -4251.67, .position_z = 38.718, .orientation = 0 },
    .{ .race_id = 10, .class_id = 2, .instance_id = InstanceIds.outland, .display_zone_id = 3431, .position_x = 10349.6, .position_y = -6357.29, .position_z = 33.4026, .orientation = 5.31605 },
    .{ .race_id = 10, .class_id = 3, .instance_id = InstanceIds.outland, .display_zone_id = 3431, .position_x = 10349.6, .position_y = -6357.29, .position_z = 33.4026, .orientation = 5.31605 },
    .{ .race_id = 10, .class_id = 4, .instance_id = InstanceIds.outland, .display_zone_id = 3431, .position_x = 10349.6, .position_y = -6357.29, .position_z = 33.4026, .orientation = 5.31605 },
    .{ .race_id = 10, .class_id = 5, .instance_id = InstanceIds.outland, .display_zone_id = 3431, .position_x = 10349.6, .position_y = -6357.29, .position_z = 33.4026, .orientation = 5.31605 },
    .{ .race_id = 10, .class_id = 6, .instance_id = InstanceIds.acherus, .display_zone_id = 4298, .position_x = 2355.84, .position_y = -5664.77, .position_z = 426.028, .orientation = 3.65997 },
    .{ .race_id = 10, .class_id = 8, .instance_id = InstanceIds.outland, .display_zone_id = 3431, .position_x = 10349.6, .position_y = -6357.29, .position_z = 33.4026, .orientation = 5.31605 },
    .{ .race_id = 10, .class_id = 9, .instance_id = InstanceIds.outland, .display_zone_id = 3431, .position_x = 10349.6, .position_y = -6357.29, .position_z = 33.4026, .orientation = 5.31605 },
    .{ .race_id = 11, .class_id = 1, .instance_id = InstanceIds.outland, .display_zone_id = 3526, .position_x = -3961.64, .position_y = -13931.2, .position_z = 100.615, .orientation = 2.08364 },
    .{ .race_id = 11, .class_id = 2, .instance_id = InstanceIds.outland, .display_zone_id = 3526, .position_x = -3961.64, .position_y = -13931.2, .position_z = 100.615, .orientation = 2.08364 },
    .{ .race_id = 11, .class_id = 3, .instance_id = InstanceIds.outland, .display_zone_id = 3526, .position_x = -3961.64, .position_y = -13931.2, .position_z = 100.615, .orientation = 2.08364 },
    .{ .race_id = 11, .class_id = 5, .instance_id = InstanceIds.outland, .display_zone_id = 3526, .position_x = -3961.64, .position_y = -13931.2, .position_z = 100.615, .orientation = 2.08364 },
    .{ .race_id = 11, .class_id = 6, .instance_id = InstanceIds.acherus, .display_zone_id = 4298, .position_x = 2358.17, .position_y = -5663.21, .position_z = 426.027, .orientation = 3.65997 },
    .{ .race_id = 11, .class_id = 7, .instance_id = InstanceIds.outland, .display_zone_id = 3526, .position_x = -3961.64, .position_y = -13931.2, .position_z = 100.615, .orientation = 2.08364 },
    .{ .race_id = 11, .class_id = 8, .instance_id = InstanceIds.outland, .display_zone_id = 3526, .position_x = -3961.64, .position_y = -13931.2, .position_z = 100.615, .orientation = 2.08364 },
};

pub fn findTemplate(race_id: u8, class_id: u8) ?Template {
    for (templates) |template| {
        if (template.race_id == race_id and template.class_id == class_id) return template;
    }
    return null;
}

test "creation templates contain known valid and invalid combinations" {
    try std.testing.expect(findTemplate(1, 1) != null);
    try std.testing.expect(findTemplate(1, 7) == null);
    try std.testing.expectEqualStrings(InstanceIds.kalimdor, findTemplate(2, 1).?.instance_id);
}
