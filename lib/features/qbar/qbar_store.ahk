; Qbar SQLite store.
;
; This module owns the Qbar persistence boundary. The database is created from
; this schema and does not depend on the INI command sections.
; Runtime queries use the in-memory registry; SQLite is only touched while
; registering plugins, changing settings, and recording completed actions.

global QbarStoreDb := 0
global QbarStoreReady := false
global QbarStoreError := ""
global QbarStoreSchemaVersion := 1
global QbarStoreRoot := A_ScriptDir . "\data"

QbarStorePath() => AppStorePath()

; AppStore owns the surrounding initialization/upgrade transaction. Reuse the
; catalog writer without publishing its candidate or opening another connection.
QbarStoreSyncCatalog(db) {
    global QbarStoreDb, QbarStoreReady
    previousDb := QbarStoreDb
    previousReady := QbarStoreReady
    try {
        QbarStoreDb := db
        QbarStoreReady := true
        return QbarPluginHostRegisterCatalog(&candidate, true, true)
    } finally {
        QbarStoreDb := previousDb
        QbarStoreReady := previousReady
    }
}

QbarStoreInit() {
    global QbarStoreDb, QbarStoreReady, QbarStoreError, AppStoreDb, AppStoreError
    if QbarStoreReady && IsObject(QbarStoreDb)
        return true
    try {
        if !AppStoreInit()
            throw Error(AppStoreError != "" ? AppStoreError : "无法初始化应用数据库")
        QbarStoreDb := AppStoreDb
        QbarStoreReady := true
        return true
    } catch as initError {
        QbarStoreError := initError.Message
        QbarStoreDb := 0
        QbarStoreReady := false
        DebugLog("Qbar AppStore attach failed detail=" . initError.Message)
        try ShowMsg(QbarStoreError, 8000)
        return false
    }
}

