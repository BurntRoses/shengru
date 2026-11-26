import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct WorkspaceView: View {
  @ObservedObject var d: Desk
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @LocalState private var search = ""
  @LocalState private var wordSection: DictionarySection = .catalog
  @LocalState private var removed = false
  @LocalState private var removingBlock: String?
  @LocalState private var wordGroup: WordCollection?
  @LocalState private var editor: TermDraft?
  @LocalState private var importPreview: ImportPreview?
  @LocalState private var importing = false
  @LocalState private var fromBottom = false
  @LocalState private var activeRecord: UUID?
  @LocalState private var deletion: UUID?
  @LocalState private var confirmErase = false
  @LocalState private var historyPart: HistoryPart = .both
  @LocalState private var notice = ""
  var body: some View {
    GeometryReader { geo in
      let compact = geo.size.width < 716
      let gutter = compact ? CGFloat(18) : Layout.gutter
      HStack(spacing: 0) {
        sidebar(compact: compact)
        VStack(alignment: .leading, spacing: Layout.sectionGap) {
          header
          Group {
            switch d.page {
            case .dictate: dictate
            case .history: history
            case .terms: dictionary
            case .settings: SettingsPane(d: d, section: d.settingsSection)
            }
          }.animation(
            reduceMotion || !d.options.appearance.animate ? nil : .easeOut(duration: 0.16), value: d.page
          )
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
          if !d.message.isEmpty || !notice.isEmpty { messageBar }
        }.padding(.top, 38).padding(.bottom, 16).padding(.horizontal, gutter)
          .frame(maxWidth: Layout.maxColumn + 2 * gutter).frame(maxWidth: .infinity)
      }
    }.frame(minWidth: Layout.minimum.width, minHeight: Layout.minimum.height)
      .background(Layout.canvas).tint(.inkMint).workspaceKeyboard()
      .onChange(of: d.page) { _, _ in
        notice = ""
        search = ""
        d.stopAudio()
      }
      .onChange(of:activeRecord) { _,id in
        if let r=d.rehearing, r.origin == .history, let id, r.recordID != id { d.rehearing=nil }
      }
      .sheet(item: $importPreview) { preview in
        ImportSheet(
          preview: preview, blocked: preview.forBlock, initialGroup: preview.group,
          reload: { mode in
            guard let url = preview.source else { return preview }
            let blocked = preview.forBlock
            let existing =
              blocked ? d.policy.blocked.map { Term(spelling: $0, spoken: "") } : d.terms
            let known = Set<String>()
            return try await Task.detached(priority: .userInitiated) {
              try LexiconImport.read(
                url, existing: existing, known: known, plainOnly: blocked, mode: mode)
            }.value
          }
        ) { group, parsed in
          if preview.forBlock {
            guard d.changePolicy({ $0.blocked += parsed.terms.map(\.spelling) }) else { return }
          } else {
            let new = parsed.terms.map {
              var t = $0
              t.pack = group?.rawValue
              t.imported = true
              return t
            }
            let next = (d.terms + new).sorted {
              $0.spelling.localizedStandardCompare($1.spelling) == .orderedAscending
            }
            d.persistTerms(next)
            guard d.terms == next else { return }
            wordGroup = group
            wordSection = group == nil ? .personal : .catalog
            removed = false
          }
          importPreview = nil
          feedback("已导入 \(parsed.terms.count) 个词条")
        }
      }
      .sheet(item: $editor) { draft in
        TermEditor(d: d, draft: draft) { group in
          search = ""
          if !draft.blocked {
            wordGroup = group
            wordSection = group == nil ? .personal : .catalog
            removed = false
          }
        }
      }
      .alert(
        "移除这个屏蔽词？",
        isPresented: Binding(get: { removingBlock != nil }, set: { if !$0 { removingBlock = nil } })
      ) {
        Button("取消", role: .cancel) {}
        Button("移除", role: .destructive) {
          if let word = removingBlock { _ = d.changePolicy { $0.blocked.removeAll { $0 == word } } }
          removingBlock = nil
        }
      } message: {
        Text("这个词会恢复正常的识别优先级。")
      }
      .alert(
        (deletion == nil ? "清空全部" : "删除这条记录的") + historyPart.rawValue + "？",
        isPresented: $confirmErase
      ) {
        Button("取消", role: .cancel) {}
        Button(deletion == nil ? "清空" : "删除", role: .destructive) {
          d.erase(deletion, part: historyPart)
          activeRecord = nil
        }
      } message: {
        Text(
          historyPart == .text
            ? "录音会保留。删除的文字无法恢复。" : historyPart == .audio ? "文字会保留。删除的录音无法恢复。" : "文字和录音都将删除，无法恢复。")
      }
  }

  private func sidebar(compact: Bool) -> some View {
    VStack(alignment: compact ? .center : .leading, spacing: 0) {
      HStack(spacing: 9) {
        BrandBadge(size: Layout.sideRow)
        if !compact { Text("语音输入").font(.system(size: 16, weight: .semibold)) }
      }.frame(height: Layout.navRow).padding(.horizontal, compact ? 0 : 8)
      VStack(spacing: 4) {
        ForEach(Page.allCases, id: \.self) { p in
          let chosen = d.page == p
          Button {
            d.page = p
          } label: {
            HStack(spacing: 10) {
              Image(systemName: p.icon).font(.system(size: 15, weight: .medium)).frame(width: 20)
              if !compact {
                Text(p.rawValue).font(.system(size: 13, weight: chosen ? .semibold : .regular))
                Spacer(minLength: 0)
              }
            }.foregroundStyle(chosen ? Color.inkMint : .primary).padding(
              .horizontal, compact ? 0 : 12
            )
            .frame(maxWidth: .infinity).frame(height: Layout.navRow)
          }.buttonStyle(RowSurface(selected: chosen)).keyCue(10)
            .accessibilityLabel(p.rawValue).accessibilityAddTraits(chosen ? .isSelected : []).help(
              p.rawValue)
        }
      }.padding(.top, 20)
      Spacer(minLength: 12)
      HStack(spacing: 7) {
        Circle().fill(d.ready ? Color.inkMint : Color.orange).frame(width: 6, height: 6)
        if !compact { Text(resourceState).font(.caption).foregroundStyle(.secondary) }
      }.frame(height: 28).padding(.horizontal, compact ? 0 : 12)
        .accessibilityElement(children: .ignore).accessibilityLabel(resourceState).help(
          resourceState)
    }.padding(.horizontal, 8).padding(.top, 12).padding(.bottom, 9)
      .frame(width: compact ? 52 : 148).frame(maxHeight: .infinity).navigationGlass(
        compact ? 20 : 18
      )
      .padding(.leading, 10).padding(.top, 30).padding(.bottom, 10)
  }
  private var resourceState: String { d.ready ? "本机听写" : (d.preparing ? "准备中" : "资源不可用") }
  private var heading: Text { Text(d.page.rawValue).font(.system(size: 26, weight: .bold)) }
  private var header: some View {
    HStack(spacing: 12) {
      heading.fixedSize().accessibilityAddTraits(.isHeader)
      Spacer(minLength: 0)
      switch d.page {
      case .terms, .history:
        let terms = d.page == .terms
        FieldSurface(
          title: terms ? "查找词条" : "查找文字",
          prompt: terms ? (wordSection == .blocked ? "查找屏蔽词" : "查找词条") : "查找文字", search: true,
          text: $search
        )
        .frame(minWidth: 110, idealWidth: 166, maxWidth: 184)
        if terms {
          Button {
            chooseImport()
          } label: {
            Label(importing ? "读取中" : "导入", systemImage: "square.and.arrow.down")
          }.deskAction().fixedSize().accessibilityLabel("导入词库").disabled(importing)
          Button {
            editor = TermDraft(
              group: wordSection == .catalog ? wordGroup : nil, blocked: wordSection == .blocked)
          } label: {
            Label(wordSection == .blocked ? "添加屏蔽词" : "添加词条", systemImage: "plus")
          }
          .deskAction(primary: true).fixedSize()
        } else if !d.rows.isEmpty {
          Menu {
            eraseChoices(nil)
          } label: {
            Text("清空…")
          }
          .fixedSize().keyCue().disabled(d.historyDraft != nil || d.editing).accessibilityLabel("清空历史")
        }
      case .settings:
        SectionTabs(title:"设置类别", items:SettingsSection.allCases, selected:$d.settingsSection)
      case .dictate: EmptyView()
      }
    }.frame(minHeight: 38)
  }
  private var live: Bool { d.phase == .listen || d.phase == .finish }
  private var dictate: some View {
    GeometryReader { space in
      let foreground = d.recordingBusy || !d.last.isEmpty
      let review = ReviewCard(d: d, editorHeight: min(300, max(126, space.size.height * 0.51)))
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          if foreground { review }
          if !d.editing && !d.awaitingReview && !d.confirming {
            dictateCard
            if !d.allowMic || !d.keyConnected || d.usingBackupKey || (d.options.autoInsert && !d.allowInsert) {
              permissionShortcut
            }
          }
          if !foreground { review }
        }.padding(.bottom, 4)
      }
    }
  }
  private var dictateCard: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(spacing: 14) {
        VStack(alignment: .leading, spacing: 6) {
          Text(d.phase == .listen ? "正在听写" : d.phase == .finish ? "正在校对" : "按住说话")
            .font(.callout.weight(.semibold)).foregroundStyle(Color.inkMint)
          Text(d.activeTrigger.rawValue).font(
            .system(size: 30, weight: .semibold, design: .rounded)
          ).fixedSize()
          Text(
            d.phase == .listen
              ? clockText(d.seconds)
              : d.options.reviewFirst
                ? "松开后审阅，确认后定稿。" : (d.options.autoInsert ? "松开后，文字会输入到光标处。" : "松开后，在悬浮窗复制文字。")
          )
          .font(.callout).foregroundStyle(.secondary).monospacedDigit()
        }
        Spacer(minLength: 0)
        Group {
          if d.options.appearance.waveform {
            WaveMark(
              power: d.level, active: d.phase == .listen && d.options.appearance.animate && !reduceMotion,
              history: d.meterHistory)
          } else {
            Image(systemName: "mic").font(.system(size: 31)).foregroundStyle(Color.inkMint)
          }
        }.frame(width: 68, height: 58).padding(.trailing, 6)
      }
      HStack(spacing: 10) {
        Button {
          d.toggle()
        } label: {
          Label(
            d.phase == .listen ? "结束听写" : "在此试说",
            systemImage: d.phase == .listen ? "stop.fill" : "mic.fill"
          )
          .font(.system(size: 13, weight: .semibold)).frame(minWidth: 76)
        }.deskAction(primary: true, large: true).disabled(d.phase == .finish || !d.ready)
        Spacer(minLength: 4)
        Text("整理方式").font(.callout).foregroundStyle(.secondary)
        Picker("整理方式", selection: $d.options.level) {
          ForEach(EditLevel.allCases) { Text($0.title).tag($0) }
        }.labelsHidden().fixedSize().keyCue().help(d.options.level.detail)
      }
    }.padding(Layout.inset).background {
      RoundedRectangle(cornerRadius: Layout.card, style: .continuous)
        .fill(
          LinearGradient(
            colors: [.inkMint.opacity(0.085), .clear], startPoint: .topTrailing,
            endPoint: .bottomLeading))
    }.panelPaint()
  }
  private var permissionShortcut: some View {
    Button {
      d.settingsSection = .privacy
      d.page = .settings
    } label: {
      HStack(spacing: 10) {
        Image(systemName: "hand.raised").foregroundStyle(Color.inkMint)
        Text(d.globalStatus).foregroundStyle(.primary)
        Spacer()
        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(
          .secondary)
      }.padding(.horizontal, Layout.inset).frame(height: 40)
    }.buttonStyle(RowSurface()).background(
      Color.inkMint.opacity(0.07), in: RoundedRectangle(cornerRadius: 10)
    )
    .keyCue(10)
  }
  private func feedback(_ text: String) {
    notice = text
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { if notice == text { notice = "" } }
  }
  private var messageBar: some View {
    HStack(spacing: 9) {
      Image(systemName: d.message.isEmpty ? "checkmark" : "exclamationmark.circle").foregroundStyle(
        d.message.isEmpty ? Color.inkMint : .orange)
      Text(d.message.isEmpty ? notice : d.message).font(.callout).textSelection(.enabled)
      Spacer(minLength: 6)
      IconAction(symbol: "xmark", title: "关闭提示", size: 26) {
        d.message = ""
        notice = ""
      }
    }.padding(.leading, 12).padding(.trailing, 5).padding(.vertical, 4).navigationGlass(15)
  }
  @ViewBuilder private func eraseChoices(_ row: Record?) -> some View {
    ForEach([HistoryPart.text, .audio, .both], id: \.self) { part in
      if part == .both
        || (part == .text
          ? (row.map { $0.text != nil } ?? d.rows.contains { $0.text != nil })
          : (row.map { $0.audio != nil } ?? d.rows.contains { $0.audio != nil }))
      {
        Button((row == nil ? "清空" : "删除") + part.rawValue + "…", role: .destructive) {
          historyPart = part
          deletion = row?.id
          confirmErase = true
        }
      }
    }
  }
  private var history: some View {
    let records = d.rows.filter {
      d.historyDraft?.id == $0.id || search.trimmed.isEmpty || ($0.text ?? "").localizedCaseInsensitiveContains(search.trimmed)
    }
    let index = records.firstIndex { $0.id == (d.historyDraft?.id ?? activeRecord) } ?? 0
    func step(_ direction: Int) -> Bool {
      let next = index + direction
      guard d.historyDraft == nil,records.indices.contains(next) else { return false }
      fromBottom = direction < 0
      activeRecord = records[next].id
      d.stopAudio()
      return true
    }
    return Group {
      if records.isEmpty {
        LibraryEmpty(icon: "clock.arrow.circlepath", title: d.rows.isEmpty ? "暂无听写记录" : "没有匹配的记录")
      } else {
        let row = records[index]
        VStack(alignment: .leading, spacing: 12) {
          HStack(spacing: 6) {
            Menu {
              ForEach(records) { item in
                Button {
                  fromBottom = false
                  activeRecord = item.id
                  d.stopAudio()
                } label: {
                  Text(
                    item.at.formatted(.dateTime.month().day().hour().minute()) + " · "
                      + String((item.text ?? "录音").prefix(24)))
                }
              }
            } label: {
              Text("第 \(index+1) / \(records.count) 条")
            }.fixedSize().keyCue().disabled(d.historyDraft != nil).accessibilityLabel("选择听写记录")
            Spacer()
            IconAction(symbol: "chevron.up", title: "上一条记录") { _ = step(-1) }.disabled(index == 0 || d.historyDraft != nil)
            IconAction(symbol: "chevron.down", title: "下一条记录") { _ = step(1) }.disabled(
              index == records.count - 1 || d.historyDraft != nil)
          }
          Divider()
          HStack(spacing: 8) {
            Text(row.at.formatted(.dateTime.month().day().hour().minute()))
            Text("·")
            Text(clockText(row.seconds))
            if row.audio != nil, let count = row.sectionCount, count > 1 {
              Text("·"); Text("\(count) 节录音").help("播放时会自动接着播放下一节。")
            }
            Spacer()
            Text(row.mode.title)
          }.font(.caption).foregroundStyle(.secondary)
          if let group = row.conversation {
            let turns = d.rows.filter { $0.conversation == group && $0.text != nil }.reversed()
            if turns.count > 1 {
              Label(
                "连续听写 · 第 \(Array(turns).firstIndex(where:{$0.id == row.id}).map{$0+1} ?? 1) 段，共 \(turns.count) 段",
                systemImage: "link"
              ).font(.caption).foregroundStyle(Color.inkMint)
            }
          }
          if let r=d.rehearing, r.origin == .history && r.recordID==row.id { RehearingInline(d:d,review:r) }
          PassageEditor(id:row.id,value:d.historyDraft?.id == row.id ? (d.historyDraft?.text ?? "") : (row.text ?? "这条记录只保留了录音。"),label:row.text == nil ? "录音记录" : "记录正文，可编辑",size:16,
            editable:row.text != nil && !d.recordingBusy && !d.confirming && !d.editing && !d.awaitingReview,editing:d.historyDraft?.id == row.id,bottomAtEntry:fromBottom,step:step,
            begin:{d.startHistory(row)},change:{if d.historyDraft?.id==row.id {d.historyDraft?.text=$0}},save:{_=d.saveHistoryEdit()},cancel:{d.historyDraft=nil})
            .frame(maxWidth:.infinity,maxHeight:.infinity).help("点按文字修改；阅读时用上下键滚动或切换记录。")
          if let text = row.text, row.choices != nil || d.canUndoHistory(row) {
            ReadingPicker(text: text, choices: row.choices ?? [], choose: { d.chooseHistory($0, id: row.id) },
              undo: d.canUndoHistory(row) ? { d.undoHistory(row.id) } : nil).disabled(!d.canPickHistory(row.id))
          }
          Divider()
          HStack(spacing: 8) {
            if row.audio != nil {
              IconAction(
                symbol: d.playing == row.id ? "stop.fill" : "play.fill",
                title: d.playing == row.id ? "停止播放" : "播放录音"
              ) { d.play(row) }
            }
            if let text = row.text {
              IconAction(symbol: "doc.on.doc", title: "复制文字") {
                if InputTarget.copy(d.historyDraft?.id == row.id ? (d.historyDraft?.text ?? text) : text) { feedback("已复制文字") }
              }
            }
            Menu {
              eraseChoices(row)
            } label: {
              Image(systemName: "ellipsis.circle").frame(width: 28, height: 28)
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().keyCue()
              .disabled(d.historyDraft != nil).accessibilityLabel("管理这条记录")
            Spacer()
            if d.historyDraft?.id == row.id {
              Button("取消") {d.historyDraft=nil}.deskAction()
              Button("保存修改") {_=d.saveHistoryEdit()}.deskAction(primary:true).disabled(d.historyDraft?.text.trimmed.isEmpty != false)
            } else {
              Button("增强识别") { d.rehear(row.id) }.deskAction().disabled(row.audio == nil || !d.canPickHistory(row.id) || (d.rehearing?.recordID==row.id && d.rehearing?.stage == .working))
            }
          }
        }.padding(Layout.inset).panelPaint()
      }
    }
  }
  private func chooseImport() {
    let panel = NSOpenPanel()
    panel.title = "导入词库"
    panel.prompt = "预览词条"
    panel.allowsMultipleSelection = false
    panel.allowedContentTypes = [
      "txt", "text", "list", "csv", "tsv", "plist", "json", "yaml", "yml",
    ].compactMap { UTType(filenameExtension: $0) }
    panel.message = "选择其他应用导出的文本词库、Rime 词典，或 macOS 文本替换文件。"
    guard let window = NSApp.keyWindow else { return }
    panel.beginSheetModal(for: window) { result in
      guard result == .OK, let url = panel.url else { return }
      importing = true
      let blocked = wordSection == .blocked
      let group = wordSection == .catalog ? wordGroup : nil
      let existing = blocked ? d.policy.blocked.map { Term(spelling: $0, spoken: "") } : d.terms
      let known = Set<String>()
      Task { @MainActor in
        defer { importing = false }
        do {
          var preview = try await Task.detached(priority: .userInitiated) {
            do {
              return try LexiconImport.read(
                url, existing: existing, known: known, plainOnly: blocked)
            } catch LexiconImport.ParseIssue.unclosedQuote {
              // A literal quotation mark is valid in line mode. Let the user resolve the split in the preview.
              return ImportPreview(
                name: url.lastPathComponent, terms: [], duplicates: 0, skipped: 0, source: url,
                issue: LexiconImport.ParseIssue.unclosedQuote.localizedDescription)
            }
          }.value
          preview.group = group
          preview.forBlock = blocked
          importPreview = preview
        } catch { d.message = "无法导入：" + error.localizedDescription }
      }
    }
  }
  private var dictionary: some View {
    VStack(alignment: .leading, spacing: 12) {
      SectionTabs(title:"词表范围", items:DictionarySection.allCases, selected:$wordSection)
      switch wordSection {
      case .catalog:
        CatalogWords(
          d: d, group: $wordGroup, removed: $removed, query: search.trimmed,
          onEdit: { editor = TermDraft(word: $0) })
      case .personal:
        PersonalShelf(d: d, query: search.trimmed) { editor = $0 }
      case .blocked:
        let words = d.policy.blocked.filter {
          search.trimmed.isEmpty || $0.localizedCaseInsensitiveContains(search.trimmed)
        }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        HStack {
          Text("\(words.count) 个屏蔽词").font(.callout).foregroundStyle(.secondary)
          Spacer()
          Image(systemName: "info.circle").foregroundStyle(.secondary).help(ShieldCopy.note)
            .accessibilityLabel(ShieldCopy.note)
        }
        if words.isEmpty {
          LibraryEmpty(
            icon: "text.badge.minus", title: d.policy.blocked.isEmpty ? "还没有屏蔽词" : "没有匹配的屏蔽词")
        } else {
          ScrollView {
            LazyVStack(spacing: 0) {
              ForEach(words, id: \.self) { w in
                HStack {
                  Text(w).textSelection(.enabled)
                  Spacer()
                  IconAction(symbol: "minus.circle", title: "移除屏蔽词“" + w + "”") {
                    removingBlock = w
                  }
                }.padding(.horizontal, Layout.inset).frame(minHeight: 42)
                if w != words.last { Divider().padding(.horizontal, Layout.inset) }
              }
            }.panelPaint()
          }
        }
      }
    }.onChange(of: wordSection) { _, _ in search = "" }
  }

}

