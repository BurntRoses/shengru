import SwiftUI

enum SettingsSection: String, CaseIterable {
  case dictate = "听写"
  case capsule = "悬浮窗"
  case model = "模型"
  case privacy = "权限与记录"
  case updates = "更新"
}

struct SettingsPane: View {
  @ObservedObject var d: Desk
  let section: SettingsSection
  @LocalState private var showMemory = false
  @LocalState private var pendingLimit: LimitChange?

  var body: some View {
    GeometryReader { geo in
      if section == .capsule { PanelStudio(d:d) } else { ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          switch section {
          case .dictate: dictate(wide: geo.size.width >= 510)
          case .capsule: EmptyView()
          case .updates:
            UpdatePane(d:d, updates:d.updates)
            UninstallRow(d:d,updates:d.updates,models:d.models)
          case .model: ModelPane(d:d, shelf:d.models)
          case .privacy: privacy
          }
        }.padding(.bottom, 4)
      }.id(section) }
    }.onDisappear { d.previewing = false }.onChange(of:section) { _,_ in d.previewing = false }.sheet(isPresented:$showMemory) { MemoryPane(d:d) }.alert(
      "降低保留数量？",
      isPresented: Binding(get: { pendingLimit != nil }, set: { if !$0 { pendingLimit = nil } }),
      presenting: pendingLimit
    ) { change in
      Button("取消", role: .cancel) {}
      Button("减少并删除", role: .destructive) { apply(change) }
    } message: { change in
      Text(
        "仅保留最近 \(change.count) \(change.audio ? "段录音" : "条文字")，更早的\(change.audio ? "录音" : "文字")将被删除，无法恢复。"
      )
    }
  }

  @ViewBuilder private func dictate(wide: Bool) -> some View {
    Surface(inset: Layout.inset) {
      choice("听写快捷键", $d.options.trigger, Trigger.allCases).disabled(d.recordingBusy)
      Divider()
      switchLine("短按切换持续听写", $d.options.shortToggle)
        .help("短按一次开始，再按一次结束。按住说话仍可用。")
      Divider()
      switchLine("将定稿输入到原光标", $d.options.autoInsert)
      Divider()
      switchLine("按语境校对用词", $d.options.proofWords).help("关闭后直接采用模型的用词，不加词库提示；仍按所选方式整理表达。")
      Divider()
      switchLine("输入前审阅", $d.options.reviewFirst)
    }
    Surface(inset: Layout.inset, spacing: 8) {
      PanelTitle(title: "整理方式")
      let columns = Array(
        repeating: GridItem(.flexible(), spacing: 8, alignment: .topLeading), count: wide ? 2 : 1)
      LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
        ForEach(EditLevel.allCases) { level in
          let selected = level == d.options.level
          Button {
            d.options.level = level
          } label: {
            HStack(alignment: .top, spacing: 8) {
              VStack(alignment: .leading, spacing: 4) {
                Text(level.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(
                  selected ? Color.inkMint : .primary)
                Text(level.detail).font(.callout).foregroundStyle(.secondary).fixedSize(
                  horizontal: false, vertical: true)
              }
              Spacer(minLength: 0)
              Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(
                Color.inkMint
              )
              .opacity(selected ? 1 : 0).accessibilityHidden(true)
            }.padding(.horizontal, 11).padding(.vertical, 9).frame(
              maxWidth: .infinity, minHeight: wide ? 60 : 48, alignment: .topLeading)
          }.buttonStyle(RowSurface(selected: selected)).keyCue().accessibilityAddTraits(
            selected ? .isSelected : [])
        }
      }
    }
  }

  @ViewBuilder private var privacy: some View {
    Surface(inset: Layout.inset) {
      PanelTitle(title: "系统权限").padding(.bottom, 4)
      PermissionRows(d:d)
    }
    Surface(inset: Layout.inset) {
      PanelTitle(title: "本机记录").padding(.bottom, 4)
      retention(audio: false)
      Divider()
      retention(audio: true)
      Divider()
      switchLine("缩短录音里的长静音", $d.options.compactQuiet).disabled(!d.options.keepAudio).help("只缩短连续四秒以上的近乎无声片段。识别始终使用完整声音。每五分钟自动保存一节。")

    }
    Surface(inset:Layout.inset) {
      PanelTitle(title:"听写记忆"); switchLine("记住改词",$d.options.learning).help("第一次改词只作备选。在不同录音里确认过，并且这句话的用法也相符时，才自动采用。"); Divider()
      switchLine("自动收录常用词", $d.options.collectFrequent).disabled(!d.options.keepText).help(FrequencyCopy.note); Divider()
      switchLine("关联连续听写",$d.options.linkContext).disabled(!d.options.keepText).help("开启文字记录后，同一应用内三分钟内的相邻听写可参考上一段。")
      HStack { Button("查看修改记忆（\(d.memories.count)）") { showMemory = true }.deskAction(); Spacer(); Button("使用引导") { d.openGuide?() }.deskAction() }.padding(.top,8)
    }
  }

  private func choice<T: RawRepresentable & Hashable>(
    _ name: String, _ value: Binding<T>, _ choices: [T]
  ) -> some View where T.RawValue == String {
    HStack(spacing: 12) {
      Text(name)
      Spacer()
      Picker(name, selection: value) { ForEach(choices, id: \.self) { Text($0.rawValue).tag($0) } }
        .labelsHidden().keyCue().frame(width: Layout.controlRail, alignment: .trailing)
    }.frame(minHeight: Layout.row)
  }
  private func switchLine(_ name: String, _ value: Binding<Bool>) -> some View {
    Toggle(isOn: value) { Text(name).frame(maxWidth: .infinity, alignment: .leading) }
      .toggleStyle(.switch).controlSize(.regular).keyCue().frame(minHeight: Layout.row)
  }
  private struct LimitChange { let audio: Bool, count: Int }
  private func apply(_ change: LimitChange) {
    if change.audio {
      d.options.limitAudio = change.count
    } else {
      d.options.limitText = change.count
    }
  }
  private func retention(audio: Bool) -> some View {
    let name = audio ? "保存录音" : "保存文字"
    let unit = audio ? "段" : "条"
    let saved = audio ? $d.options.keepAudio : $d.options.keepText
    let limit = Binding<Int>(
      get: { audio ? d.options.limitAudio : d.options.limitText },
      set: { next in
        let change = LimitChange(audio: audio, count: next)
        let existing = d.rows.filter { audio ? $0.audio != nil : $0.text != nil }.count
        if next < existing { pendingLimit = change } else { apply(change) }
      })
    return HStack(spacing: 12) {
      Text(name)
      Spacer(minLength: 4)
      HStack(spacing:12) {
        Picker(audio ? "保留录音" : "保留文字", selection: limit) {
          ForEach([10, 20, 50, 100], id: \.self) { Text("最近 \($0) \(unit)").tag($0) }
        }.labelsHidden().keyCue().disabled(!saved.wrappedValue)
        Toggle(name, isOn: saved).labelsHidden().toggleStyle(.switch).keyCue()
      }.frame(width:Layout.controlRail,alignment:.trailing)
    }.frame(minHeight:Layout.row).help("关闭后不再保存，已有记录可在历史中删除。")
  }
}

private struct UninstallRow: View {
  @ObservedObject var d:Desk
  @ObservedObject var updates:AppUpdates
  @ObservedObject var models:ModelShelf
  var body:some View { HStack {Spacer();Button("卸载如流…"){d.uninstall?()}.deskAction().disabled(!d.allowsUpdateRestart || updates.busy)} }
}
