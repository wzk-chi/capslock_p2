; Persistent storage for AI chat sessions and question/answer turns.
; User data lives below A_ScriptDir\data and is never shipped or removed by
; the installer.

global AiChatStoreDb := 0
global AiChatStoreReady := false
global AiChatStoreError := ""
global AiChatStoreVersion := 1
global AiChatStoreRoot := A_ScriptDir . "\data"

AiChatStoreEnsureSchema(db) {
    schema := "CREATE TABLE IF NOT EXISTS ai_chat_sessions ("
        . "id INTEGER PRIMARY KEY AUTOINCREMENT,title TEXT NOT NULL,"
        . "title_state TEXT NOT NULL DEFAULT 'pending' CHECK(title_state IN ('pending','auto','fallback','manual')),"
        . "is_pinned INTEGER NOT NULL DEFAULT 0 CHECK(is_pinned IN (0,1)),"
        . "created_at INTEGER NOT NULL,last_chat_at INTEGER NOT NULL);"
        . "CREATE TABLE IF NOT EXISTS ai_chat_turns ("
        . "id INTEGER PRIMARY KEY AUTOINCREMENT,session_id INTEGER NOT NULL REFERENCES ai_chat_sessions(id) ON DELETE CASCADE,"
        . "ordinal INTEGER NOT NULL,question TEXT NOT NULL,answer TEXT NOT NULL DEFAULT '',"
        . "answer_status TEXT NOT NULL DEFAULT 'generating' CHECK(answer_status IN ('generating','complete','interrupted','failed')),"
        . "created_at INTEGER NOT NULL,completed_at INTEGER,UNIQUE(session_id,ordinal));"
        . "CREATE INDEX IF NOT EXISTS idx_ai_chat_sessions_order ON ai_chat_sessions(is_pinned DESC,last_chat_at DESC,id DESC);"
        . "CREATE INDEX IF NOT EXISTS idx_ai_chat_turns_session ON ai_chat_turns(session_id,ordinal DESC);"
    if !db.Exec(schema)
        throw Error(db.ErrorMsg != "" ? db.ErrorMsg : "无法创建 AI 会话数据表")
    return true
}

AiChatStorePath() {
    global AiChatStoreRoot
    return AiChatStoreRoot . "\capslock_p2.db"
}

AiChatStoreInit() {
    global AiChatStoreDb, AiChatStoreReady, AiChatStoreError, AppStoreDb
    if AiChatStoreReady && IsObject(AiChatStoreDb)
        return true

    AiChatStoreError := ""
    db := 0
    try {
        if !AppStoreInit()
            throw Error(AppStoreError != "" ? AppStoreError : "无法初始化应用数据库")
        AiChatStoreDb := AppStoreDb
        if !AppStoreTransaction("ai-recovery", (*) => AiChatStoreRecover(AppStoreDb))
            throw Error(AppStoreError != "" ? AppStoreError : "无法恢复未完成的 AI 会话")
        AiChatStoreReady := true
        return true
    } catch as initError {
        AiChatStoreError := "AI 会话数据库初始化失败：" . initError.Message
        AiChatStoreDb := 0
        AiChatStoreReady := false
        DebugLog("AI chat store init failed error=" . initError.Message)
        return false
    }
}

; A generating row can remain only when the process ended before its callback.
; The question and any saved answer checkpoint stay available to the user.
AiChatStoreRecover(db) {
    now := AiChatStoreNow()
    if !db.Exec("UPDATE ai_chat_sessions SET last_chat_at=" . now
        . " WHERE id IN (SELECT DISTINCT session_id FROM ai_chat_turns WHERE answer_status='generating');")
        throw Error(db.ErrorMsg != "" ? db.ErrorMsg : "无法更新中断会话时间")
    if !db.Exec("UPDATE ai_chat_turns SET answer_status='interrupted',completed_at=" . now
        . " WHERE answer_status='generating';")
        throw Error(db.ErrorMsg != "" ? db.ErrorMsg : "无法恢复未完成的 AI 回答")
    ; A pending title already contains its first-question fallback. If the
    ; app stopped before its one title request, keep that fallback.
    if !db.Exec("UPDATE ai_chat_sessions SET title_state='fallback' WHERE title_state='pending';")
        throw Error(db.ErrorMsg != "" ? db.ErrorMsg : "无法恢复 AI 会话标题状态")
    return true
}

