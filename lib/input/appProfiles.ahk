; Per-application hotkey profiles.
; A profile is keyed by the normalized executable path selected by the user.
; Only explicit Keys and CustomHotkey values are stored; missing values inherit
; the global configuration.

global AppProfiles := Map()
global AppProfilesStamp := ""
global AppProfilesLastLoadFailure := ""
global AppProfilesSourceContent := ""
global AppProfilesSourceExists := false
global AppProfilesSourceKnown := false

; Builds a profile candidate from a fresh read or a supplied INI snapshot.
; `changed` compares it to the published stamp; `publish` controls replacement.
AppProfilesLoad(&changed := false, publish := true, source := 0) {
    global AppProfiles, AppProfilesStamp, SettingsFile, AppProfilesLastLoadFailure
    global AppProfilesSourceContent, AppProfilesSourceExists, AppProfilesSourceKnown
    changed := false
    previousStamp := AppProfilesStamp
    sourceProvided := IsObject(source)
    sourceContent := ""
    sourceExists := false
    if sourceProvided {
        sections := source
    } else {
        sourceContent := ConfigReadIni(SettingsFile, &loaded, &sourceExists)
        if !loaded {
            if AppProfilesLastLoadFailure != "read"
                DebugLog("Application profiles load failed stage=read")
            AppProfilesLastLoadFailure := "read"
            return false
        }
        if (AppProfilesSourceKnown
            && sourceExists = AppProfilesSourceExists
            && sourceContent == AppProfilesSourceContent) {
            AppProfilesLastLoadFailure := ""
            return true
        }
        sections := ConfigParseIniText(sourceContent)
    }
    try {
        candidateProfiles := Map()

        for sectionName, values in sections {
            if !RegExMatch(String(sectionName), "^KeyProfile:([^:]+)$", &match)
                continue
            profileId := String(match[1])
            if !AppProfileIsValidId(profileId)
                continue
            exePath := values.Has("exePath") ? AppProfileNormalizePath(values["exePath"]) : ""
            if exePath = ""
                continue
            displayName := values.Has("displayName") ? Trim(String(values["displayName"])) : ""
            if displayName = ""
                displayName := AppProfileDisplayName(exePath)
            enabled := values.Has("enabled") ? AppProfileBoolean(values["enabled"], true) : true
            candidateProfiles[profileId] := Map(
                "id", profileId,
                "displayName", displayName,
                "exePath", exePath,
                "enabled", enabled ? "1" : "0",
                "sections", Map("Keys", Map(), "CustomHotkey", Map()))
        }

        for sectionName, values in sections {
            if !RegExMatch(String(sectionName), "^KeyProfile:([^:]+):(Keys|CustomHotkey)$", &match)
                continue
            profileId := String(match[1])
            sectionName := String(match[2])
            if !candidateProfiles.Has(profileId)
                continue
            for key, value in values {
                if !ConfigValidateKey(sectionName, key)
                    continue
                if !ConfigValidateValue(sectionName, key, value, &normalized)
                    continue
                if Trim(String(normalized)) = ""
                    continue
                candidateProfiles[profileId]["sections"][sectionName][String(key)] := String(normalized)
            }
        }
        candidateStamp := AppProfilesCurrentStamp(candidateProfiles)
    } catch {
        if AppProfilesLastLoadFailure != "candidate"
            DebugLog("Application profiles load failed stage=candidate")
        AppProfilesLastLoadFailure := "candidate"
        return false
    }

    AppProfilesLastLoadFailure := ""
    changed := previousStamp != candidateStamp
    if publish {
        AppProfiles := candidateProfiles
        AppProfilesStamp := candidateStamp
        if sourceProvided {
            ; The supplied INI Map has no raw-text baseline. Force one content
            ; read before later probes can take the unchanged fast path.
            AppProfilesSourceKnown := false
        } else {
            AppProfilesSourceContent := sourceContent
            AppProfilesSourceExists := sourceExists
            AppProfilesSourceKnown := true
        }
    } else if !sourceProvided && candidateStamp = previousStamp {
        ; A comment/format-only edit does not change published profiles, but
        ; accepting its text avoids reparsing the same file on every probe.
        AppProfilesSourceContent := sourceContent
        AppProfilesSourceExists := sourceExists
        AppProfilesSourceKnown := true
    }
    return true
}

