; Persistent storage for clipboard history.
;
; The store lives below A_ScriptDir\data so it follows the project's large
; runtime-data rule. Clipboard payloads are SQLite BLOBs; metadata queries never
; select the payload column.

global ClipboardHistoryDb := 0
global ClipboardHistoryDbReady := false
global ClipboardHistoryStoreError := ""
global ClipboardHistoryStoreVersion := 5
global ClipboardHistoryStoreRoot := A_ScriptDir . "\data"
global ClipboardHistoryStoreMaxItems := 500
global ClipboardHistoryStoreMaxBytes := 512 * 1024 * 1024
global ClipboardHistoryStoreMaxThumbnailChars := 128 * 1024

ClipboardHistoryStoreEnsureSchema(db) {
    schema := "CREATE TABLE IF NOT EXISTS clipboard_items ("
        . "id TEXT PRIMARY KEY,primary_type TEXT NOT NULL,is_rich_text INTEGER NOT NULL DEFAULT 0,"
        . "content_hash TEXT NOT NULL,text_plain TEXT NOT NULL DEFAULT '',search_text TEXT NOT NULL DEFAULT '',"
        . "preview_text TEXT NOT NULL DEFAULT '',files_json TEXT NOT NULL DEFAULT '[]',"
        . "image_width INTEGER NOT NULL DEFAULT 0,image_height INTEGER NOT NULL DEFAULT 0,"
        . "byte_size INTEGER NOT NULL DEFAULT 0,last_captured_at_utc TEXT NOT NULL,"
        . "is_favorite INTEGER NOT NULL DEFAULT 0,note_text TEXT NOT NULL DEFAULT '',"
        . "is_pinned INTEGER NOT NULL DEFAULT 0,pin_order INTEGER NOT NULL DEFAULT 0,file_count INTEGER NOT NULL DEFAULT 0);"
        . "CREATE TABLE IF NOT EXISTS clipboard_payloads (item_id TEXT PRIMARY KEY,snapshot_blob BLOB NOT NULL,"
        . "format_manifest_json TEXT NOT NULL DEFAULT '[]',payload_version INTEGER NOT NULL DEFAULT 1,"
        . "FOREIGN KEY(item_id) REFERENCES clipboard_items(id) ON DELETE CASCADE);"
        . "CREATE TABLE IF NOT EXISTS clipboard_thumbnails (item_id TEXT PRIMARY KEY,png_data_uri TEXT NOT NULL,"
        . "FOREIGN KEY(item_id) REFERENCES clipboard_items(id) ON DELETE CASCADE);"
        . "CREATE UNIQUE INDEX IF NOT EXISTS clipboard_items_hash_idx ON clipboard_items(content_hash);"
        . "CREATE INDEX IF NOT EXISTS clipboard_items_recent_idx ON clipboard_items(is_pinned DESC,pin_order DESC,last_captured_at_utc DESC,id DESC);"
    if !db.Exec(schema)
        throw Error(db.ErrorMsg != "" ? db.ErrorMsg : "无法创建剪贴板历史数据表")
    return true
}

ClipboardHistoryStorePath() {
    global ClipboardHistoryStoreRoot
    return ClipboardHistoryStoreRoot . "\capslock_p2.db"
}

ClipboardHistoryStoreInit() {
    global ClipboardHistoryDb, ClipboardHistoryDbReady, ClipboardHistoryStoreError
    global AppStoreDb
    if ClipboardHistoryDbReady && IsObject(ClipboardHistoryDb)
        return true

    ClipboardHistoryStoreError := ""
    try {
        if !AppStoreInit()
            throw Error(AppStoreError != "" ? AppStoreError : "无法初始化应用数据库")
        ClipboardHistoryDb := AppStoreDb
        ClipboardHistoryDbReady := true
        return true
    } catch as initError {
        ClipboardHistoryStoreError := "剪贴板历史数据库初始化失败：" . initError.Message
        ClipboardHistoryDb := 0
        ClipboardHistoryDbReady := false
        DebugLog("Clipboard history store init failed")
        return false
    }
}

