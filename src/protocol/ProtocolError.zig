pub const ProtocolErrorSet = error{
    // The message is malformed
    InvalidMessage,

    // The message is appropriate in shape
    // but unexpected for the current server state
    IllegalClientState,
};
