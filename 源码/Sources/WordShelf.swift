import SwiftUI

enum DictionarySection: String, CaseIterable {
  case catalog = "内置词库", personal = "我的词库", blocked = "屏蔽词"
}
enum ShieldCopy { static let note = "有同音候选时，优先选其他词。清楚说出的词照常保留。" }
enum FrequencyCopy { static let note = "需开启「保存听写文字」。一个词在三次不同的定稿中出现，就会收进我的词库。" }

struct PackDestination: View {
  @Binding var group: WordCollection?
  var body: some View {
    Picker("词库", selection: $group) {
      Text("我的词库").tag(nil as WordCollection?)
      Divider()
      ForEach(WordCollection.allCases) { Text($0.title).tag(Optional($0)) }
    }.labelsHidden().keyCue()
  }
}
private struct CollectionSwitch: View {
  @ObservedObject var d: Desk
  let shelf: WordCollection
  var body: some View {
    let state = d.policy.state(shelf)
    HStack(spacing: 6) {
      Toggle("启用" + shelf.title, isOn: Binding(get: { state == .on }, set: { on in
        _ = d.changePolicy { $0.set(shelf, enabled: on) }
      })).labelsHidden().toggleStyle(.switch).controlSize(.small).keyCue().accessibilityLabel("启用" + shelf.title)
        .accessibilityValue(state == .on ? "已启用" : state == .mixed ? "部分启用" : "未启用")
        .help(state == .on ? "停用这个分类" : "启用这个分类的全部词条")
    }.fixedSize()
  }
}
struct CatalogWords: View {
  @ObservedObject var d: Desk
  @Binding var group: WordCollection?
  @Binding var removed: Bool
  @Environment(\.colorScheme) private var scheme
  let query: String, onEdit: (Term) -> Void
  @LocalState private var removal: BuiltinVocabulary.Word?
  @LocalState private var topic: String?
  private var home: Bool { group == nil && query.isEmpty && !removed }
  private var catalog: WordCatalog { .shared }
  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      if home { overview } else { detail }
    }.onChange(of: group) { _, _ in topic = nil }
    .alert("从词库移除“" + (removal?.name ?? "") + "”？", isPresented: Binding(
      get: { removal != nil }, set: { if !$0 { removal = nil } })) {
      Button("取消", role: .cancel) {}
      Button("移除", role: .destructive) {
        if let w = removal { _ = d.changePolicy { $0.hidden.insert(w.name.lowercased()) } }
        removal = nil
      }
    } message: { Text("听写不再优先使用这条写法。可在“已移除”中恢复。") }
  }
  @ViewBuilder private var overview: some View {
    let full = WordCollection.allCases.allSatisfy { d.policy.state($0) == .on }
    let counts = catalog.counts(policy: d.policy, additions: d.terms)
    HStack(spacing: 8) {
      Text("全部分类").font(.headline)
      Text("\(counts.values.reduce(0, +)) 条").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
      Spacer()
      IconAction(symbol: "tray", title: "查看已移除的词条") { removed = true }
      Button { _ = d.changePolicy { $0.enableAll() } } label: {
        Label(full ? "已全部启用" : "全部启用", systemImage: full ? "checkmark.circle.fill" : "checkmark.circle")
      }.deskAction().disabled(full).help("启用全部分类，保留手动移除的词条和屏蔽词。")
    }.frame(minHeight: 30)
    GeometryReader { viewport in
      let shelves = WordCollection.allCases
      // Keep the whole overview visible on a short window without shrinking the text or switches.
      let rowHeight = min(58, max(42, ((viewport.size.height - CGFloat(shelves.count)) / CGFloat(shelves.count)).rounded(.down)))
      let iconSide = min(36, rowHeight - 9)
      ScrollView {
        VStack(spacing: 0) {
          ForEach(shelves) { shelf in
            HStack(spacing: 12) {
              Button { group = shelf } label: {
                HStack(spacing: 12) {
                  Image(systemName: shelf.symbol).font(.system(size: min(16, iconSide * 0.55), weight: .medium)).foregroundStyle(Color.inkMint)
                    .frame(width: iconSide, height: iconSide).background(Color.inkMint.opacity(0.1), in: RoundedRectangle(cornerRadius: iconSide * 0.29))
                  Text(shelf.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.primary)
                  if d.policy.state(shelf) == .mixed { Text("部分启用").font(.caption).foregroundStyle(.secondary) }
                  Spacer(minLength: 0)
                  Text("\(counts[shelf] ?? 0) 条").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                  Image(systemName: "chevron.forward").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                }.frame(minHeight: rowHeight).contentShape(Rectangle())
              }.buttonStyle(RowSurface()).keyCue().accessibilityLabel("浏览" + shelf.title)
              CollectionSwitch(d: d, shelf: shelf)
            }.padding(.horizontal, 14)
            if shelf != shelves.last { Divider().padding(.leading, 26 + iconSide) }
          }
        }.panelPaint()
      }
    }
  }
  @ViewBuilder private var detail: some View {
    let keys = CatalogSearch.tokens(query)
    let assigned = d.terms.filter { $0.collection != nil }
    let custom = removed ? [] : assigned.filter { catalog.matches($0, keys: keys, in: group, topic: topic) }
    let rows = catalog.find(query, in: group, topic: topic, removed: removed, policy: d.policy, overriding: Set(assigned.map { $0.spelling.lowercased() }))
    HStack(spacing: 8) {
      if group != nil || removed {
        IconAction(symbol: "chevron.backward", title: "返回全部分类") { group = nil; removed = false }
      }
      Text(removed ? "已移除" : group?.title ?? "全部搜索结果").font(.headline).lineLimit(1)
      Text("\(rows.count + custom.count) 条").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
      Spacer(minLength: 2)
      if let group, !removed {
        Menu {
          Button { topic = nil } label: { Label("全部主题", systemImage: topic == nil ? "checkmark" : "list.bullet") }
          ForEach(group.subjects, id: \.self) { part in
            Menu(part.rawValue) {
              Toggle("启用" + part.rawValue, isOn: Binding(get: { d.policy.subjectState(part) == .on }, set: { on in
                _ = d.changePolicy { $0.setSubject(part, enabled: on) }
              }))
              Divider()
              ForEach(catalog.subjectTopics[part] ?? [], id: \.self) { item in
                Button { topic = item } label: { if topic == item { Label(item, systemImage: "checkmark") } else { Text(item) } }
              }
            }
          }
          if assigned.contains(where: { $0.collection == group }) { Button(WordCatalog.customTopic) { topic = WordCatalog.customTopic } }
        } label: {
          let quick = [ClassicalCorpus.verseTopic, ClassicalCorpus.idiomTopic]
          let title = group == .humanities && (topic == nil || quick.contains(topic ?? "")) ? "更多主题" : topic ?? "全部主题"
          HStack(spacing: 5) {
            Text(title).lineLimit(1)
            Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
          }.font(.callout.weight(.medium)).padding(.horizontal, 10).frame(height: 28)
            .foregroundStyle(scheme == .dark ? Color(white: 0.9) : Color(white: 0.16))
            .background(Color.primary.opacity(0.065), in: Capsule())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().keyCue()
        .accessibilityLabel("筛选主题：" + (topic ?? "全部主题"))
        CollectionSwitch(d: d, shelf: group)
      }
    }.frame(minHeight: 30)
    if group == .humanities && !removed {
      HStack(spacing: 6) {
        ForEach([ClassicalCorpus.verseTopic, ClassicalCorpus.idiomTopic], id: \.self) { item in
          Button { topic = topic == item ? nil : item } label: {
            Label(item, systemImage: item == ClassicalCorpus.verseTopic ? "book.pages" : "quote.bubble")
              .font(.callout.weight(.medium)).padding(.horizontal, 10).frame(height: 28)
              .background(topic == item ? Color.inkMint.opacity(0.16) : Color.secondary.opacity(0.07), in: Capsule())
              .foregroundStyle(topic == item ? Color.inkMint : Color.primary)
          }.buttonStyle(RowSurface()).keyCue().accessibilityAddTraits(topic == item ? .isSelected : [])
        }
        Spacer()
      }
    }
    if rows.isEmpty && custom.isEmpty {
      LibraryEmpty(icon: removed ? "tray" : "magnifyingglass", title: removed ? "没有已移除的匹配词条" : "没有匹配的词条")
    } else {
      ScrollView {
        LazyVStack(spacing: 0) {
          ForEach(custom) { t in
            HStack { Text(catalog.byName[t.spelling.lowercased()]?.searchLabel(query, spelling: t.spelling) ?? t.spelling).textSelection(.enabled); Spacer(); IconAction(symbol: "pencil", title: "编辑“" + t.spelling + "”") { onEdit(t) } }
              .padding(.horizontal, Layout.inset).frame(minHeight: 39)
            Divider().padding(.horizontal, Layout.inset)
          }
          ForEach(rows) { w in
            HStack(spacing: 8) {
              Text(w.searchLabel(query)).help(w.flags.contains("v") ? w.tags.prefix(2).joined(separator: " · ") : w.topic).font(.system(size: 14, weight: .medium)).textSelection(.enabled)
              Spacer(minLength: 2)
              if group == nil || !d.policy.uses(w) && !removed {
                Text([group == nil ? w.collection.title : nil, !removed && !d.policy.uses(w) ? "未启用" : nil].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
              }
              if removed {
                IconAction(symbol: "arrow.uturn.backward", title: "恢复“" + w.name + "”") { _ = d.changePolicy { $0.hidden.remove(w.name.lowercased()) } }
              } else { IconAction(symbol: "minus.circle", title: "移除“" + w.name + "”") { removal = w } }
            }.padding(.horizontal, Layout.inset).frame(minHeight: 39)
            if w.id != rows.last?.id { Divider().padding(.horizontal, Layout.inset) }
          }
        }.panelPaint()
      }.id([group?.rawValue ?? "", topic ?? "", removed ? "移除" : "", query])
    }
  }
}

struct PersonalShelf: View {
  @ObservedObject var d: Desk
  let query: String, edit: (TermDraft) -> Void
  @LocalState private var clear = false
  var body: some View {
    let q = CatalogSearch.key(query)
    let manual = d.terms.filter { q.isEmpty || CatalogSearch.key($0.spelling + " " + $0.spoken).contains(q) }
    let occupied = Set(d.terms.map { $0.spelling.lowercased() })
    let learned = d.frequencies.ordered.filter { !occupied.contains($0.spelling.lowercased()) && (q.isEmpty || CatalogSearch.key($0.spelling).contains(q)) }
    HStack(spacing: 8) {
      Text("\(manual.count + learned.count) 词").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
      Spacer()
      Toggle("自动收录常用词", isOn: $d.options.collectFrequent).toggleStyle(.switch).controlSize(.small).keyCue()
        .disabled(!d.options.keepText).help(FrequencyCopy.note)
      Menu { Button("清空自动收录…", role: .destructive) { clear = true }.disabled(!d.frequencies.hasEvidence) }
        label: { Image(systemName: "ellipsis.circle").font(.system(size: 16)).frame(width: 26, height: 26) }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().keyCue().accessibilityLabel("常用词选项")
    }.frame(minHeight: 30)
    if manual.isEmpty && learned.isEmpty {
      LibraryEmpty(icon: q.isEmpty ? "character.book.closed" : "magnifyingglass", title: q.isEmpty ? "还没有个人词条" : "没有匹配的词条")
    } else {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(manual) { w in
            row(w.spelling, subtitle: w.spoken.isEmpty ? nil : "读作：" + w.spoken, trail: w.imported == true ? "导入" : "手动") { edit(TermDraft(word: w)) }
          }
          ForEach(learned) { w in
            row(w.spelling, subtitle: nil, trail: "常用 · \(w.count) 次") { edit(TermDraft(frequency: w.spelling)) }
          }
        }.panelPaint()
      }
    }
    // Attach to an always-present part of the view, including when only pending counts exist.
    Color.clear.frame(height: 0).accessibilityHidden(true).alert("清空自动收录？", isPresented: $clear) {
      Button("取消", role: .cancel) {}
      Button("清空", role: .destructive) { d.clearFrequent() }
    } message: { Text("移除自动收录的词和待收录次数，保留手动、导入的词条。新听写会重新累计。") }
  }
  private func row(_ name: String, subtitle: String?, trail: String, action: @escaping () -> Void) -> some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        VStack(alignment: .leading, spacing: 2) {
          Text(name).font(.system(size: 14, weight: .medium)).textSelection(.enabled)
          if let subtitle { Text(subtitle).font(.callout).foregroundStyle(.secondary) }
        }
        Spacer(); Text(trail).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        IconAction(symbol: "pencil", title: "编辑“" + name + "”", action: action)
      }.padding(.horizontal, Layout.inset).padding(.vertical, 5).frame(minHeight: 40)
      Divider().padding(.horizontal, Layout.inset)
    }
  }
}