AiChatStoreClose() {
    global AiChatStoreDb, AiChatStoreReady
    AiChatStoreDb := 0
    AiChatStoreReady := false
}

AiChatStoreNow() {
    return Integer(A_Now)
}

AiChatStoreText(value) {
    ; sqlite3_bind_text16's wrapper uses a NUL-terminated string.
    return StrReplace(String(value), Chr(0), "")
}

AiChatStoreParseId(value, &id) {
    id := 0
    raw := Trim(String(value))
    if !RegExMatch(raw, "^\d{1,19}$")
        return false
    raw := RegExReplace(raw, "^0+(?=\d)")
    if raw = "0" || (StrLen(raw) = 19 && StrCompare(raw, "9223372036854775807") > 0)
        return false
    try id := Integer(raw)
    catch
        return false
    return id > 0
}

AiChatStoreBindText(db, statement, index, value, errorMessage) {
    if !db.StatementBindText(statement, index, AiChatStoreText(value))
        throw Error(errorMessage)
}

AiChatStoreBindInteger(db, statement, index, value, errorMessage) {
    if !db.StatementBindInteger(statement, index, Integer(value))
        throw Error(errorMessage)
}

AiChatStoreStep(db, statement, errorMessage) {
    if db.StatementStep(statement) != 101
        throw Error(db.ErrorMsg != "" ? db.ErrorMsg : errorMessage)
}

AiChatStoreExec(sql) {
    global AiChatStoreDb, AiChatStoreReady, AiChatStoreError
    if !AiChatStoreInit()
        return false
    if !AiChatStoreDb.Exec(sql) {
        AiChatStoreError := AiChatStoreDb.ErrorMsg != "" ? AiChatStoreDb.ErrorMsg : "AI 会话数据库写入失败"
        DebugLog("AI chat store write failed error=" . AiChatStoreDb.ErrorMsg)
        return false
    }
    AiChatStoreError := ""
    return true
}

AiChatStoreQuery(sql, &table) {
    global AiChatStoreDb, AiChatStoreError
    table := 0
    if !AiChatStoreInit()
        return false
    if !AiChatStoreDb.GetTable(sql, &table) {
        AiChatStoreError := AiChatStoreDb.ErrorMsg != "" ? AiChatStoreDb.ErrorMsg : "AI 会话数据库读取失败"
        DebugLog("AI chat store query failed error=" . AiChatStoreDb.ErrorMsg)
        return false
    }
    AiChatStoreError := ""
    return true
}

