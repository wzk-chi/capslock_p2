; Per-application hotkey profiles.
; A profile is keyed by the normalized executable path selected by the user.
; Only explicit Keys and CustomHotkey values are stored; missing values inherit
; the global configuration.

global AppProfiles := Map()
global AppProfilesStamp := ""
global AppProfilesLastLoadFailure := ""

; Loads runtime profiles from the prepared application database.
AppProfilesLoad(&changed := false, publish := true) {
    global AppProfiles, AppProfilesStamp, AppProfilesLastLoadFailure
    changed := false
    previousStamp := AppProfilesStamp
    if !AppProfileStoreRead(&candidateProfiles)
        return false
    AppProfilesLastLoadFailure := ""
    candidateStamp := AppProfilesCurrentStamp(candidateProfiles)
    changed := previousStamp != candidateStamp
    if publish {
        AppProfiles := candidateProfiles
        AppProfilesStamp := candidateStamp
    }
    return true
}

AppProfileStoreRead(&profiles) {
    global AppStoreDb, AppStoreReady
    profiles := Map()
    if !AppStoreReady || !IsObject(AppStoreDb)
        return false
    if !AppStoreDb.GetTable("SELECT id,display_name,exe_path,enabled FROM cfg_hotkey_scopes "
        . "WHERE kind='application' ORDER BY id;", &rows) {
        DiagnosticLogAlways("Application profiles database read failed stage=scopes detail="
            . AppStoreDb.ErrorMsg)
        return false
    }
    for row in rows.Rows {
        profileId := String(row[1])
        exePath := AppProfileNormalizePath(row[3])
        if !AppProfileIsValidId(profileId) || exePath = ""
            continue
        profiles[profileId] := Map("id", profileId,
            "displayName", String(row[2]), "exePath", exePath,
            "enabled", String(row[4]) = "1" ? "1" : "0",
            "sections", Map("Keys", Map(), "CustomHotkey", Map()))
    }
    if !AppStoreDb.GetTable("SELECT scope_id,trigger,action_key,args_json FROM cfg_key_overrides;", &rows) {
        DiagnosticLogAlways("Application profiles database read failed stage=key-overrides detail="
            . AppStoreDb.ErrorMsg)
        return false
    }
    for row in rows.Rows {
        profileId := String(row[1])
        if profiles.Has(profileId)
            profiles[profileId]["sections"]["Keys"][String(row[2])] :=
                SettingsStoreComposeAction(String(row[3]), String(row[4]))
    }
    if !AppStoreDb.GetTable("SELECT scope_id,trigger,action_value FROM cfg_custom_hotkeys;", &rows) {
        DiagnosticLogAlways("Application profiles database read failed stage=custom-hotkeys detail="
            . AppStoreDb.ErrorMsg)
        return false
    }
    for row in rows.Rows {
        profileId := String(row[1])
        if profiles.Has(profileId)
            profiles[profileId]["sections"]["CustomHotkey"][String(row[2])] := String(row[3])
    }
    return true
}

AppProfileStoreReplace(profiles, db := 0) {
    global AppStoreDb
    if !IsObject(db)
        db := AppStoreDb
    if Type(profiles) != "Array"
        return false
    if !db.Exec("DELETE FROM cfg_hotkey_scopes WHERE kind='application';")
        return false
    for profile in profiles {
        if Type(profile) != "Map" || !AppProfileIsValidId(profile["id"])
            || AppProfileNormalizePath(profile["exePath"]) = ""
            return false
        exePath := AppProfileNormalizePath(profile["exePath"])
        enabled := AppProfileBoolean(profile["enabled"], true) ? 1 : 0
        sql := "INSERT INTO cfg_hotkey_scopes(id,kind,exe_path,normalized_path,display_name,enabled) VALUES ("
            . AppStoreSql(profile["id"]) . ",'application'," . AppStoreSql(exePath) . ","
            . AppStoreSql(exePath) . "," . AppStoreSql(profile["displayName"]) . "," . enabled . ");"
        if !db.Exec(sql)
            return false
        for key, action in profile["sections"]["Keys"] {
            if !ConfigValidateKey("Keys", key)
                return false
            if !SettingsStoreParseAction(action, &actionKey, &actionArgs)
                return false
            if !db.Exec("INSERT INTO cfg_key_overrides(scope_id,trigger,action_key,args_json) VALUES ("
                . AppStoreSql(profile["id"]) . "," . AppStoreSql(key) . ","
                . AppStoreSql(actionKey) . "," . AppStoreSql(JSON.stringify(actionArgs, 0)) . ");")
                return false
        }
        for trigger, action in profile["sections"]["CustomHotkey"] {
            if !ConfigValidateKey("CustomHotkey", trigger)
                return false
            if !db.Exec("INSERT INTO cfg_custom_hotkeys(scope_id,trigger,action_kind,action_value) VALUES ("
                . AppStoreSql(profile["id"]) . "," . AppStoreSql(trigger)
                . ",'serialized'," . AppStoreSql(action) . ");")
                return false
        }
    }
    return true
}

