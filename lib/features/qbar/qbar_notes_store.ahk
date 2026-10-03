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

NotesStoreDbPath() {
    global NotesStoreRoot
    return NotesStoreRoot . "\qbar-notes.db"
}

NotesStoreInit() {
    global NotesDB, NotesDBReady, NotesStoreError, NotesStoreRoot, NotesStoreMedia
    if NotesDBReady && IsObject(NotesDB)
        return true

    NotesStoreError := ""
    try {
        DirCreate(NotesStoreRoot)
        DirCreate(NotesStoreMedia)
        if !DirExist(NotesStoreRoot) || !DirExist(NotesStoreMedia)
            throw Error("笔记数据目录不可写：" . NotesStoreRoot)

        db := CSQLite(A_ScriptDir . "\resources")
        if !db.OpenDB(NotesStoreDbPath(), "W", true)
            throw Error(db.ErrorMsg != "" ? db.ErrorMsg : "无法打开笔记数据库")
        if !db.SetTimeout(2000)
            throw Error(db.ErrorMsg != "" ? db.ErrorMsg : "无法设置 SQLite 超时")
        if !db.Exec("PRAGMA foreign_keys = ON; PRAGMA busy_timeout = 2000;")
            throw Error(db.ErrorMsg != "" ? db.ErrorMsg : "无法初始化 SQLite")
        NotesStoreMigrate(db)
        NotesDB := db
        NotesDBReady := true
        normalizeOk := false
        try {
            normalizeOk := NotesStoreNormalizeAssetFiles()
        } catch as normalizeError {
            DebugLog("notes asset normalization skipped: " . normalizeError.Message)
        }
        if normalizeOk {
            try {
                NotesStoreCleanOrphans()
            } catch as cleanupError {
                DebugLog("notes orphan cleanup skipped: " . cleanupError.Message)
            }
        }
        return true
    } catch as initError {
        NotesStoreError := "笔记数据库初始化失败（" . NotesStoreDbPath() . "）：" . initError.Message
        if IsObject(NotesDB)
            try NotesDB.CloseDB()
        NotesDB := 0
        NotesDBReady := false
        DebugLog(NotesStoreError)
        return false
    }
}

NotesStoreMigrate(db) {
    global NotesDBVersion
    current := 0
    if !db.GetTable("PRAGMA user_version;", &versionTable)
        throw Error(db.ErrorMsg != "" ? db.ErrorMsg : "无法读取笔记数据库版本")
    if versionTable.RowCount > 0
        current := Integer(versionTable.Rows[1][1])
    if current > NotesDBVersion
        throw Error("笔记数据库版本过高，请更新程序后再使用。")
    if current = NotesDBVersion
        return true
    if current = 1 {
        NotesStoreMigrateV1ToV2(db)
        return true
    }

    schema := ""
    schema .= "CREATE TABLE IF NOT EXISTS notes ("
        . "id INTEGER PRIMARY KEY AUTOINCREMENT,"
        . "title TEXT NOT NULL DEFAULT '',"
        . "content_md TEXT NOT NULL DEFAULT '',"
        . "pinned INTEGER NOT NULL DEFAULT 0,"
        . "created_at INTEGER NOT NULL,"
        . "updated_at INTEGER NOT NULL);"
    schema .= "CREATE TABLE IF NOT EXISTS tags ("
        . "id INTEGER PRIMARY KEY AUTOINCREMENT,"
        . "name TEXT NOT NULL COLLATE NOCASE UNIQUE,"
        . "created_at INTEGER NOT NULL,"
        . "updated_at INTEGER NOT NULL);"
    schema .= "CREATE TABLE IF NOT EXISTS note_tags ("
        . "note_id INTEGER NOT NULL REFERENCES notes(id) ON DELETE CASCADE,"
        . "tag_id INTEGER NOT NULL REFERENCES tags(id) ON DELETE CASCADE,"
        . "PRIMARY KEY(note_id, tag_id));"
    schema .= "CREATE TABLE IF NOT EXISTS note_assets ("
        . "id TEXT PRIMARY KEY,"
        . "note_id INTEGER NOT NULL REFERENCES notes(id) ON DELETE CASCADE,"
        . "relative_path TEXT NOT NULL,"
        . "mime TEXT NOT NULL,"
        . "original_name TEXT NOT NULL DEFAULT '',"
        . "created_at INTEGER NOT NULL);"
    schema .= "CREATE INDEX IF NOT EXISTS idx_notes_order ON notes(pinned DESC, updated_at DESC, id DESC);"
        . "CREATE INDEX IF NOT EXISTS idx_note_tags_tag ON note_tags(tag_id, note_id);"
        . "CREATE INDEX IF NOT EXISTS idx_assets_note ON note_assets(note_id);"

    if !db.Exec("BEGIN IMMEDIATE;")
        throw Error(db.ErrorMsg != "" ? db.ErrorMsg : "无法开始数据库迁移")
    try {
        if !db.Exec(schema)
            throw Error(db.ErrorMsg != "" ? db.ErrorMsg : "创建笔记数据库结构失败")
        if !db.Exec("PRAGMA user_version = " . NotesDBVersion . ";")
            throw Error(db.ErrorMsg != "" ? db.ErrorMsg : "写入笔记数据库版本失败")
        if !db.Exec("COMMIT;")
            throw Error(db.ErrorMsg != "" ? db.ErrorMsg : "提交笔记数据库迁移失败")
    } catch as migrationError {
        try db.Exec("ROLLBACK;")
        throw migrationError
    }
    return true
}