; Create a session on its first submitted question and insert the turn before
; starting the network request. Failed and interrupted questions stay visible.
AiChatStoreBeginTurn(sessionId, fallbackTitle, question,
    &outSessionId, &outTurnId, &firstTurn) {
    global AiChatStoreDb, AiChatStoreError
    outSessionId := 0
    outTurnId := 0
    firstTurn := false
    if !AiChatStoreInit()
        return false
    if sessionId {
        if !AiChatStoreParseId(sessionId, &parsedSessionId)
            return false
        sessionId := parsedSessionId
    }
    question := AiChatStoreText(Trim(String(question)))
    if question = ""
        return false

    now := AiChatStoreNow()
    criticalState := Critical("On")
    try {
        if !AiChatStoreDb.Exec("BEGIN IMMEDIATE;")
            return AiChatStoreSetError(AiChatStoreDb.ErrorMsg, "AI chat begin turn failed")
        try {
            if !sessionId {
                statement := AiChatStoreDb.Prepare(
                    "INSERT INTO ai_chat_sessions(title,title_state,is_pinned,created_at,last_chat_at) VALUES(?, 'pending',0,?,?);")
                if !statement
                    throw Error(AiChatStoreDb.ErrorMsg != "" ? AiChatStoreDb.ErrorMsg : "创建 AI 会话失败")
                try {
                    AiChatStoreBindText(AiChatStoreDb, statement, 1, fallbackTitle, "绑定 AI 会话标题失败")
                    AiChatStoreBindInteger(AiChatStoreDb, statement, 2, now, "绑定 AI 会话时间失败")
                    AiChatStoreBindInteger(AiChatStoreDb, statement, 3, now, "绑定 AI 会话时间失败")
                    AiChatStoreStep(AiChatStoreDb, statement, "创建 AI 会话失败")
                } finally {
                    AiChatStoreDb.StatementFinalize(statement)
                }
                sessionId := AiChatStoreDb.LastInsertRowID()
                firstTurn := true
            } else {
                if !AiChatStoreQuery("SELECT id FROM ai_chat_sessions WHERE id=" . Integer(sessionId) . " LIMIT 1;", &sessionTable)
                    throw Error(AiChatStoreError)
                if sessionTable.RowCount < 1
                    throw Error("会话已不存在，请重新打开历史列表。")
            }

            if !AiChatStoreQuery("SELECT COALESCE(MAX(ordinal),0)+1 FROM ai_chat_turns WHERE session_id=" . Integer(sessionId) . ";", &ordinalTable)
                throw Error(AiChatStoreError)
            ordinal := ordinalTable.RowCount ? Integer(ordinalTable.Rows[1][1]) : 1
            statement := AiChatStoreDb.Prepare(
                "INSERT INTO ai_chat_turns(session_id,ordinal,question,answer,answer_status,created_at) VALUES(?,?,?,'','generating',?);")
            if !statement
                throw Error(AiChatStoreDb.ErrorMsg != "" ? AiChatStoreDb.ErrorMsg : "保存问题失败")
            try {
                AiChatStoreBindInteger(AiChatStoreDb, statement, 1, sessionId, "绑定会话编号失败")
                AiChatStoreBindInteger(AiChatStoreDb, statement, 2, ordinal, "绑定对话顺序失败")
                AiChatStoreBindText(AiChatStoreDb, statement, 3, question, "绑定问题失败")
                AiChatStoreBindInteger(AiChatStoreDb, statement, 4, now, "绑定问题时间失败")
                AiChatStoreStep(AiChatStoreDb, statement, "保存问题失败")
            } finally {
                AiChatStoreDb.StatementFinalize(statement)
            }
            outTurnId := AiChatStoreDb.LastInsertRowID()

            statement := AiChatStoreDb.Prepare("UPDATE ai_chat_sessions SET last_chat_at=? WHERE id=?;")
            if !statement
                throw Error(AiChatStoreDb.ErrorMsg != "" ? AiChatStoreDb.ErrorMsg : "更新会话时间失败")
            try {
                AiChatStoreBindInteger(AiChatStoreDb, statement, 1, now, "绑定会话时间失败")
                AiChatStoreBindInteger(AiChatStoreDb, statement, 2, sessionId, "绑定会话编号失败")
                AiChatStoreStep(AiChatStoreDb, statement, "更新会话时间失败")
            } finally {
                AiChatStoreDb.StatementFinalize(statement)
            }
            if !AiChatStoreDb.Exec("COMMIT;")
                throw Error(AiChatStoreDb.ErrorMsg != "" ? AiChatStoreDb.ErrorMsg : "提交问题失败")
        } catch as beginError {
            try AiChatStoreDb.Exec("ROLLBACK;")
            AiChatStoreError := beginError.Message
            DebugLog("AI chat store begin turn failed error=" . beginError.Message)
            return false
        }
    } finally {
        Critical(criticalState)
    }
    outSessionId := Integer(sessionId)
    AiChatStoreError := ""
    return true
}

