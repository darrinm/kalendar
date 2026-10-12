import os

public enum Log {
    /// Also the bundle ID and the Keychain service name.
    public static let subsystem = "com.massena.kalendar"
    public static let shell = Logger(subsystem: subsystem, category: "shell")
    public static let auth = Logger(subsystem: subsystem, category: "auth")
    public static let sync = Logger(subsystem: subsystem, category: "sync")
}
