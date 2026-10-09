# 剪贴板历史位图载荷压缩方案

日期：2026-10-09

状态：已实现。本方案只压缩启用后新捕获的内容，不批量处理现有历史。

## 1. 目标与范围

使用 Windows Compression API 的 XPRESS-HUFF，对新捕获快照内的标准位图格式 CF_DIB（8）和 CF_DIBV5（17）做无损压缩。压缩改变数据库中的存储表示；读取时必须逐字节重建原来的 ClipboardAll 兼容快照，保证交给现有恢复流程的各个格式块与压缩前完全相同。

不做以下处理：

- 不批量转换、重写或扫描已有历史记录。现有 payload_version=1 记录继续按当前原始快照路径读取。
- 不做数据库 VACUUM、WAL checkpoint 或空间压实。启用压缩不会自动缩小当前数据库文件。
- 不压缩文本、CF_HDROP 文件列表、HTML、RTF 或其他非位图格式块。
- 不压缩 PNG 等已经压缩的图像块；不把 DIB 转成 PNG/JPEG，也不重新编码像素。
- 不改变 manifest、预览、缩略图、内容哈希、记录时间、收藏、置顶、备注或排序。

## 2. 现有样本的离线测量

使用只读 SQLite 连接读取当时主库全部 466 条快照；在内存中调用 Windows Compression API 的 XPRESS-HUFF，并模拟本方案的 CPZ2 容器。未运行 AHK、未改数据库；每条快照均解码重建并逐字节比较，466 条全部通过，非 DIB/DIBV5 格式块逐字节保持不变。

| 记录主类型 | 条数 | 原始快照 | 按本方案保存 | 样本中节省 |
| --- | ---: | ---: | ---: | ---: |
| 图片 | 71 | 224.3 MiB | 33.1 MiB | 191.2 MiB |
| 文件 | 14 | 6.7 MiB | 5.1 MiB | 1.6 MiB |
| 文本/富文本 | 381 | 0.8 MiB | 0.8 MiB | 0 MiB |
| 合计 | 466 | 231.8 MiB | 39.0 MiB | 192.8 MiB |

统计按快照格式 ID，而非记录主类型；样本中 4 条文件类型记录同时含 DIB 块，因此文件类样本也有少量收益。PNG、文本和其他格式保持原样。样本载荷总量减少约 83.2%，仅作为当前图片内容的算法参考，不能预测未来捕获内容的压缩率。

这批记录用于算法参考，本方案不批量重写它们；启用压缩不会立即缩小当前数据库。下文改为单次 Compress 调用、减少缓冲复制，本次文档修订未重新测量，表中的结果不是这些 AHK 调用的耗时验收。

## 3. 存储版本与容器格式

clipboard_payloads 已有 payload_version 字段，当前版本 1 表示 snapshot_blob 是原始 ClipboardAll 兼容快照。版本 1 的数据和读取语义不变；新增版本 2 表示 snapshot_blob 是仅供数据库内部使用的 CPZ2 容器。无需增加表或数据库 schema 迁移。

整数均按 little-endian 写入，不使用结构体对齐或 AHK 对象序列化。

| 偏移/长度 | 字段 | 规则 |
| --- | --- | --- |
| 0 / 4 | Magic | ASCII CPZ2，字节 43 50 5A 32 |
| 4 / 1 | ContainerVersion | 固定 2，且须等于数据库 payload_version |
| 5 / 1 | BlockCount | 1–64，不包括 ClipboardAll 末尾零格式 ID |
| 6 / 2 | Reserved | 必须为 0 |
| 每块 / 4 | FormatId | 原剪贴板格式 ID，不得为 0 |
| +4 / 1 | Encoding | 0=原始字节，1=XPRESS-HUFF |
| +5 / 3 | Reserved | 必须全为 0 |
| +8 / 4 | RawLength | 原始块长度，最大 256 MiB |
| +12 / 4 | StoredLength | 后续 Data 的长度 |
| +16 / StoredLength | Data | 压缩或原始数据 |

容器没有结束标记。解析完 BlockCount 块后，offset 必须恰好等于 BLOB 长度。Encoding=1 仅允许 FormatId 为 8 或 17，且 0 < StoredLength < RawLength；Encoding=0 必须满足 StoredLength=RawLength。

解码后按当前快照布局为每块重建 FormatId:uint32、RawLength:uint32、RawData，最后写 FormatId:uint32=0。分配前以受检算术计算总长 4 + Σ(8 + RawLength)，且不能超过当前 512 MiB 快照读取上限。每次读取前先检查 offset <= buffer.Size 和 length <= buffer.Size - offset，再推进 offset；累计目标长度时先检查本块长度是否超过剩余额度。Magic、版本、保留位、块数、格式 ID、长度、结束位置任一无效都拒绝解码。