QbarStoreMigrate(db) {
    schema := ""
    schema .= "CREATE TABLE IF NOT EXISTS plugin_definitions ("
        . "id TEXT PRIMARY KEY,"
        . "source TEXT NOT NULL,"
        . "version INTEGER NOT NULL,"
        . "name TEXT NOT NULL,"
        . "icon TEXT NOT NULL DEFAULT '',"
        . "capabilities_json TEXT NOT NULL DEFAULT '[]',"
        . "settings_schema_json TEXT NOT NULL DEFAULT '{}',"
        . "manifest_json TEXT NOT NULL DEFAULT '{}',"
        . "trust_level TEXT NOT NULL,"
        . "available INTEGER NOT NULL DEFAULT 1,"
        . "installed_at TEXT NOT NULL,"
        . "updated_at TEXT NOT NULL);"
    schema .= "CREATE TABLE IF NOT EXISTS plugins ("
        . "id TEXT PRIMARY KEY,"
        . "definition_id TEXT NOT NULL,"
        . "source TEXT NOT NULL,"
        . "display_name TEXT NOT NULL,"
        . "enabled INTEGER NOT NULL DEFAULT 1,"
        . "deleted_at TEXT NOT NULL DEFAULT '',"
        . "installed_at TEXT NOT NULL,"
        . "updated_at TEXT NOT NULL,"
        . "FOREIGN KEY(definition_id) REFERENCES plugin_definitions(id));"
    schema .= "CREATE TABLE IF NOT EXISTS commands ("
        . "id TEXT PRIMARY KEY,"
        . "plugin_id TEXT NOT NULL,"
        . "title TEXT NOT NULL,"
        . "kind TEXT NOT NULL,"
        . "handler_id TEXT NOT NULL,"
        . "arg_mode TEXT NOT NULL,"
        . "priority INTEGER NOT NULL DEFAULT 100,"
        . "enabled INTEGER NOT NULL DEFAULT 1,"
        . "usage_key TEXT NOT NULL,"
        . "deleted_at TEXT NOT NULL DEFAULT '',"
        . "created_at TEXT NOT NULL,"
        . "updated_at TEXT NOT NULL,"
        . "FOREIGN KEY(plugin_id) REFERENCES plugins(id) ON DELETE CASCADE);"
    schema .= "CREATE TABLE IF NOT EXISTS command_aliases ("
        . "command_id TEXT NOT NULL,"
        . "alias TEXT NOT NULL,"
        . "normalized_alias TEXT NOT NULL,"
        . "origin TEXT NOT NULL,"
        . "enabled INTEGER NOT NULL DEFAULT 1,"
        . "is_default INTEGER NOT NULL DEFAULT 0,"
        . "created_at TEXT NOT NULL,"
        . "updated_at TEXT NOT NULL,"
        . "PRIMARY KEY(command_id, normalized_alias),"
        . "FOREIGN KEY(command_id) REFERENCES commands(id) ON DELETE CASCADE);"
    schema .= "CREATE TABLE IF NOT EXISTS plugin_settings ("
        . "plugin_id TEXT PRIMARY KEY,"
        . "schema_version INTEGER NOT NULL,"
        . "values_json TEXT NOT NULL DEFAULT '{}',"
        . "pending_restart INTEGER NOT NULL DEFAULT 0,"
        . "updated_at TEXT NOT NULL,"
        . "FOREIGN KEY(plugin_id) REFERENCES plugins(id) ON DELETE CASCADE);"
    schema .= "CREATE TABLE IF NOT EXISTS plugin_state ("
        . "plugin_id TEXT PRIMARY KEY,"
        . "schema_version INTEGER NOT NULL,"
        . "state_json TEXT NOT NULL DEFAULT '{}',"
        . "updated_at TEXT NOT NULL,"
        . "FOREIGN KEY(plugin_id) REFERENCES plugins(id) ON DELETE CASCADE);"
    schema .= "CREATE TABLE IF NOT EXISTS command_usage ("
        . "usage_key TEXT PRIMARY KEY,"
        . "command_id TEXT NOT NULL,"
        . "candidate_key TEXT NOT NULL DEFAULT '',"
        . "score REAL NOT NULL DEFAULT 0,"
        . "use_count INTEGER NOT NULL DEFAULT 0,"
        . "last_used_at TEXT NOT NULL DEFAULT '',"
        . "FOREIGN KEY(command_id) REFERENCES commands(id) ON DELETE CASCADE);"
    schema .= "CREATE TABLE IF NOT EXISTS command_history ("
        . "id TEXT PRIMARY KEY,"
        . "command_id TEXT NOT NULL,"
        . "plugin_id TEXT NOT NULL,"
        . "command_title TEXT NOT NULL,"
        . "candidate_key TEXT NOT NULL DEFAULT '',"
        . "input_text TEXT NOT NULL,"
        . "args_json TEXT NOT NULL DEFAULT '{}',"
        . "payload_json TEXT NOT NULL DEFAULT '{}',"
        . "replayable INTEGER NOT NULL DEFAULT 1,"
        . "created_at TEXT NOT NULL,"
        . "last_used_at TEXT NOT NULL,"
        . "FOREIGN KEY(command_id) REFERENCES commands(id) ON DELETE CASCADE);"
    schema .= "CREATE INDEX IF NOT EXISTS commands_plugin_idx ON commands(plugin_id);"
        . "CREATE INDEX IF NOT EXISTS aliases_lookup_idx ON command_aliases(normalized_alias, enabled);"
        . "CREATE INDEX IF NOT EXISTS usage_command_idx ON command_usage(command_id);"
        . "CREATE INDEX IF NOT EXISTS history_command_idx ON command_history(command_id, last_used_at);"

    if !db.Exec(schema)
        throw Error(db.ErrorMsg != "" ? db.ErrorMsg : "创建 Qbar 数据库结构失败")

    return true
}

QbarStoreClose() {
    global QbarStoreDb, QbarStoreReady
    QbarStoreDb := 0
    QbarStoreReady := false
}

QbarStoreBegin() {
    return QbarStoreExec("BEGIN IMMEDIATE;")
}

QbarStoreCommit() {
    return QbarStoreExec("COMMIT;")
}

QbarStoreRollback() {
    return QbarStoreExec("ROLLBACK;")
}

