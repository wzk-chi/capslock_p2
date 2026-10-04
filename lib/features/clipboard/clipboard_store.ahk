; Persistent storage for clipboard history.
;
; The store lives below A_ScriptDir\data so it follows the project's large
; runtime-data rule. Clipboard payloads are SQLite BLOBs; metadata queries never
; select the payload column.

global ClipboardHistoryDb := 0
global ClipboardHistoryDbReady := false
global ClipboardHistoryStoreError := ""
global ClipboardHistoryStoreVersion := 1
global ClipboardHistoryStoreRoot := A_ScriptDir . "\data\clipboard-history"
global ClipboardHistoryStoreMaxItems := 500

ClipboardHistoryStorePath() {
    global ClipboardHistoryStoreRoot
    return ClipboardHistoryStoreRoot . "\clipboard-history.db"
}

ClipboardHistoryStoreInit() {
    global ClipboardHistoryDb, ClipboardHistoryDbReady, ClipboardHistoryStoreError
    global ClipboardHistoryStoreRoot
    if ClipboardHistoryDbReady && IsObject(ClipboardHistoryDb)
        return true

    ClipboardHistoryStoreError := ""
    try {
        DirCreate(ClipboardHistoryStoreRoot)
        if !DirExist(ClipboardHistoryStoreRoot)
            throw Error("剪贴板历史目录不可写：" . ClipboardHistoryStoreRoot)

        db := CSQLite(A_ScriptDir . "\resources")
        if !db.OpenDB(ClipboardHistoryStorePath(), "W", true)
            throw Error(db.ErrorMsg != "" ? db.ErrorMsg : "无法打开剪贴板历史数据库")
        if !db.SetTimeout(2000)
            throw Error(db.ErrorMsg != "" ? db.ErrorMsg : "无法设置剪贴板历史 SQLite 超时")
        if !db.Exec("PRAGMA foreign_keys = ON; PRAGMA busy_timeout = 2000;")
            throw Error(db.ErrorMsg != "" ? db.ErrorMsg : "无法初始化剪贴板历史 SQLite")
        ClipboardHistoryStoreMigrate(db)
        ClipboardHistoryDb := db
        ClipboardHistoryDbReady := true
        return true
    } catch as initError {
        ClipboardHistoryStoreError := "剪贴板历史数据库初始化失败：" . initError.Message
        if IsObject(ClipboardHistoryDb)
            try ClipboardHistoryDb.CloseDB()
        ClipboardHistoryDb := 0
        ClipboardHistoryDbReady := false
        DebugLog("Clipboard history store init failed")
        return false
    }
}

ClipboardHistoryStoreMigrate(db) {
    global ClipboardHistoryStoreVersion
    schema := ""
    schema .= "CREATE TABLE IF NOT EXISTS history_meta ("
        . "key TEXT PRIMARY KEY,value TEXT NOT NULL);"
    schema .= "CREATE TABLE IF NOT EXISTS clipboard_items ("
        . "id TEXT PRIMARY KEY,"
        . "primary_type TEXT NOT NULL,"
        . "is_rich_text INTEGER NOT NULL DEFAULT 0,"
        . "content_hash TEXT NOT NULL,"
        . "text_plain TEXT NOT NULL DEFAULT '',"
        . "search_text TEXT NOT NULL DEFAULT '',"
        . "preview_text TEXT NOT NULL DEFAULT '',"
        . "files_json TEXT NOT NULL DEFAULT '[]',"
        . "image_width INTEGER NOT NULL DEFAULT 0,"
        . "image_height INTEGER NOT NULL DEFAULT 0,"
        . "item_count INTEGER NOT NULL DEFAULT 0,"
        . "byte_size INTEGER NOT NULL DEFAULT 0,"
        . "created_at_utc TEXT NOT NULL,"
        . "last_captured_at_utc TEXT NOT NULL,"
        . "last_capture_order INTEGER NOT NULL,"
        . "is_favorite INTEGER NOT NULL DEFAULT 0,"
        . "favorited_at_utc TEXT NOT NULL DEFAULT '',"
        . "format_manifest_json TEXT NOT NULL DEFAULT '[]');"
    schema .= "CREATE TABLE IF NOT EXISTS clipboard_payloads ("
        . "item_id TEXT PRIMARY KEY,"
        . "snapshot_blob BLOB NOT NULL,"
        . "format_manifest_json TEXT NOT NULL DEFAULT '[]',"
        . "payload_version INTEGER NOT NULL DEFAULT 1,"
        . "FOREIGN KEY(item_id) REFERENCES clipboard_items(id) ON DELETE CASCADE);"
    schema .= "CREATE INDEX IF NOT EXISTS clipboard_items_order_idx "
        . "ON clipboard_items(last_capture_order DESC,id DESC);"
        . "CREATE INDEX IF NOT EXISTS clipboard_items_type_idx "
        . "ON clipboard_items(primary_type,last_capture_order DESC);"
        . "CREATE INDEX IF NOT EXISTS clipboard_items_favorite_idx "
        . "ON clipboard_items(is_favorite,last_capture_order DESC);"
        . "CREATE UNIQUE INDEX IF NOT EXISTS clipboard_items_hash_idx "
        . "ON clipboard_items(content_hash);"

    if !db.Exec(schema)
        throw Error(db.ErrorMsg != "" ? db.ErrorMsg : "创建剪贴板历史数据库结构失败")
    version := String(ClipboardHistoryStoreVersion)
    if !db.Exec("INSERT OR REPLACE INTO history_meta(key,value) VALUES ('schema_version',"
        . ClipboardHistoryStoreSql(version) . ");")
        throw Error(db.ErrorMsg != "" ? db.ErrorMsg : "写入剪贴板历史 schema 版本失败")
    return true
}

