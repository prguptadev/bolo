import os

/// Watch live:  log stream --predicate 'subsystem == "dev.prgupta.bolo"' --level info
/// Look back:   log show --last 10m --predicate 'subsystem == "dev.prgupta.bolo"' --info
enum Log {
    static let agent = Logger(subsystem: "dev.prgupta.bolo", category: "agent")
    static let skills = Logger(subsystem: "dev.prgupta.bolo", category: "skills")
    static let speech = Logger(subsystem: "dev.prgupta.bolo", category: "speech")
}