QbarStoreExec(sql) {
    global QbarStoreDb, QbarStoreReady, QbarStoreError
    QbarStoreError := ""
    if !QbarStoreReady || !IsObject(QbarStoreDb) {
        QbarStoreError := "Qbar 数据库尚未初始化"
        return false
    }
    if QbarStoreDb.Exec(sql)
        return true
    QbarStoreError := QbarStoreDb.ErrorMsg != "" ? QbarStoreDb.ErrorMsg : "SQLite 执行失败"
    DebugLog("Qbar SQLite exec failed: " . QbarStoreError)
    return false
}

QbarStoreRows(sql, &table := 0) {
    global QbarStoreDb, QbarStoreReady, QbarStoreError
    table := 0
    QbarStoreError := ""
    if !QbarStoreReady || !IsObject(QbarStoreDb) {
        QbarStoreError := "Qbar 数据库尚未初始化"
        return false
    }
    if QbarStoreDb.GetTable(sql, &table, -1)
        return true
    QbarStoreError := QbarStoreDb.ErrorMsg != "" ? QbarStoreDb.ErrorMsg : "SQLite 查询失败"
    DebugLog("Qbar SQLite query failed: " . QbarStoreError)
    return false
}

QbarStoreRowMap(table, row) {
    result := Map()
    if !IsObject(table) || !table.HasOwnProp("Cols") || !IsObject(row)
        return result
    for index, column in table.Cols
        result[column] := index <= row.Length ? String(row[index]) : ""
    return result
}

QbarStoreLoadRuntimeRows(&rows) {
    rows := []
    if !QbarStoreRows("SELECT p.id AS plugin_id,p.definition_id,p.source AS plugin_source,p.display_name,p.enabled AS plugin_enabled,"
        . "p.deleted_at AS plugin_deleted,d.name AS plugin_name,d.icon AS plugin_icon,"
        . "d.capabilities_json,d.settings_schema_json,d.trust_level,d.available,"
        . "c.id AS command_id,c.title AS command_title,c.kind,c.handler_id,c.arg_mode,c.priority,"
        . "c.enabled AS command_enabled,c.usage_key,c.deleted_at AS command_deleted,"
        . "COALESCE(a.alias,'') AS alias,COALESCE(a.normalized_alias,'') AS normalized_alias,"
        . "COALESCE(a.origin,'') AS origin,COALESCE(a.is_default,0) AS is_default,"
        . "COALESCE(a.enabled,0) AS alias_enabled "
        . "FROM plugins p JOIN plugin_definitions d ON d.id=p.definition_id "
        . "JOIN commands c ON c.plugin_id=p.id "
        . "LEFT JOIN command_aliases a ON a.command_id=c.id "
        . "ORDER BY c.id,a.normalized_alias;", &table)
        return false
    for raw in table.Rows
        rows.Push(QbarStoreRowMap(table, raw))
    return true
}

QbarStoreUpsertDefinition(definition) {
    if !IsObject(definition) || !definition.Has("definitionId")
        return false
    definitionId := String(definition["definitionId"])
    source := definition.Has("source") ? String(definition["source"]) : "builtin"
    version := definition.Has("version") ? Integer(definition["version"]) : 1
    name := definition.Has("name") ? String(definition["name"]) : definitionId
    icon := definition.Has("icon") ? String(definition["icon"]) : ""
    capabilities := definition.Has("capabilities") ? definition["capabilities"] : []
    settingsSchema := definition.Has("settingsSchema") ? definition["settingsSchema"] : Map()
    trustLevel := definition.Has("trustLevel") ? String(definition["trustLevel"]) : "host-declarative"
    available := definition.Has("available") && !definition["available"] ? 0 : 1
    now := QbarStoreNow()
    manifestJson := JSON.stringify(definition, 0)
    sql := "INSERT OR IGNORE INTO plugin_definitions(id,source,version,name,icon,capabilities_json,"
        . "settings_schema_json,manifest_json,trust_level,available,installed_at,updated_at) VALUES ("
        . QbarStoreSql(definitionId) . "," . QbarStoreSql(source) . "," . version . ","
        . QbarStoreSql(name) . "," . QbarStoreSql(icon) . ","
        . QbarStoreSql(JSON.stringify(capabilities, 0)) . ","
        . QbarStoreSql(JSON.stringify(settingsSchema, 0)) . ","
        . QbarStoreSql(manifestJson) . "," . QbarStoreSql(trustLevel) . "," . available . ","
        . QbarStoreSql(now) . "," . QbarStoreSql(now) . ");"
    if !QbarStoreExec(sql)
        return false
    return QbarStoreExec("UPDATE plugin_definitions SET source=" . QbarStoreSql(source)
        . ",version=" . version . ",name=" . QbarStoreSql(name)
        . ",icon=" . QbarStoreSql(icon) . ",capabilities_json="
        . QbarStoreSql(JSON.stringify(capabilities, 0)) . ",settings_schema_json="
        . QbarStoreSql(JSON.stringify(settingsSchema, 0)) . ",manifest_json="
        . QbarStoreSql(manifestJson) . ",trust_level=" . QbarStoreSql(trustLevel)
        . ",available=" . available . ",updated_at=" . QbarStoreSql(now)
        . " WHERE id=" . QbarStoreSql(definitionId) . ";")
}

