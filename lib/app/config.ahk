; Typed configuration schema and runtime accessors.

global Config := Map()
global ConfigDefaults := Map()
global ConfigLoadLastFailure := ""

ConfigLoad(&errorCode := "", &userDocument := 0) {
    global Config, ConfigDefaults, ConfigLoadLastFailure
    errorCode := ""
    userDocument := 0
    try {
        if !SettingsStoreLoad(&defaultsCandidate, &overrides)
            return ConfigLoadFail("database_read", &errorCode)
        if !SettingsStoreValidateDefaultSet(defaultsCandidate, &missingDefault)
            throw Error("数据库缺少可信默认值 " . missingDefault)
        for section, record in ConfigSchema()
            if record["kind"] = "static"
                for key in record["keys"]
                    if !defaultsCandidate.Has(section) || !defaultsCandidate[section].Has(key)
                        throw Error("数据库缺少可信默认值 " . section . "/" . key)
        for document in [defaultsCandidate, overrides]
            for section, values in document
                for key, value in values {
                    if !ConfigValidateValue(section, key, value, &normalized)
                        throw Error("数据库配置值无效 " . section . "/" . key)
                    values[key] := normalized
                }
        configCandidate := ConfigCloneDocument(defaultsCandidate)
        ConfigOverlay(configCandidate, overrides)
        for section in ConfigSchemaSections()
            if !configCandidate.Has(section)
                configCandidate[section] := Map()
    } catch as loadError {
        DiagnosticLogAlways("Config database load failed errorType=" . Type(loadError)
            . " detail=" . loadError.Message)
        return ConfigLoadFail("candidate_decode", &errorCode)
    }
    ConfigDefaults := defaultsCandidate
    Config := configCandidate
    userDocument := overrides
    ConfigLoadLastFailure := ""
    return true
}

ConfigLoadFail(stage, &errorCode) {
    global ConfigLoadLastFailure
    errorCode := stage
    if ConfigLoadLastFailure != stage {
        DiagnosticLogAlways("Config load failed stage=" . stage)
        ConfigLoadLastFailure := stage
    }
    return false
}

ConfigCloneDocument(source) {
    result := Map()
    if !IsObject(source)
        return result
    for section, values in source {
        result[section] := Map()
        if IsObject(values) {
            for key, value in values
                result[section][key] := value
        }
    }
    return result
}

; One metadata boundary for values accepted by the live settings surface.
; Dynamic sections accept user keys under the generic key
; restrictions enforced by ConfigValidateValue().
ConfigSchema() {
    static schema := ConfigBuildSchema()
    return schema
}

