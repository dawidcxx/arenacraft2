pub const srp6 = struct {
    pub const SrpSession = @import("Srp6Session.zig").SrpSession;
    pub const InitOptions = @import("Srp6Session.zig").InitOptions;
    pub const Challenge = @import("Srp6Session.zig").Challenge;
    pub const ClientProof = @import("Srp6Session.zig").ClientProof;
    pub const Error = @import("Srp6Session.zig").Error;
    pub const VerifySuccess = @import("Srp6Session.zig").VerifySuccess;
    pub const State = @import("Srp6Session.zig").State;
};
