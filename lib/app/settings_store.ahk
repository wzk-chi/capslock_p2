; Configuration defaults, user overrides and secrets in the shared AppStore.
global SettingsStoreSourceVersion := 2

SettingsStoreValidateDefaultSet(defaults, &missingField := "") {
    missingField := ""
    expected := ConfigSchema()
    ; Empty sections have no cfg_defaults rows. Require only declared fields.
    for section, definition in expected {
        fields := definition.Has("keys") ? definition["keys"] : definition.Get("defaults", Map())
        for key in fields {
            if !defaults.Has(section) || !defaults[section].Has(key) {
                missingField := section . "/" . key
                return false
            }
        }
    }
    return true
}

SettingsStoreSyncDefaults(db) {
    seed := ConfigDefaultDocument()
    if !SettingsStoreValidateDefaultSet(seed, &missingField)
        throw Error("可信默认配置声明不完整：" . missingField)
    for section, values in seed {
        if section = "Qbar"
            continue
        for key, value in values {
            if !ConfigValidateValue(section, key, value, &normalized)
                throw Error("可信默认配置无效：" . section . "/" . key)
            jsonValue := SettingsStoreJsonScalar(normalized)
            sql := "INSERT INTO cfg_defaults(scope,key,value_json) VALUES ("
                . AppStoreSql(section) . "," . AppStoreSql(key) . "," . AppStoreSql(jsonValue)
                . ") ON CONFLICT(scope,key) DO UPDATE SET value_json=excluded.value_json;"
            if !db.Exec(sql)
                throw Error(db.ErrorMsg != "" ? db.ErrorMsg : "无法保存默认配置")
        }
    }
    return true
}

SettingsStoreCreateGlobalScope(db) {
    sql := "INSERT OR IGNORE INTO cfg_hotkey_scopes(id,kind,exe_path,normalized_path,display_name,enabled) "
        . "VALUES ('global','global','','','全局',1);"
    if !db.Exec(sql)
        throw Error(db.ErrorMsg != "" ? db.ErrorMsg : "无法创建全局快捷键范围")
}

SettingsStoreJsonScalar(value) => SubStr(JSON.stringify([String(value)], 0), 2, -1)

SettingsStoreParseScalar(jsonValue) {
    try value := JSON.Parse("[" . String(jsonValue) . "]")
    catch
        throw Error("数据库配置值不是有效 JSON")
    if !IsObject(value) || value.Length != 1 || IsObject(value[1])
        throw Error("数据库配置值必须为 JSON 标量")
    return String(value[1])
}

SettingsStoreLoad(&defaults, &overrides) {
    global AppStoreDb
    defaults := Map()
    overrides := Map()
    if !AppStoreInit()
        return false
    if !AppStoreDb.GetTable("SELECT scope,key,value_json FROM cfg_defaults ORDER BY scope,key;", &rows)
        throw Error(AppStoreDb.ErrorMsg != "" ? AppStoreDb.ErrorMsg : "无法读取默认配置")
    for row in rows.Rows
        SettingsStorePut(defaults, String(row[1]), String(row[2]), SettingsStoreParseScalar(row[3]))

    if !AppStoreDb.GetTable("SELECT scope,key,value_json FROM cfg_values ORDER BY scope,key;", &rows)
        throw Error(AppStoreDb.ErrorMsg != "" ? AppStoreDb.ErrorMsg : "无法读取用户配置")
    for row in rows.Rows
        SettingsStorePut(overrides, String(row[1]), String(row[2]), SettingsStoreParseScalar(row[3]))

    if !AppStoreDb.GetTable("SELECT trigger,action_key,args_json FROM cfg_key_overrides WHERE scope_id='global';", &rows)
        throw Error(AppStoreDb.ErrorMsg != "" ? AppStoreDb.ErrorMsg : "无法读取快捷键映射")
    for row in rows.Rows
        SettingsStorePut(overrides, "Keys", String(row[1]),
            SettingsStoreComposeAction(String(row[2]), String(row[3])))
    if !AppStoreDb.GetTable("SELECT trigger,action_value FROM cfg_custom_hotkeys WHERE scope_id='global';", &rows)
        throw Error(AppStoreDb.ErrorMsg != "" ? AppStoreDb.ErrorMsg : "无法读取自定义快捷键")
    for row in rows.Rows
        SettingsStorePut(overrides, "CustomHotkey", String(row[1]), String(row[2]))
    if !AppStoreDb.GetTable("SELECT trigger,replacement_text FROM cfg_hotstrings;", &rows)
        throw Error(AppStoreDb.ErrorMsg != "" ? AppStoreDb.ErrorMsg : "无法读取热字符串")
    for row in rows.Rows
        SettingsStorePut(overrides, "TabHotString", String(row[1]), String(row[2]))

    if !AppStoreDb.GetTable("SELECT scope,key,hex(protected_blob) FROM cfg_secrets;", &rows)
        throw Error(AppStoreDb.ErrorMsg != "" ? AppStoreDb.ErrorMsg : "无法读取凭据")
    for row in rows.Rows {
        try secret := SettingsStoreUnprotectHex(String(row[3]))
        catch as decryptError {
            DiagnosticLogAlways("Settings credential unavailable scope=" . String(row[1])
                . " key=" . String(row[2]) . " errorType=" . Type(decryptError))
            throw Error("无法读取已保存的凭据 " . String(row[1]) . "/" . String(row[2]))
        }
        SettingsStorePut(overrides, String(row[1]), String(row[2]), secret)
    }
    return true
}

