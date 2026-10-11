/// Build an outgoing-only Windows sender. No PC listener or discovery is allowed.
const outgoingOnlyMode = bool.fromEnvironment('LOCALSEND_OUTGOING_ONLY');

/// Both custom editions disable all device discovery and automatic listeners.
const linkOnlyMode = bool.fromEnvironment('LOCALSEND_LINK_ONLY') || outgoingOnlyMode;

const customEditionName = outgoingOnlyMode ? 'LocalSend Wi-Fi Sender' : 'LocalSend Link-Only';