只有至少一个 DIB/DIBV5 块的压缩结果严格小于原块，并且完整 CPZ2（包括所有头部）小于原始快照时，才使用版本 2。否则存原始快照、版本 1，避免小图或不可压缩内容因容器开销变大。

## 4. 新捕获写入路径

### 4.1 函数改动

在 lib/features/clipboard/clipboard_formats.ahk 增加纯载荷转换函数：

- ClipboardHistoryPayloadEncode(archive, &payloadVersion, &storedPayload)：返回值表示原快照结构是否有效。默认输出为原 Buffer/版本 1；只有完整容器有收益时才输出 CPZ2/版本 2。单块压缩无收益或失败时保留该块原字节，压缩器不可用或容器构造失败时保留默认输出。
- ClipboardHistoryPayloadDecode(storedPayload, payloadVersion, &archive)：版本 1 校验并返回原 Buffer；版本 2 校验 CPZ2、解压并重建原快照；未知版本或坏数据返回失败。失败时 archive := 0。这两个函数不访问数据库或系统剪贴板。

原快照解析复用 ClipboardHistoryParseArchive(archive, "", false)，只取 id、dataOffset 和 dataSize，不复制各块。编码与版本 1 解码还须检查总长不超过 512 MiB、块数非零，以及末块 dataOffset + dataSize + 4 恰好等于 archive.Size。现有解析器会检查结束标记，但允许其后有多余字节，因此需补上最后这一项检查。不要另写一套原快照解析器，也不要调用会筛选格式并访问系统剪贴板的 ClipboardHistoryParseClipboardSnapshot。

ClipboardHistoryProcessEvent(eventId) 继续完成捕获、epoch 和记录有效性检查，再按现有方式调用 ClipboardHistoryRemember(record, event)。接入只改 Remember 函数内部，函数签名保持不变：

1. 在 Critical("On") 之前检查 record 和 event 的 epoch，再调用 PayloadEncode。
2. 编码结果保存在局部 storedPayload、payloadVersion 中。record["snapshot"] 始终表示原始快照；byteSize、contentHash 和 manifest 均由原捕获逻辑生成。
3. 进入现有 Critical 区间后再次检查 epoch，继续现有去重、ID、收藏/置顶和事务流程；StoreSave 使用局部存储载荷和版本。

在 Remember 的 global 声明之后、进入 Critical 之前增加：

```ahk
if !IsObject(record)
    return false
if IsObject(event) && event.Has("epoch") && event["epoch"] != ClipboardHistoryEpoch
    return false
if !ClipboardHistoryPayloadEncode(record["snapshot"], &payloadVersion, &storedPayload) {
    ClipboardHistoryStoreError := "无法保存此次剪贴板内容。"
    return false
}
```

临界区内原来的 record 检查已在入口完成，只保留 StoreInit 检查及原 epoch 检查。StoreSave 调用替换为：

```ahk
ClipboardHistoryStoreSave(record, storedPayload, record["manifestJson"],
    ClipboardHistoryRetentionCutoff(), ClipboardHistoryStoreMaxItems, payloadVersion)
```

编码器先零复制解析；没有非空的格式 8/17 块就立即返回原 Buffer，纯文本、纯 PNG 快照不创建压缩器，也不构造容器。首次遇到可尝试的 DIB 块时才创建局部 compressor，后续块复用该句柄，并在 finally 关闭。

压缩期间，各块描述符只增加 encoding、storedLength 和可选 packed Buffer；原始块仍引用 archive 中的偏移。先计算 containerSize := 8 + Σ(16 + StoredLength)，只有满足第 3 节的收益条件才分配最终 CPZ2 Buffer。组装时每块只复制一次实际存储字节，写完检查最终偏移等于 containerSize，最后才同时设置 storedPayload 和 payloadVersion=2。

压缩和容器组装都在 Critical 和 BEGIN IMMEDIATE 之前完成。写入路径不额外解压快照做往返自检，只检查 API 返回值、长度和组装偏移；完整结构验证及解压在读取时执行。一次 DllCall 仍会同步占用当前执行线程，移出 Critical 不等于后台执行；单条实际耗时应独立记录，不能由全库测量均值推断。

### 4.2 SQLite 写入

ClipboardHistoryStoreSave 的第二个参数改名为 storedPayload，末尾增加可选 payloadVersion := 1；内部只负责保存，不解析或编码载荷。唯一调用点 ClipboardHistoryRemember 显式传入局部 storedPayload 和 payloadVersion，默认值用于原始快照调用。

```ahk
ClipboardHistoryStoreSave(item, storedPayload, manifestJson,
    retentionCutoff := "", maxItems := 0, payloadVersion := 1)
```