QbarStoreUpsertPlugin(plugin) {
    if !IsObject(plugin) || !plugin.Has("pluginId") || !plugin.Has("definitionId")
        return false
    pluginId := String(plugin["pluginId"])
    definitionId := String(plugin["definitionId"])
    source := plugin.Has("source") ? String(plugin["source"]) : "builtin"
    displayName := plugin.Has("displayName") ? String(plugin["displayName"]) : ""
    enabled := true
    if plugin.Has("enabled") && !QbarPluginHostParseBoolean(plugin["enabled"], &enabled)
        return false
    enabled := enabled ? 1 : 0
    now := QbarStoreNow()
    if !QbarStoreExec("INSERT OR IGNORE INTO plugins(id,definition_id,source,display_name,enabled,deleted_at,"
        . "installed_at,updated_at) VALUES (" . QbarStoreSql(pluginId) . ","
        . QbarStoreSql(definitionId) . "," . QbarStoreSql(source) . ","
        . QbarStoreSql(displayName) . "," . enabled . ",''," . QbarStoreSql(now) . ","
        . QbarStoreSql(now) . ");")
        return false
    return QbarStoreExec("UPDATE plugins SET definition_id=" . QbarStoreSql(definitionId)
        . ",source=" . QbarStoreSql(source)
        . ",updated_at=" . QbarStoreSql(now) . " WHERE id=" . QbarStoreSql(pluginId) . ";")
}

QbarStoreRetirePlugin(pluginId) {
    if pluginId = ""
        return false
    now := QbarStoreNow()
    if !QbarStoreExec("UPDATE command_aliases SET enabled=0,origin='retired',updated_at="
        . QbarStoreSql(now) . " WHERE command_id IN (SELECT id FROM commands WHERE plugin_id="
        . QbarStoreSql(pluginId) . ");")
        return false
    if !QbarStoreExec("UPDATE commands SET enabled=0,deleted_at=" . QbarStoreSql(now)
        . ",updated_at=" . QbarStoreSql(now) . " WHERE plugin_id=" . QbarStoreSql(pluginId) . ";")
        return false
    if !QbarStoreExec("UPDATE command_history SET replayable=0 WHERE plugin_id="
        . QbarStoreSql(pluginId) . ";")
        return false
    return QbarStoreExec("UPDATE plugins SET enabled=0,deleted_at=" . QbarStoreSql(now)
        . ",updated_at=" . QbarStoreSql(now) . " WHERE id=" . QbarStoreSql(pluginId) . ";")
}

QbarStoreSetPluginDisplayName(pluginId, displayName) {
    displayName := Trim(String(displayName))
    if pluginId = "" || displayName = ""
        return false
    return QbarStoreExec("UPDATE plugins SET display_name=" . QbarStoreSql(displayName)
        . ",updated_at=" . QbarStoreSql(QbarStoreNow())
        . " WHERE id=" . QbarStoreSql(pluginId) . ";")
}