ConfigBuildSchema() {
    languages := TranslateLanguageCodes()
    targetLanguages := ["system"]
    for language in languages
        targetLanguages.Push(language)
    return Map(
        "Global", Map("kind", "static", "keys", Map(
            "autostart", ConfigDefineField("bool", "0", "开机启动", "general", "order", 30),
            "mouseSpeed", ConfigDefineField("int", "3", "临时鼠标速度", "mouse", "wide", true, "min", 1, "max", 20),
            "allowClipboard", ConfigDefineField("bool", "1", "独立剪贴板", "general", "order", 50),
            "debug", ConfigDefineField("bool", "0", "调试日志", "general", "order", 70),
            "loadingAnimation", ConfigDefineField("bool", "1", "启动动画", "general", "order", 60),
            "webViewDestroyMinutes", ConfigDefineField("int", "30", "面板隐藏后释放页面（分钟）", "general", "order", 20, "min", 0, "max", 1440, "hint", "0 表示关闭。"),
            "language", ConfigDefineField("enum", "1", "界面语言", "general", "order", 10, "values", ["0", "1", "2"], "labels", Map("0", "跟随系统", "1", "简体中文", "2", "English")),
            "runAsAdmin", ConfigDefineField("bool", "1", "以管理员身份运行", "general", "order", 40, "hint", "重启后生效。"),
            ; Internal first-run state; it is persisted but intentionally has
            ; no control in the settings page.
            "usageShown", ConfigDefineField("bool", "0", "首次使用状态", "general", "hidden", true))),
        "LLM", Map("kind", "static", "keys", Map(
            "endpoint", ConfigDefineField("text", "", "API 地址", "llm", "order", 10, "wide", true, "placeholder", "https://.../v1/chat/completions"),
            "apiKey", ConfigDefineField("secret", "", "API Key", "llm", "order", 20),
            "apiKeyHeader", ConfigDefineField("text", "Authorization", "认证字段", "llm", "hidden", true),
            "apiKeyPrefix", ConfigDefineField("text", "Bearer", "密钥前缀", "llm", "hidden", true),
            "model", ConfigDefineField("text", "deepseek-flash", "模型", "llm", "order", 30),
            "thinking", ConfigDefineField("bool", "0", "使用模型默认思考模式", "llm", "order", 70),
            "temperature", ConfigDefineField("optionalNumber", "0.2", "Temperature", "llm", "order", 50),
            "timeout", ConfigDefineField("int", "30000", "超时（毫秒）", "llm", "order", 60, "min", 1000, "max", 120000),
            "maxInputTokens", ConfigDefineField("optionalPositiveInt", "200000", "最大输入 Token", "llm", "order", 40))),
        "LLMTranslate", Map("kind", "static", "keys", Map(
            "systemPrompt", ConfigDefineField("text", "You are a precise translation engine. Translate the user's message into {{targetLanguage}}. Preserve meaning, tone, formatting, names and code. Keep the source text's line breaks and paragraph structure. Return only the translation, nothing else.", "系统提示词", "llmTranslate", "codec", "jsonScalar", "wide", true, "multiline", true))),
        "TTranslate", Map("kind", "static", "keys", Map(
            "mode", ConfigDefineField("enum", "fixed", "翻译方式", "translate", "order", 10, "values", ["fixed", "bidirectional"], "labels", Map("fixed", "固定目标语言", "bidirectional", "两种语言互译")),
            "languageA", ConfigDefineField("enum", "zh-CN", "语言 A", "translate", "order", 40, "values", languages, "when", Map("key", "mode", "equals", "bidirectional")),
            "languageB", ConfigDefineField("enum", "en", "语言 B", "translate", "order", 50, "values", languages, "when", Map("key", "mode", "equals", "bidirectional")),
            "targetLanguage", ConfigDefineField("enum", "system", "目标语言", "translate", "order", 30, "wide", true, "values", targetLanguages, "when", Map("key", "mode", "equals", "fixed"), "labels", Map("system", "系统语言")),
            "engine", ConfigDefineField("enum", "auto", "引擎", "translate", "order", 20, "values", ["auto", "llm", "youdao", "volcengine"], "labels", Map("auto", "自动", "llm", "LLM", "youdao", "有道", "volcengine", "火山")))),
        "TYoudao", Map("kind", "static", "keys", Map(
            "appPaidID", ConfigDefineField("secret", "", "App ID", "youdao", "order", 10),
            "appPaidKey", ConfigDefineField("secret", "", "App Key", "youdao", "order", 20))),
        "TVolcengine", Map("kind", "static", "keys", Map(
            "accessKey", ConfigDefineField("secret", "", "Access Key", "volcengine", "order", 20),
            "secretKey", ConfigDefineField("secret", "", "Secret Key", "volcengine", "order", 30),
            "region", ConfigDefineField("text", "cn-north-1", "Region", "volcengine", "order", 10, "wide", true))),
        "QAI", Map("kind", "static", "keys", Map(
            "systemPrompt", ConfigDefineField("text", "You are the assistant built into the capslock_p2 launcher. The user's message is either a question to answer or a text to explain; decide which one it is. If it is a question, answer it directly and completely. If it is a text (a word, sentence, paragraph, error message, log entry, code snippet or URL), explain what it means. Reply in the language of the user's message; if the message is not in Chinese or English, reply in {{uiLanguage}}. Be concise.", "系统提示词", "ai", "codec", "jsonScalar", "wide", true, "multiline", true))),
        "Keys", Map("kind", "keys", "defaults", ConfigDefaultShortcuts()),
        "TabHotString", Map("kind", "dynamic", "codec", "hotString"),
        "CustomHotkey", Map("kind", "dynamic", "codec", "plain"))
}

ConfigDefineField(typeName, initialValue, label, group, options*) {
    field := Map("type", typeName, "default", initialValue, "label", label, "group", group)
    if options.Length
        field.Set(options*)
    return field
}

; Consumed only when creating/upgrading the database.
ConfigDefaultDocument() {
    document := Map()
    for section, definition in ConfigSchema() {
        values := Map()
        if definition.Has("keys") {
            for key, field in definition["keys"]
                values[key] := field["default"]
        } else if definition.Has("defaults") {
            for key, value in definition["defaults"]
                values[key] := value
        }
        document[section] := values
    }
    return document
}

