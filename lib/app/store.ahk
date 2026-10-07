; One application database and one connection for all user data.
global AppStoreDb := 0
global AppStoreReady := false
global AppStoreError := ""
global AppStoreVersion := 1
global AppStoreFailed := false
global AppStoreTransactionOwner := ""

AppStorePath() => A_ScriptDir . "\data\capslock_p2.db"

AppStoreInit() {
    global AppStoreDb, AppStoreReady, AppStoreError, AppStoreVersion, AppStoreFailed
    if AppStoreReady && IsObject(AppStoreDb)
        return true
    if AppStoreFailed
        return false

    db := 0
    stagingPath := ""
    try {
        dataPath := A_ScriptDir . "\data"
        DirCreate(dataPath)
        if !DirExist(dataPath)
            throw Error("应用数据目录不可写")

        isNew := !FileExist(AppStorePath())
        if isNew && AppStoreSidecarExists(AppStorePath())
            throw Error("应用数据库主文件缺失但仍存在数据库日志；为避免丢失已提交数据，初始化已停止")

        openPath := AppStorePath()
        if isNew {
            stagingPath := dataPath . "\capslock_p2-create-" . A_TickCount
                . "-" . Random(100000, 999999) . ".stage"
            if FileExist(stagingPath)
                throw Error("无法分配唯一的数据库暂存路径")
            openPath := stagingPath
        }
        db := CSQLite(A_ScriptDir . "\resources")
        if !db.OpenDB(openPath, "W", isNew)
            throw Error(db.ErrorMsg != "" ? db.ErrorMsg : "无法打开应用数据库")
        if !db.SetTimeout(2000)
            throw Error(db.ErrorMsg != "" ? db.ErrorMsg : "无法设置数据库等待时间")
        if !db.Exec("PRAGMA foreign_keys=ON; PRAGMA busy_timeout=2000;")
            throw Error(db.ErrorMsg != "" ? db.ErrorMsg : "无法启用数据库约束")
        if isNew && !AppStoreConfigureJournal(db)
            throw Error(db.ErrorMsg != "" ? db.ErrorMsg : "无法配置数据库日志模式")
        if !isNew && !AppStoreConfigureExisting(db)
            throw Error(db.ErrorMsg != "" ? db.ErrorMsg : "无法验证数据库日志模式")

        AppStoreMigrate(db, isNew)
        if isNew {
            if !AppStoreVerifyDatabase(db)
                throw Error("应用数据库完整性检查失败")
            if !db.CloseDB()
                throw Error("无法安全关闭数据库暂存文件：" . db.ErrorMsg)
            db := 0
            if DllCall("Kernel32\MoveFileW", "WStr", stagingPath,
                "WStr", AppStorePath(), "Int") = 0
                throw Error("无法发布已初始化的主数据库，错误代码 " . A_LastError)
            db := CSQLite(A_ScriptDir . "\resources")
            if !db.OpenDB(AppStorePath(), "W", false)
                throw Error(db.ErrorMsg != "" ? db.ErrorMsg : "无法重新打开主数据库")
            if !db.SetTimeout(2000)
                throw Error(db.ErrorMsg != "" ? db.ErrorMsg : "无法设置主数据库等待时间")
            if !db.Exec("PRAGMA foreign_keys=ON; PRAGMA busy_timeout=2000;")
                throw Error(db.ErrorMsg != "" ? db.ErrorMsg : "无法初始化主数据库连接")
            if !AppStoreConfigurePublished(db)
                throw Error(db.ErrorMsg != "" ? db.ErrorMsg : "无法启用主数据库日志模式")
        }
        AppStoreDb := db
        AppStoreReady := true
        return true
    } catch as initError {
        AppStoreError := initError.Message
        AppStoreFailed := true
        if IsObject(db)
            try db.CloseDB()
        AppStoreLogInitializationFailure(Type(initError), initError.Message)
        return false
    }
}

AppStoreLogInitializationFailure(errorType, detail) {
    DiagnosticLogAlways("AppStore initialization failed errorType=" . String(errorType)
        . " detail=" . String(detail))
}