struct LibraryEmpty: View {
  let icon: String, title: String
  var body: some View {
    VStack(spacing: 0) {
      Image(systemName: icon).font(.system(size: 26, weight: .regular)).foregroundStyle(
        Color.inkMint
      )
      .frame(width: 58, height: 58).background(Color.inkMint.opacity(0.09), in: Circle())
      .accessibilityHidden(true)
      Text(title).font(.system(size: 16, weight: .semibold)).padding(.top, 14)
    }.multilineTextAlignment(.center).padding(18).frame(maxWidth: .infinity, maxHeight: .infinity)
      .padding(.bottom, 32)
  }
}

struct TermDraft: Identifiable {
  var frequency: String? = nil
  var word: Term? = nil
  var group: WordCollection? = nil
  var blocked = false
  let id = UUID()
}
struct TermEditor: View {
  @ObservedObject var d: Desk
  let draft: TermDraft
  let saved: (WordCollection?) -> Void
  @LocalState private var group: WordCollection?
  @Environment(\.dismiss) private var dismiss
  @LocalState private var spelling: String
  @LocalState private var spoken: String
  @LocalState private var confirmDelete = false
  init(d: Desk, draft: TermDraft, saved: @escaping (WordCollection?) -> Void = { _ in }) {
    self.saved = saved
    _group = LocalState(
      initialValue: draft.word?.collection ?? draft.group
    )
    self.d = d
    self.draft = draft
    _spelling = LocalState(initialValue: draft.word?.spelling ?? draft.frequency ?? "")
    _spoken = LocalState(initialValue: draft.word?.spoken ?? "")
  }
  private var duplicate: Bool {
    if draft.blocked {
      return d.policy.blocked.contains {
        $0.caseInsensitiveCompare(spelling.trimmed) == .orderedSame
      }
    }
    let keys = Set(
      [spelling.trimmed.lowercased(), spoken.trimmed.lowercased()].filter { !$0.isEmpty })
    return d.terms.contains { t in
      t.id != draft.word?.id
        && (!keys.isDisjoint(with: [t.spelling.lowercased(), t.spoken.lowercased()]))
    }
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(draft.blocked ? "添加屏蔽词" : draft.frequency != nil ? "编辑常用词" : draft.word == nil ? "添加词条" : "编辑词条").font(.title2.bold())
        .accessibilityAddTraits(
          .isHeader)
      Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
        GridRow {
          Text(draft.blocked ? "屏蔽词" : "写作")
          FieldSurface(
            title: draft.blocked ? "屏蔽词" : "写作", prompt: draft.blocked ? "输入常被误认出的词" : "例如：gRPC",
            text: $spelling)
        }
        if !draft.blocked {
          GridRow {
            Text("读作")
            FieldSurface(title: "读作", prompt: "可选，填入听写时出现的写法", text: $spoken)
          }
          GridRow {
            Text("词库")
            PackDestination(group: $group)
          }
        }
      }
      if duplicate {
        Text(draft.blocked ? "已经屏蔽了这个词。" : "词库中已有相同的写法或读法。").font(.callout).foregroundStyle(.orange)
      }
      HStack(spacing: 8) {
        if draft.word != nil || draft.frequency != nil {
          Button("删除词条…", role: .destructive) { confirmDelete = true }.deskAction().foregroundStyle(
            .red)
        }
        Spacer()
        Button("取消") { dismiss() }.deskAction().keyboardShortcut(.cancelAction)
        Button(draft.frequency == nil ? "保存" : "保存为手动词条") {
          if draft.blocked {
            if d.changePolicy({ $0.blocked.append(spelling.trimmed) }) {
              saved(nil)
              dismiss()
            }
            return
          }
          let word = Term(
            id: draft.word?.id ?? UUID(), spelling: spelling.trimmed, spoken: spoken.trimmed,
            pack: draft.word?.collection == group ? (draft.word?.pack ?? group?.rawValue) : group?.rawValue)
          d.persistTerms(
            (d.terms.filter { $0.id != word.id } + [word]).sorted {
              $0.spelling.localizedStandardCompare($1.spelling) == .orderedAscending
            })
          if d.terms.contains(word) {
            if let name = draft.frequency { _ = d.forgetFrequent(name) }
            saved(group)
            dismiss()
          }
        }.deskAction(primary: true).keyboardShortcut(.defaultAction).disabled(
          spelling.trimmed.isEmpty || spelling.trimmed.count > 96 || spoken.trimmed.count > 96
            || duplicate || (draft.word == nil && (draft.blocked ? d.policy.blocked.count : d.terms.count) >= 40000)
            || (spelling + spoken).unicodeScalars.contains(
              where: CharacterSet.controlCharacters.contains)
        )
      }.padding(.top, 4)
      if !d.message.isEmpty { Text(d.message).font(.callout).foregroundStyle(.secondary) }
    }.padding(24).frame(width: 384).tint(.inkMint).workspaceKeyboard()
      .alert("删除这个词条？", isPresented: $confirmDelete) {
        Button("取消", role: .cancel) {}
        Button("删除", role: .destructive) {
          if let name = draft.frequency { if d.forgetFrequent(name) { dismiss() }; return }
          d.persistTerms(d.terms.filter { $0.id != draft.word?.id })
          if !d.terms.contains(where: { $0.id == draft.word?.id }) { dismiss() }
        }
      } message: {
        Text("词条会从我的词库移除，不再自动收录。以往定稿不变。")
      }
  }
}