ConfigDefaultShortcuts() {
    return Map(
        "press_caps", "keyFunc_toggleCapsLock",
        "caps_a", "keyFunc_moveWordLeft",
        "caps_b", "keyFunc_moveDown(10)",
        "caps_c", "keyFunc_copy_1",
        "caps_d", "keyFunc_moveDown",
        "caps_e", "keyFunc_moveUp",
        "caps_f", "keyFunc_moveRight",
        "caps_g", "keyFunc_moveWordRight",
        "caps_h", "keyFunc_selectWordLeft",
        "caps_i", "keyFunc_selectUp",
        "caps_j", "keyFunc_selectLeft",
        "caps_k", "keyFunc_selectDown",
        "caps_l", "keyFunc_selectRight",
        "caps_m", "keyFunc_doNothing",
        "caps_n", "keyFunc_selectDown(10)",
        "caps_o", "keyFunc_selectEnd",
        "caps_p", "keyFunc_home",
        "caps_q", "keyFunc_qbar",
        "caps_r", "keyFunc_delete",
        "caps_s", "keyFunc_moveLeft",
        "caps_t", "keyFunc_translate",
        "caps_u", "keyFunc_selectHome",
        "caps_v", "keyFunc_paste_1",
        "caps_w", "keyFunc_backspace",
        "caps_x", "keyFunc_cut_1",
        "caps_y", "keyFunc_selectUp(10)",
        "caps_z", "keyFunc_clipboardHistory",
        "caps_backquote", "keyFunc_doNothing",
        "caps_1", "keyFunc_winbind_activate(1)",
        "caps_2", "keyFunc_winbind_activate(2)",
        "caps_3", "keyFunc_winbind_activate(3)",
        "caps_4", "keyFunc_winbind_activate(4)",
        "caps_5", "keyFunc_winbind_activate(5)",
        "caps_6", "keyFunc_winbind_activate(6)",
        "caps_7", "keyFunc_winbind_activate(7)",
        "caps_8", "keyFunc_winbind_activate(8)",
        "caps_9", "keyFunc_winbind_activate(9)",
        "caps_0", "keyFunc_winbind_activate(10)",
        "caps_minus", "keyFunc_pageUp",
        "caps_equal", "keyFunc_pageDown",
        "caps_backspace", "keyFunc_deleteLine",
        "caps_tab", "keyFunc_tabHotString",
        "caps_esc", "keyFunc_esc",
        "caps_leftSquareBracket", "keyFunc_deleteToLineBeginning",
        "caps_rightSquareBracket", "keyFunc_doNothing",
        "caps_backslash", "keyFunc_doNothing",
        "caps_semicolon", "keyFunc_end",
        "caps_quote", "keyFunc_doNothing",
        "caps_enter", "keyFunc_enterWherever",
        "caps_comma", "keyFunc_selectCurrentWord",
        "caps_dot", "keyFunc_selectWordRight",
        "caps_slash", "keyFunc_deleteToLineEnd",
        "caps_space", "keyFunc_enter",
        "caps_ralt", "keyFunc_doNothing",
        "caps_f1", "keyFunc_openCpasDocs",
        "caps_f2", "keyFunc_notes",
        "caps_f3", "keyFunc_translate",
        "caps_f4", "keyFunc_winTransparent",
        "caps_f5", "keyFunc_reload",
        "caps_f6", "keyFunc_winPin",
        "caps_f7", "keyFunc_aiChat",
        "caps_f8", "keyFunc_doNothing",
        "caps_f9", "keyFunc_doNothing",
        "caps_f10", "keyFunc_doNothing",
        "caps_f11", "keyFunc_doNothing",
        "caps_f12", "keyFunc_openSettings",
        "caps_lalt_a", "keyFunc_moveWordLeft(3)",
        "caps_lalt_b", "keyFunc_moveDown(30)",
        "caps_lalt_c", "keyFunc_copy_2",
        "caps_lalt_d", "keyFunc_moveDown(3)",
        "caps_lalt_e", "keyFunc_moveUp(3)",
        "caps_lalt_f", "keyFunc_moveRight(5)",
        "caps_lalt_g", "keyFunc_moveWordRight(3)",
        "caps_lalt_h", "keyFunc_selectWordLeft(3)",
        "caps_lalt_i", "keyFunc_selectUp(3)",
        "caps_lalt_j", "keyFunc_selectLeft(5)",
        "caps_lalt_k", "keyFunc_selectDown(3)",
        "caps_lalt_l", "keyFunc_selectRight(5)",
        "caps_lalt_m", "keyFunc_doNothing",
        "caps_lalt_n", "keyFunc_selectDown(30)",
        "caps_lalt_o", "keyFunc_selectToPageEnd",
        "caps_lalt_p", "keyFunc_moveToPageBeginning",
        "caps_lalt_q", "keyFunc_doNothing",
        "caps_lalt_r", "keyFunc_forwardDeleteWord",
        "caps_lalt_s", "keyFunc_moveLeft(5)",
        "caps_lalt_t", "keyFunc_moveUp(30)",
        "caps_lalt_u", "keyFunc_selectToPageBeginning",
        "caps_lalt_v", "keyFunc_paste_2",
        "caps_lalt_w", "keyFunc_deleteWord",
        "caps_lalt_x", "keyFunc_cut_2",
        "caps_lalt_y", "keyFunc_selectUp(30)",
        "caps_lalt_z", "keyFunc_doNothing",
        "caps_lalt_backquote", "keyFunc_doNothing",
        "caps_lalt_1", "keyFunc_winbind_binding(1)",
        "caps_lalt_2", "keyFunc_winbind_binding(2)",
        "caps_lalt_3", "keyFunc_winbind_binding(3)",
        "caps_lalt_4", "keyFunc_winbind_binding(4)",
        "caps_lalt_5", "keyFunc_winbind_binding(5)",
        "caps_lalt_6", "keyFunc_winbind_binding(6)",
        "caps_lalt_7", "keyFunc_winbind_binding(7)",
        "caps_lalt_8", "keyFunc_winbind_binding(8)",
        "caps_lalt_9", "keyFunc_winbind_binding(9)",
        "caps_lalt_0", "keyFunc_winbind_binding(10)",
        "caps_lalt_minus", "keyFunc_doNothing",
        "caps_lalt_equal", "keyFunc_doNothing",
        "caps_lalt_backspace", "keyFunc_deleteAll",
        "caps_lalt_tab", "keyFunc_doNothing",
        "caps_lalt_esc", "keyFunc_esc",
        "caps_lalt_leftSquareBracket", "keyFunc_deleteToPageBeginning",
        "caps_lalt_rightSquareBracket", "keyFunc_doNothing",
        "caps_lalt_backslash", "keyFunc_doNothing",
        "caps_lalt_semicolon", "keyFunc_moveToPageEnd",
        "caps_lalt_quote", "keyFunc_doNothing",
        "caps_lalt_enter", "keyFunc_doNothing",
        "caps_lalt_comma", "keyFunc_selectCurrentLine",
        "caps_lalt_dot", "keyFunc_selectWordRight(3)",
        "caps_lalt_slash", "keyFunc_deleteToPageEnd",
        "caps_lalt_space", "keyFunc_doNothing",
        "caps_lalt_ralt", "keyFunc_doNothing",
        "caps_lalt_f1", "keyFunc_doNothing",
        "caps_lalt_f2", "keyFunc_doNothing",
        "caps_lalt_f3", "keyFunc_doNothing",
        "caps_lalt_f4", "keyFunc_doNothing",
        "caps_lalt_f5", "keyFunc_doNothing",
        "caps_lalt_f6", "keyFunc_doNothing",
        "caps_lalt_f7", "keyFunc_doNothing",
        "caps_lalt_f8", "keyFunc_doNothing",
        "caps_lalt_f9", "keyFunc_doNothing",
        "caps_lalt_f10", "keyFunc_doNothing",
        "caps_lalt_f11", "keyFunc_doNothing",
        "caps_lalt_f12", "keyFunc_doNothing",
        "caps_lalt_wheelUp", "keyFunc_mouseSpeedIncrease",
        "caps_lalt_wheelDown", "keyFunc_mouseSpeedDecrease")
}