ClipboardHistoryStoreClose() {
    global ClipboardHistoryDb, ClipboardHistoryDbReady
    if IsObject(ClipboardHistoryDb)
        try ClipboardHistoryDb.CloseDB()
    ClipboardHistoryDb := 0
    ClipboardHistoryDbReady := false
}

ClipboardHistoryStoreSql(value) {
    ; String-only helper used for small structural predicates. Clipboard text
    ; itself is written through bound statements below; removing NUL here also
    ; keeps diagnostic/search predicates from terminating SQLite SQL strings.
    value := StrReplace(String(value), Chr(0), "")
    return "'" . StrReplace(value, "'", "''") . "'"
}

ClipboardHistoryStoreNow() {
    return FormatTime(A_NowUTC, "yyyy-MM-ddTHH:mm:ssZ")
}

ClipboardHistoryStoreExec(sql) {
    global ClipboardHistoryDb, ClipboardHistoryDbReady, ClipboardHistoryStoreError
    ClipboardHistoryStoreError := ""
    if !ClipboardHistoryDbReady || !IsObject(ClipboardHistoryDb) {
        ClipboardHistoryStoreError := "剪贴板历史数据库尚未初始化"
        return false
    }
    if ClipboardHistoryDb.Exec(sql)
        return true
    ClipboardHistoryStoreError := ClipboardHistoryDb.ErrorMsg != ""
        ? ClipboardHistoryDb.ErrorMsg : "剪贴板历史 SQLite 执行失败"
    DebugLog("Clipboard history SQLite exec failed")
    return false
}

ClipboardHistoryStoreRows(sql, &table := 0) {
    global ClipboardHistoryDb, ClipboardHistoryDbReady, ClipboardHistoryStoreError
    table := 0
    ClipboardHistoryStoreError := ""
    if !ClipboardHistoryDbReady || !IsObject(ClipboardHistoryDb) {
        ClipboardHistoryStoreError := "剪贴板历史数据库尚未初始化"
        return false
    }
    if ClipboardHistoryDb.GetTable(sql, &table, -1)
        return true
    ClipboardHistoryStoreError := ClipboardHistoryDb.ErrorMsg != ""
        ? ClipboardHistoryDb.ErrorMsg : "剪贴板历史 SQLite 查询失败"
    DebugLog("Clipboard history SQLite query failed")
    return false
}

ClipboardHistoryStoreJoin(values, delimiter := "`n") {
    result := ""
    for index, value in values
        result .= (index > 1 ? delimiter : "") . String(value)
    return result
}

ClipboardHistoryStoreRowMap(table, row) {
    result := Map()
    if !IsObject(table) || !table.HasOwnProp("Cols") || !IsObject(row)
        return result
    for index, column in table.Cols
        result[column] := index <= row.Length ? String(row[index]) : ""
    return result
}

ClipboardHistoryStoreNextOrder() {
    if !ClipboardHistoryStoreRows(
        "SELECT COALESCE(MAX(last_capture_order),0)+1 AS next_order FROM clipboard_items;",
        &table)
        return A_TickCount
    if table.RowCount < 1 || table.Rows[1].Length < 1
        return A_TickCount
    try return Integer(table.Rows[1][1])
    catch
        return A_TickCount
}

ClipboardHistoryStoreFindByHash(contentHash) {
    sql := "SELECT id,is_favorite,created_at_utc,favorited_at_utc FROM clipboard_items WHERE content_hash="
        . ClipboardHistoryStoreSql(contentHash) . ";"
    if !ClipboardHistoryStoreRows(sql, &table) || table.RowCount < 1
        return 0
    return ClipboardHistoryStoreRowMap(table, table.Rows[1])
}