AppProfilesCurrentStamp(profiles := 0) {
    ; Compare profile data to detect changes in the database.
    global AppProfiles
    if !IsObject(profiles)
        profiles := AppProfiles
    return JSON.stringify(profiles, 0)
}

AppProfilesStampValue() {
    global AppProfilesStamp
    return AppProfilesStamp
}

AppProfileIsValidId(profileId) {
    return RegExMatch(String(profileId), "^kp_[A-Za-z0-9_]+$")
}

AppProfileBoolean(value, fallback := false) {
    if Type(value) = "ComValue" {
        try return value == JSON.true
        catch
            return fallback
    }
    lowered := StrLower(Trim(String(value)))
    if lowered = "1" || lowered = "true" || lowered = "on"
        return true
    if lowered = "0" || lowered = "false" || lowered = "off"
        return false
    return fallback
}

AppProfileTryBoolean(value, &parsed := false) {
    parsed := false
    if Type(value) = "ComValue" {
        try {
            if value == JSON.true {
                parsed := true
                return true
            }
            if value == JSON.false
                return true
        } catch {
            return false
        }
        return false
    }
    if IsObject(value)
        return false
    lowered := StrLower(Trim(String(value)))
    if lowered = "1" || lowered = "true" || lowered = "on" {
        parsed := true
        return true
    }
    if lowered = "0" || lowered = "false" || lowered = "off"
        return true
    return false
}