NotesStoreMigrateV1ToV2(db) {
    if !db.Exec("PRAGMA foreign_keys = OFF;")
        throw Error(db.ErrorMsg != "" ? db.ErrorMsg : "无法准备笔记数据库升级")
    if !db.Exec("BEGIN IMMEDIATE;") {
        try db.Exec("PRAGMA foreign_keys = ON;")
        throw Error(db.ErrorMsg != "" ? db.ErrorMsg : "无法开始笔记数据库升级")
    }
    schema := "CREATE TABLE notes_v2 ("
        . "id INTEGER PRIMARY KEY AUTOINCREMENT,"
        . "title TEXT NOT NULL DEFAULT '',"
        . "content_md TEXT NOT NULL DEFAULT '',"
        . "pinned INTEGER NOT NULL DEFAULT 0,"
        . "created_at INTEGER NOT NULL,"
        . "updated_at INTEGER NOT NULL);"
    try {
        if !db.Exec(schema)
            throw Error(db.ErrorMsg != "" ? db.ErrorMsg : "创建升级后的笔记表失败")
        if !db.Exec("INSERT INTO notes_v2(id,title,content_md,pinned,created_at,updated_at) "
            . "SELECT id,title,content_md,pinned,created_at,updated_at FROM notes;")
            throw Error(db.ErrorMsg != "" ? db.ErrorMsg : "迁移笔记内容失败")
        if !db.Exec("DROP TABLE notes;")
            throw Error(db.ErrorMsg != "" ? db.ErrorMsg : "删除旧笔记表失败")
        if !db.Exec("ALTER TABLE notes_v2 RENAME TO notes;")
            throw Error(db.ErrorMsg != "" ? db.ErrorMsg : "重命名升级后的笔记表失败")
        if !db.Exec("CREATE INDEX IF NOT EXISTS idx_notes_order ON notes(pinned DESC, updated_at DESC, id DESC);")
            throw Error(db.ErrorMsg != "" ? db.ErrorMsg : "恢复笔记排序索引失败")
        if !db.Exec("PRAGMA user_version = 2;")
            throw Error(db.ErrorMsg != "" ? db.ErrorMsg : "写入笔记数据库版本失败")
        if !db.Exec("COMMIT;")
            throw Error(db.ErrorMsg != "" ? db.ErrorMsg : "提交笔记数据库升级失败")
    } catch as migrationError {
        try db.Exec("ROLLBACK;")
        try db.Exec("PRAGMA foreign_keys = ON;")
        throw migrationError
    }
    if !db.Exec("PRAGMA foreign_keys = ON;")
        throw Error(db.ErrorMsg != "" ? db.ErrorMsg : "恢复笔记数据库约束失败")
    return true
}