AiChatStoreSaveAnswer(sessionId, turnId, answer, status, updateActivity := false) {
    global AiChatStoreDb, AiChatStoreError
    if !AiChatStoreParseId(sessionId, &parsedSessionId) || !AiChatStoreParseId(turnId, &parsedTurnId)
        return false
    sessionId := parsedSessionId
    turnId := parsedTurnId
    if status != "generating" && status != "complete" && status != "interrupted" && status != "failed"
        return false
    if !AiChatStoreInit()
        return false
    now := AiChatStoreNow()
    completedAt := status = "generating" ? 0 : now
    criticalState := Critical("On")
    try {
        if !AiChatStoreDb.Exec("BEGIN IMMEDIATE;")
            return AiChatStoreSetError(AiChatStoreDb.ErrorMsg, "AI chat answer update failed")
        try {
            statement := AiChatStoreDb.Prepare(
                "UPDATE ai_chat_turns SET answer=?,answer_status=?,completed_at=? WHERE id=? AND session_id=?;")
            if !statement
                throw Error(AiChatStoreDb.ErrorMsg != "" ? AiChatStoreDb.ErrorMsg : "保存回答失败")
            try {
                AiChatStoreBindText(AiChatStoreDb, statement, 1, answer, "绑定回答失败")
                AiChatStoreBindText(AiChatStoreDb, statement, 2, status, "绑定回答状态失败")
                if completedAt
                    AiChatStoreBindInteger(AiChatStoreDb, statement, 3, completedAt, "绑定完成时间失败")
                else if !AiChatStoreDb.StatementBindInteger(statement, 3, 0)
                    throw Error("绑定回答状态失败")
                AiChatStoreBindInteger(AiChatStoreDb, statement, 4, turnId, "绑定对话编号失败")
                AiChatStoreBindInteger(AiChatStoreDb, statement, 5, sessionId, "绑定会话编号失败")
                AiChatStoreStep(AiChatStoreDb, statement, "保存回答失败")
            } finally {
                AiChatStoreDb.StatementFinalize(statement)
            }
            if AiChatStoreDb.Changes() < 1
                throw Error("会话或回答已不存在。")
            if updateActivity {
                statement := AiChatStoreDb.Prepare("UPDATE ai_chat_sessions SET last_chat_at=? WHERE id=?;")
                if !statement
                    throw Error(AiChatStoreDb.ErrorMsg != "" ? AiChatStoreDb.ErrorMsg : "更新会话时间失败")
                try {
                    AiChatStoreBindInteger(AiChatStoreDb, statement, 1, now, "绑定会话时间失败")
                    AiChatStoreBindInteger(AiChatStoreDb, statement, 2, sessionId, "绑定会话编号失败")
                    AiChatStoreStep(AiChatStoreDb, statement, "更新会话时间失败")
                } finally {
                    AiChatStoreDb.StatementFinalize(statement)
                }
            }
            if !AiChatStoreDb.Exec("COMMIT;")
                throw Error(AiChatStoreDb.ErrorMsg != "" ? AiChatStoreDb.ErrorMsg : "提交回答失败")
        } catch as updateError {
            try AiChatStoreDb.Exec("ROLLBACK;")
            AiChatStoreError := updateError.Message
            DebugLog("AI chat store answer update failed")
            return false
        }
    } finally {
        Critical(criticalState)
    }
    AiChatStoreError := ""
    return true
}

AiChatStoreResolveTitle(sessionId, title, success) {
    global AiChatStoreDb, AiChatStoreError
    if !AiChatStoreParseId(sessionId, &parsedSessionId) || !AiChatStoreInit()
        return false
    sessionId := parsedSessionId
    state := success ? "auto" : "fallback"
    statement := AiChatStoreDb.Prepare(
        "UPDATE ai_chat_sessions SET title=?,title_state=? WHERE id=? AND title_state='pending';")
    if !statement
        return AiChatStoreSetError(AiChatStoreDb.ErrorMsg, "AI chat title update failed")
    try {
        AiChatStoreBindText(AiChatStoreDb, statement, 1, title, "绑定会话标题失败")
        AiChatStoreBindText(AiChatStoreDb, statement, 2, state, "绑定标题状态失败")
        AiChatStoreBindInteger(AiChatStoreDb, statement, 3, sessionId, "绑定会话编号失败")
        AiChatStoreStep(AiChatStoreDb, statement, "更新会话标题失败")
    } catch as titleError {
        AiChatStoreError := titleError.Message
        DebugLog("AI chat store title update failed")
        return false
    } finally {
        AiChatStoreDb.StatementFinalize(statement)
    }
    AiChatStoreError := ""
    return AiChatStoreDb.Changes() > 0
}