AppStoreConfigureJournal(db) {
    if !db.GetTable("PRAGMA journal_mode=DELETE;", &journal)
        return false
    if !journal.RowCount || StrLower(String(journal.Rows[1][1])) != "delete"
        return false
    return db.Exec("PRAGMA synchronous=FULL;")
}

AppStoreConfigureExisting(db) {
    global AppStoreVersion
    if !db.GetTable("PRAGMA application_id;", &application)
        return false
    if !db.GetTable("PRAGMA user_version;", &version)
        return false
    if !application.RowCount || Integer(application.Rows[1][1]) != 1129335858
        || !version.RowCount || Integer(version.Rows[1][1]) < 1
        || Integer(version.Rows[1][1]) > AppStoreVersion
        return false
    if !db.GetTable("PRAGMA journal_mode;", &journal)
        return false
    if !journal.RowCount
        return false
    if StrLower(String(journal.Rows[1][1])) != "wal" {
        if !db.GetTable("PRAGMA journal_mode=WAL;", &journal)
            return false
        if !journal.RowCount || StrLower(String(journal.Rows[1][1])) != "wal"
            return false
    }
    if !db.Exec("PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON; PRAGMA busy_timeout=2000;")
        return false
    if !db.GetTable("PRAGMA synchronous;", &syncMode)
        return false
    return syncMode.RowCount && Integer(syncMode.Rows[1][1]) = 2
}

AppStoreConfigurePublished(db) {
    if !db.GetTable("PRAGMA journal_mode=WAL;", &journal)
        return false
    if !journal.RowCount || StrLower(String(journal.Rows[1][1])) != "wal"
        return false
    if !db.Exec("PRAGMA synchronous=FULL;")
        return false
    return true
}

AppStoreSidecarExists(databasePath) {
    return FileExist(databasePath . "-wal") || FileExist(databasePath . "-shm")
        || FileExist(databasePath . "-journal")
}

