import SQLKit

enum FoundationSchema {
    private static let ownership = """
        CHECK ((scope = 'user' AND owner_id IS NOT NULL AND group_id IS NULL)
            OR (scope = 'group' AND group_id IS NOT NULL AND owner_id IS NULL))
        """
    private static let scopeKey = """
        CHECK (scope_key = CASE scope WHEN 'user' THEN 'user:' || owner_id ELSE 'group:' || group_id END)
        """
    private static let username = """
        CHECK (length(CAST(username AS BLOB)) BETWEEN 1 AND \(ServerLimits.usernameMaxBytes)
            AND instr(username, char(0)) = 0 AND username NOT GLOB '*[^a-z0-9_.-]*')
        """

    static let statements: [SQLQueryString] = [
        """
        CREATE TABLE meta (
            singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
            database_id TEXT NOT NULL UNIQUE CHECK (
                length(CAST(database_id AS BLOB)) = 36
                AND substr(database_id, 9, 1) = '-' AND substr(database_id, 14, 1) = '-'
                AND substr(database_id, 19, 1) = '-' AND substr(database_id, 24, 1) = '-'
                AND length(replace(database_id, '-', '')) = 32
                AND replace(database_id, '-', '') NOT GLOB '*[^0-9A-F]*')
        )
        """,
        """
        CREATE TRIGGER meta_durable BEFORE DELETE ON meta
        BEGIN SELECT RAISE(ABORT, 'Database identity cannot be deleted'); END
        """,
        """
        CREATE TRIGGER meta_no_replace BEFORE INSERT ON meta
        WHEN EXISTS (SELECT 1 FROM meta)
        BEGIN SELECT RAISE(ABORT, 'Database identity cannot be replaced'); END
        """,
        """
        CREATE TABLE users (
            id TEXT PRIMARY KEY NOT NULL,
            username TEXT NOT NULL UNIQUE \(unsafeRaw: username),
            display_name TEXT NOT NULL,
            password_hash TEXT NOT NULL,
            account_kind TEXT NOT NULL CHECK (account_kind IN ('member', 'admin')),
            created_at TEXT NOT NULL,
            disabled_at TEXT
        )
        """,
        """
        CREATE TABLE groups (
            id TEXT PRIMARY KEY NOT NULL,
            name TEXT NOT NULL,
            created_by TEXT NOT NULL REFERENCES users(id),
            created_at TEXT NOT NULL,
            deleted_at TEXT
        )
        """,
        """
        CREATE TABLE memberships (
            group_id TEXT NOT NULL REFERENCES groups(id),
            user_id TEXT NOT NULL REFERENCES users(id),
            role TEXT NOT NULL CHECK (role IN ('owner', 'editor', 'viewer')),
            joined_at TEXT NOT NULL,
            PRIMARY KEY (group_id, user_id)
        )
        """,
        """
        CREATE TABLE prompts (
            id TEXT PRIMARY KEY NOT NULL,
            scope TEXT NOT NULL,
            owner_id TEXT REFERENCES users(id),
            group_id TEXT REFERENCES groups(id),
            path TEXT NOT NULL,
            path_key TEXT NOT NULL,
            content TEXT NOT NULL,
            title TEXT NOT NULL,
            rev INTEGER NOT NULL CHECK (typeof(rev) = 'integer' AND rev > 0),
            created_by TEXT NOT NULL REFERENCES users(id),
            created_at TEXT NOT NULL,
            updated_by TEXT NOT NULL REFERENCES users(id),
            updated_at TEXT NOT NULL,
            deleted_at TEXT,
            \(unsafeRaw: ownership)
        )
        """,
        "CREATE UNIQUE INDEX prompts_user_path ON prompts(owner_id, path_key) WHERE deleted_at IS NULL AND scope = 'user'",
        "CREATE UNIQUE INDEX prompts_group_path ON prompts(group_id, path_key) WHERE deleted_at IS NULL AND scope = 'group'",
        """
        CREATE TRIGGER prompts_identity_immutable BEFORE UPDATE OF id ON prompts
        WHEN NEW.id != OLD.id
        BEGIN SELECT RAISE(ABORT, 'Prompt identity is immutable'); END
        """,
        """
        CREATE TRIGGER prompts_no_replace BEFORE INSERT ON prompts
        WHEN EXISTS (SELECT 1 FROM prompts WHERE id = NEW.id)
        BEGIN SELECT RAISE(ABORT, 'Prompt identities cannot be replaced'); END
        """,
        """
        CREATE TABLE prompt_revisions (
            prompt_id TEXT NOT NULL REFERENCES prompts(id) ON DELETE CASCADE,
            rev INTEGER NOT NULL CHECK (typeof(rev) = 'integer' AND rev > 0),
            author_id TEXT NOT NULL REFERENCES users(id),
            scope TEXT NOT NULL,
            owner_id TEXT REFERENCES users(id),
            group_id TEXT REFERENCES groups(id),
            path TEXT NOT NULL,
            content TEXT NOT NULL,
            created_at TEXT NOT NULL,
            origin TEXT NOT NULL,
            PRIMARY KEY (prompt_id, rev),
            \(unsafeRaw: ownership)
        )
        """,
        """
        CREATE TABLE scope_heads (
            scope_key TEXT PRIMARY KEY NOT NULL,
            head_seq INTEGER NOT NULL CHECK (typeof(head_seq) = 'integer' AND head_seq >= 0)
        )
        """,
        """
        CREATE TABLE changes (
            seq INTEGER PRIMARY KEY AUTOINCREMENT CHECK (seq > 0),
            scope_key TEXT NOT NULL,
            scope TEXT NOT NULL,
            owner_id TEXT REFERENCES users(id),
            group_id TEXT REFERENCES groups(id),
            prompt_id TEXT NOT NULL,
            kind TEXT NOT NULL CHECK (kind IN ('upsert', 'delete', 'move_out')),
            path TEXT NOT NULL,
            rev INTEGER NOT NULL CHECK (typeof(rev) = 'integer' AND rev > 0),
            content TEXT,
            at TEXT NOT NULL,
            \(unsafeRaw: ownership),
            \(unsafeRaw: scopeKey),
            CHECK ((kind = 'upsert' AND content IS NOT NULL)
                OR (kind IN ('delete', 'move_out') AND content IS NULL))
        )
        """,
        "CREATE INDEX changes_scope_seq ON changes(scope_key, seq)",
        """
        CREATE TRIGGER changes_immutable BEFORE UPDATE ON changes
        BEGIN SELECT RAISE(ABORT, 'Change events are immutable'); END
        """,
        """
        CREATE TRIGGER changes_no_replace BEFORE INSERT ON changes
        WHEN EXISTS (SELECT 1 FROM changes WHERE seq = NEW.seq)
        BEGIN SELECT RAISE(ABORT, 'Change events cannot be replaced'); END
        """,
        """
        CREATE TRIGGER changes_raise_head AFTER INSERT ON changes
        BEGIN
            INSERT INTO scope_heads (scope_key, head_seq) VALUES (NEW.scope_key, NEW.seq)
            ON CONFLICT (scope_key) DO UPDATE SET head_seq = MAX(head_seq, excluded.head_seq);
        END
        """,
        """
        CREATE TRIGGER scope_heads_valid_insert BEFORE INSERT ON scope_heads
        WHEN NEW.head_seq != 0 AND NOT EXISTS (
            SELECT 1 FROM changes WHERE seq = NEW.head_seq AND scope_key = NEW.scope_key)
        BEGIN SELECT RAISE(ABORT, 'Nonzero scope heads require a change event'); END
        """,
        """
        CREATE TRIGGER scope_heads_valid_raise BEFORE UPDATE OF head_seq ON scope_heads
        WHEN NEW.head_seq > OLD.head_seq AND NOT EXISTS (
            SELECT 1 FROM changes WHERE seq = NEW.head_seq AND scope_key = NEW.scope_key)
        BEGIN SELECT RAISE(ABORT, 'Scope head raises require a change event'); END
        """,
        """
        CREATE TABLE scope_floors (
            scope_key TEXT PRIMARY KEY NOT NULL REFERENCES scope_heads(scope_key),
            floor_seq INTEGER NOT NULL CHECK (typeof(floor_seq) = 'integer' AND floor_seq >= 1)
        )
        """,
        """
        CREATE TRIGGER scope_floors_valid_insert BEFORE INSERT ON scope_floors
        WHEN NEW.floor_seq - 1 > (SELECT head_seq FROM scope_heads WHERE scope_key = NEW.scope_key)
        BEGIN SELECT RAISE(ABORT, 'Scope floors cannot pass head plus one'); END
        """,
        """
        CREATE TRIGGER scope_floors_valid_raise BEFORE UPDATE OF floor_seq ON scope_floors
        WHEN NEW.floor_seq - 1 > (SELECT head_seq FROM scope_heads WHERE scope_key = NEW.scope_key)
        BEGIN SELECT RAISE(ABORT, 'Scope floors cannot pass head plus one'); END
        """,
        """
        CREATE TRIGGER scope_heads_monotonic BEFORE UPDATE ON scope_heads
        WHEN NEW.head_seq < OLD.head_seq OR NEW.scope_key != OLD.scope_key
        BEGIN SELECT RAISE(ABORT, 'Scope heads cannot decrease or change identity'); END
        """,
        """
        CREATE TRIGGER scope_heads_no_lower_replace BEFORE INSERT ON scope_heads
        WHEN NEW.head_seq < (SELECT head_seq FROM scope_heads WHERE scope_key = NEW.scope_key)
        BEGIN SELECT RAISE(ABORT, 'Scope heads cannot decrease'); END
        """,
        """
        CREATE TRIGGER scope_heads_durable BEFORE DELETE ON scope_heads
        BEGIN SELECT RAISE(ABORT, 'Scope heads must survive retention'); END
        """,
        """
        CREATE TRIGGER scope_floors_monotonic BEFORE UPDATE ON scope_floors
        WHEN NEW.floor_seq < OLD.floor_seq OR NEW.scope_key != OLD.scope_key
        BEGIN SELECT RAISE(ABORT, 'Scope floors cannot decrease or change identity'); END
        """,
        """
        CREATE TRIGGER scope_floors_no_lower_replace BEFORE INSERT ON scope_floors
        WHEN NEW.floor_seq < (SELECT floor_seq FROM scope_floors WHERE scope_key = NEW.scope_key)
        BEGIN SELECT RAISE(ABORT, 'Scope floors cannot decrease'); END
        """,
        """
        CREATE TRIGGER scope_floors_durable BEFORE DELETE ON scope_floors
        BEGIN SELECT RAISE(ABORT, 'Scope floors must survive retention'); END
        """,
        """
        CREATE TABLE retired_prompt_ids (
            prompt_id TEXT PRIMARY KEY NOT NULL,
            scope TEXT NOT NULL,
            owner_id TEXT REFERENCES users(id),
            group_id TEXT REFERENCES groups(id),
            retired_at TEXT NOT NULL,
            \(unsafeRaw: ownership)
        )
        """,
        """
        CREATE TRIGGER retired_ids_immutable BEFORE UPDATE ON retired_prompt_ids
        BEGIN SELECT RAISE(ABORT, 'Retired IDs are immutable'); END
        """,
        """
        CREATE TRIGGER retired_ids_durable BEFORE DELETE ON retired_prompt_ids
        BEGIN SELECT RAISE(ABORT, 'Retired IDs must survive retention'); END
        """,
        """
        CREATE TRIGGER retired_ids_no_replace BEFORE INSERT ON retired_prompt_ids
        WHEN EXISTS (SELECT 1 FROM retired_prompt_ids WHERE prompt_id = NEW.prompt_id)
        BEGIN SELECT RAISE(ABORT, 'Retired IDs cannot be replaced'); END
        """,
        """
        CREATE TRIGGER prompts_no_retired_id BEFORE INSERT ON prompts
        WHEN EXISTS (SELECT 1 FROM retired_prompt_ids WHERE prompt_id = NEW.id)
        BEGIN SELECT RAISE(ABORT, 'Retired prompt IDs cannot be reused'); END
        """,
        """
        CREATE TABLE snapshots (
            database_id TEXT NOT NULL REFERENCES meta(database_id),
            scope_key TEXT NOT NULL REFERENCES scope_heads(scope_key),
            head_seq INTEGER NOT NULL CHECK (typeof(head_seq) = 'integer' AND head_seq >= 0),
            manifest BLOB NOT NULL CHECK (typeof(manifest) = 'blob' AND length(manifest) BETWEEN 1 AND \(literal: ServerLimits.snapshotMaxBytes)),
            created_at TEXT NOT NULL,
            expires_at TEXT NOT NULL,
            PRIMARY KEY (database_id, scope_key, head_seq),
            CHECK (julianday(created_at) IS NOT NULL AND julianday(expires_at) IS NOT NULL
                AND julianday(expires_at) > julianday(created_at)
                AND julianday(expires_at) <= julianday(created_at, \(literal: ServerLimits.snapshotLifetimeSeconds) || ' seconds'))
        )
        """,
        "CREATE INDEX snapshots_expiry ON snapshots(expires_at)",
        """
        CREATE TRIGGER snapshots_valid_head BEFORE INSERT ON snapshots
        WHEN NEW.head_seq > (SELECT head_seq FROM scope_heads WHERE scope_key = NEW.scope_key)
        BEGIN SELECT RAISE(ABORT, 'Snapshot heads cannot exceed the scope head'); END
        """,
        """
        CREATE TRIGGER snapshots_storage_bound BEFORE INSERT ON snapshots
        WHEN (SELECT COALESCE(SUM(length(manifest)), 0) FROM snapshots) + length(NEW.manifest) > \(literal: ServerLimits.snapshotTotalMaxBytes)
        BEGIN SELECT RAISE(ABORT, 'Snapshot storage limit exceeded'); END
        """,
        """
        CREATE TRIGGER snapshots_immutable BEFORE UPDATE ON snapshots
        BEGIN SELECT RAISE(ABORT, 'Snapshots are immutable'); END
        """,
        """
        CREATE TRIGGER snapshots_no_replace BEFORE INSERT ON snapshots
        WHEN EXISTS (SELECT 1 FROM snapshots
            WHERE database_id = NEW.database_id AND scope_key = NEW.scope_key AND head_seq = NEW.head_seq)
        BEGIN SELECT RAISE(ABORT, 'Snapshots cannot be replaced'); END
        """,
        """
        CREATE TABLE devices (
            id TEXT PRIMARY KEY NOT NULL,
            user_id TEXT NOT NULL REFERENCES users(id),
            name TEXT NOT NULL,
            token_hash TEXT NOT NULL UNIQUE,
            created_at TEXT NOT NULL,
            last_seen_at TEXT NOT NULL,
            revoked_at TEXT
        )
        """,
        """
        CREATE TABLE invites (
            token_hash TEXT PRIMARY KEY NOT NULL,
            group_id TEXT REFERENCES groups(id),
            role TEXT,
            created_by TEXT NOT NULL REFERENCES users(id),
            expires_at TEXT NOT NULL,
            consumed_at TEXT,
            CHECK ((group_id IS NULL AND role IS NULL)
                OR (group_id IS NOT NULL AND role IS NOT NULL AND role IN ('owner', 'editor', 'viewer')))
        )
        """,
        """
        CREATE TABLE login_account_buckets (
            username TEXT PRIMARY KEY NOT NULL \(unsafeRaw: username),
            failures INTEGER NOT NULL CHECK (typeof(failures) = 'integer' AND failures >= 0),
            locked_until TEXT,
            updated_at TEXT NOT NULL
        )
        """,
        """
        CREATE TABLE login_ip_buckets (
            ip TEXT PRIMARY KEY NOT NULL,
            failures INTEGER NOT NULL CHECK (typeof(failures) = 'integer' AND failures >= 0),
            locked_until TEXT,
            updated_at TEXT NOT NULL
        )
        """,
        """
        CREATE TABLE audit_events (
            id TEXT PRIMARY KEY NOT NULL,
            actor_id TEXT REFERENCES users(id),
            action TEXT NOT NULL,
            target TEXT NOT NULL,
            at TEXT NOT NULL
        )
        """,
    ]
}