QbarStoreUpsertCommand(pluginId, command) {
    if !IsObject(command) || !command.Has("id")
        return false
    commandId := String(command["id"])
    title := command.Has("title") ? String(command["title"]) : commandId
    kind := command.Has("kind") ? String(command["kind"]) : "tool"
    handlerId := command.Has("handlerId") ? String(command["handlerId"]) : ""
    argMode := command.Has("argMode") ? String(command["argMode"]) : "optional"
    priority := command.Has("priority") ? Integer(command["priority"]) : 100
    usageKey := command.Has("usageKey") ? String(command["usageKey"]) : commandId
    now := QbarStoreNow()
    if !QbarStoreExec("INSERT OR IGNORE INTO commands(id,plugin_id,title,kind,handler_id,arg_mode,priority,"
        . "enabled,usage_key,deleted_at,created_at,updated_at) VALUES ("
        . QbarStoreSql(commandId) . "," . QbarStoreSql(pluginId) . ","
        . QbarStoreSql(title) . "," . QbarStoreSql(kind) . "," . QbarStoreSql(handlerId) . ","
        . QbarStoreSql(argMode) . "," . priority . ",1," . QbarStoreSql(usageKey) . ",'',"
        . QbarStoreSql(now) . "," . QbarStoreSql(now) . ");")
        return false
    return QbarStoreExec("UPDATE commands SET plugin_id=" . QbarStoreSql(pluginId)
        . ",title=" . QbarStoreSql(title) . ",kind=" . QbarStoreSql(kind)
        . ",handler_id=" . QbarStoreSql(handlerId) . ",arg_mode=" . QbarStoreSql(argMode)
        . ",priority=" . priority . ",usage_key=" . QbarStoreSql(usageKey)
        . ",updated_at=" . QbarStoreSql(now) . " WHERE id=" . QbarStoreSql(commandId) . ";")
}

QbarStoreEnsureAlias(commandId, alias, origin := "manifest-default", isDefault := true) {
    normalized := QbarNormalizeAlias(alias)
    if normalized = "" || InStr(alias, "`n") || InStr(alias, "`r")
        return false
    now := QbarStoreNow()
    return QbarStoreExec("INSERT OR IGNORE INTO command_aliases(command_id,alias,normalized_alias,origin,"
        . "enabled,is_default,created_at,updated_at) VALUES ("
        . QbarStoreSql(commandId) . "," . QbarStoreSql(String(alias)) . ","
        . QbarStoreSql(normalized) . "," . QbarStoreSql(origin) . ",1,"
        . (isDefault ? 1 : 0) . "," . QbarStoreSql(now) . "," . QbarStoreSql(now) . ");")
}

QbarStoreRemoveManifestAlias(commandId, alias) {
    normalized := QbarNormalizeAlias(alias)
    if commandId = "" || normalized = ""
        return false
    return QbarStoreExec("DELETE FROM command_aliases WHERE command_id="
        . QbarStoreSql(commandId) . " AND normalized_alias="
        . QbarStoreSql(normalized) . " AND origin='manifest-default';")
}

QbarStoreRememberUsage(usageKey, commandId, candidateKey := "") {
    if usageKey = "" || commandId = ""
        return false
    score := 0.0
    useCount := 0
    if QbarStoreRows("SELECT score,use_count,last_used_at FROM command_usage WHERE usage_key="
        . QbarStoreSql(usageKey) . ";", &table) && table.RowCount > 0 {
        row := QbarStoreRowMap(table, table.Rows[1])
        score := QbarStoreFloat(row["score"], 0)
        useCount := QbarStoreInteger(row["use_count"], 0)
        lastUsedAt := row["last_used_at"]
        if lastUsedAt != "" {
            try {
                elapsed := DateDiff(A_NowUTC, QbarStoreCompactUtc(lastUsedAt), "Seconds")
                if elapsed > 0
                    score *= 2 ** (0 - elapsed / 604800)
            } catch
                score := 0
        }
    }
    score += 1
    now := QbarStoreNow()
    return QbarStoreExec("INSERT OR REPLACE INTO command_usage(usage_key,command_id,candidate_key,score,"
        . "use_count,last_used_at) VALUES (" . QbarStoreSql(usageKey) . ","
        . QbarStoreSql(commandId) . "," . QbarStoreSql(candidateKey) . "," . score . ","
        . (useCount + 1) . "," . QbarStoreSql(now) . ");")
}