struct ImportSheet: View {
  let original: ImportPreview, blocked: Bool
  @LocalState private var preview: ImportPreview
  @LocalState private var group: WordCollection?
  @LocalState private var mode: TextImportMode = .automatic
  @LocalState private var shownMode: TextImportMode? = .automatic
  @LocalState private var error = ""
  let reload: (TextImportMode) async throws -> ImportPreview
  let apply: (WordCollection?, ImportPreview) -> Void
  init(
    preview: ImportPreview, blocked: Bool, initialGroup: WordCollection?,
    reload: @escaping (TextImportMode) async throws -> ImportPreview,
    apply: @escaping (WordCollection?, ImportPreview) -> Void
  ) {
    original = preview
    self.blocked = blocked
    _preview = LocalState(initialValue: preview)
    _group = LocalState(initialValue: initialGroup)
    self.reload = reload
    self.apply = apply
  }
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(blocked ? "导入屏蔽词" : "导入词库").font(.title2.bold())
      Text(original.name).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
      Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
        if !blocked {
          GridRow {
            Text("导入到")
            PackDestination(group: $group)
          }
        }
        if let ext = original.source?.pathExtension.lowercased(),
          ["txt", "text", "list"].contains(ext)
        {
          GridRow {
            Text("拆分方式")
            Picker("拆分方式", selection: $mode) {
              ForEach(TextImportMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.labelsHidden().keyCue().help(
              mode == .table ? "左列是写法，右列是读法。两列可用制表符或逗号分隔。" : "空白、逗号或顿号分隔词语；用引号保留多词短语。")
          }
        }
      }
      if !error.isEmpty {
        Text(error).font(.callout).foregroundStyle(.red)
      } else if shownMode != mode {
        ProgressView().controlSize(.small)
      } else {
        Text("新增 \(preview.terms.count) 条 · 重复 \(preview.duplicates) 条 · 跳过 \(preview.skipped) 条")
          .font(.callout).foregroundStyle(.secondary)
      }
      Divider()
      if shownMode != mode || preview.terms.isEmpty {
        Spacer()
        if error.isEmpty && shownMode == mode {
          Text("没有可以新增的词条。").foregroundStyle(.secondary).frame(maxWidth: .infinity)
        }
        Spacer()
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 8) {
            ForEach(preview.terms) { w in
              HStack {
                Text(w.spelling)
                Spacer()
                if !w.spoken.isEmpty { Text(w.spoken).foregroundStyle(.secondary) }
              }
            }
          }
        }
      }
      Divider()
      HStack {
        if blocked {
          Image(systemName: "info.circle").foregroundStyle(.secondary).help(ShieldCopy.note)
            .accessibilityLabel(ShieldCopy.note)
        }
        Spacer()
        Button("取消") { dismiss() }.deskAction().keyboardShortcut(.cancelAction)
        Button("导入 \(shownMode==mode ? preview.terms.count : 0) 条") { apply(group, preview) }
          .deskAction(primary: true).disabled(
            preview.terms.isEmpty || shownMode != mode || !error.isEmpty)
      }
    }.padding(22).frame(width: 440, height: 390).workspaceKeyboard().tint(.inkMint)
      .task(id: mode) {
        let requested = mode
        error = ""
        if requested == .automatic {
          preview = original
          error = original.issue ?? ""
          shownMode = requested
          return
        }
        shownMode = nil
        do {
          let parsed = try await reload(requested)
          guard !Task.isCancelled, mode == requested else { return }
          preview = parsed
          shownMode = requested
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
      }
  }
}
