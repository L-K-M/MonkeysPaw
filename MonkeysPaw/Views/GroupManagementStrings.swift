import MonkeysPawCore

enum GroupManagementStrings {
    static let groups = "Groups"
    static let refresh = "Refresh groups"
    static let busyAccount = "Wait for group management to finish."
    static let unavailable = "Sign in to create a group or view your memberships."
    static let noGroups = "You do not belong to any groups."
    static let selectGroup = "Select a group to view its members."
    static let createName = "New group name"
    static let create = "Create group"
    static let rename = "Rename group"
    static let name = "Group name"
    static let delete = "Delete group…"
    static let confirmDelete = "Delete group"
    static let deleteWarning = "Delete this group and its shared prompts? This cannot be undone."
    static let cancel = "Cancel"
    static let members = "Members"
    static let userID = "Existing user ID"
    static let userIDGuidance = "Enter an existing account's user ID to add a member or change their role."
    static let role = "Member role"
    static let setRole = "Set role"
    static let remove = "Remove member"
    static let readOnly = "You can view members. Only owners or admins can manage this group."
    static let inviteRole = "Invite role"
    static let createInvite = "Create one-use invite"
    static let inviteGuidance = "The link can be used once. Copy it before closing Account; it will not be shown again."
    static let copyInvite = "Copy invite link"
    static let confirmed = "The server confirmed the change."

    static func role(_ role: SyncAPI.Role) -> String {
        switch role {
        case .owner: return "Owner"
        case .editor: return "Editor"
        case .viewer: return "Viewer"
        }
    }

    static func group(_ group: SyncAPI.GroupMembership) -> String { "\(group.name) (\(role(group.role)))" }
    static func groupID(_ group: SyncAPI.GroupMembership) -> String { "Group ID: \(group.groupID)" }
    static func member(_ member: SyncAPI.Member) -> String {
        let name = member.displayName.map { "\($0) (@\(member.username))" } ?? "@\(member.username)"
        return "\(name) · \(role(member.role))\nUser ID: \(member.userID)"
    }
    static func expires(_ date: String) -> String { "Expires: \(date)" }
    static func renameWarning(_ name: String) -> String { "Rename this group and its local folder to “\(name)”?" }

    static func progress(_ operation: GroupManagementOperation) -> String {
        switch operation {
        case .loading: return "Loading groups…"
        case .refreshing: return "Refreshing groups…"
        case .creating: return "Creating group…"
        case .renaming: return "Renaming group…"
        case .deleting: return "Deleting group…"
        case .settingRole: return "Updating member role…"
        case .removingMember: return "Removing member…"
        case .creatingInvite: return "Creating invite…"
        }
    }
}