payload 写入语句改为：

    INSERT INTO clipboard_payloads
        (item_id, snapshot_blob, format_manifest_json, payload_version)
    VALUES (?, ?, ?, ?)
    ON CONFLICT(item_id) DO UPDATE SET
        snapshot_blob=excluded.snapshot_blob,
        format_manifest_json=excluded.format_manifest_json,
        payload_version=excluded.payload_version;

绑定顺序：item ID 文本、storedPayload BLOB、manifest JSON 文本、整数 payloadVersion。沿用现有 StatementBindBlob(..., copyData := false) 生命周期规则，最终载荷 Buffer 必须保持强引用直到 statement finalize；不能把容量大于实际数据长度的块压缩缓冲直接绑定为整条载荷。元数据与 payload 继续在同一现有事务中提交。

```ahk
if !ClipboardHistoryDb.StatementBindBlob(statement, 2, storedPayload, false)
    throw Error("绑定剪贴板历史 BLOB 失败")
if !ClipboardHistoryDb.StatementBindInteger(statement, 4, payloadVersion)
    throw Error("绑定剪贴板历史存储版本失败")
```

新增的整数绑定与其余绑定一样检查返回值，失败沿用当前事务回滚。

ClipboardHistoryStoreStorageBytesExpression() 继续以 length(snapshot_blob) 计费，容量限制自然按压缩后的实际 BLOB 大小计算。clipboard_items.byte_size 继续表示未压缩快照大小。

## 5. 读取与恢复路径

修改 ClipboardHistoryStoreReadPayload(id, &manifestJson) 的查询：

    SELECT snapshot_blob, format_manifest_json, payload_version
    FROM clipboard_payloads
    WHERE item_id=?;

使用 CSQLite.Prepare、StatementBindText、StatementStep、StatementColumnBlob、StatementColumnText 和 StatementColumnInteger。先复制 BLOB、manifest 和版本，再 finalize statement，最后调用 PayloadDecode。BLOB 读取仍限制为 512 MiB。不可用 GetTable() 读 BLOB，因为 CSQLite.GetTable 将列内容当作 UTF-8 文本。

版本 1 零复制校验并返回读取到的原 Buffer；版本 2 按以下顺序处理：

1. 完整验证容器头和所有块头、数据边界、结束位置，计算目标快照总长度；描述符只保存偏移和长度。
2. 分配一个最终 archive Buffer，令 archiveSize 从末尾终止符的 4 字节起算；每块的格式 ID 写在 archiveSize - 4，RawLength 写在 archiveSize，数据目标位置为 archiveSize + 4。Encoding=0 直接复制到目标位置；Encoding=1 的 Decompress 输出指针直接指向该数据位置，容量只传该块 RawLength，成功后 actualSize 必须等于 RawLength。每块完成后 archiveSize 增加 8 + RawLength。
3. 写入末尾零格式 ID，并确认最终长度。全部成功才向调用者返回 archive。

解码句柄仅在遇到压缩块时创建，并在 finally 关闭。不分配各块的解压 Buffer，也不通过 ClipboardHistoryBuildArchive 再复制整个快照。未知版本或解码失败都返回读取失败，绝不把 CPZ2 直接传给 ClipboardHistoryParseArchive 或 ClipboardHistoryRestoreArchive。

ClipboardHistoryStoreGetItem() 保持给预览、复制、粘贴和拖放调用者返回统一的标准快照。格式名重注册仍使用 format_manifest_json。所有解码和结构验证在现有恢复代码准备分配全局句柄、打开或清空系统剪贴板之前完成；解码失败的载荷不会触发 EmptyClipboard。

## 6. Windows API 的 AHK 调用约定

算法为 COMPRESS_ALGORITHM_XPRESS_HUFF=4，API 位于系统 cabinet.dll，使用默认 buffer mode，不添加 COMPRESS_RAW 或自定义分块。AHK DllCall 参数使用 UInt 表示算法 DWORD、Int 接 BOOL 返回值、UPtr 接 SIZE_T、Ptr 接句柄和数据指针；输出句柄和尺寸分别使用 Ptr*、UPtr*。每个 API 失败后立即复制 A_LastError，再进行其他调用。

官方 Compress 支持传入空输出指针和零容量来查询所需空间；本方案仅接受有收益的压缩，直接申请 RawLength 容量、每块调用一次 Compress，不查询容量、不扩大缓冲、不重试。ERROR_INSUFFICIENT_BUFFER（122）表示本次有界尝试不可用，该块保存原始字节；这不是需要展示或告警的捕获失败。

编码器已设置版本 1 默认输出后，创建与关闭句柄使用：

```ahk
compressor := 0
if !DllCall("cabinet\CreateCompressor", "uint", 4, "ptr", 0,
    "ptr*", &compressor, "int") {
    errorCode := A_LastError
    DebugLog("Clipboard payload compressor unavailable: error=" . errorCode)
    return true
}
try {
    ; 按第 4.1 节压缩块并组装容器。
} finally {
    DllCall("cabinet\CloseCompressor", "ptr", compressor, "int")
}
```