QbarStoreApplyCommandAliases(commandId, aliases) {
    if commandId = "" || Type(aliases) != "Array"
        return false
    now := QbarStoreNow()
    if !QbarStoreExec("UPDATE command_aliases SET enabled=0,origin='user',updated_at="
        . QbarStoreSql(now) . " WHERE command_id=" . QbarStoreSql(commandId) . ";")
        return false
    seen := Map()
    for alias in aliases {
        if Type(alias) != "String"
            return false
        normalized := QbarNormalizeAlias(alias)
        if normalized = "" || InStr(alias, "`n") || InStr(alias, "`r")
            return false
        if seen.Has(normalized)
            continue
        seen[normalized] := true
        if !QbarStoreExec("INSERT OR REPLACE INTO command_aliases(command_id,alias,normalized_alias,"
            . "origin,enabled,is_default,created_at,updated_at) VALUES ("
            . QbarStoreSql(commandId) . "," . QbarStoreSql(alias) . ","
            . QbarStoreSql(normalized) . ",'user',1,0," . QbarStoreSql(now) . ","
            . QbarStoreSql(now) . ");")
            return false
    }
    return true
}

QbarStoreSetPluginEnabled(pluginId, enabled) {
    if pluginId = ""
        return false
    return QbarStoreExec("UPDATE plugins SET enabled=" . (enabled ? 1 : 0)
        . ",updated_at=" . QbarStoreSql(QbarStoreNow())
        . " WHERE id=" . QbarStoreSql(pluginId) . ";")
}

QbarStoreEnsurePluginSettings(pluginId, schemaVersion := 1, values := 0) {
    if pluginId = ""
        return false
    valuesJson := IsObject(values) ? JSON.stringify(values, 0) : "{}"
    now := QbarStoreNow()
    return QbarStoreExec("INSERT OR IGNORE INTO plugin_settings(plugin_id,schema_version,values_json,"
        . "pending_restart,updated_at) VALUES (" . QbarStoreSql(pluginId) . ","
        . Integer(schemaVersion) . "," . QbarStoreSql(valuesJson) . ",0,"
        . QbarStoreSql(now) . ");")
}

QbarStoreSetPluginSettings(pluginId, values, schemaVersion := 1, pendingRestart := false) {
    if pluginId = "" || !IsObject(values)
        return false
    now := QbarStoreNow()
    return QbarStoreExec("INSERT OR REPLACE INTO plugin_settings(plugin_id,schema_version,values_json,"
        . "pending_restart,updated_at) VALUES (" . QbarStoreSql(pluginId) . ","
        . Integer(schemaVersion) . "," . QbarStoreSql(JSON.stringify(values, 0)) . ","
        . (pendingRestart ? 1 : 0) . "," . QbarStoreSql(now) . ");")
}

QbarStoreLoadPluginSettings(&settings, &invalidPluginSettings) {
    global QbarStoreError
    settings := Map()
    invalidPluginSettings := Map()
    if !QbarStoreRows("SELECT plugin_id,values_json FROM plugin_settings;", &table)
        return false
    for raw in table.Rows {
        row := QbarStoreRowMap(table, raw)
        try values := JSON.Parse(row["values_json"], false, true)
        catch {
            invalidPluginSettings[row["plugin_id"]] := true
            DebugLog("Qbar plugin settings JSON invalid plugin=" . row["plugin_id"])
            continue
        }
        if Type(values) != "Map" {
            invalidPluginSettings[row["plugin_id"]] := true
            DebugLog("Qbar plugin settings JSON is not a map plugin=" . row["plugin_id"])
            continue
        }
        settings[row["plugin_id"]] := values
    }
    return true
}

QbarStoreLoadUsageRows(&rows) {
    rows := []
    if !QbarStoreRows("SELECT usage_key,command_id,candidate_key,score,use_count,last_used_at "
        . "FROM command_usage;", &table)
        return false
    for raw in table.Rows
        rows.Push(QbarStoreRowMap(table, raw))
    return true
}