SettingsStorePut(document, section, key, value) {
    if !document.Has(section)
        document[section] := Map()
    document[section][key] := String(value)
}

SettingsStoreParseAction(actionText, &actionKey := "", &args := 0) {
    text := Trim(String(actionText))
    actionKey := ""
    args := []
    if text = "@block" || text = "@native" {
        actionKey := text
        return true
    }
    open := InStr(text, "(")
    if open {
        if SubStr(text, -1) != ")"
            return false
        actionKey := Trim(SubStr(text, 1, open - 1))
        argumentText := SubStr(text, open + 1, StrLen(text) - open - 1)
        args := SplitActionArguments(argumentText, &argumentsValid)
        if !argumentsValid
            return false
    } else {
        if InStr(text, ")")
            return false
        actionKey := text
    }
    if !ConfiguredActionFunctionAllowed(actionKey) || args.Length > 8
        return false
    for value in args
        if InStr(value, "`r") || InStr(value, "`n") || StrLen(value) > 2048
            return false
    return SettingsStoreValidateActionArguments(actionKey, args)
}

SettingsStoreValidateActionArguments(actionKey, args) {
    static optionalCount := Map("keyFunc_moveLeft", true, "keyFunc_moveRight", true,
        "keyFunc_moveUp", true, "keyFunc_moveDown", true, "keyFunc_moveWordLeft", true,
        "keyFunc_moveWordRight", true, "keyFunc_selectUp", true, "keyFunc_selectDown", true,
        "keyFunc_selectLeft", true, "keyFunc_selectRight", true, "keyFunc_selectWordLeft", true,
        "keyFunc_selectWordRight", true, "keyFunc_pageMoveLineUp", true, "keyFunc_pageMoveLineDown", true)
    static textArguments := Map("keyFunc_send", true, "keyFunc_run", true, "keyFunc_sendChar", true)
    if optionalCount.Has(actionKey) {
        if !args.Length
            return true
        if args.Length != 1 || !RegExMatch(Trim(args[1]), "^\d+$")
            return false
        try argumentNumber := Integer(args[1])
        catch
            return false
        return argumentNumber >= 1 && argumentNumber <= 10000
    }
    if actionKey = "keyFunc_winbind_activate" || actionKey = "keyFunc_winbind_binding" {
        if args.Length != 1 || !RegExMatch(Trim(args[1]), "^\d+$")
            return false
        try argumentNumber := Integer(args[1])
        catch
            return false
        return argumentNumber >= 1 && argumentNumber <= 10
    }
    if textArguments.Has(actionKey)
        return args.Length = 1
    if actionKey = "keyFunc_doubleChar"
        return args.Length >= 1 && args.Length <= 2
    return args.Length = 0
}

SettingsStoreComposeAction(actionKey, argsJson) {
    try args := JSON.Parse(String(argsJson))
    catch
        throw Error("快捷键参数不是有效 JSON")
    if Type(args) != "Array" || args.Length > 8
        throw Error("快捷键参数格式无效")
    action := String(actionKey)
    if action = "@block" || action = "@native" {
        if args.Length
            throw Error("保留的快捷键动作不能带参数")
        return action
    }
    if !ConfiguredActionFunctionAllowed(action)
        throw Error("快捷键动作未注册")
    if !args.Length
        return action
    quote := Chr(34)
    encodedArgs := ""
    for value in args {
        value := String(value)
        encoded := RegExMatch(value, "^-?\d+$") ? value
            : quote . StrReplace(value, quote, quote . quote) . quote
        encodedArgs .= (encodedArgs = "" ? "" : ",") . encoded
    }
    return action . "(" . encodedArgs . ")"
}

