; QBar notes SQLite store.
; The store deliberately keeps user data beside the installed program. The
; installer does not ship or remove this directory.

global NotesDB := 0
global NotesDBReady := false
global NotesDBVersion := 2
global NotesStoreError := ""
global NotesStoreRoot := A_ScriptDir . "\data\qbar-notes"
global NotesStoreMedia := A_ScriptDir . "\data\qbar-notes\media"
global NotesPendingAssets := Map()

NotesStoreEnsureSchema(db) {
    schema := "CREATE TABLE IF NOT EXISTS notes ("
        . "id INTEGER PRIMARY KEY AUTOINCREMENT,title TEXT NOT NULL DEFAULT '',"
        . "content_md TEXT NOT NULL DEFAULT '',pinned INTEGER NOT NULL DEFAULT 0,"
        . "created_at INTEGER NOT NULL,updated_at INTEGER NOT NULL);"
        . "CREATE TABLE IF NOT EXISTS tags ("
        . "id INTEGER PRIMARY KEY AUTOINCREMENT,name TEXT NOT NULL COLLATE NOCASE UNIQUE,"
        . "created_at INTEGER NOT NULL,updated_at INTEGER NOT NULL);"
        . "CREATE TABLE IF NOT EXISTS note_tags ("
        . "note_id INTEGER NOT NULL REFERENCES notes(id) ON DELETE CASCADE,"
        . "tag_id INTEGER NOT NULL REFERENCES tags(id) ON DELETE CASCADE,PRIMARY KEY(note_id,tag_id));"
        . "CREATE TABLE IF NOT EXISTS note_assets ("
        . "id TEXT PRIMARY KEY,note_id INTEGER NOT NULL REFERENCES notes(id) ON DELETE CASCADE,"
        . "relative_path TEXT NOT NULL,mime TEXT NOT NULL,original_name TEXT NOT NULL DEFAULT '',"
        . "created_at INTEGER NOT NULL);"
        . "CREATE INDEX IF NOT EXISTS idx_notes_order ON notes(pinned DESC,updated_at DESC,id DESC);"
        . "CREATE INDEX IF NOT EXISTS idx_note_tags_tag ON note_tags(tag_id,note_id);"
        . "CREATE INDEX IF NOT EXISTS idx_assets_note ON note_assets(note_id);"
    if !db.Exec(schema)
        throw Error(db.ErrorMsg != "" ? db.ErrorMsg : "无法创建笔记数据表")
    return true
}

NotesStoreDbPath() {
    return AppStorePath()
}

NotesStoreInit() {
    global NotesDB, NotesDBReady, NotesStoreError, AppStoreDb
    if NotesDBReady && IsObject(NotesDB)
        return true
    NotesStoreError := ""
    try {
        if !AppStoreInit()
            throw Error(AppStoreError != "" ? AppStoreError : "无法初始化应用数据库")
        NotesDB := AppStoreDb
        NotesDBReady := true
        DirCreate(NotesStoreMedia)
        if !DirExist(NotesStoreMedia)
            throw Error("笔记图片目录不可用")
        return true
    } catch as initError {
        NotesStoreError := "笔记数据库初始化失败（" . NotesStoreDbPath() . "）：" . initError.Message
        NotesDB := 0
        NotesDBReady := false
        DebugLog(NotesStoreError)
        return false
    }
}

NotesStoreClose() {
    global NotesDB, NotesDBReady
    NotesDB := 0
    NotesDBReady := false
}

; Assets reach the store from two places that do not agree on their keys: a
; pending upload carries an absolute `path` next to its relative `relativePath`,
; while a stored asset carries only `path`, which is the row's relative_path.
; `note_assets.relative_path` must always be written in the relative form —
; NotesStoreCleanOrphans compares it against "media\<file>" and deletes anything
; that does not match, so an absolute value there wipes the media folder on the
; next start.
NotesAssetStoredPath(asset) {
    if !IsObject(asset)
        return ""
    if asset.Has("relativePath")
        return String(asset["relativePath"])
    return asset.Has("path") ? String(asset["path"]) : ""
}