NotesStoreClose() {
    global NotesDB, NotesDBReady
    if IsObject(NotesDB)
        try NotesDB.CloseDB()
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
NotesStoreNormalizeAssetFiles() {
    global NotesStoreRoot, NotesStoreError
    if !NotesStoreQuery("SELECT id,relative_path,mime FROM note_assets;", &table)
        return false
    changes := []
    for raw in table.Rows {
        assetId := String(raw[1])
        stored := StrReplace(String(raw[2]), "/", "\")
        mime := String(raw[3])
        if assetId = "" || stored = ""
            continue
        relative := NotesStoreRelativeAssetPath(stored)
        if relative = ""
            continue
        if !RegExMatch(relative, "\.[A-Za-z0-9]+$")
            relative .= "." . NotesAssetExtension(mime)
        if relative = stored
            continue
        oldPath := NotesStoreRoot . "\" . stored
        newPath := NotesStoreRoot . "\" . relative
        moved := false
        ; Only a legacy row stored without its extension has a file to move;
        ; an absolute path already names the same file as its relative form.
        if FileExist(oldPath) && !FileExist(newPath) {
            try {
                FileMove(oldPath, newPath)
                moved := true
            } catch
                continue
        }
        changes.Push(Map("id", assetId, "oldPath", oldPath, "newPath", newPath,
            "relative", relative, "moved", moved))
    }
    if !changes.Length
        return true
    if !NotesStoreExec("BEGIN IMMEDIATE;") {
        for change in changes
            if change["moved"] && FileExist(change["newPath"]) && !FileExist(change["oldPath"])
                try FileMove(change["newPath"], change["oldPath"])
        return false
    }
    try {
        for change in changes
            if !NotesStoreExec("UPDATE note_assets SET relative_path=" . NotesStoreSql(change["relative"])
                . " WHERE id=" . NotesStoreSql(change["id"]) . ";")
                throw Error(NotesStoreError != "" ? NotesStoreError : "更新图片路径失败")
        if !NotesStoreExec("COMMIT;")
            throw Error(NotesStoreError != "" ? NotesStoreError : "提交图片路径更新失败")
    } catch as normalizeError {
        try NotesStoreExec("ROLLBACK;")
        for change in changes
            if change["moved"] && FileExist(change["newPath"]) && !FileExist(change["oldPath"])
                try FileMove(change["newPath"], change["oldPath"])
        NotesStoreError := normalizeError.Message
        return false
    }
    return true
}

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

NotesStoreList(searchText := "", tagName := "") {
    if !NotesStoreInit()
        return 0
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
    sql := "SELECT n.id,n.title,substr(n.content_md,1,4000),n.pinned,n.updated_at,"
        . "IFNULL((SELECT t.name FROM note_tags nt JOIN tags t ON t.id=nt.tag_id"
        . " WHERE nt.note_id=n.id ORDER BY t.name LIMIT 1),'')"
        . " FROM notes n WHERE " . where
        . " ORDER BY n.pinned DESC,n.updated_at DESC,n.id DESC;"
    if !NotesStoreQuery(sql, &table)
        return 0
    noteIds := []
    for raw in table.Rows
        noteIds.Push(Integer(raw[1]))
    assetIndex := NotesStorePreviewAssetIndex(noteIds)
    rows := []
    for raw in table.Rows {
        noteId := Integer(raw[1])
        noteAssets := assetIndex.Has(noteId) ? assetIndex[noteId] : Map()
        rows.Push(Map(
            "id", noteId,
            "title", raw[2],
            "blocks", NotesStorePreviewBlocks(raw[3], noteAssets),
            "pinned", Integer(raw[4]) != 0,
            "updatedAt", String(raw[5]),
            "tag", raw[6]))
    }
    return rows
}

; The notes list sends rendered preview blocks instead of flat text lines so the
; page can show images and code as they are. Every block carries both what to
; render and the exact plain text its row copies, which keeps Markdown syntax
; out of the clipboard without the page having to strip it.
;
; `assetUrls` maps asset id -> media host URL for the note being previewed;
; images whose asset cannot be resolved fall back to a text row.
;
; `maxRows` is the preview budget: a text row costs 1, an image costs
; `imageRows` and a code block costs its visible line count. Once the next
; block would exceed the budget it is dropped rather than partly rendered.
NotesStorePreviewBlocks(markdown, assetUrls := 0, maxRows := 12, maxCodeLines := 6, imageRows := 4) {
    tick := Chr(96)
    source := StrReplace(StrReplace(String(markdown), "`r`n", "`n"), "`r", "`n")
    lines := StrSplit(source, "`n")
    blocks := []
    rows := 0
    index := 1
    while index <= lines.Length {
        trimmed := Trim(lines[index])

        ; Fenced code: kept verbatim (the copy text is never truncated), only
        ; the displayed body is capped at `maxCodeLines`.
        if RegExMatch(trimmed, "^(" . tick . "{3,}|~{3,})([A-Za-z0-9_+.#-]*)[ \t]*$", &fenceMatch) {
            closer := fenceMatch[1]
            code := []
            index += 1
            while index <= lines.Length && !RegExMatch(Trim(lines[index]), "^" . closer . "[ \t]*$") {
                code.Push(lines[index])
                index += 1
            }
            index += 1
            while code.Length && Trim(code[code.Length]) = ""
                code.Pop()
            if !code.Length
                continue
            full := NotesStorePreviewJoin(code)
            shown := code
            if shown.Length > maxCodeLines {
                cut := []
                Loop maxCodeLines
                    cut.Push(shown[A_Index])
                cut.Push("…")
                shown := cut
            }
            if rows + shown.Length > maxRows
                break
            blocks.Push(Map("kind", "code", "text", NotesStorePreviewJoin(shown), "copy", full))
            rows += shown.Length
            continue
        }

        ; A standalone image line resolves to the media host through the asset
        ; map; anything else keeps falling through to the text path below.
        if RegExMatch(trimmed, "^!\[([^\]]*)\]\(([^)]+)\)$", &imageMatch) {
            url := NotesStorePreviewAssetUrl(imageMatch[2], assetUrls)
            if url != "" {
                if rows + imageRows > maxRows
                    break
                alt := NotesStorePreviewInline(imageMatch[1])
                block := Map("kind", "image", "url", url, "alt", alt)
                if alt != ""
                    block["copy"] := alt
                blocks.Push(block)
                rows += imageRows
                index += 1
                continue
            }
        }

        if RegExMatch(trimmed, "^(#{1,6})[ \t]+(.+)$", &headingMatch) {
            heading := NotesStorePreviewInline(headingMatch[2])
            if heading != "" {
                if rows + 1 > maxRows
                    break
                blocks.Push(Map("kind", "heading", "level", StrLen(headingMatch[1]),
                    "text", heading, "copy", heading))
                rows += 1
                index += 1
                continue
            }
        }

        if RegExMatch(trimmed, "^(?:-{3,}|\*{3,}|_{3,})$") {
            if rows + 1 > maxRows
                break
            blocks.Push(Map("kind", "rule"))
            rows += 1
            index += 1
            continue
        }

        marker := ""
        body := trimmed
        if RegExMatch(trimmed, "^>[ \t]?(.*)$", &quoteMatch) {
            marker := "▏"
            body := quoteMatch[1]
        } else if RegExMatch(trimmed, "^([-*+]|\d+[.)])[ \t]+(.+)$", &listMatch) {
            marker := RegExMatch(listMatch[1], "^\d") ? listMatch[1] : "•"
            body := listMatch[2]
        }
        body := NotesStorePreviewInline(body)
        if body = "" {
            index += 1
            continue
        }
        body := RegExReplace(body, "[ \t]+", " ")
        if rows + 1 > maxRows
            break
        block := Map("kind", "text", "text", body, "copy", body)
        if marker != ""
            block["marker"] := marker
        blocks.Push(block)
        rows += 1
        index += 1
    }
    return blocks
}

NotesStorePreviewJoin(lines) {
    output := ""
    for line in lines
        output .= (A_Index = 1 ? "" : "`n") . line
    return output
}

; Inline Markdown -> the plain text a row copies. Links and images keep their
; label, emphasis keeps its inner text, and code spans lose their backticks, so
; "# 一级标题" copies "一级标题".
NotesStorePreviewInline(text) {
    tick := Chr(96)
    value := String(text)
    value := RegExReplace(value, "!\[([^\]]*)\]\([^)]*\)", "$1")
    value := RegExReplace(value, "\[([^\]]*)\]\([^)]*\)", "$1")
    value := RegExReplace(value, "\*\*([^*]+)\*\*", "$1")
    value := RegExReplace(value, "__([^_]+)__", "$1")
    value := RegExReplace(value, "\*([^*]+)\*", "$1")
    value := RegExReplace(value, "_([^_]+)_", "$1")
    value := RegExReplace(value, "~~([^~]+)~~", "$1")
    value := RegExReplace(value, tick . "([^" . tick . "]+)" . tick, "$1")
    return Trim(value)
}

NotesStorePreviewAssetUrl(source, assetUrls) {
    if !IsObject(assetUrls) || !RegExMatch(String(source), "^asset:([A-Za-z0-9_-]+)$", &match)
        return ""
    return assetUrls.Has(match[1]) ? assetUrls[match[1]] : ""
}

; One query for every asset referenced by the listed notes, so the preview does
; not add a lookup per image. Only assets whose file is actually on disk are
; mapped, so an image whose file was lost falls back to a text row instead of
; rendering a broken image.
NotesStorePreviewAssetIndex(noteIds) {
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
    for path in oldAssets
        NotesDeleteRelativeAsset(path)
    return true
}

NotesStoreSetPinned(noteIds, value) {
    global NotesStoreError
    if !NotesStoreInit() || Type(noteIds) != "Array"
        return false
    pin := value ? 1 : 0
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
    return true
}

; Re-derives the preview from the stored Markdown and only accepts text that
; still exists, so a row clicked against stale content copies nothing. The
; budget is wider than the list's so every row the page could be showing is
; re-derived, and the comparison uses the block's plain copy text.
NotesStoreCopyLine(noteId, line) {
    line := String(line)
    if line = ""
        return ""
    note := NotesStoreReadNote(noteId)
    if !IsObject(note)
        return ""
    assetUrls := Map()
    for asset in NotesStoreAssets(noteId)
        assetUrls[asset["id"]] := asset["url"]
    for block in NotesStorePreviewBlocks(note["content"], assetUrls, 60, 20)
        if block.Has("copy") && block["copy"] = line
            return block["copy"]
    return ""
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