AppProfilesCurrentStamp(profiles := 0) {
    ; File timestamps are only precise to whole seconds, so compare the parsed
    ; profile data to detect fast external edits.
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

AppProfilesSnapshot() {
    global AppProfiles
    result := []
    for profileId, profile in AppProfiles
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
                if Trim(String(normalized)) != ""
                    normalizedProfile["sections"][sectionName][String(key)] := String(normalized)
            }
        }
        normalizedProfiles.Push(normalizedProfile)
    }
    return true
}

AppProfilePrepareDraftContent(normalizedProfiles, baseContent,
    &outputContent := "", &errorText := "") {
    errorText := ""
    outputContent := ""
    if Type(normalizedProfiles) != "Array" {
        errorText := "应用配置数据无效。"
        return false
    }

    original := StrReplace(String(baseContent), "`r`n", "`n")
    content := original
    existingSections := ConfigParseIniText(original)
    profilesById := Map()
    for profile in normalizedProfiles
        profilesById[profile["id"]] := profile
    preservedMetadata := Map()
    preservedSections := Map()
    preservedExtraSections := []
    for sectionName, values in existingSections {
        if RegExMatch(String(sectionName), "^KeyProfile:([^:]+)$", &metadataMatch) {
            profileId := String(metadataMatch[1])
            if !profilesById.Has(profileId)
                continue
            unknown := Map()
            for key, value in values
                if key != "displayName" && key != "enabled" && key != "exePath"
                    unknown[key] := value
            if unknown.Count
                preservedMetadata[profileId] := unknown
        } else if RegExMatch(String(sectionName), "^KeyProfile:([^:]+):(Keys|CustomHotkey)$", &knownMatch) {
            profileId := String(knownMatch[1])
            sectionKind := String(knownMatch[2])
            if !profilesById.Has(profileId)
                continue
            unknown := Map()
            for key, value in values
                if !ConfigValidateKey(sectionKind, key)
                    unknown[key] := value
            if unknown.Count
                preservedSections[profileId . "|" . sectionKind] := unknown
        } else if RegExMatch(String(sectionName), "^KeyProfile:([^:]+):", &extraMatch) {
            if profilesById.Has(String(extraMatch[1]))
                preservedExtraSections.Push(Map("name", sectionName, "values", values))
        }
    }
    for sectionName, values in existingSections {
        if RegExMatch(String(sectionName), "^KeyProfile:")
            content := ConfigDeleteIniSection(content, sectionName)
    }
    for profile in normalizedProfiles {
        baseSection := "KeyProfile:" . profile["id"]
        metadata := Map(
            "displayName", profile["displayName"],
            "enabled", profile["enabled"],
            "exePath", profile["exePath"])
        if preservedMetadata.Has(profile["id"])
            for key, value in preservedMetadata[profile["id"]]
                metadata[key] := value
        content := AppProfileAppendSection(content, baseSection, metadata)
        for sectionName in ["Keys", "CustomHotkey"] {
            values := Map()
            for key, value in profile["sections"][sectionName]
                values[key] := value
            preservedKey := profile["id"] . "|" . sectionName
            if preservedSections.Has(preservedKey)
                for key, value in preservedSections[preservedKey]
                    if !values.Has(key)
                        values[key] := value
            if values.Count
                content := AppProfileAppendSection(content, baseSection . ":" . sectionName, values)
        }
    }
    for extra in preservedExtraSections
        content := AppProfileAppendSection(content, extra["name"], extra["values"])
    outputContent := content
    return true
}

AppProfileAppendSection(content, sectionName, values) {
    content := RTrim(StrReplace(String(content), "`r", ""), "`n")
    if content != ""
        content .= "`n`n"
    content .= "[" . sectionName . "]`n"
    for key, value in values
        content .= String(key) . "=" . String(value) . "`n"
    return content
}