AiChatStoreRenameSession(sessionId, title) {
    global AiChatStoreDb, AiChatStoreError
    if (!AiChatStoreParseId(sessionId, &parsedSessionId) || Trim(String(title)) = ""
        || StrLen(Trim(String(title))) > 80 || !AiChatStoreInit())
        return false
    sessionId := parsedSessionId
    statement := AiChatStoreDb.Prepare(
        "UPDATE ai_chat_sessions SET title=?,title_state='manual' WHERE id=?;")
    if !statement
        return AiChatStoreSetError(AiChatStoreDb.ErrorMsg, "AI chat rename failed")
    try {
        AiChatStoreBindText(AiChatStoreDb, statement, 1, Trim(title), "绑定会话标题失败")
        AiChatStoreBindInteger(AiChatStoreDb, statement, 2, sessionId, "绑定会话编号失败")
        AiChatStoreStep(AiChatStoreDb, statement, "重命名会话失败")
    } catch as renameError {
        AiChatStoreError := renameError.Message
        DebugLog("AI chat store rename failed")
        return false
    } finally {
        AiChatStoreDb.StatementFinalize(statement)
    }
    AiChatStoreError := ""
    return AiChatStoreDb.Changes() > 0
}

AiChatStoreSetPinned(sessionId, value) {
    global AiChatStoreDb, AiChatStoreError
    if !AiChatStoreParseId(sessionId, &parsedSessionId) || !AiChatStoreInit()
        return false
    sessionId := parsedSessionId
    statement := AiChatStoreDb.Prepare("UPDATE ai_chat_sessions SET is_pinned=? WHERE id=?;")
    if !statement
        return AiChatStoreSetError(AiChatStoreDb.ErrorMsg, "AI chat pin update failed")
    try {
        AiChatStoreBindInteger(AiChatStoreDb, statement, 1, value ? 1 : 0, "绑定置顶状态失败")
        AiChatStoreBindInteger(AiChatStoreDb, statement, 2, sessionId, "绑定会话编号失败")
        AiChatStoreStep(AiChatStoreDb, statement, "更新置顶状态失败")
    } catch as pinError {
        AiChatStoreError := pinError.Message
        DebugLog("AI chat store pin update failed")
        return false
    } finally {
        AiChatStoreDb.StatementFinalize(statement)
    }
    AiChatStoreError := ""
    return AiChatStoreDb.Changes() > 0
}

AiChatStoreDeleteSessions(sessionIds) {
    global AiChatStoreDb, AiChatStoreError
    if Type(sessionIds) != "Array" || !AiChatStoreInit()
        return false
    ids := []
    seen := Map()
    for sessionId in sessionIds {
        if !AiChatStoreParseId(sessionId, &parsedSessionId)
            continue
        if !seen.Has(parsedSessionId) {
            seen[parsedSessionId] := true
            ids.Push(parsedSessionId)
        }
    }
    if !ids.Length
        return false
    criticalState := Critical("On")
    try {
        if !AiChatStoreDb.Exec("BEGIN IMMEDIATE;")
            return AiChatStoreSetError(AiChatStoreDb.ErrorMsg, "AI chat delete failed")
        try {
            for sessionId in ids
                if !AiChatStoreDb.Exec("DELETE FROM ai_chat_sessions WHERE id=" . sessionId . ";")
                    throw Error(AiChatStoreDb.ErrorMsg != "" ? AiChatStoreDb.ErrorMsg : "删除会话失败")
            if !AiChatStoreDb.Exec("COMMIT;")
                throw Error(AiChatStoreDb.ErrorMsg != "" ? AiChatStoreDb.ErrorMsg : "提交会话删除失败")
        } catch as deleteError {
            try AiChatStoreDb.Exec("ROLLBACK;")
            AiChatStoreError := deleteError.Message
            DebugLog("AI chat store delete failed")
            return false
        }
    } finally {
        Critical(criticalState)
    }
    AiChatStoreError := ""
    return true
}