ConfigEditorSchema() {
    fields := Map()
    for section, definition in ConfigSchema() {
        if !definition.Has("keys")
            continue
        fields[section] := Map()
        for key, field in definition["keys"] {
            publicField := Map()
            for name, value in field
                if name != "default" && name != "codec"
                    publicField[name] := value
            fields[section][key] := publicField
        }
    }
    return Map("fields", fields, "groups", [
        Map("id", "general", "page", "general", "title", "通用设置"),
        Map("id", "mouse", "page", "mouse", "title", "鼠标",
            "hint", "按住 CapsLock + 左 Alt 时生效，松开后恢复系统鼠标速度。"),
        Map("id", "llm", "page", "llm", "title", "共用 LLM", "action", "testLlm"),
        Map("id", "translate", "page", "translate", "title", "翻译共用配置"),
        Map("id", "llmTranslate", "page", "translate", "title", "LLM 翻译", "action", "openLlm"),
        Map("id", "youdao", "page", "translate", "title", "有道翻译", "action", "testYoudao"),
        Map("id", "volcengine", "page", "translate", "title", "火山翻译", "action", "testVolcengine"),
        Map("id", "ai", "page", "ai", "title", "问答设置", "action", "openLlm")])
}

ConfigSchemaSections() {
    sections := []
    for section in ConfigSchema()
        sections.Push(section)
    return sections
}