QbarStoreLoadHistoryRows(&rows, limit := 10) {
    rows := []
    limit := Max(1, Min(100, Integer(limit)))
    if !QbarStoreRows("SELECT h.id,h.command_id,h.plugin_id,h.command_title,h.candidate_key,"
        . "h.input_text,h.args_json,h.payload_json,h.replayable,h.created_at,h.last_used_at,c.handler_id "
        . "FROM command_history h LEFT JOIN commands c ON c.id=h.command_id "
        . "ORDER BY h.last_used_at DESC,h.id DESC LIMIT " . limit . ";", &table)
        return false
    for raw in table.Rows
        rows.Push(QbarStoreRowMap(table, raw))
    return true
}

; A run command's elevation flag changes the stored command text ("*RunAs"),
; but it does not make a different Qbar command or a different set of arguments.
; Keep only the latest persisted row for each run command ID and argument set.
QbarStoreDeduplicateRunHistory() {
    sql := "DELETE FROM command_history WHERE id IN ("
        . "SELECT older.id FROM command_history AS older "
        . "JOIN commands AS command ON command.id=older.command_id "
        . "WHERE command.handler_id='builtin.run' AND EXISTS ("
        . "SELECT 1 FROM command_history AS newer "
        . "WHERE newer.command_id=older.command_id AND newer.args_json=older.args_json "
        . "AND (newer.last_used_at>older.last_used_at "
        . "OR (newer.last_used_at=older.last_used_at AND newer.id>older.id))));"
    return QbarStoreExec(sql)
}

QbarStoreSaveHistoryEntry(entry, command) {
    if !IsObject(entry) || !IsObject(command)
        return false
    id := entry.Has("id") ? String(entry["id"]) : ""
    if id = ""
        return false
    payload := entry.Has("payload") && IsObject(entry["payload"]) ? entry["payload"] : Map()
    args := entry.Has("args") && IsObject(entry["args"]) ? entry["args"] : Map()
    pluginId := command["pluginId"]
    title := entry.Has("label") && String(entry["label"]) != ""
        ? String(entry["label"]) : command["displayName"]
    candidateKey := entry.Has("candidateKey") ? String(entry["candidateKey"]) : ""
    input := entry.Has("input") ? String(entry["input"]) : ""
    now := QbarStoreNow()
    createdAt := entry.Has("createdAt") && String(entry["createdAt"]) != ""
        ? entry["createdAt"] : now
    replayable := entry.Has("replayable") && QbarHistoryBoolValue(entry["replayable"]) ? 1 : 0
    return QbarStoreExec("INSERT OR REPLACE INTO command_history(id,command_id,plugin_id,command_title,"
        . "candidate_key,input_text,args_json,payload_json,replayable,created_at,last_used_at) VALUES ("
        . QbarStoreSql(id) . "," . QbarStoreSql(command["commandId"]) . ","
        . QbarStoreSql(pluginId) . "," . QbarStoreSql(title) . "," . QbarStoreSql(candidateKey) . ","
        . QbarStoreSql(input) . "," . QbarStoreSql(JSON.stringify(args, 0)) . ","
        . QbarStoreSql(JSON.stringify(payload, 0)) . "," . replayable . ","
        . QbarStoreSql(createdAt) . "," . QbarStoreSql(now) . ");")
}

QbarNormalizeAlias(alias) {
    return StrLower(RegExReplace(Trim(String(alias), " `t"), "\s+", " "))
}

QbarStoreNow() {
    return FormatTime(A_NowUTC, "yyyy-MM-ddTHH:mm:ssZ")
}

QbarStoreSql(value) {
    return "'" . StrReplace(String(value), "'", "''") . "'"
}

QbarStoreCompactUtc(value) {
    value := StrReplace(String(value), "-", "")
    value := StrReplace(value, "T", "")
    value := StrReplace(value, ":", "")
    return StrReplace(value, "Z", "")
}

QbarStoreFloat(value, fallback := 0) {
    try return Float(value)
    catch
        return fallback
}

QbarStoreInteger(value, fallback := 0) {
    try return Integer(value)
    catch
        return fallback
}

QbarStoreJsonMap(value) {
    try parsed := JSON.Parse(value, false, true)
    catch
        return Map()
    return Type(parsed) = "Map" ? parsed : Map()
}