AiChatStoreListSessions(limit := 50, offset := 0) {
    limit := Max(1, Min(100, Integer(limit)))
    offset := Max(0, Integer(offset))
    sql := "SELECT id,title,is_pinned,title_state,last_chat_at FROM ai_chat_sessions "
        . "ORDER BY is_pinned DESC,last_chat_at DESC,id DESC LIMIT " . limit . " OFFSET " . offset . ";"
    if !AiChatStoreQuery(sql, &table)
        return 0
    rows := []
    for raw in table.Rows
        rows.Push(Map(
            "id", Integer(raw[1]),
            "title", String(raw[2]),
            "pinned", Integer(raw[3]) != 0,
            "titleState", String(raw[4]),
            "lastChatAt", String(raw[5])))
    return rows
}

AiChatStoreGetSession(sessionId) {
    if !AiChatStoreParseId(sessionId, &parsedSessionId)
        return 0
    sessionId := parsedSessionId
    sql := "SELECT id,title,is_pinned,title_state,last_chat_at FROM ai_chat_sessions WHERE id="
        . Integer(sessionId) . " LIMIT 1;"
    if !AiChatStoreQuery(sql, &table) || table.RowCount < 1
        return 0
    raw := table.Rows[1]
    return Map(
        "id", Integer(raw[1]),
        "title", String(raw[2]),
        "pinned", Integer(raw[3]) != 0,
        "titleState", String(raw[4]),
        "lastChatAt", String(raw[5]))
}

; Read the newest page in ascending order. beforeOrdinal loads the page directly
; before the current oldest turn, preserving an unambiguous scroll anchor.
AiChatStoreReadTurns(sessionId, beforeOrdinal := 0, limit := 100, &hasOlder := false) {
    hasOlder := false
    if !AiChatStoreParseId(sessionId, &parsedSessionId)
        return 0
    sessionId := parsedSessionId
    beforeOrdinal := Max(0, Integer(beforeOrdinal))
    limit := Max(1, Min(100, Integer(limit)))
    where := "session_id=" . sessionId
    if beforeOrdinal
        where .= " AND ordinal<" . beforeOrdinal
    sql := "SELECT id,ordinal,question,answer,answer_status,created_at FROM ai_chat_turns WHERE "
        . where . " ORDER BY ordinal DESC LIMIT " . (limit + 1) . ";"
    if !AiChatStoreQuery(sql, &table)
        return 0
    hasOlder := table.RowCount > limit
    count := Min(table.RowCount, limit)
    rows := []
    Loop count {
        raw := table.Rows[count - A_Index + 1]
        rows.Push(Map(
            "id", Integer(raw[1]),
            "ordinal", Integer(raw[2]),
            "question", String(raw[3]),
            "answer", String(raw[4]),
            "status", String(raw[5]),
            "createdAt", String(raw[6])))
    }
    return rows
}

; Build prompt context from completed turns only. The in-flight question is
; appended by the AI chat host after loading this history.
AiChatStoreLoadContext(sessionId) {
    if !AiChatStoreParseId(sessionId, &parsedSessionId)
        return []
    sessionId := parsedSessionId
    sql := "SELECT question,answer FROM ai_chat_turns WHERE session_id=" . sessionId
        . " AND answer_status='complete' ORDER BY ordinal DESC LIMIT 50;"
    if !AiChatStoreQuery(sql, &table)
        return []
    history := []
    Loop table.RowCount {
        raw := table.Rows[table.RowCount - A_Index + 1]
        history.Push(Map("role", "user", "content", raw[1]))
        history.Push(Map("role", "assistant", "content", raw[2]))
    }
    return history
}

AiChatStoreSetError(detail, logMessage) {
    global AiChatStoreError
    AiChatStoreError := String(detail)
    DebugLog(logMessage)
    return false
}