ConfigField(section, key) {
    schema := ConfigSchema()
    if !schema.Has(section)
        return 0
    record := schema[section]
    if !record.Has("keys") || !record["keys"].Has(key)
        return 0
    return record["keys"][key]
}

ConfigIsDynamicSection(section) {
    schema := ConfigSchema()
    return schema.Has(section) && schema[section].Has("kind")
        && schema[section]["kind"] = "dynamic"
}

ConfigValidateKey(section, key) {
    key := String(key)
    if key = "" || RegExMatch(key, "[=`r`n]") || StrLen(key) > 120
        return false
    if section != "CustomHotkey" && RegExMatch(key, "[\[\]]")
        return false
    if section = "Keys"
        return RegExMatch(key, "i)^(press_caps|caps(_lalt)?_[A-Za-z0-9_]+)$")
    if section = "CustomHotkey"
        return ConfigValidateCustomHotkeyTrigger(key)
    field := ConfigField(section, key)
    return IsObject(field) || ConfigIsDynamicSection(section)
}

ConfigNormalizeCustomHotkeyTrigger(trigger) {
    raw := Trim(String(trigger))
    if raw = ""
        return ""
    prefix := ""
    while StrLen(raw) && InStr("^!+#", SubStr(raw, 1, 1)) {
        prefix .= SubStr(raw, 1, 1)
        raw := SubStr(raw, 2)
    }
    canonicalPrefix := ""
    for modifier in ["^", "!", "+", "#"]
        if InStr(prefix, modifier)
            canonicalPrefix .= modifier
    ; The recorder uses Send syntax for special keys; Hotkey names omit braces.
    if StrLen(raw) >= 2 && SubStr(raw, 1, 1) = "{" && SubStr(raw, -1) = "}"
        raw := SubStr(raw, 2, StrLen(raw) - 2)
    return StrLower(canonicalPrefix . raw)
}

ConfigValidateCustomHotkeyTrigger(trigger) {
    normalized := ConfigNormalizeCustomHotkeyTrigger(trigger)
    if normalized = ""
        return false
    keyName := normalized
    while StrLen(keyName) && InStr("^!+#", SubStr(keyName, 1, 1))
        keyName := SubStr(keyName, 2)
    if keyName = "" || RegExMatch(keyName, "[{}\s]")
        return false
    keyCode := 0
    try keyCode := GetKeyVK(keyName)
    catch
        keyCode := 0
    if keyCode
        return true
    ; Mouse and joystick hotkeys do not map to a virtual key code.
    return RegExMatch(keyName,
        "i)^(?:Wheel(?:Up|Down|Left|Right)|[LRM]Button|XButton[12]|Joy(?:[1-9]|[12][0-9]|3[0-2]))$")
}