ClipboardHistoryStoreClose() {
    global ClipboardHistoryDb, ClipboardHistoryDbReady
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
    loop {
        utc := A_NowUTC
        milliseconds := A_MSec
        if utc = A_NowUTC
            break
    }
    return FormatTime(utc, "yyyy-MM-ddTHH:mm:ss") . "." . milliseconds . "Z"
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

ClipboardHistoryStoreRowMap(table, row) {
    result := Map()
    if !IsObject(table) || !table.HasOwnProp("Cols") || !IsObject(row)
        return result
    for index, column in table.Cols
        result[column] := index <= row.Length ? String(row[index]) : ""
    return result
}

ClipboardHistoryStoreTouch(id) {
    global ClipboardHistoryDb, ClipboardHistoryStoreError
    Critical("On")
    try {
        if !ClipboardHistoryStoreExec("UPDATE clipboard_items SET last_captured_at_utc="
            . ClipboardHistoryStoreSql(ClipboardHistoryStoreNow()) . " WHERE id="
            . ClipboardHistoryStoreSql(id) . ";")
            return false
        if ClipboardHistoryDb.Changes() < 1 {
            ClipboardHistoryStoreError := "剪贴板历史项已不存在"
            return false
        }
        return true
    } finally {
        Critical("Off")
    }
}

ClipboardHistoryStoreFindByHash(contentHash) {
    sql := "SELECT id,is_favorite,note_text,is_pinned,pin_order FROM clipboard_items WHERE content_hash="
        . ClipboardHistoryStoreSql(contentHash) . ";"
    if !ClipboardHistoryStoreRows(sql, &table) || table.RowCount < 1
        return 0
    return ClipboardHistoryStoreRowMap(table, table.Rows[1])
}

ClipboardHistoryStoreSave(item, storedPayload, manifestJson, retentionCutoff := "",
    maxItems := 0, payloadVersion := 1) {
    global ClipboardHistoryDb, ClipboardHistoryStoreError
    if !IsObject(item) || !IsObject(storedPayload) || !ClipboardHistoryStoreInit()
        return false
    id := String(item["id"])
    if id = ""
        return false
    if !ClipboardHistoryStoreExec("BEGIN IMMEDIATE;")
        return false
    committed := false
    try {
        statement := ClipboardHistoryDb.Prepare(
            "INSERT INTO clipboard_items(id,primary_type,is_rich_text,content_hash,"
            . "text_plain,search_text,preview_text,files_json,image_width,image_height,byte_size,"
            . "last_captured_at_utc,is_favorite,note_text,is_pinned,pin_order,file_count) "
            . "VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?) "
            . "ON CONFLICT(id) DO UPDATE SET primary_type=excluded.primary_type,"
            . "is_rich_text=excluded.is_rich_text,content_hash=excluded.content_hash,"
            . "text_plain=excluded.text_plain,search_text=excluded.search_text,"
            . "preview_text=excluded.preview_text,files_json=excluded.files_json,"
                . "image_width=excluded.image_width,image_height=excluded.image_height,"
                . "byte_size=excluded.byte_size,last_captured_at_utc=excluded.last_captured_at_utc,"
                . "is_favorite=excluded.is_favorite,note_text=excluded.note_text,"
                . "is_pinned=excluded.is_pinned,pin_order=excluded.pin_order,"
                . "file_count=excluded.file_count;")
        if !statement
            throw Error(ClipboardHistoryStoreError)
        try {
            textValues := [id, item["primaryType"], item["contentHash"], item["textPlain"],
                item["searchText"], item["previewText"], item["filesJson"],
                item["lastCapturedAtUtc"], item["noteText"]]
            integerValues := Map(3, item["isRichText"] ? 1 : 0, 9, item["imageWidth"],
                10, item["imageHeight"], 11, item["byteSize"],
                13, item["isFavorite"] ? 1 : 0, 15, item["isPinned"] ? 1 : 0,
                16, item["pinOrder"], 17, item["files"].Length)
            textIndex := 1
            for index in [1, 2, 4, 5, 6, 7, 8, 12, 14] {
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
            "INSERT INTO clipboard_payloads(item_id,snapshot_blob,format_manifest_json,payload_version) "
            . "VALUES (?,?,?,?) ON CONFLICT(item_id) DO UPDATE SET "
            . "snapshot_blob=excluded.snapshot_blob,format_manifest_json=excluded.format_manifest_json,"
            . "payload_version=excluded.payload_version;")
        if !statement
            throw Error(ClipboardHistoryStoreError)
        try {
            if !ClipboardHistoryDb.StatementBindText(statement, 1, id)
                throw Error("绑定剪贴板历史 ID 失败")
            ; `storedPayload` remains strongly referenced until statement finalize,
            ; so avoid a second SQLite-owned copy.
            if !ClipboardHistoryDb.StatementBindBlob(statement, 2, storedPayload, false)
                throw Error("绑定剪贴板历史 BLOB 失败")
            if !ClipboardHistoryDb.StatementBindText(statement, 3, manifestJson)
                throw Error("绑定剪贴板历史格式清单失败")
            if !ClipboardHistoryDb.StatementBindInteger(statement, 4, payloadVersion)
                throw Error("绑定剪贴板历史存储版本失败")
            if ClipboardHistoryDb.StatementStep(statement) != 101
                throw Error("写入剪贴板历史 BLOB 失败")
        } finally {
            ClipboardHistoryDb.StatementFinalize(statement)
        }

        ; Expiration, count trimming, payload writes, and byte-budget trimming
        ; belong to the same transaction. A failed cleanup must not leave a
        ; partially accepted history item behind.
        if retentionCutoff != "" && !ClipboardHistoryStoreDeleteExpired(retentionCutoff)
            throw Error(ClipboardHistoryStoreError)
        if maxItems > 0 && !ClipboardHistoryStoreTrimNonFavorites(maxItems, id,
            !item["isFavorite"] && !item["isPinned"])
            throw Error(ClipboardHistoryStoreError)
        ClipboardHistoryStoreTrimToByteBudget(id)

        if !ClipboardHistoryStoreExec("COMMIT;")
            throw Error(ClipboardHistoryStoreError)
        committed := true
    } catch as saveError {
        try ClipboardHistoryStoreExec("ROLLBACK;")
        ClipboardHistoryStoreError := saveError.Message
    }
    return committed
}

ClipboardHistoryStoreStorageBytes(&totalBytes := 0) {
    totalBytes := 0
    bytesExpression := ClipboardHistoryStoreStorageBytesExpression()
    sql := "SELECT COALESCE(SUM(" . bytesExpression . "),0) FROM clipboard_items AS item "
        . "LEFT JOIN clipboard_payloads AS payload ON payload.item_id=item.id "
        . "LEFT JOIN clipboard_thumbnails AS thumbnail ON thumbnail.item_id=item.id;"
    if !ClipboardHistoryStoreRows(sql, &table)
        return false
    if table.RowCount > 0
        totalBytes := Integer(table.Rows[1][1])
    return true
}

ClipboardHistoryStoreStorageBytesExpression(itemAlias := "item", payloadAlias := "payload",
    thumbnailAlias := "thumbnail") {
    return "COALESCE(length(" . payloadAlias . ".snapshot_blob),0)+"
        . "COALESCE(length(CAST(" . payloadAlias . ".format_manifest_json AS BLOB)),0)+"
        . "length(CAST(" . itemAlias . ".text_plain AS BLOB))+"
        . "length(CAST(" . itemAlias . ".search_text AS BLOB))+"
        . "length(CAST(" . itemAlias . ".preview_text AS BLOB))+"
        . "length(CAST(" . itemAlias . ".files_json AS BLOB))+"
        . "length(CAST(" . itemAlias . ".note_text AS BLOB))+"
        . "COALESCE(length(CAST(" . thumbnailAlias . ".png_data_uri AS BLOB)),0)"
}

ClipboardHistoryStoreTrimToByteBudget(protectedId := "") {
    global ClipboardHistoryStoreMaxBytes, ClipboardHistoryStoreError
    protectedClause := ""
    if Type(protectedId) = "Array" {
        protectedIdList := ClipboardHistoryStoreIdListSql(protectedId)
        if protectedIdList != ""
            protectedClause := " AND item.id NOT IN (" . protectedIdList . ")"
    } else if protectedId != ""
        protectedClause := " AND item.id<>" . ClipboardHistoryStoreSql(protectedId)
    if !ClipboardHistoryStoreStorageBytes(&totalBytes)
        throw Error(ClipboardHistoryStoreError)
    if totalBytes <= ClipboardHistoryStoreMaxBytes
        return true

    bytesToFree := totalBytes - ClipboardHistoryStoreMaxBytes
    bytesExpression := ClipboardHistoryStoreStorageBytesExpression()
    sql := "SELECT item.id," . bytesExpression . " AS storage_bytes "
        . "FROM clipboard_items AS item "
        . "LEFT JOIN clipboard_payloads AS payload ON payload.item_id=item.id "
        . "LEFT JOIN clipboard_thumbnails AS thumbnail ON thumbnail.item_id=item.id "
        . "WHERE item.is_favorite=0 AND item.is_pinned=0" . protectedClause
        . " ORDER BY item.last_captured_at_utc ASC,item.id ASC;"
    if !ClipboardHistoryStoreRows(sql, &table)
        throw Error(ClipboardHistoryStoreError)

    victimIds := []
    bytesFreed := 0
    for row in table.Rows {
        victimIds.Push(String(row[1]))
        bytesFreed += Integer(row[2])
        if bytesFreed >= bytesToFree
            break
    }
    if bytesFreed < bytesToFree
        throw Error("剪贴板历史容量已满，收藏和置顶记录占用了全部可用空间")

    escapedIds := []
    for victimId in victimIds
        escapedIds.Push(ClipboardHistoryStoreSql(victimId))
    idList := ClipboardHistoryJoin(escapedIds, ",")
    if idList = ""
        throw Error("剪贴板历史容量清理没有可删除的记录")
    if !ClipboardHistoryStoreExec("DELETE FROM clipboard_items WHERE id IN (" . idList . ");")
        throw Error(ClipboardHistoryStoreError)
    for victimId in victimIds
        ClipboardHistoryImagePreviewCacheDelete(victimId)
    return true
}

ClipboardHistoryStoreReadPayload(id, &manifestJson := "") {
    global ClipboardHistoryDb
    manifestJson := ""
    if !ClipboardHistoryStoreInit()
        return 0
    statement := ClipboardHistoryDb.Prepare(
        "SELECT snapshot_blob,format_manifest_json,payload_version "
        . "FROM clipboard_payloads WHERE item_id=?;")
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
        payloadVersion := ClipboardHistoryDb.StatementColumnInteger(statement, 2)
    } finally {
        ClipboardHistoryDb.StatementFinalize(statement)
    }
    if !IsObject(payload)
        return 0
    if !ClipboardHistoryPayloadDecode(payload, payloadVersion, &archive) {
        DebugLog("Clipboard history payload decode failed: version=" . payloadVersion)
        return 0
    }
    return archive
}

ClipboardHistoryStoreList(searchText := "", primaryType := "", favoriteOnly := false,
    dateAfter := "", dateBefore := "", page := 1, limit := 20) {
    limit := Max(1, Min(100, Integer(limit)))
    page := Max(1, Integer(page))
    offset := (page - 1) * limit
    whereClause := ClipboardHistoryStoreWhere(searchText, primaryType, favoriteOnly,
        dateAfter, dateBefore)
    sql := "SELECT id,primary_type,is_rich_text,"
        . "CASE WHEN primary_type IN ('text','rich') AND text_plain<>'' "
        . "THEN substr(text_plain,1,240) ELSE preview_text END AS preview_text,file_count,"
        . "image_width,image_height,byte_size,last_captured_at_utc,is_favorite,note_text,is_pinned,pin_order FROM clipboard_items WHERE "
        . whereClause
        . " ORDER BY is_pinned DESC,pin_order DESC,last_captured_at_utc DESC,id DESC LIMIT " . limit
        . " OFFSET " . offset . ";"
    rows := []
    if !ClipboardHistoryStoreRows(sql, &table)
        return rows
    for raw in table.Rows
        rows.Push(ClipboardHistoryStoreRowMap(table, raw))
    return rows
}

ClipboardHistoryStoreGetItem(id, forView := false) {
    sql := "SELECT id,primary_type" . (forView ? ",text_plain " : " ")
        . "FROM clipboard_items WHERE id="
        . ClipboardHistoryStoreSql(id) . ";"
    if !ClipboardHistoryStoreRows(sql, &table) || table.RowCount < 1
        return 0
    row := ClipboardHistoryStoreRowMap(table, table.Rows[1])
    ; Full text is already stored separately; viewing it need not decode the snapshot.
    if forView && row["primary_type"] = "text"
        return row
    payload := ClipboardHistoryStoreReadPayload(id, &manifest)
    if !IsObject(payload)
        return 0
    row["snapshot"] := payload
    row["manifestJson"] := manifest
    return row
}

ClipboardHistoryStoreGetThumbnail(id) {
    global ClipboardHistoryDb
    if !ClipboardHistoryStoreInit()
        return ""
    statement := ClipboardHistoryDb.Prepare(
        "SELECT png_data_uri FROM clipboard_thumbnails WHERE item_id=?;")
    if !statement
        return ""
    preview := ""
    try {
        if !ClipboardHistoryDb.StatementBindText(statement, 1, String(id))
            return ""
        if ClipboardHistoryDb.StatementStep(statement) = 100
            preview := ClipboardHistoryDb.StatementColumnText(statement, 0)
    } finally {
        ClipboardHistoryDb.StatementFinalize(statement)
    }
    return preview
}

ClipboardHistoryStoreSaveThumbnail(id, preview) {
    global ClipboardHistoryDb, ClipboardHistoryStoreError, ClipboardHistoryStoreMaxThumbnailChars
    global ClipboardHistoryStoreMaxBytes
    if preview = "" || StrLen(preview) > ClipboardHistoryStoreMaxThumbnailChars
        return false
    Critical("On")
    try {
        if !ClipboardHistoryStoreInit() || !ClipboardHistoryStoreExec("BEGIN IMMEDIATE;")
            return false
        committed := false
        try {
            statement := ClipboardHistoryDb.Prepare(
                "INSERT INTO clipboard_thumbnails(item_id,png_data_uri) VALUES (?,?) "
                . "ON CONFLICT(item_id) DO UPDATE SET png_data_uri=excluded.png_data_uri;")
            if !statement
                throw Error(ClipboardHistoryStoreError)
            try {
                if !ClipboardHistoryDb.StatementBindText(statement, 1, String(id))
                    throw Error("绑定缩略图 ID 失败")
                if !ClipboardHistoryDb.StatementBindText(statement, 2, preview)
                    throw Error("绑定图片缩略图失败")
                if ClipboardHistoryDb.StatementStep(statement) != 101
                    throw Error("写入图片缩略图失败")
            } finally {
                ClipboardHistoryDb.StatementFinalize(statement)
            }
            if !ClipboardHistoryStoreStorageBytes(&totalBytes)
                throw Error(ClipboardHistoryStoreError)
            if totalBytes > ClipboardHistoryStoreMaxBytes
                throw Error("图片缩略图超出剪贴板历史容量，已跳过持久化")
            if !ClipboardHistoryStoreExec("COMMIT;")
                throw Error(ClipboardHistoryStoreError)
            committed := true
        } catch as thumbnailError {
            try ClipboardHistoryStoreExec("ROLLBACK;")
            ClipboardHistoryStoreError := thumbnailError.Message
        }
        return committed
    } finally {
        Critical("Off")
    }
}

ClipboardHistoryStoreSetFavorite(id, desiredState) {
    return ClipboardHistoryStoreBudgetedMutation("UPDATE clipboard_items SET is_favorite="
        . (desiredState ? 1 : 0) . " WHERE id="
        . ClipboardHistoryStoreSql(id) . ";", [String(id)])
}

ClipboardHistoryStoreSetNote(id, noteText) {
    return ClipboardHistoryStoreBudgetedMutation("UPDATE clipboard_items SET note_text="
        . ClipboardHistoryStoreSql(SubStr(String(noteText), 1, 4000)) . " WHERE id="
        . ClipboardHistoryStoreSql(id) . ";", [String(id)])
}

ClipboardHistoryStoreIdListSql(ids) {
    if Type(ids) != "Array"
        return ""
    values := []
    seen := Map()
    for id in ids {
        id := String(id)
        if id = "" || StrLen(id) > 256 || seen.Has(id)
            continue
        seen[id] := true
        values.Push(ClipboardHistoryStoreSql(id))
    }
    return ClipboardHistoryJoin(values, ",")
}

ClipboardHistoryStoreSetNotes(ids, noteText) {
    idList := ClipboardHistoryStoreIdListSql(ids)
    if idList = ""
        return false
    return ClipboardHistoryStoreBudgetedMutation("UPDATE clipboard_items SET note_text="
        . ClipboardHistoryStoreSql(SubStr(String(noteText), 1, 4000))
        . " WHERE id IN (" . idList . ");", ids)
}

ClipboardHistoryStoreBudgetedMutation(sql, protectedIds) {
    global ClipboardHistoryDb, ClipboardHistoryStoreError
    Critical("On")
    committed := false
    try {
        if !ClipboardHistoryStoreInit() || !ClipboardHistoryStoreExec("BEGIN IMMEDIATE;")
            return false
        try {
            if !ClipboardHistoryStoreExec(sql)
                throw Error(ClipboardHistoryStoreError)
            if ClipboardHistoryDb.Changes() < 1
                throw Error("剪贴板历史项已不存在")
            ClipboardHistoryStoreTrimToByteBudget(protectedIds)
            if !ClipboardHistoryStoreExec("COMMIT;")
                throw Error(ClipboardHistoryStoreError)
            committed := true
        } catch as mutationError {
            try ClipboardHistoryStoreExec("ROLLBACK;")
            ClipboardHistoryStoreError := mutationError.Message
        }
    } finally {
        Critical("Off")
    }
    return committed
}

ClipboardHistoryStoreDeleteMany(ids) {
    idList := ClipboardHistoryStoreIdListSql(ids)
    if idList = ""
        return false
    Critical("On")
    try return ClipboardHistoryStoreExec("DELETE FROM clipboard_items WHERE id IN (" . idList . ");")
    finally Critical("Off")
}

ClipboardHistoryStoreSetPinned(id, desiredState) {
    global ClipboardHistoryDb, ClipboardHistoryStoreError
    Critical("On")
    committed := false
    try {
        if !ClipboardHistoryStoreInit() || !ClipboardHistoryStoreExec("BEGIN IMMEDIATE;")
            return false
        try {
            if desiredState {
                if !ClipboardHistoryStoreRows(
                    "SELECT COALESCE(MAX(pin_order),0)+1 AS next_pin_order FROM clipboard_items;",
                    &table)
                    throw Error(ClipboardHistoryStoreError)
                nextPinOrder := table.RowCount > 0 ? Integer(table.Rows[1][1]) : 1
                updateSql := "UPDATE clipboard_items SET is_pinned=1,pin_order="
                    . nextPinOrder . " WHERE id=" . ClipboardHistoryStoreSql(id) . ";"
            } else
                updateSql := "UPDATE clipboard_items SET is_pinned=0,pin_order=0 WHERE id="
                    . ClipboardHistoryStoreSql(id) . ";"
            if !ClipboardHistoryStoreExec(updateSql)
                throw Error(ClipboardHistoryStoreError)
            if ClipboardHistoryDb.Changes() < 1
                throw Error("剪贴板历史项已不存在")
            ClipboardHistoryStoreTrimToByteBudget(desiredState ? [String(id)] : "")
            if !ClipboardHistoryStoreExec("COMMIT;")
                throw Error(ClipboardHistoryStoreError)
            committed := true
        } catch as pinError {
            try ClipboardHistoryStoreExec("ROLLBACK;")
            ClipboardHistoryStoreError := pinError.Message
        }
    }
    finally Critical("Off")
    return committed
}

ClipboardHistoryStoreDeleteExpired(cutoffUtc) {
    return ClipboardHistoryStoreExec("DELETE FROM clipboard_items WHERE is_favorite=0 AND is_pinned=0 AND last_captured_at_utc<"
        . ClipboardHistoryStoreSql(cutoffUtc) . ";")
}

ClipboardHistoryStoreDelete(id) {
    Critical("On")
    try return ClipboardHistoryStoreExec("DELETE FROM clipboard_items WHERE id="
        . ClipboardHistoryStoreSql(id) . ";")
    finally Critical("Off")
}

ClipboardHistoryStoreClearNonFavorites() {
    return ClipboardHistoryStoreExec("DELETE FROM clipboard_items WHERE is_favorite=0;")
}

ClipboardHistoryStoreCounts(searchText := "", primaryType := "", favoriteOnly := false,
    dateAfter := "", dateBefore := "") {
    global ClipboardHistoryStoreError
    counts := Map("total", 0, "favorite", 0, "nonFavorite", 0, "matching", 0,
        "ready", false, "error", "")
    if !ClipboardHistoryStoreInit() {
        counts["error"] := ClipboardHistoryStoreError
        return counts
    }
    if !ClipboardHistoryStoreRows("SELECT COUNT(*) AS total,"
        . "COALESCE(SUM(CASE WHEN is_favorite=1 THEN 1 ELSE 0 END),0) AS favorite "
        . "FROM clipboard_items;", &table) {
        counts["error"] := ClipboardHistoryStoreError
        return counts
    }
    if table.RowCount > 0 {
        counts["total"] := Integer(table.Rows[1][1])
        counts["favorite"] := Integer(table.Rows[1][2])
        counts["nonFavorite"] := counts["total"] - counts["favorite"]
    }
    whereClause := ClipboardHistoryStoreWhere(searchText, primaryType, favoriteOnly,
        dateAfter, dateBefore)
    if !ClipboardHistoryStoreRows("SELECT COUNT(*) AS matching FROM clipboard_items WHERE "
        . whereClause . ";", &matchingTable) {
        counts["error"] := ClipboardHistoryStoreError
        return counts
    }
    if matchingTable.RowCount > 0
        counts["matching"] := Integer(matchingTable.Rows[1][1])
    counts["ready"] := true
    return counts
}

ClipboardHistoryStoreWhere(searchText, primaryType, favoriteOnly, dateAfter, dateBefore) {
    conditions := ["1=1"]
    searchText := Trim(String(searchText))
    if searchText != ""
        conditions.Push("(INSTR(LOWER(search_text),LOWER(" . ClipboardHistoryStoreSql(searchText)
            . "))>0 OR INSTR(LOWER(note_text),LOWER(" . ClipboardHistoryStoreSql(searchText) . "))>0)")
    if primaryType != "" && primaryType != "all"
        conditions.Push("primary_type=" . ClipboardHistoryStoreSql(primaryType))
    if favoriteOnly
        conditions.Push("is_favorite=1")
    if Trim(dateAfter) != ""
        conditions.Push("last_captured_at_utc>=" . ClipboardHistoryStoreSql(dateAfter))
    if Trim(dateBefore) != ""
        conditions.Push("last_captured_at_utc<" . ClipboardHistoryStoreSql(dateBefore))
    return ClipboardHistoryJoin(conditions, " AND ")
}

ClipboardHistoryStoreTrimNonFavorites(maxItems, protectedId := "", protectedIsEligible := false) {
    maxItems := Max(0, Integer(maxItems))
    protectedClause := protectedId = "" ? ""
        : " AND id<>" . ClipboardHistoryStoreSql(protectedId)
    keepCount := Max(0, maxItems - (protectedIsEligible ? 1 : 0))
    return ClipboardHistoryStoreExec("DELETE FROM clipboard_items WHERE is_favorite=0 AND is_pinned=0 AND id IN ("
        . "SELECT id FROM clipboard_items WHERE is_favorite=0 AND is_pinned=0"
        . protectedClause . " "
        . "ORDER BY last_captured_at_utc DESC,id DESC "
        . "LIMIT -1 OFFSET " . keepCount . ");")
}