ClipboardHistoryStoreSave(item, snapshot, manifestJson) {
    global ClipboardHistoryDb, ClipboardHistoryStoreError
    if !IsObject(item) || !IsObject(snapshot) || !ClipboardHistoryStoreInit()
        return false
    id := String(item["id"])
    if id = ""
        return false
    if !ClipboardHistoryStoreExec("BEGIN IMMEDIATE;")
        return false
    committed := false
    try {
        statement := ClipboardHistoryDb.Prepare(
            "INSERT OR REPLACE INTO clipboard_items(id,primary_type,is_rich_text,content_hash,"
            . "text_plain,search_text,preview_text,files_json,image_width,image_height,item_count,"
            . "byte_size,created_at_utc,last_captured_at_utc,last_capture_order,is_favorite,"
            . "favorited_at_utc,format_manifest_json) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);")
        if !statement
            throw Error(ClipboardHistoryStoreError)
        try {
            textValues := [id, item["primaryType"], item["contentHash"], item["textPlain"],
                item["searchText"], item["previewText"], item["filesJson"], item["createdAtUtc"],
                item["lastCapturedAtUtc"], item["favoritedAtUtc"], manifestJson]
            integerValues := Map(3, item["isRichText"] ? 1 : 0, 9, item["imageWidth"],
                10, item["imageHeight"], 11, item["itemCount"], 12, item["byteSize"],
                15, item["lastCaptureOrder"], 16, item["isFavorite"] ? 1 : 0)
            textIndex := 1
            for index in [1, 2, 4, 5, 6, 7, 8, 13, 14, 17, 18] {
                if !ClipboardHistoryDb.StatementBindText(statement, index, textValues[textIndex])
                    throw Error("绑定剪贴板历史元数据失败")
                textIndex += 1
            }
            for index, value in integerValues
                if !ClipboardHistoryDb.StatementBindInteger(statement, index, value)
                    throw Error("绑定剪贴板历史数值失败")
            if ClipboardHistoryDb.StatementStep(statement) != 101
                throw Error("写入剪贴板历史元数据失败")
        } finally {
            ClipboardHistoryDb.StatementFinalize(statement)
        }

        statement := ClipboardHistoryDb.Prepare(
            "INSERT OR REPLACE INTO clipboard_payloads(item_id,snapshot_blob,format_manifest_json,payload_version) VALUES (?,?,?,1);")
        if !statement
            throw Error(ClipboardHistoryStoreError)
        try {
            if !ClipboardHistoryDb.StatementBindText(statement, 1, id)
                throw Error("绑定剪贴板历史 ID 失败")
            if !ClipboardHistoryDb.StatementBindBlob(statement, 2, snapshot)
                throw Error("绑定剪贴板历史 BLOB 失败")
            if !ClipboardHistoryDb.StatementBindText(statement, 3, manifestJson)
                throw Error("绑定剪贴板历史格式清单失败")
            if ClipboardHistoryDb.StatementStep(statement) != 101
                throw Error("写入剪贴板历史 BLOB 失败")
        } finally {
            ClipboardHistoryDb.StatementFinalize(statement)
        }

        if !ClipboardHistoryStoreExec("COMMIT;")
            throw Error(ClipboardHistoryStoreError)
        committed := true
    } catch as saveError {
        try ClipboardHistoryStoreExec("ROLLBACK;")
        ClipboardHistoryStoreError := saveError.Message
    }
    return committed
}

ClipboardHistoryStoreReadPayload(id, &manifestJson := "") {
    global ClipboardHistoryDb
    manifestJson := ""
    if !ClipboardHistoryStoreInit()
        return 0
    statement := ClipboardHistoryDb.Prepare(
        "SELECT snapshot_blob,format_manifest_json FROM clipboard_payloads WHERE item_id=?;")
    if !statement
        return 0
    payload := 0
    try {
        if !ClipboardHistoryDb.StatementBindText(statement, 1, String(id))
            return 0
        if ClipboardHistoryDb.StatementStep(statement) != 100
            return 0
        payload := ClipboardHistoryDb.StatementColumnBlob(statement, 0, &size,
            512 * 1024 * 1024)
        manifestJson := ClipboardHistoryDb.StatementColumnText(statement, 1)
    } finally {
        ClipboardHistoryDb.StatementFinalize(statement)
    }
    return payload
}