AppStoreMigrate(db, initialize := false) {
    global AppStoreVersion
    if !db.GetTable("PRAGMA application_id;", &idTable)
        throw Error("无法读取应用数据库标识")
    applicationId := idTable.RowCount ? Integer(idTable.Rows[1][1]) : 0
    if applicationId != 0 && applicationId != 1129335858
        throw Error("数据库不属于 capslock_p2")
    if !db.GetTable("PRAGMA user_version;", &versionTable)
        throw Error("无法读取应用数据库版本")
    current := versionTable.RowCount ? Integer(versionTable.Rows[1][1]) : 0
    if current > AppStoreVersion
        throw Error("数据库由较新版本创建，请升级应用后再启动")
    if current = 0 && !initialize
        throw Error("应用数据库缺少有效版本信息")
    if current = AppStoreVersion && !AppStoreValidateRequiredTables(db)
        throw Error("应用数据库缺少必要的数据表")

    if current > 0 && current < AppStoreVersion
        AppStoreBackupDatabase(db)

    schema := "CREATE TABLE IF NOT EXISTS app_meta (key TEXT PRIMARY KEY,value TEXT NOT NULL);"
        . "CREATE TABLE IF NOT EXISTS app_state (key TEXT PRIMARY KEY,value_json TEXT NOT NULL);"
        . "CREATE TABLE IF NOT EXISTS cfg_defaults (scope TEXT NOT NULL,key TEXT NOT NULL,value_json TEXT NOT NULL,PRIMARY KEY(scope,key));"
        . "CREATE TABLE IF NOT EXISTS cfg_values (scope TEXT NOT NULL,key TEXT NOT NULL,value_json TEXT NOT NULL,PRIMARY KEY(scope,key));"
        . "CREATE TABLE IF NOT EXISTS cfg_secrets (scope TEXT NOT NULL,key TEXT NOT NULL,protected_blob BLOB NOT NULL,PRIMARY KEY(scope,key));"
        . "CREATE TABLE IF NOT EXISTS cfg_hotkey_scopes (id TEXT PRIMARY KEY,kind TEXT NOT NULL CHECK(kind IN ('global','application')),exe_path TEXT NOT NULL DEFAULT '',normalized_path TEXT NOT NULL UNIQUE,display_name TEXT NOT NULL,enabled INTEGER NOT NULL CHECK(enabled IN (0,1)));"
        . "CREATE TABLE IF NOT EXISTS cfg_key_overrides (scope_id TEXT NOT NULL,trigger TEXT NOT NULL,action_key TEXT NOT NULL,args_json TEXT NOT NULL DEFAULT '[]',PRIMARY KEY(scope_id,trigger),FOREIGN KEY(scope_id) REFERENCES cfg_hotkey_scopes(id) ON DELETE CASCADE);"
        . "CREATE TABLE IF NOT EXISTS cfg_custom_hotkeys (scope_id TEXT NOT NULL,trigger TEXT NOT NULL,action_kind TEXT NOT NULL,action_value TEXT NOT NULL DEFAULT '',PRIMARY KEY(scope_id,trigger),FOREIGN KEY(scope_id) REFERENCES cfg_hotkey_scopes(id) ON DELETE CASCADE);"
        . "CREATE TABLE IF NOT EXISTS cfg_hotstrings (trigger TEXT PRIMARY KEY,replacement_text TEXT NOT NULL);"
        . "CREATE TABLE IF NOT EXISTS cfg_window_bindings (slot INTEGER PRIMARY KEY CHECK(slot BETWEEN 1 AND 10),mode INTEGER NOT NULL CHECK(mode IN (1,2,3)),application_path TEXT NOT NULL DEFAULT '');"
        . "CREATE TABLE IF NOT EXISTS cfg_window_targets (slot INTEGER NOT NULL,ordinal INTEGER NOT NULL CHECK(ordinal>0),exe_path TEXT NOT NULL DEFAULT '',exe_name TEXT NOT NULL DEFAULT '',window_class TEXT NOT NULL DEFAULT '',PRIMARY KEY(slot,ordinal),FOREIGN KEY(slot) REFERENCES cfg_window_bindings(slot) ON DELETE CASCADE);"

    if !db.Exec("BEGIN IMMEDIATE;")
        throw Error(db.ErrorMsg != "" ? db.ErrorMsg : "无法开始应用数据库升级")
    try {
        if !db.Exec(schema)
            throw Error(db.ErrorMsg != "" ? db.ErrorMsg : "无法创建应用数据库结构")
        AppStoreEnsureContentSchemas(db)
        SettingsStoreCreateGlobalScope(db)
        if current = 0 {
            if !db.Exec("PRAGMA application_id=1129335858;")
                throw Error(db.ErrorMsg != "" ? db.ErrorMsg : "无法写入数据库标识")
            AppStoreSeedMetadata(db)
        }
        if current < AppStoreVersion {
            ; A version step commits the schema and its trusted default set atomically.
            SettingsStoreSyncDefaults(db)
            QbarStoreSyncCatalog(db)
            if !db.Exec("PRAGMA user_version=" . AppStoreVersion . ";")
                throw Error(db.ErrorMsg != "" ? db.ErrorMsg : "无法写入数据库版本")
        }
        SettingsStoreUpgradeDefaultSet(db)
        if current < AppStoreVersion && !AppStoreVerifyDatabase(db)
            throw Error("数据库校验失败，未发布初始化结果")
        if !db.Exec("COMMIT;")
            throw Error(db.ErrorMsg != "" ? db.ErrorMsg : "无法提交应用数据库升级")
    } catch as migrationError {
        if !db.Exec("ROLLBACK;")
            throw Error(migrationError.Message . "; 回滚失败，数据库连接状态不确定")
        throw migrationError
    }
    return true
}