AppProfileNormalizePath(path) {
    path := StrReplace(Trim(String(path)), "/", "\")
    return StrLower(RTrim(path, "\"))
}

AppProfileDisplayName(path) {
    SplitPath(path, &fileName, &directory, &extension, &nameNoExt)
    if nameNoExt != ""
        return nameNoExt
    return fileName
}

AppProfileGenerateId() {
    global AppProfiles
    Loop 20 {
        candidate := "kp_" . Format("{:08X}", A_TickCount) . "_" . Format("{:06X}", Random(0, 0xFFFFFF))
        if !AppProfiles.Has(candidate)
            return candidate
    }
    return "kp_" . A_TickCount
}

AppProfileFindByPath(path) {
    normalizedPath := AppProfileNormalizePath(path)
    if normalizedPath = ""
        return 0
    for profileId, profile in AppProfiles {
        if profile["exePath"] = normalizedPath
            return profile
    }
    return 0
}

AppProfileDraftFromPath(path) {
    path := AppProfileNormalizePath(path)
    if path = ""
        return 0
    existing := AppProfileFindByPath(path)
    if IsObject(existing)
        return AppProfileSnapshotOne(existing)
    return Map(
        "id", AppProfileGenerateId(),
        "displayName", AppProfileDisplayName(path),
        "exePath", path,
        "enabled", "1",
        "sections", Map("Keys", Map(), "CustomHotkey", Map()))
}

AppProfilesSnapshot(profiles := 0) {
    global AppProfiles
    if !IsObject(profiles)
        profiles := AppProfiles
    result := []
    for profileId, profile in profiles
        result.Push(AppProfileSnapshotOne(profile))
    return result
}

AppProfileSnapshotOne(profile) {
    result := Map(
        "id", String(profile["id"]),
        "displayName", String(profile["displayName"]),
        "exePath", String(profile["exePath"]),
        "enabled", String(profile["enabled"]),
        "sections", Map("Keys", Map(), "CustomHotkey", Map()))
    for sectionName in ["Keys", "CustomHotkey"] {
        if !profile["sections"].Has(sectionName)
            continue
        for key, value in profile["sections"][sectionName]
            result["sections"][sectionName][String(key)] := String(value)
    }
    return result
}

AppProfileActiveForPath(path) {
    global AppProfiles
    normalizedPath := AppProfileNormalizePath(path)
    if normalizedPath = ""
        return 0
    for profileId, profile in AppProfiles {
        if profile["enabled"] = "1" && profile["exePath"] = normalizedPath
            return profile
    }
    return 0
}

AppProfileActive() {
    active := GetActiveWindowInfo()
    if !active
        return 0
    return AppProfileActiveForPath(active.path)
}

AppProfileResolveAction(sectionName, key, fallback, path := "") {
    global Config
    if path = "" {
        active := GetActiveWindowInfo()
        path := active ? active.path : ""
    }
    profile := AppProfileActiveForPath(path)
    if (IsObject(profile) && profile["sections"].Has(sectionName)
        && profile["sections"][sectionName].Has(key))
        return String(profile["sections"][sectionName][key])

    if Config.Has(sectionName) && Config[sectionName].Has(key)
        return String(Config[sectionName][key])
    return fallback
}

AppProfilesNormalizeDraft(profiles, &normalizedProfiles := 0, &errorText := "") {
    errorText := ""
    normalizedProfiles := []
    if Type(profiles) != "Array" {
        errorText := "应用配置数据无效。"
        return false
    }
    seenIds := Map()
    seenPaths := Map()
    for rawProfile in profiles {
        if Type(rawProfile) != "Map" {
            errorText := "应用配置数据无效。"
            return false
        }
        profileId := rawProfile.Has("id") ? Trim(String(rawProfile["id"])) : ""
        displayName := rawProfile.Has("displayName") ? Trim(String(rawProfile["displayName"])) : ""
        exePath := rawProfile.Has("exePath") ? AppProfileNormalizePath(rawProfile["exePath"]) : ""
        enabled := true
        if rawProfile.Has("enabled") && !AppProfileTryBoolean(rawProfile["enabled"], &enabled) {
            errorText := "应用配置启用状态无效。"
            return false
        }
        if (!AppProfileIsValidId(profileId) || exePath = ""
            || RegExMatch(displayName, "[`r`n]") || RegExMatch(exePath, "[`r`n]")) {
            errorText := "应用配置缺少有效的程序路径。"
            return false
        }
        if displayName = ""
            displayName := AppProfileDisplayName(exePath)
        pathKey := exePath
        if seenIds.Has(profileId) || seenPaths.Has(pathKey) {
            errorText := "应用配置重复：" . displayName
            return false
        }
        seenIds[profileId] := true
        seenPaths[pathKey] := true
        sections := rawProfile.Has("sections") ? rawProfile["sections"] : Map()
        if Type(sections) != "Map" {
            errorText := "应用快捷键分组无效。"
            return false
        }
        for sectionName, values in sections {
            if (sectionName != "Keys" && sectionName != "CustomHotkey"
                || Type(values) != "Map") {
                errorText := "应用快捷键分组无效。"
                return false
            }
        }
        normalizedProfile := Map(
            "id", profileId,
            "displayName", displayName,
            "exePath", exePath,
            "enabled", enabled ? "1" : "0",
            "sections", Map("Keys", Map(), "CustomHotkey", Map()))
        for sectionName in ["Keys", "CustomHotkey"] {
            if !sections.Has(sectionName)
                continue
            for key, value in sections[sectionName] {
                normalized := ""
                if sectionName = "CustomHotkey"
                    key := ConfigNormalizeCustomHotkeyTrigger(key)
                if !ConfigValidateKey(sectionName, key) {
                    errorText := "应用快捷键触发键无效：" . displayName . "/" . key
                    return false
                }
                if !ConfigValidateValue(sectionName, key, value, &normalized) {
                    errorText := "应用快捷键值无效：" . displayName . "/" . key
                    return false
                }
                if sectionName = "Keys" && String(normalized) = "@native" {
                    errorText := "CapsLock 层不支持保留应用原键：" . displayName . "/" . key
                    return false
                }
                if normalizedProfile["sections"][sectionName].Has(key) {
                    errorText := "应用快捷键触发键重复：" . displayName . "/" . key
                    return false
                }
                if Trim(String(normalized)) != ""
                    normalizedProfile["sections"][sectionName][String(key)] := String(normalized)
            }
        }
        normalizedProfiles.Push(normalizedProfile)
    }
    return true
}