SettingsStoreSecretPresent(section, key) {
    global AppStoreDb, AppStoreReady
    if !AppStoreReady || !IsObject(AppStoreDb)
        return false
    if !AppStoreDb.GetTable("SELECT count(*) FROM cfg_secrets WHERE scope="
        . AppStoreSql(section) . " AND key=" . AppStoreSql(key) . ";", &rows)
        return false
    return rows.RowCount && Integer(rows.Rows[1][1]) > 0
}

SettingsStoreReadSecret(section, key, &value := "") {
    global AppStoreDb, AppStoreReady
    value := ""
    field := ConfigField(String(section), String(key))
    if !AppStoreReady || !IsObject(AppStoreDb) || !IsObject(field)
        || !field.Has("type") || field["type"] != "secret"
        return false
    if !AppStoreDb.GetTable("SELECT hex(protected_blob) FROM cfg_secrets WHERE scope="
        . AppStoreSql(section) . " AND key=" . AppStoreSql(key) . ";", &rows)
        return false
    if rows.RowCount != 1 || rows.Rows[1].Length < 1
        return false
    try value := SettingsStoreUnprotectHex(String(rows.Rows[1][1]))
    catch as decryptError {
        DebugLog("Settings credential unavailable scope=" . String(section)
            . " key=" . String(key) . " errorType=" . Type(decryptError))
        return false
    }
    return true
}

SettingsStoreSetValue(section, key, value, &normalizedOut := "", db := 0) {
    global AppStoreDb, ConfigDefaults
    if !IsObject(db)
        db := AppStoreDb
    normalized := ""
    if !ConfigValidateValue(section, key, value, &normalized)
        return false
    normalizedOut := normalized
    if section = "Keys" {
        if ConfigDefaults.Has(section) && ConfigDefaults[section].Has(key)
            && String(ConfigDefaults[section][key]) = normalized
            return db.Exec("DELETE FROM cfg_key_overrides WHERE scope_id='global' AND trigger="
                . AppStoreSql(key) . ";")
        if !SettingsStoreParseAction(normalized, &actionKey, &actionArgs)
            return false
        sql := "INSERT INTO cfg_key_overrides(scope_id,trigger,action_key,args_json) VALUES ('global',"
            . AppStoreSql(key) . "," . AppStoreSql(actionKey) . ","
            . AppStoreSql(JSON.stringify(actionArgs, 0))
            . ") ON CONFLICT(scope_id,trigger) DO UPDATE SET action_key=excluded.action_key,args_json=excluded.args_json;"
        return db.Exec(sql)
    }
    if section = "CustomHotkey" {
        if normalized = ""
            return db.Exec("DELETE FROM cfg_custom_hotkeys WHERE scope_id='global' AND trigger="
                . AppStoreSql(key) . ";")
        return db.Exec("INSERT INTO cfg_custom_hotkeys(scope_id,trigger,action_kind,action_value) VALUES ('global',"
            . AppStoreSql(key) . ",'serialized'," . AppStoreSql(normalized)
            . ") ON CONFLICT(scope_id,trigger) DO UPDATE SET action_kind=excluded.action_kind,action_value=excluded.action_value;")
    }
    if section = "TabHotString" {
        if normalized = ""
            return db.Exec("DELETE FROM cfg_hotstrings WHERE trigger=" . AppStoreSql(key) . ";")
        return db.Exec("INSERT INTO cfg_hotstrings(trigger,replacement_text) VALUES ("
            . AppStoreSql(key) . "," . AppStoreSql(normalized)
            . ") ON CONFLICT(trigger) DO UPDATE SET replacement_text=excluded.replacement_text;")
    }
    isSecret := IsObject(ConfigField(section, key))
        && ConfigField(section, key).Has("type") && ConfigField(section, key)["type"] = "secret"
    try {
        if isSecret {
            if normalized = ""
                return db.Exec("DELETE FROM cfg_secrets WHERE scope=" . AppStoreSql(section)
                    . " AND key=" . AppStoreSql(key) . ";")
            protectedHex := SettingsStoreProtectHex(normalized)
            sql := "INSERT INTO cfg_secrets(scope,key,protected_blob) VALUES ("
                . AppStoreSql(section) . "," . AppStoreSql(key) . ",X'" . protectedHex
                . "') ON CONFLICT(scope,key) DO UPDATE SET protected_blob=excluded.protected_blob;"
            return db.Exec(sql)
        }
        if ConfigDefaults.Has(section) && ConfigDefaults[section].Has(key)
            && String(ConfigDefaults[section][key]) = normalized
            return db.Exec("DELETE FROM cfg_values WHERE scope=" . AppStoreSql(section)
                . " AND key=" . AppStoreSql(key) . ";")
        jsonValue := SettingsStoreJsonScalar(normalized)
        sql := "INSERT INTO cfg_values(scope,key,value_json) VALUES ("
            . AppStoreSql(section) . "," . AppStoreSql(key) . "," . AppStoreSql(jsonValue)
            . ") ON CONFLICT(scope,key) DO UPDATE SET value_json=excluded.value_json;"
        return db.Exec(sql)
    } catch as storeError {
        DebugLog("Settings store write failed scope=" . section . " key=" . key
            . " errorType=" . Type(storeError))
        return false
    }
}

