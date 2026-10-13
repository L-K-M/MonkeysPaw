import ArgumentParser
import Foundation
import MonkeysPawCore
import MonkeysPawServer

struct UserCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "user", abstract: "Manage accounts as the local operator.",
        subcommands: [UserAdd.self, UserDisable.self, UserResetPassword.self]
    )
}

struct GroupCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "group", abstract: "Manage groups as the local operator.",
        subcommands: [GroupAdd.self, GroupAddMember.self]
    )
}

struct InviteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "invite", abstract: "Issue single-use invites as the local operator.", subcommands: [InviteCreate.self]
    )
}

private struct UserAdd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "add", abstract: "Create an account.")
    @Argument(help: "Lowercase username.") var username: String
    @Option(help: "Account kind: member or admin.") var kind = "member"
    @Option(help: "Optional display name.") var displayName: String?
    @OptionGroup var password: PasswordInput
    @OptionGroup var output: AdminOutput

    mutating func run() async throws {
        guard let kind = SyncAPI.AccountKind(rawValue: kind) else { throw OperatorCommandError.invalidInput }
        let username = username
        let displayName = displayName
        let secret = try password.read()
        let user = try await administer { try await $0.addUser(username: username, password: secret, kind: kind, displayName: displayName) }
        try output.write(user, text: user.id)
    }
}

private struct UserDisable: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "disable", abstract: "Disable an account and revoke its devices.")
    @Argument(help: "User ULID.") var id: String
    @OptionGroup var output: AdminOutput

    mutating func run() async throws {
        let id = id
        let user = try await administer { try await $0.disableUser(id: id) }
        try output.write(user, text: user.id)
    }
}

private struct UserResetPassword: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "reset-password", abstract: "Reset a password and revoke every target device.")
    @Argument(help: "User ULID.") var id: String
    @OptionGroup var password: PasswordInput
    @OptionGroup var output: AdminOutput

    mutating func run() async throws {
        let id = id
        let secret = try password.read()
        let user = try await administer { try await $0.resetPassword(id: id, password: secret) }
        try output.write(user, text: user.id)
    }
}

private struct GroupAdd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "add", abstract: "Create a group with an initial owner.")
    @Argument(help: "Group name.") var name: String
    @Option(help: "Enabled initial owner's user ULID; also stored as the creator.") var owner: String
    @OptionGroup var output: AdminOutput

    mutating func run() async throws {
        let name = name
        let owner = owner
        let group = try await administer { try await $0.addGroup(name: name, ownerID: owner) }
        try output.write(group, text: group.id)
    }
}

private struct GroupAddMember: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "add-member", abstract: "Add a member or change an existing member's role.")
    @Argument(help: "Group ULID.") var groupID: String
    @Argument(help: "User ULID.") var userID: String
    @Option(help: "Membership role: viewer, editor or owner.") var role = "viewer"
    @OptionGroup var output: AdminOutput

    mutating func run() async throws {
        guard let role = SyncAPI.Role(rawValue: role) else { throw OperatorCommandError.invalidInput }
        let groupID = groupID
        let userID = userID
        let member = try await administer { try await $0.addMember(groupID: groupID, userID: userID, role: role) }
        try output.write(member, text: member.userID)
    }
}

private struct InviteCreate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Print a single-use token or link exactly once.")
    @Option(help: "Enabled admin user ULID stored as the invite issuer.") var issuer: String
    @Option(help: "Group ULID; omit both --group and --role for an account-only invite.") var group: String?
    @Option(help: "Group role: viewer, editor or owner (CLI only). Required with --group.") var role: String?
    @Option(help: "Lifetime in seconds: 1 through 604800; default seven days.") var expiresIn: Int64?
    @OptionGroup var output: AdminOutput

    mutating func run() async throws {
        let inviteRole: SyncAPI.Role?
        if let role {
            guard let value = SyncAPI.Role(rawValue: role) else { throw OperatorCommandError.invalidInput }
            inviteRole = value
        } else {
            inviteRole = nil
        }
        let issuer = issuer
        let group = group
        let expiresIn = expiresIn
        let invite = try await administer {
            try await $0.createInvite(issuerID: issuer, groupID: group, role: inviteRole, expiresIn: expiresIn)
        }
        try output.write(invite, text: invite.secret)
    }
}

private func administer<T: Sendable>(_ operation: @escaping @Sendable (OperatorAdminService) async throws -> T) async throws -> T {
    do {
        let configuration = try ServerConfiguration()
        return try await ServerDatabase.withMigratedDatabase(configuration: DatabaseConfiguration()) { database in
            try await operation(OperatorAdminService(database: database, configuration: configuration))
        }
    } catch {
        throw OperatorCommandError(sanitizing: error)
    }
}

struct AdminOutput: ParsableArguments {
    @Flag(help: "Print one JSON result to stdout; failures use safe stderr messages.") var json = false

    func write(_ value: some Encodable, text: String) throws {
        do {
            var bytes: Data
            if json {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                bytes = try encoder.encode(value)
            } else {
                bytes = Data(text.utf8)
            }
            bytes.append(10)
            try FileHandle.standardOutput.write(contentsOf: bytes)
        } catch {
            throw OperatorCommandError.failed
        }
    }
}

private struct PasswordInput: ParsableArguments {
    @Option(help: "Read the password from a regular UTF-8 file instead of stdin.") var passwordFile: String?

    func read() throws -> String {
        do {
            let handle: FileHandle
            if let passwordFile {
                let url = URL(fileURLWithPath: passwordFile).resolvingSymlinksInPath()
                guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                    throw OperatorCommandError.passwordInput
                }
                handle = try FileHandle(forReadingFrom: url)
            } else {
                handle = .standardInput
            }
            defer { if passwordFile != nil { try? handle.close() } }
            let limit = ServerLimits.operatorPasswordInputMaximumBytes
            var data = Data()
            while data.count <= limit {
                let chunk = try handle.read(upToCount: limit + 1 - data.count) ?? Data()
                if chunk.isEmpty { break }
                data.append(chunk)
            }
            guard data.count <= limit else { throw OperatorCommandError.passwordInput }
            // Match bootstrap files: strip one terminal LF/CRLF, preserve spaces.
            if data.last == 10 {
                data.removeLast()
                if data.last == 13 { data.removeLast() }
            }
            guard let secret = String(data: data, encoding: .utf8), !secret.isEmpty else {
                throw OperatorCommandError.passwordInput
            }
            return secret
        } catch {
            throw OperatorCommandError.passwordInput
        }
    }
}
