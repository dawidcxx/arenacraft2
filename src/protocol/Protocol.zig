pub const ProtocolErrorSet = @import("./ProtocolError.zig").ProtocolErrorSet;

pub const auth = struct {
    pub const Opcode = @import("./AuthProtocol.zig").Opcode;
    pub const Frame = @import("./AuthProtocol.zig").Frame;
    pub const AuthLogonClientChallenge = @import("./AuthProtocol.zig").AuthLogonClientChallenge;
    pub const AuthLogonServerChallengeSuccess = @import("./AuthProtocol.zig").AuthLogonServerChallengeSuccess;
    pub const AuthLogonServerChallengeFailure = @import("./AuthProtocol.zig").AuthLogonServerChallengeFailure;
    pub const AuthLogonClientProof = @import("./AuthProtocol.zig").AuthLogonClientProof;
    pub const AuthLogonServerProofSuccess = @import("./AuthProtocol.zig").AuthLogonServerProofSuccess;
    pub const AuthLogonServerProofFailure = @import("./AuthProtocol.zig").AuthLogonServerProofFailure;
    pub const AuthRealmListClientRequest = @import("./AuthProtocol.zig").AuthRealmListClientRequest;
    pub const AuthRealmListServerResponse = @import("./AuthProtocol.zig").AuthRealmListServerResponse;
};

pub const world = struct {
    pub const Opcode = @import("./WorldProtocol.zig").Opcode;
    pub const Frame = @import("./WorldProtocol.zig").Frame;
    pub const AuthChallengeServer = @import("./WorldProtocol.zig").AuthChallengeServer;
    pub const AuthSessionClient = @import("./WorldProtocol.zig").AuthSessionClient;
    pub const AuthResponseServer = @import("./WorldProtocol.zig").AuthResponseServer;
    pub const PongServer = @import("./WorldProtocol.zig").PongServer;
    pub const ClientCacheVersionServer = @import("./WorldProtocol.zig").ClientCacheVersionServer;
    pub const TutorialFlagsServer = @import("./WorldProtocol.zig").TutorialFlagsServer;
    pub const AccountDataTimesServer = @import("./WorldProtocol.zig").AccountDataTimesServer;
    pub const RealmSplitServer = @import("./WorldProtocol.zig").RealmSplitServer;
    pub const UpdateAccountDataCompleteServer = @import("./WorldProtocol.zig").UpdateAccountDataCompleteServer;
    pub const AddonInfo = @import("./WorldProtocol.zig").AddonInfo;
    pub const AddonInfoServer = @import("./WorldProtocol.zig").AddonInfoServer;
    pub const CharEnumEntry = @import("./WorldProtocol.zig").CharEnumEntry;
    pub const CharEnumServer = @import("./WorldProtocol.zig").CharEnumServer;
    pub const CharCreateClient = @import("./WorldProtocol.zig").CharCreateClient;
    pub const CharCreateServer = @import("./WorldProtocol.zig").CharCreateServer;
    pub const CharDeleteClient = @import("./WorldProtocol.zig").CharDeleteClient;
    pub const CharDeleteServer = @import("./WorldProtocol.zig").CharDeleteServer;
    pub const NameQueryClient = @import("./WorldProtocol.zig").NameQueryClient;
    pub const NameQueryResponseServer = @import("./WorldProtocol.zig").NameQueryResponseServer;
    pub const ItemQuerySingleClient = @import("./WorldProtocol.zig").ItemQuerySingleClient;
    pub const ItemQuerySingleResponseServer = @import("./WorldProtocol.zig").ItemQuerySingleResponseServer;
    pub const PlayerLoginClient = @import("./WorldProtocol.zig").PlayerLoginClient;
    pub const PlayerCreateServer = @import("./WorldProtocol.zig").PlayerCreateServer;
    pub const DestroyObjectServer = @import("./WorldProtocol.zig").DestroyObjectServer;
    pub const PingClient = @import("./WorldProtocol.zig").PingClient;
    pub const RealmSplitClient = @import("./WorldProtocol.zig").RealmSplitClient;
    pub const RequestAccountDataClient = @import("./WorldProtocol.zig").RequestAccountDataClient;
    pub const UpdateAccountDataClient = @import("./WorldProtocol.zig").UpdateAccountDataClient;
    pub const LoginVerifyWorldServer = @import("./WorldProtocol.zig").LoginVerifyWorldServer;
    pub const BindPointUpdateServer = @import("./WorldProtocol.zig").BindPointUpdateServer;
    pub const TalentsInfoServer = @import("./WorldProtocol.zig").TalentsInfoServer;
    pub const InitialSpellsServer = @import("./WorldProtocol.zig").InitialSpellsServer;
    pub const LearnedSpellServer = @import("./WorldProtocol.zig").LearnedSpellServer;
    pub const ActionButtonsServer = @import("./WorldProtocol.zig").ActionButtonsServer;
    pub const InitializeFactionsServer = @import("./WorldProtocol.zig").InitializeFactionsServer;
    pub const LoginSetTimeSpeedServer = @import("./WorldProtocol.zig").LoginSetTimeSpeedServer;
    pub const TimeSyncRequestServer = @import("./WorldProtocol.zig").TimeSyncRequestServer;
    pub const TimeSyncResponseClient = @import("./WorldProtocol.zig").TimeSyncResponseClient;
    pub const InitWorldStatesServer = @import("./WorldProtocol.zig").InitWorldStatesServer;
    pub const MotdServer = @import("./WorldProtocol.zig").MotdServer;
    pub const packGameTime = @import("./WorldProtocol.zig").packGameTime;
};

pub const chat = struct {
    pub const ChatType = @import("./ChatProtocol.zig").ChatType;
    pub const MessageText = @import("./ChatProtocol.zig").MessageText;
    pub const MessageChatClient = @import("./ChatProtocol.zig").MessageChatClient;
    pub const MessageChatServer = @import("./ChatProtocol.zig").MessageChatServer;
};

pub const object = @import("./UpdateObject.zig");
pub const movement = @import("./Movement.zig");

pub const world_auth = struct {
    pub const AuthCrypt = @import("./WorldAuthCrypt.zig").AuthCrypt;
    pub const computeWorldAuthDigest = @import("./WorldAuthCrypt.zig").computeWorldAuthDigest;
};

test {
    _ = @import("./AuthProtocol.zig");
    _ = @import("./WorldProtocol.zig");
    _ = @import("./ChatProtocol.zig");
    _ = @import("./WorldAuthCrypt.zig");
    _ = @import("./Movement.zig");
    _ = @import("./UpdateObject.zig");
}