AppStoreBackupDatabase(sourceDb) {
    backupRoot := A_ScriptDir . "\data\backups"
    DirCreate(backupRoot)
    if !DirExist(backupRoot)
        throw Error("无法创建数据库升级备份目录")
    backupPath := backupRoot . "\capslock_p2-before-upgrade-" . A_TickCount
        . "-" . Random(100000, 999999) . ".db"
    if FileExist(backupPath)
        throw Error("数据库备份路径已存在")
    backupDb := CSQLite(A_ScriptDir . "\resources")
    backup := 0
    try {
        if !backupDb.OpenDB(backupPath, "W", true)
            throw Error(backupDb.ErrorMsg != "" ? backupDb.ErrorMsg : "无法创建数据库备份")
        if !backupDb.SetTimeout(2000)
            throw Error(backupDb.ErrorMsg != "" ? backupDb.ErrorMsg : "无法设置备份等待时间")
        backup := DllCall("SQLite3.dll\sqlite3_backup_init", "Ptr", backupDb.ptr,
            "AStr", "main", "Ptr", sourceDb.ptr, "AStr", "main", "Cdecl Ptr")
        if !backup
            throw Error("SQLite 备份无法开始：" . AppStoreSQLiteError(backupDb))
        stepCode := 0
        busyRetries := 0
        Loop {
            stepCode := DllCall("SQLite3.dll\sqlite3_backup_step", "Ptr", backup,
                "Int", -1, "Cdecl Int")
            if stepCode = 101
                break
            if stepCode = 0 {
                Sleep(1)
                continue
            }
            if stepCode != 5 && stepCode != 6
                throw Error("SQLite 备份失败，代码 " . stepCode)
            busyRetries += 1
            if busyRetries >= 20
                throw Error("数据库持续被占用，备份未能完成")
            Sleep(50)
        }
        finishCode := DllCall("SQLite3.dll\sqlite3_backup_finish", "Ptr", backup, "Cdecl Int")
        backup := 0
        if stepCode != 101 || finishCode != 0
            throw Error("SQLite 备份未能安全完成，代码 " . finishCode)
        if !AppStoreVerifyDatabase(backupDb)
            throw Error("数据库升级备份未通过完整性校验")
        if !backupDb.CloseDB()
            throw Error("无法关闭数据库备份：" . backupDb.ErrorMsg)
        return backupPath
    } catch as backupError {
        if backup
            try DllCall("SQLite3.dll\sqlite3_backup_finish", "Ptr", backup, "Cdecl Int")
        if IsObject(backupDb)
            try backupDb.CloseDB()
        DebugLog("AppStore backup failed errorType=" . Type(backupError)
            . " detail=" . backupError.Message)
        throw backupError
    }
}

AppStoreSQLiteError(db) {
    if IsObject(db) && db.ptr {
        pointer := DllCall("SQLite3.dll\sqlite3_errmsg", "Ptr", db.ptr, "Cdecl Ptr")
        if pointer
            return StrGet(pointer, "UTF-8")
    }
    return IsObject(db) && db.ErrorMsg != "" ? db.ErrorMsg : "未知 SQLite 错误"
}

AppStoreValidateRequiredTables(db) {
    tables := ["app_meta", "app_state", "cfg_defaults", "cfg_values", "cfg_secrets",
        "cfg_hotkey_scopes", "cfg_key_overrides", "cfg_custom_hotkeys", "cfg_hotstrings",
        "cfg_window_bindings", "cfg_window_targets", "plugin_definitions", "plugins",
        "commands", "command_aliases", "plugin_settings", "plugin_state", "command_usage",
        "command_history", "notes", "tags", "note_tags", "note_assets", "clipboard_items",
        "clipboard_payloads", "clipboard_thumbnails", "ai_chat_sessions", "ai_chat_turns"]
    for tableName in tables {
        sql := "SELECT count(*) FROM sqlite_master WHERE type='table' AND name="
            . AppStoreSql(tableName) . ";"
        if !db.GetTable(sql, &row) || !row.RowCount || Integer(row.Rows[1][1]) != 1
            return false
    }
    return true
}

AppStoreVerifyDatabase(db) {
    if !db.GetTable("PRAGMA integrity_check;", &integrity)
        return false
    if integrity.RowCount != 1 || integrity.Rows[1].Length < 1
        || String(integrity.Rows[1][1]) != "ok"
        return false
    if !db.GetTable("PRAGMA foreign_key_check;", &foreignKeys)
        return false
    return foreignKeys.RowCount = 0
}

AppStoreEnsureContentSchemas(db) {
    QbarStoreMigrate(db)
    NotesStoreEnsureSchema(db)
    ClipboardHistoryStoreEnsureSchema(db)
    AiChatStoreEnsureSchema(db)
}

