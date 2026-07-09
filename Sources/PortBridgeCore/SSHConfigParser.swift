import Foundation

public struct SSHConfigEntry: Equatable, Sendable {
    public var patterns: [String]
    public var hostname: String?
    public var user: String?
    public var port: Int?
    public var identityFile: String?

    public init(patterns: [String], hostname: String? = nil, user: String? = nil, port: Int? = nil, identityFile: String? = nil) {
        self.patterns = patterns
        self.hostname = hostname
        self.user = user
        self.port = port
        self.identityFile = identityFile
    }
}

public enum SSHConfigParser {
    public static func parse(_ text: String) -> [SSHConfigEntry] {
        var entries: [SSHConfigEntry] = []
        var current: SSHConfigEntry?

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let noComment = rawLine.split(separator: "#", maxSplits: 1).first.map(String.init) ?? ""
            let line = noComment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            let pieces = line.split(maxSplits: 1, whereSeparator: { char in
                char == " " || char == "\t"
            }).map(String.init)
            guard pieces.count == 2 else { continue }
            let key = pieces[0].lowercased()
            let value = pieces[1].trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

            if key == "host" {
                if let current {
                    entries.append(current)
                }
                let splitPatterns = value.split(whereSeparator: { char in
                    char == " " || char == "\t"
                })
                let patterns = splitPatterns.map(String.init)
                current = SSHConfigEntry(patterns: patterns)
                continue
            }

            guard current != nil else { continue }
            switch key {
            case "hostname":
                current?.hostname = value
            case "user":
                current?.user = value
            case "port":
                current?.port = Int(value)
            case "identityfile":
                current?.identityFile = value
            default:
                break
            }
        }

        if let current {
            entries.append(current)
        }

        return entries.filter { entry in
            entry.patterns.contains { pattern in
                !pattern.contains("*") && !pattern.contains("?") && !pattern.hasPrefix("!")
            }
        }
    }

    public static func readUserConfig() -> [SSHConfigEntry] {
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".ssh")
            .appendingPathComponent("config")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }
        return parse(text)
    }

    public static func hostProfilesFromUserConfig() -> [HostProfile] {
        readUserConfig().flatMap { entry in
            entry.patterns.compactMap { pattern -> HostProfile? in
                guard !pattern.contains("*"), !pattern.contains("?"), !pattern.hasPrefix("!") else {
                    return nil
                }
                return HostProfile(
                    alias: pattern,
                    hostname: entry.hostname ?? "",
                    user: entry.user ?? "",
                    port: entry.port ?? 22,
                    enabled: false,
                    useSSHConfigAlias: true
                )
            }
        }
    }
}