SettingsStoreWriteChanges(changes, profiles := 0) {
    for section, values in changes
        for key, value in values
            if !SettingsStoreSetValue(String(section), String(key), value)
                return false
    if IsObject(profiles) && !AppProfileStoreReplace(profiles)
        return false
    return true
}

SettingsStoreProtectHex(value) {
    bytes := StrPut(String(value), "UTF-8") - 1
    input := Buffer(bytes + 1, 0)
    StrPut(String(value), input, "UTF-8")
    inputBlob := Buffer(A_PtrSize = 8 ? 16 : 8, 0)
    NumPut("UInt", bytes, inputBlob, 0)
    NumPut("Ptr", input.Ptr, inputBlob, A_PtrSize = 8 ? 8 : 4)
    outputBlob := Buffer(A_PtrSize = 8 ? 16 : 8, 0)
    if !DllCall("Crypt32\CryptProtectData", "Ptr", inputBlob, "Ptr", 0, "Ptr", 0,
        "Ptr", 0, "Ptr", 0, "UInt", 1, "Ptr", outputBlob)
        throw Error("Windows 无法保护凭据")
    try {
        count := NumGet(outputBlob, 0, "UInt")
        pointer := NumGet(outputBlob, A_PtrSize = 8 ? 8 : 4, "Ptr")
        hex := ""
        Loop count
            hex .= Format("{:02X}", NumGet(pointer, A_Index - 1, "UChar"))
        return hex
    } finally {
        DllCall("Kernel32\LocalFree", "Ptr", NumGet(outputBlob, A_PtrSize = 8 ? 8 : 4, "Ptr"))
    }
}

SettingsStoreUnprotectHex(hex) {
    if !RegExMatch(hex, "i)^(?:[0-9a-f]{2})+$")
        throw Error("数据库凭据密文无效")
    byteCount := StrLen(hex) // 2
    input := Buffer(byteCount, 0)
    Loop byteCount
        NumPut("UChar", Integer("0x" . SubStr(hex, A_Index * 2 - 1, 2)), input, A_Index - 1)
    inputBlob := Buffer(A_PtrSize = 8 ? 16 : 8, 0)
    NumPut("UInt", byteCount, inputBlob, 0)
    NumPut("Ptr", input.Ptr, inputBlob, A_PtrSize = 8 ? 8 : 4)
    outputBlob := Buffer(A_PtrSize = 8 ? 16 : 8, 0)
    if !DllCall("Crypt32\CryptUnprotectData", "Ptr", inputBlob, "Ptr", 0, "Ptr", 0,
        "Ptr", 0, "Ptr", 0, "UInt", 1, "Ptr", outputBlob)
        throw Error("Windows 无法读取此凭据")
    try {
        count := NumGet(outputBlob, 0, "UInt")
        pointer := NumGet(outputBlob, A_PtrSize = 8 ? 8 : 4, "Ptr")
        plainBuffer := Buffer(count + 1, 0)
        DllCall("Kernel32\RtlMoveMemory", "Ptr", plainBuffer, "Ptr", pointer, "UPtr", count)
        return StrGet(plainBuffer, "UTF-8")
    } finally {
        DllCall("Kernel32\LocalFree", "Ptr", NumGet(outputBlob, A_PtrSize = 8 ? 8 : 4, "Ptr"))
    }
}