AppStoreSeedMetadata(db) {
    createdAt := FormatTime(A_NowUTC, "yyyy-MM-ddTHH:mm:ssZ")
    for key, value in Map("database_id", "capslock_p2-user-data", "created_at", createdAt,
        "settings_revision", "1", "migration_sources", "[]",
        "settings_defaults_version", String(SettingsStoreSourceVersion)) {
        sql := "INSERT INTO app_meta(key,value) VALUES (" . AppStoreSql(key) . ","
            . AppStoreSql(value) . ");"
        if !db.Exec(sql)
            throw Error(db.ErrorMsg != "" ? db.ErrorMsg : "无法初始化应用数据库信息")
    }
}

SettingsStoreUpgradeDefaultSet(db) {
    if !db.GetTable("SELECT value FROM app_meta WHERE key='settings_defaults_version';", &rows)
        throw Error(db.ErrorMsg != "" ? db.ErrorMsg : "无法读取默认设置版本")
    current := rows.RowCount ? Integer(rows.Rows[1][1]) : 0
    if current > SettingsStoreSourceVersion
        throw Error("数据库默认设置由较新版本创建")
    if current < SettingsStoreSourceVersion {
        SettingsStoreSyncDefaults(db)
        if current < 3
            SettingsStoreRetireSelectedTextAction(db)
        QbarStoreSyncCatalog(db)
        if !db.Exec("INSERT INTO app_meta(key,value) VALUES ('settings_defaults_version',"
            . AppStoreSql(String(SettingsStoreSourceVersion))
            . ") ON CONFLICT(key) DO UPDATE SET value=excluded.value;")
            throw Error(db.ErrorMsg != "" ? db.ErrorMsg : "无法更新默认设置版本")
    }
    return true
}

AppStoreIncrementSettingsRevision(db) {
    if !db.Exec("UPDATE app_meta SET value=CAST(value AS INTEGER)+1 WHERE key='settings_revision';")
        throw Error(db.ErrorMsg != "" ? db.ErrorMsg : "无法更新设置版本")
    if db.Changes() != 1
        throw Error("设置版本记录缺失")
    return true
}

AppStoreSettingsRevision() {
    global AppStoreDb, AppStoreReady
    if !AppStoreReady || !IsObject(AppStoreDb)
        return 0
    if !AppStoreDb.GetTable("SELECT value FROM app_meta WHERE key='settings_revision';", &rows)
        throw Error(AppStoreDb.ErrorMsg != "" ? AppStoreDb.ErrorMsg : "无法读取设置版本")
    if !rows.RowCount
        throw Error("设置版本记录缺失")
    return Integer(rows.Rows[1][1])
}

AppStoreSql(value) => "'" . StrReplace(String(value), "'", "''") . "'"

AppStoreTransaction(owner, callback) {
    global AppStoreDb, AppStoreReady, AppStoreTransactionOwner
    if !AppStoreReady || !IsObject(AppStoreDb) || AppStoreTransactionOwner != ""
        return false
    state := Critical("On")
    AppStoreTransactionOwner := String(owner)
    try {
        if !AppStoreDb.Exec("BEGIN IMMEDIATE;")
            throw Error(AppStoreDb.ErrorMsg != "" ? AppStoreDb.ErrorMsg : "无法开始保存")
        try {
            result := callback.Call()
            if !result
                throw Error("保存操作未能完成")
            if !AppStoreDb.Exec("COMMIT;")
                throw Error("数据库提交失败：" . AppStoreDb.ErrorMsg)
            return true
        } catch as transactionError {
            if !AppStoreDb.Exec("ROLLBACK;")
                AppStorePoison()
            throw transactionError
        }
    } catch as storeError {
        DiagnosticLogAlways("AppStore transaction failed owner=" . String(owner)
            . " errorType=" . Type(storeError) . " detail=" . storeError.Message)
        return false
    } finally {
        AppStoreTransactionOwner := ""
        Critical(state)
    }
}

AppStorePoison() {
    global AppStoreReady, AppStoreFailed, AppStoreError
    AppStoreReady := false
    AppStoreFailed := true
    AppStoreError := "数据库事务回滚失败，需重新启动应用"
}

AppStoreShutdown() {
    global AppStoreDb, AppStoreReady
    if IsObject(AppStoreDb) && !AppStoreDb.CloseDB()
        DebugLog("AppStore close failed detail=" . AppStoreDb.ErrorMsg)
    AppStoreDb := 0
    AppStoreReady := false
}