; Accepts either a relative "media\name" value or an absolute path pointing
; inside the media directory, and returns the relative form. Returns "" for
; anything else, including paths outside the media directory, so unexpected
; values are left alone instead of being rewritten into something worse.
NotesStoreRelativeAssetPath(stored) {
    global NotesStoreMedia
    value := Trim(StrReplace(String(stored), "/", "\"))
    if value = "" || InStr(value, "..")
        return ""
    prefix := NotesStoreMedia . "\"
    if SubStr(value, 1, StrLen(prefix)) = prefix
        value := SubStr(value, StrLen(prefix) + 1)
    else if SubStr(value, 1, 6) = "media\"
        value := SubStr(value, 7)
    else if RegExMatch(value, "^[A-Za-z]:\\")
        return ""
    if !RegExMatch(value, "^[^\\]+$")
        return ""
    return "media\" . value
}

; Repairs note_assets rows written by older builds: an absolute media path, and
; a path stored without its file extension. Both forms are rewritten to
; "media\<file>.<ext>" and the file is moved when the extension was missing.
NotesStoreSql(value) {
    return "'" . StrReplace(String(value), "'", "''") . "'"
}

NotesStoreLike(value) {
    value := StrReplace(String(value), "\", "\\")
    value := StrReplace(value, "%", "\%")
    value := StrReplace(value, "_", "\_")
    return NotesStoreSql("%" . value . "%")
}

NotesStoreEscapeSql() {
    return " ESCAPE " . NotesStoreSql("\")
}

NotesStoreNow() {
    return Integer(FormatTime(A_NowUTC, "yyyyMMddHHmmss"))
}

NotesStoreQuery(sql, &table) {
    global NotesDB, NotesDBReady, NotesStoreError
    table := 0
    if !NotesDBReady || !IsObject(NotesDB) {
        if NotesStoreError = ""
            NotesStoreError := "笔记数据库尚未初始化"
        return false
    }
    if !NotesDB.GetTable(sql, &table) {
        NotesStoreError := NotesDB.ErrorMsg != "" ? NotesDB.ErrorMsg : "笔记数据库查询失败"
        DebugLog("notes query failed: " . NotesStoreError)
        return false
    }
    NotesStoreError := ""
    return true
}

NotesStoreExec(sql) {
    global NotesDB, NotesDBReady, NotesStoreError
    if !NotesDBReady || !IsObject(NotesDB) {
        if NotesStoreError = ""
            NotesStoreError := "笔记数据库尚未初始化"
        return false
    }
    if !NotesDB.Exec(sql) {
        NotesStoreError := NotesDB.ErrorMsg != "" ? NotesDB.ErrorMsg : "笔记数据库写入失败"
        DebugLog("notes exec failed: " . NotesStoreError)
        return false
    }
    NotesStoreError := ""
    return true
}

NotesStoreList(searchText := "", tagName := "", dateAfter := "", dateBefore := "",
    page := 1, pageSize := 20) {
    global NotesStoreError
    if !NotesStoreInit()
        return 0
    dateAfter := Trim(String(dateAfter))
    dateBefore := Trim(String(dateBefore))
    invalidAfter := dateAfter != "" && !RegExMatch(dateAfter, "^\d{14}$")
    invalidBefore := dateBefore != "" && !RegExMatch(dateBefore, "^\d{14}$")
    if invalidAfter || invalidBefore {
        NotesStoreError := "日期筛选无效"
        return 0
    }
    if pageSize != 20 && pageSize != 50 && pageSize != 100
        pageSize := 20
    where := "1=1"
    searchText := Trim(searchText)
    if searchText != "" {
        like := NotesStoreLike(searchText)
        escape := NotesStoreEscapeSql()
        where .= " AND (n.title LIKE " . like . escape
            . " OR n.content_md LIKE " . like . escape
            . " OR EXISTS (SELECT 1 FROM note_tags nst JOIN tags st ON st.id=nst.tag_id"
            . " WHERE nst.note_id=n.id AND st.name LIKE " . like . escape . "))"
    }
    tagName := Trim(tagName)
    if tagName = "__none__" {
        where .= " AND NOT EXISTS (SELECT 1 FROM note_tags unt WHERE unt.note_id=n.id)"
    } else if tagName != "" && StrLower(tagName) != "all" {
        where .= " AND EXISTS (SELECT 1 FROM note_tags ft JOIN tags ftag ON ftag.id=ft.tag_id"
            . " WHERE ft.note_id=n.id AND ftag.name=" . NotesStoreSql(tagName) . ")"
    }
    if dateAfter != ""
        where .= " AND n.updated_at>=" . Integer(dateAfter)
    if dateBefore != ""
        where .= " AND n.updated_at<" . Integer(dateBefore)
    if !NotesStoreQuery("SELECT COUNT(*) AS matching FROM notes n WHERE " . where . ";",
        &countTable)
        return 0
    total := countTable.RowCount > 0 ? Integer(countTable.Rows[1][1]) : 0
    pageCount := Max(1, Ceil(total / pageSize))
    page := page > pageCount ? pageCount : Max(1, Integer(page))
    if !total
        return Map("rows", [], "total", 0, "page", 1, "pageCount", 1)
    offset := (page - 1) * pageSize
    sql := "SELECT n.id,n.title,substr(n.content_md,1,4000),n.pinned,n.updated_at,"
        . "IFNULL((SELECT t.name FROM note_tags nt JOIN tags t ON t.id=nt.tag_id"
        . " WHERE nt.note_id=n.id ORDER BY t.name LIMIT 1),'')"
        . " FROM notes n WHERE " . where
        . " ORDER BY n.pinned DESC,n.updated_at DESC,n.id DESC"
        . " LIMIT " . pageSize . " OFFSET " . offset . ";"
    if !NotesStoreQuery(sql, &table)
        return 0
    noteIds := []
    for raw in table.Rows
        noteIds.Push(Integer(raw[1]))
    assetIndex := NotesStoreAssetUrlIndex(noteIds)
    rows := []
    for raw in table.Rows {
        noteId := Integer(raw[1])
        noteAssets := assetIndex.Has(noteId) ? assetIndex[noteId] : Map()
        assetList := []
        for assetId, assetUrl in noteAssets
            assetList.Push(Map("id", assetId, "url", assetUrl))
        rows.Push(Map(
            "id", noteId,
            "title", raw[2],
            ; The page renders this with Vditor and walks the result, so it gets
            ; the Markdown itself. `assets` has the same shape NotesStoreAssets
            ; hands the editor, and `revision` is the token the page echoes back
            ; so a click can be validated without reparsing anything here.
            "markdown", raw[3],
            "assets", assetList,
            "revision", NotesNoteRevision(raw[5]),
            "pinned", Integer(raw[4]) != 0,
            "updatedAt", String(raw[5]),
            "tag", raw[6]))
    }
    return Map("rows", rows, "total", total, "page", page, "pageCount", pageCount)
}

; Change token for a note: the page echoes it back with a click and the store
; compares it against the note as it is now.
;
; Only updated_at is used. Pairing it with a content length looks stricter but
; SQLite's length() counts characters while AHK's StrLen() counts UTF-16 code
; units, so any note holding an emoji or an astral CJK character would compute
; two different tokens and copying would fail outright. The window this leaves
; open -- two saves inside the same second -- is closed in practice because the
; list is re-sent (and the card re-rendered) after every save.
NotesNoteRevision(updatedAt) {
    return String(updatedAt)
}

NotesNoteRevisionOf(note) {
    return NotesNoteRevision(note["updatedAt"])
}

; Absolute path of an asset that still belongs to the given note, or "" when the
; note no longer references it (a stale row) or the file is missing. Copying and
; pasting an image both go through this, so a row can never reach a file that is
; not part of the note it was clicked on.
NotesStoreAssetFilePath(noteId, assetId) {
    global NotesStoreRoot
    asset := NotesStoreGetNoteAsset(noteId, assetId)
    if !IsObject(asset)
        return ""
    relative := NotesStoreRelativeAssetPath(asset["path"])
    if relative = ""
        return ""
    path := NotesStoreRoot . "\" . relative
    return FileExist(path) ? path : ""
}

; One query for every asset referenced by the listed notes, so rendering the
; list does not add a lookup per image. Assets whose file is gone are left out
; on purpose: the page substitutes asset: references through this map and falls
; back to the alt text when an id is missing, which is what keeps a lost image
; from turning into a broken picture.
NotesStoreAssetUrlIndex(noteIds) {
    global NotesStoreRoot
    index := Map()
    if !IsObject(noteIds) || !noteIds.Length
        return index
    ids := ""
    for noteId in noteIds
        ids .= (ids = "" ? "" : ",") . Integer(noteId)
    if ids = "" || !NotesStoreQuery("SELECT note_id,id,relative_path,mime FROM note_assets WHERE note_id IN (" . ids . ");", &table)
        return index
    for raw in table.Rows {
        relative := NotesStoreRelativeAssetPath(raw[3])
        if relative = "" || !FileExist(NotesStoreRoot . "\" . relative)
            continue
        noteId := Integer(raw[1])
        if !index.Has(noteId)
            index[noteId] := Map()
        index[noteId][raw[2]] := NotesAssetUrl(raw[2], raw[4])
    }
    return index
}

NotesStoreReadNote(noteId) {
    if !NotesStoreInit() || !RegExMatch(String(noteId), "^\d+$")
        return 0
    sql := "SELECT id,title,content_md,pinned,created_at,updated_at FROM notes WHERE id=" . Integer(noteId) . " LIMIT 1;"
    if !NotesStoreQuery(sql, &table) || table.RowCount < 1
        return 0
    raw := table.Rows[1]
    tags := []
    if NotesStoreQuery("SELECT t.name FROM note_tags nt JOIN tags t ON t.id=nt.tag_id WHERE nt.note_id=" . Integer(noteId) . " ORDER BY t.name;", &tagTable)
        for tagRow in tagTable.Rows
            tags.Push(tagRow[1])
    assets := NotesStoreAssets(noteId)
    return Map(
        "id", Integer(raw[1]),
        "title", raw[2],
        "content", raw[3],
        "pinned", Integer(raw[4]) != 0,
        "createdAt", String(raw[5]),
        "updatedAt", String(raw[6]),
        "tags", tags,
        "assets", assets)
}

NotesStoreAssets(noteId) {
    assets := []
    if !NotesStoreQuery("SELECT id,relative_path,mime,original_name FROM note_assets WHERE note_id=" . Integer(noteId) . " ORDER BY created_at,id;", &table)
        return assets
    for raw in table.Rows
        assets.Push(Map(
            "id", raw[1],
            "path", raw[2],
            "mime", raw[3],
            "name", raw[4],
            "url", NotesAssetUrl(raw[1], raw[3])))
    return assets
}

NotesStoreGetAssetRows(noteId) {
    rows := []
    if NotesStoreQuery("SELECT id,relative_path,mime,original_name FROM note_assets WHERE note_id=" . Integer(noteId) . ";", &table)
        for raw in table.Rows
            rows.Push(Map("id", raw[1], "path", raw[2], "mime", raw[3], "name", raw[4]))
    return rows
}

NotesStoreGetNoteAsset(noteId, assetId) {
    if !RegExMatch(String(noteId), "^\d+$") || !RegExMatch(String(assetId), "^[A-Za-z0-9_-]+$")
        return 0
    sql := "SELECT id,relative_path,mime,original_name FROM note_assets WHERE note_id=" . Integer(noteId)
        . " AND id=" . NotesStoreSql(assetId) . " LIMIT 1;"
    if !NotesStoreQuery(sql, &table) || table.RowCount < 1
        return 0
    raw := table.Rows[1]
    return Map("id", raw[1], "path", raw[2], "mime", raw[3], "name", raw[4])
}

NotesStoreSaveNote(noteId, title, content, tagNames, editorId, &savedId := 0) {
    global NotesDB, NotesStoreError
    savedId := 0
    if !NotesStoreInit()
        return false
    if noteId != "" && !RegExMatch(String(noteId), "^\d+$")
        return false
    if Type(tagNames) != "Array"
        tagNames := []
    content := String(content)
    referenced := NotesAssetIdsFromMarkdown(content)
    if !NotesValidateAssetReferences(noteId, editorId, referenced)
        return false
    oldAssets := noteId != "" ? NotesStoreGetAssetRows(noteId) : []
    oldAssetMap := Map()
    for oldAsset in oldAssets
        oldAssetMap[oldAsset["id"]] := oldAsset
    now := NotesStoreNow()
    criticalState := Critical("On")
    try {
        if !NotesStoreExec("BEGIN IMMEDIATE;")
            return false
        try {
            if noteId = "" {
                sql := "INSERT INTO notes(title,content_md,pinned,created_at,updated_at) VALUES("
                    . NotesStoreSql(title) . "," . NotesStoreSql(content)
                    . ",0," . now . "," . now . ");"
                if !NotesStoreExec(sql)
                    throw Error(NotesStoreError)
                noteId := String(NotesDB.LastInsertRowID())
            } else {
                sql := "UPDATE notes SET title=" . NotesStoreSql(title)
                    . ",content_md=" . NotesStoreSql(content)
                    . ",updated_at=" . now . " WHERE id=" . Integer(noteId) . ";"
                if !NotesStoreExec(sql)
                    throw Error(NotesStoreError)
            }
            if !NotesStoreExec("DELETE FROM note_tags WHERE note_id=" . Integer(noteId) . ";")
                throw Error(NotesStoreError)
            for tagName in tagNames {
                tagName := Trim(String(tagName))
                if tagName = ""
                    continue
                if !NotesStoreExec("INSERT OR IGNORE INTO tags(name,created_at,updated_at) VALUES(" . NotesStoreSql(tagName) . "," . now . "," . now . ");")
                    throw Error(NotesStoreError)
                if !NotesStoreQuery("SELECT id FROM tags WHERE name=" . NotesStoreSql(tagName) . " LIMIT 1;", &tagTable) || tagTable.RowCount < 1
                    throw Error("读取标签失败")
                tagId := Integer(tagTable.Rows[1][1])
                if !NotesStoreExec("INSERT OR IGNORE INTO note_tags(note_id,tag_id) VALUES(" . Integer(noteId) . "," . tagId . ");")
                    throw Error(NotesStoreError)
            }
            if !NotesStoreExec("DELETE FROM note_assets WHERE note_id=" . Integer(noteId) . ";")
                throw Error(NotesStoreError)
            for assetId in referenced {
                asset := NotesAssetForSave(assetId, noteId, editorId, oldAssetMap)
                if !IsObject(asset)
                    throw Error("图片资产不存在或不属于当前笔记")
                if !NotesStoreExec("INSERT INTO note_assets(id,note_id,relative_path,mime,original_name,created_at) VALUES("
                    . NotesStoreSql(asset["id"]) . "," . Integer(noteId) . "," . NotesStoreSql(NotesAssetStoredPath(asset))
                    . "," . NotesStoreSql(asset["mime"]) . "," . NotesStoreSql(asset["name"]) . "," . now . ");")
                    throw Error(NotesStoreError)
            }
            if !NotesStoreExec("COMMIT;")
                throw Error(NotesStoreError)
        } catch as saveError {
            try NotesStoreExec("ROLLBACK;")
            NotesStoreError := saveError.Message
            return false
        }
    } finally {
        Critical(criticalState)
    }
    savedId := Integer(noteId)
    NotesFinalizeAssets(editorId, referenced, savedId)
    for old in oldAssets {
        keep := false
        for assetId in referenced
            if old["id"] = assetId
                keep := true
        if !keep
            NotesDeleteRelativeAsset(old["path"])
    }
    return true
}

NotesStoreDeleteNotes(noteIds) {
    global NotesStoreError
    if !NotesStoreInit() || Type(noteIds) != "Array"
        return false
    oldAssets := []
    for noteId in noteIds {
        if !RegExMatch(String(noteId), "^\d+$")
            continue
        for asset in NotesStoreGetAssetRows(noteId)
            oldAssets.Push(asset["path"])
    }
    criticalState := Critical("On")
    try {
        if !NotesStoreExec("BEGIN IMMEDIATE;")
            return false
        try {
            for noteId in noteIds
                if RegExMatch(String(noteId), "^\d+$")
                    if !NotesStoreExec("DELETE FROM notes WHERE id=" . Integer(noteId) . ";")
                        throw Error(NotesStoreError)
            if !NotesStoreExec("COMMIT;")
                throw Error(NotesStoreError)
        } catch as deleteError {
            try NotesStoreExec("ROLLBACK;")
            NotesStoreError := deleteError.Message
            return false
        }
    } finally {
        Critical(criticalState)
    }
    for path in oldAssets
        NotesDeleteRelativeAsset(path)
    return true
}

NotesStoreSetPinned(noteIds, value) {
    global NotesStoreError
    if !NotesStoreInit() || Type(noteIds) != "Array"
        return false
    pin := value ? 1 : 0
    criticalState := Critical("On")
    try {
        if !NotesStoreExec("BEGIN IMMEDIATE;")
            return false
        try {
            for noteId in noteIds
                if RegExMatch(String(noteId), "^\d+$")
                    if !NotesStoreExec("UPDATE notes SET pinned=" . pin . ",updated_at=updated_at WHERE id=" . Integer(noteId) . ";")
                        throw Error(NotesStoreError)
            if !NotesStoreExec("COMMIT;")
                throw Error(NotesStoreError)
        } catch as pinError {
            try NotesStoreExec("ROLLBACK;")
            NotesStoreError := pinError.Message
            return false
        }
    } finally {
        Critical(criticalState)
    }
    return true
}

; Only accepts a row whose note has not changed since the page rendered it.
;
; The page derives its copy text from the Markdown the list handed out, so while
; the revision still matches, that text is still what the note says and nothing
; needs reparsing on this side. A stale card copies nothing instead.
NotesStoreCopyRow(noteId, revision, text) {
    text := String(text)
    if text = ""
        return ""
    note := NotesStoreReadNote(noteId)
    if !IsObject(note)
        return ""
    return NotesNoteRevisionOf(note) = String(revision) ? text : ""
}

NotesStoreTagList() {
    tags := []
    if !NotesStoreInit()
        return tags
    sql := "SELECT t.id,t.name,(SELECT COUNT(*) FROM note_tags nt2 WHERE nt2.tag_id=t.id) FROM tags t ORDER BY t.name;"
    if NotesStoreQuery(sql, &table)
        for row in table.Rows
            tags.Push(Map("id", Integer(row[1]), "name", row[2], "count", Integer(row[3])))
    return tags
}

NotesStoreAddTag(name) {
    name := Trim(String(name))
    if name = "" || !NotesStoreInit()
        return false
    return NotesStoreExec("INSERT OR IGNORE INTO tags(name,created_at,updated_at) VALUES(" . NotesStoreSql(name) . "," . NotesStoreNow() . "," . NotesStoreNow() . ");")
}

NotesStoreRenameTag(tagId, name) {
    name := Trim(String(name))
    if name = "" || !RegExMatch(String(tagId), "^\d+$") || !NotesStoreInit()
        return false
    return NotesStoreExec("UPDATE tags SET name=" . NotesStoreSql(name) . ",updated_at=" . NotesStoreNow() . " WHERE id=" . Integer(tagId) . ";")
}

NotesStoreDeleteTag(tagId) {
    if !RegExMatch(String(tagId), "^\d+$") || !NotesStoreInit()
        return false
    return NotesStoreExec("DELETE FROM tags WHERE id=" . Integer(tagId) . ";")
}