ConfigValidateValue(section, key, value, &normalized := "") {
    normalized := ""
    if IsObject(value)
        return false
    text := String(value)
    ; An empty custom-hotkey action removes the mapping, including a malformed
    ; legacy trigger which must remain removable from the settings page.
    if (!ConfigValidateKey(section, key)
        && !(section = "CustomHotkey" && Trim(text) = ""))
        return false
    field := ConfigField(section, key)
    if !IsObject(field) {
        if section = "Keys" {
            if Trim(text) = "" {
                normalized := "@block"
                return true
            }
            normalized := text
            return !RegExMatch(text, "[`r`n]")
                && (text = "@block" || text = "@native"
                    || SettingsStoreParseAction(text, &actionKey, &actionArgs))
        }
        if ConfigIsDynamicSection(section) {
            normalized := text
            if section = "TabHotString"
                return true
            return !RegExMatch(text, "[`r`n]")
        }
        return false
    }

    valueType := field.Has("type") ? field["type"] : "text"
    switch valueType {
        case "bool":
            lowered := StrLower(Trim(text))
            if lowered = "1" || lowered = "true" || lowered = "on"
                normalized := "1"
            else if lowered = "0" || lowered = "false" || lowered = "off"
                normalized := "0"
            else
                return false
        case "int":
            if !RegExMatch(Trim(text), "^-?\d+$")
                return false
            parsedInteger := Integer(text)
            if field.Has("min") && parsedInteger < field["min"]
                return false
            if field.Has("max") && parsedInteger > field["max"]
                return false
            normalized := String(parsedInteger)
        case "optionalPositiveInt":
            if Trim(text) = "" {
                normalized := ""
            } else {
                if !RegExMatch(Trim(text), "^\d+$") || Integer(text) < 1
                    return false
                normalized := String(Integer(text))
            }
        case "optionalNumber":
            if Trim(text) = "" {
                normalized := ""
            } else {
                if !RegExMatch(Trim(text), "^-?(?:\d+\.?\d*|\.\d+)$")
                    return false
                normalized := Trim(text)
            }
        case "enum":
            normalized := Trim(text)
            enumMatch := false
            for candidate in field["values"] {
                if StrLower(candidate) = StrLower(normalized) {
                    normalized := candidate
                    enumMatch := true
                    break
                }
            }
            if !enumMatch
                return false
        case "text", "secret":
            if (!field.Has("codec") || field["codec"] != "jsonScalar") {
                if RegExMatch(text, "[`r`n]")
                    return false
            }
            normalized := text
        default:
            return false
    }
    return true
}

ConfigOverlay(target, overlay) {
    if !IsObject(overlay)
        return
    for section, values in overlay {
        if !target.Has(section)
            target[section] := Map()
        for key, value in values
            target[section][key] := value
    }
}

ConfigRead(section, key, defaultValue := "") {
    global Config
    if Config.Has(section) && Config[section].Has(key)
        return Config[section][key]
    return defaultValue
}

ConfigGlobalRead(key, defaultValue := "") {
    return ConfigRead("Global", key, defaultValue)
}

ConfigSection(section) {
    global Config
    return Config.Has(section) ? Config[section] : Map()
}

ConfigSnapshot() {
    global Config
    return ConfigClone(Config)
}

ConfigClone(document) {
    result := Map()
    if !IsObject(document)
        return result
    for section, values in document {
        result[section] := Map()
        if !IsObject(values)
            continue
        for key, value in values
            result[section][key] := IsObject(value) ? ConfigClone(value) : String(value)
    }
    return result
}

ConfigEffectiveDiff(previous, current) {
    changes := Map()
    sections := Map()
    if IsObject(previous)
        for section, values in previous
            sections[section] := true
    if IsObject(current)
        for section, values in current
            sections[section] := true
    for section in sections {
        oldValues := IsObject(previous) && previous.Has(section) ? previous[section] : Map()
        newValues := IsObject(current) && current.Has(section) ? current[section] : Map()
        keys := Map()
        if IsObject(oldValues)
            for key, value in oldValues
                keys[key] := true
        if IsObject(newValues)
            for key, value in newValues
                keys[key] := true
        for key in keys {
            oldHasKey := IsObject(oldValues) && oldValues.Has(key)
            newHasKey := IsObject(newValues) && newValues.Has(key)
            oldValue := oldHasKey ? String(oldValues[key]) : ""
            newValue := newHasKey ? String(newValues[key]) : ""
            if oldHasKey = newHasKey && oldValue = newValue
                continue
            if !changes.Has(section)
                changes[section] := Map()
            changes[section][key] := newValue
        }
    }
    return changes
}

ConfigDefaultHas(section, key) {
    global ConfigDefaults
    return ConfigDefaults.Has(section) && ConfigDefaults[section].Has(key)
}

ConfigDefaultRead(section, key, defaultValue := "") {
    global ConfigDefaults
    if ConfigDefaults.Has(section) && ConfigDefaults[section].Has(key)
        return ConfigDefaults[section][key]
    return defaultValue
}