压缩辅助函数直接读取原 archive 内的块，不构造输入副本：

```ahk
ClipboardHistoryPayloadCompressBlock(compressor, archive, block, &packed, &storedLength) {
    packed := 0
    storedLength := block["dataSize"]
    if !storedLength
        return false
    output := Buffer(storedLength)
    actualSize := 0
    ok := DllCall("cabinet\Compress", "ptr", compressor,
        "ptr", archive.Ptr + block["dataOffset"], "uptr", block["dataSize"],
        "ptr", output.Ptr, "uptr", output.Size, "uptr*", &actualSize, "int")
    if !ok {
        errorCode := A_LastError
        if errorCode != 122
            DebugLog("Clipboard payload compression failed: error=" . errorCode)
        return false
    }
    if actualSize <= 0 || actualSize > output.Size {
        DebugLog("Clipboard payload compression failed: invalid output size")
        return false
    }
    if actualSize >= block["dataSize"]
        return false
    packed := output
    storedLength := actualSize
    return true
}
```

packed 的 Buffer.Size 是容量，storedLength 才是有效长度；构造 CPZ2 时只复制 storedLength 字节，不再分配紧凑 packed Buffer。辅助函数返回 false 时，编码器沿用原块的 encoding=0 和原始长度。默认输出在结构验证后保持版本 1，优化阶段的 Buffer 分配或 DllCall 异常由编码器捕获并回退，不能让可选压缩失败丢弃记录。

解码对应 CreateDecompressor(4, null, &decompressor)、Decompress 和 CloseDecompressor。Decompress 直接写最终 archive，传入已验证的 StoredLength 与 RawLength；BOOL 失败时丢弃部分输出，成功时检查实际大小。所有句柄是局部状态，创建成功后必须在 finally 关闭，不引入全局句柄缓存。

官方依据：[Compress](https://learn.microsoft.com/en-us/windows/win32/api/compressapi/nf-compressapi-compress)、[Compression API buffer mode 示例](https://learn.microsoft.com/en-us/windows/win32/cmpapi/using-the-compression-api-in-buffer-mode)。

## 7. 错误、日志与历史数据边界

编码输出先初始化为 payloadVersion := 1、storedPayload := archive。原快照结构不合法才返回失败；优化阶段失败沿用这些默认值并继续保存。单块 Compress 无收益、返回缓冲不足或其他错误时保留原块；压缩器创建失败、容器构造异常或最终偏移不符时回退整条原快照。仅在完整容器构造成功后提交版本 2 输出，不能返回半成品。

无 DIB、无收益和缓冲不足属于正常分支，不逐条写错误日志。其他压缩回退只记非敏感诊断；不记录正文、文件路径、图片字节或 manifest 内容。

版本 2 解码失败时拒绝该条目恢复；页面沿用现有用户可理解的失败反馈，底层 Win32 状态码和 SQLite 错误类别写日志，不直接展示技术异常。日志可记录操作阶段、payloadVersion、块数、原始/存储字节和错误码，但不写载荷内容。

已有历史不做批量扫描或迁移，未再次捕获的版本 1 记录继续走原始快照读取路径。正常再次捕获相同内容时，现有 contentHash 去重会复用条目 ID，StoreSave 的 UPSERT 会把此次新捕获载荷和版本写回该条目；允许这条正常更新路径，不增加保留旧载荷的特殊分支。无需 app_meta 游标、后台迁移 timer、启动导入、VACUUM 或 WAL 整理。

## 8. 文件落点与实施验收边界

| 文件 | 实现内容 |
| --- | --- |
| lib/features/clipboard/clipboard_formats.ahk | 复用原快照零复制解析；新增编码、解码及单次压缩辅助函数；只压格式 8/17；一次构造 CPZ2、直接解压进最终快照 |
| lib/features/clipboard/clipboard_history.ahk | Remember 在 Critical 前编码，局部载荷和版本传入 StoreSave；保持 record 的原始快照语义 |
| lib/features/clipboard/clipboard_store.ahk | Save 使用 storedPayload 并绑定 payload_version；ReadPayload 读版本并在 finalize 后解码；预算仍按实际 BLOB 大小 |

不新增 schema 表、WebView 页面逻辑、第三方库或并行存储路径。AHK v2 /validate 已通过且无警告；项目未运行，实际剪贴板恢复仍待运行验收。后续修改 AHK 源码时，按 AGENTS.md 使用 PowerShell AutoHotkey v2 /validate，并检查退出码与全部警告；禁止启动项目，不编写测试。语法验证不能替代实际剪贴板恢复验证；此前离线压缩结果也不代表 AHK 运行验收。