ClipboardHistoryStoreList(searchText := "", primaryType := "", favoriteOnly := false,
    cursor := 0, limit := 50) {
    limit := Max(1, Min(100, Integer(limit)))
    cursor := Max(0, Integer(cursor))
    conditions := ["1=1"]
    if Trim(searchText) != ""
        conditions.Push("INSTR(LOWER(search_text),LOWER(" . ClipboardHistoryStoreSql(Trim(searchText)) . "))>0")
    if primaryType != "" && primaryType != "all"
        conditions.Push("primary_type=" . ClipboardHistoryStoreSql(primaryType))
    if favoriteOnly
        conditions.Push("is_favorite=1")
    if cursor > 0
        conditions.Push("last_capture_order<" . cursor)
    sql := "SELECT id,primary_type,is_rich_text,text_plain,search_text,preview_text,files_json,"
        . "image_width,image_height,item_count,byte_size,created_at_utc,last_captured_at_utc,"
        . "last_capture_order,is_favorite,favorited_at_utc FROM clipboard_items WHERE "
        . ClipboardHistoryStoreJoin(conditions, " AND ")
        . " ORDER BY last_capture_order DESC,id DESC LIMIT " . limit . ";"
    rows := []
    if !ClipboardHistoryStoreRows(sql, &table)
        return rows
    for raw in table.Rows
        rows.Push(ClipboardHistoryStoreRowMap(table, raw))
    return rows
}

ClipboardHistoryStoreGetItem(id) {
    sql := "SELECT id,primary_type,is_rich_text,content_hash,text_plain,search_text,preview_text,"
        . "files_json,image_width,image_height,item_count,byte_size,created_at_utc,last_captured_at_utc,"
        . "last_capture_order,is_favorite,favorited_at_utc,format_manifest_json FROM clipboard_items WHERE id="
        . ClipboardHistoryStoreSql(id) . ";"
    if !ClipboardHistoryStoreRows(sql, &table) || table.RowCount < 1
        return 0
    row := ClipboardHistoryStoreRowMap(table, table.Rows[1])
    payload := ClipboardHistoryStoreReadPayload(id, &manifest)
    if !IsObject(payload)
        return 0
    row["snapshot"] := payload
    row["manifestJson"] := manifest
    return row
}

ClipboardHistoryStoreSetFavorite(id, desiredState) {
    timestamp := desiredState ? ClipboardHistoryStoreNow() : ""
    return ClipboardHistoryStoreExec("UPDATE clipboard_items SET is_favorite="
        . (desiredState ? 1 : 0) . ",favorited_at_utc="
        . ClipboardHistoryStoreSql(timestamp) . " WHERE id="
        . ClipboardHistoryStoreSql(id) . ";")
}

ClipboardHistoryStoreDelete(id) {
    return ClipboardHistoryStoreExec("DELETE FROM clipboard_items WHERE id="
        . ClipboardHistoryStoreSql(id) . ";")
}

ClipboardHistoryStoreClearNonFavorites() {
    return ClipboardHistoryStoreExec("DELETE FROM clipboard_items WHERE is_favorite=0;")
}

ClipboardHistoryStoreCounts(searchText := "", primaryType := "", favoriteOnly := false) {
    global ClipboardHistoryStoreError
    counts := Map("total", 0, "favorite", 0, "nonFavorite", 0, "matching", 0,
        "ready", false, "error", "")
    if !ClipboardHistoryStoreInit() {
        counts["error"] := ClipboardHistoryStoreError
        return counts
    }
    if !ClipboardHistoryStoreRows("SELECT COUNT(*) AS total,"
        . "SUM(CASE WHEN is_favorite=1 THEN 1 ELSE 0 END) AS favorite FROM clipboard_items;", &table) {
        counts["error"] := ClipboardHistoryStoreError
        return counts
    }
    if table.RowCount > 0 {
        counts["total"] := Integer(table.Rows[1][1])
        counts["favorite"] := Integer(table.Rows[1][2])
        counts["nonFavorite"] := counts["total"] - counts["favorite"]
    }
    conditions := ["1=1"]
    if Trim(searchText) != ""
        conditions.Push("INSTR(LOWER(search_text),LOWER(" . ClipboardHistoryStoreSql(Trim(searchText)) . "))>0")
    if primaryType != "" && primaryType != "all"
        conditions.Push("primary_type=" . ClipboardHistoryStoreSql(primaryType))
    if favoriteOnly
        conditions.Push("is_favorite=1")
    if !ClipboardHistoryStoreRows("SELECT COUNT(*) AS matching FROM clipboard_items WHERE "
        . ClipboardHistoryStoreJoin(conditions, " AND ") . ";", &matchingTable) {
        counts["error"] := ClipboardHistoryStoreError
        return counts
    }
    if matchingTable.RowCount > 0
        counts["matching"] := Integer(matchingTable.Rows[1][1])
    counts["ready"] := true
    return counts
}

ClipboardHistoryStoreTrimNonFavorites(maxItems) {
    maxItems := Max(0, Integer(maxItems))
    return ClipboardHistoryStoreExec("DELETE FROM clipboard_items WHERE is_favorite=0 AND id IN ("
        . "SELECT id FROM clipboard_items WHERE is_favorite=0 ORDER BY last_capture_order DESC,id DESC "
        . "LIMIT -1 OFFSET " . maxItems . ");")
}
