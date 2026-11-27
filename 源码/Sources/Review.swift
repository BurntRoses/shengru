import AppKit
import SwiftUI

struct ReviewCard: View {
  @ObservedObject var d: Desk
  var editorHeight: CGFloat = 140
  @LocalState private var compare = false
  @LocalState private var discard = false
  private var live: Bool { d.recordingBusy }
  var body: some View {
    Surface(spacing: 10) {
      HStack(spacing: 8) {
        PanelTitle(title: d.awaitingReview ? "待审阅" : d.editing ? "修改定稿" : "最近定稿")
        Spacer()
        if d.confirming {
          ProgressView().controlSize(.small)
          Text("正在输入…").font(.callout).foregroundStyle(.secondary)
        } else if !live && !d.last.isEmpty {
          if !d.editing { Button("增强识别") { d.rehear() }.deskAction().disabled(d.rehearing?.stage == .working).help("重听原声并校正用词") }
          if d.editing && !d.panelEditing {
            Button(compare ? "隐藏对照" : "删改对照") { compare.toggle() }.deskAction()
          } else {
            if d.awaitingReview && !d.panelEditing {
              Button("放弃…") { discard=true }.deskAction()
              Button(d.canSendReviewed ? "确认并输入" : "确认定稿") { d.confirmReview() }.deskAction(primary: true)
            }
          }
        }
        if !d.confirming && !live && !d.last.isEmpty {
          Button {
            d.copyCurrent()
          } label: {
            Label(d.copied ? "已复制" : "复制", systemImage: d.copied ? "checkmark" : "doc.on.doc")
          }
          .deskAction().fixedSize().disabled(d.copyText.isEmpty).accessibilityLabel(d.copyLabel)
          .help(d.copyLabel)
        }
      }.frame(minHeight: 30)
      if let r=d.rehearing, r.origin == .dictate, !r.inCapsule { RehearingInline(d:d,review:r) }
      if d.last.isEmpty {
        Label("暂无定稿", systemImage: "text.cursor").font(.callout).foregroundStyle(
          .secondary
        ).frame(maxWidth: .infinity, minHeight: 68)
      } else if let id=d.lastID {
        PassageEditor(id:id,value:d.reviewText,label:"本次定稿，可编辑",editable:!live && !d.confirming,editing:d.editing && !d.panelEditing,
          begin:{d.editLast(open:false);return d.editing && !d.panelEditing},change:{d.draft=$0},save:{d.confirmReview()},cancel:{d.cancelEdit()})
          .padding(4).frame(height:d.editing ? editorHeight : min(editorHeight,max(58,CapsuleMetrics.inkHeight(d.reviewText,width:490,font:.systemFont(ofSize:15))+14)))
          .background(Color.inkMint.opacity(d.editing ? 0.055 : 0),in:RoundedRectangle(cornerRadius:9)).help("点按文字修改")
        if !live { candidates }
        if compare || (d.showEdits && d.raw != d.last && !d.editing) {
          Text(ReviewRuns.styled(d.draft != d.last ? d.last : d.raw,d.reviewText,tail:false)).font(.callout).lineSpacing(3)
        }
        if d.editing && !d.panelEditing {
          HStack {
            Button("取消") { d.cancelEdit() }.deskAction()
            Spacer(); Button(d.canSendReviewed ? "确认并输入" : (d.awaitingReview ? "确认定稿" : "保存修改")) {d.confirmReview()}
              .deskAction(primary:true).disabled(d.draft.trimmed.isEmpty || d.confirming)
          }
        } else if !d.confirming && !d.awaitingReview && !d.status.isEmpty {Text(d.status).font(.caption).foregroundStyle(.secondary)}
      }
    }.onChange(of:d.editing) {_,_ in compare=false}
    .alert("放弃这次听写？", isPresented: $discard) {
      Button("继续审阅", role: .cancel) {}
      Button("放弃", role: .destructive) { d.discardReview() }
    } message: {
      Text("这次的文字和录音不会保存，也不会输入。")
    }
  }
  private var candidates: some View {
    ReadingPicker(text: d.reviewText, choices: d.readingChoices, choose: d.chooseReading,
      undo: d.canUndoReading ? d.undoReading : nil).disabled(d.confirming)
  }
}

struct ReadingPicker: View {
  let text: String, choices: [ReadingChoice], choose: (ReadingChoice) -> Void, undo: (() -> Void)?
  private struct Place: Hashable { let heard: String, left: String, right: String }
  private var candidateRows: [(key: Place, value: [ReadingChoice])] {
    var rows: [(key: Place, value: [ReadingChoice])] = []
    for choice in choices where choice.applying(to: text) != nil {
      let key = Place(heard: choice.heard, left: choice.left, right: choice.right)
      if let i = rows.firstIndex(where: { $0.key == key }) { rows[i].value.append(choice) }
      else { rows.append((key, [choice])) }
    }
    return rows
  }
  @ViewBuilder private func wordButtons(_ choices: [ReadingChoice]) -> some View {
    ForEach(choices) { choice in
      Button(choice.word) { choose(choice) }
        .deskAction().fixedSize().accessibilityLabel("把“" + choice.heard + "”替换为“" + choice.word + "”")
        .help("只替换这里的“" + choice.heard + "”")
    }
  }
  @ViewBuilder var body: some View {
    let rows = candidateRows
    if !rows.isEmpty || undo != nil {
      VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 10) {
          if !rows.isEmpty { Text("可选写法").font(.callout.weight(.medium)).foregroundStyle(.secondary) }
          if let undo {
            Button(action: undo) { Label("撤销替换", systemImage: "arrow.uturn.backward") }.deskAction()
          }
        }
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
          ForEach(rows, id: \.key) { row in
            GridRow {
              Text(row.key.heard).font(.callout).foregroundStyle(.secondary)
                .help(row.key.left + row.key.heard + row.key.right)
              Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary).accessibilityHidden(true)
              ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { wordButtons(row.value) }.fixedSize()
                VStack(alignment: .leading, spacing: 4) { wordButtons(row.value) }
              }
            }
          }
        }
      }.frame(maxWidth: .infinity, alignment: .leading)
    }
  }

}

struct MemoryPane: View {
  @ObservedObject var d: Desk
  @Environment(\.dismiss) private var dismiss
  @LocalState private var removing: Term?
  @LocalState private var confirm = false
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Text("修改记忆").font(.title2.bold())
        Spacer()
        Button("完成") { dismiss() }.deskAction()
      }

      if d.memories.isEmpty {
        Spacer()
        Text("暂无改词记录").foregroundStyle(.secondary).frame(maxWidth: .infinity)
        Spacer()
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 0) {
            ForEach(d.memories.reversed()) { pair in
              HStack {
                VStack(alignment: .leading, spacing: 3) {
                  Text(pair.spelling).font(.headline)
                  Text("原写法：" + pair.spoken).font(.callout).foregroundStyle(.secondary)
                  Text(pair.scope?.label ?? "待再次确认")
                    .font(.caption).foregroundStyle(Color.inkMint)
                }
                Spacer()
                IconAction(symbol: "trash", title: "删除这条修改记忆") {
                  removing = pair
                  confirm = true
                }
              }.padding(.vertical, 8)
              Divider()
            }
          }
        }
        Button("清空修改记忆…", role: .destructive) {
          removing = nil
          confirm = true
        }.deskAction()
      }
    }.padding(22).frame(width: 430, height: 360).workspaceKeyboard().tint(.inkMint)
      .alert(removing == nil ? "清空修改记忆？" : "删除这条修改记忆？", isPresented: $confirm) {
        Button("取消", role: .cancel) {}
        Button("删除", role: .destructive) {
          d.saveMemories(removing.map { item in d.memories.filter { $0.id != item.id } } ?? [])
        }
      } message: {
        Text("删除后不再套用这些写法，以往定稿不变。")
      }
  }
}

struct ModelPane: View {
  @ObservedObject var d: Desk
  @ObservedObject var shelf: ModelShelf
  @LocalState private var removing:SpeechModel?
  var body: some View {
    Surface(spacing:8) {
      PanelTitle(title:"本地识别模型")
      Label("离线运行",systemImage:"internaldrive").font(.callout).foregroundStyle(.secondary)
      ForEach(SpeechModel.allCases,id:\.self) { model in
        Divider().padding(.vertical,3)
        HStack(spacing:10) {
          VStack(alignment:.leading,spacing:4) { Text(model.title).font(.headline); HStack(spacing:4) { Text(model.caption).font(.caption).foregroundStyle(.secondary)
            if model != .bundled { Image(systemName:"info.circle").font(.caption).foregroundStyle(.secondary).help(model.cost).accessibilityLabel(model.cost) } }
          }.fixedSize(horizontal:false,vertical:true)
          Spacer(minLength:4)
          if d.loadingModel == model { ProgressView().controlSize(.small) }
          else if model == d.activeModel && d.ready { Label("使用中",systemImage:"checkmark").font(.callout).foregroundStyle(Color.inkMint) }
          else if shelf.installed.contains(model) {
            Button("使用") { d.selectModel(model,remember:true) }.deskAction().disabled(d.recordingBusy || d.preparing)
            if model != .bundled { IconAction(symbol:"trash",title:"移除"+model.title) { removing=model }.disabled(d.preparing || shelf.installing != nil) }
          } else if shelf.installing != model {
            Button("下载") { shelf.install(model) }.deskAction().disabled(shelf.installing != nil).help(model.cost)
          }
        }
        if shelf.installing == model, let value=shelf.progress { HStack { ProgressView(value:value).tint(.inkMint); Text(shelf.verifying ? "校验中" : "\(Int(value*100))%").font(.caption.monospacedDigit()); Button("取消") { shelf.cancel() }.deskAction() } }
      }
      if !shelf.note.isEmpty { Text(shelf.note).font(.callout).foregroundStyle(.secondary) }
    }.alert("移除这个模型？",isPresented:Binding(get:{removing != nil},set:{if !$0 { removing=nil }}),presenting:removing) { model in
      Button("取消",role:.cancel) {}; Button("移除",role:.destructive) { if d.activeModel != model { shelf.remove(model) } }
    } message:{ model in Text("将删除“"+model.title+"”的下载文件。听写记录不变，之后可重新安装。") }
  }
}

// Keep streaming text in a fixed-height surface. The previous finalized passage stays
// mounted below, with its own selection, undo state and scroll position.
private struct StreamTail: View {
  let d: Desk
  var body: some View {
    let text = String((d.stable + d.tail).suffix(240))
    if let before = d.inkBefore(text) { Text(ReviewRuns.styled(before,text)) }
    else { Text(text.isEmpty ? "正在听…" : text).foregroundStyle(text.isEmpty ? .secondary : .primary) }
  }
}
struct LiveLine: View {
  @ObservedObject var d: Desk
  var body: some View {
    HStack(alignment:.top,spacing:9) {
      Image(systemName:"quote.opening").font(.caption).foregroundStyle(Color.inkMint).padding(.top,3)
      if d.recordingBusy {
        ScrollViewReader { reader in
          ScrollView { VStack(alignment:.leading,spacing:0) { StreamTail(d:d); Color.clear.frame(height:1).id("end") }.frame(maxWidth:.infinity,alignment:.leading) }
            .scrollIndicators(.hidden).onChange(of:d.stable+d.tail,initial:true) { _,_ in reader.scrollTo("end",anchor:.bottom) }
        }
      } else { Text("等待听写").foregroundStyle(.secondary); Spacer() }
    }.font(.body).frame(maxWidth:.infinity,minHeight:32,maxHeight:32,alignment:.topLeading)
  }
}
struct CaptureWave: View {
  let live: LiveCapture, active: Bool
  var body: some View { WaveMark(power:live.level,active:active,history:live.meterHistory) }
}
struct CaptureCaption: View {
  @ObservedObject var d:Desk
  var body:some View {
    Text(d.phase == .listen ? clockText(d.seconds) + (d.handsFree ? " · 再按一次结束" : "") : d.options.reviewFirst ? (d.options.autoInsert ? "确认后输入" : "结束后审阅") : d.options.autoInsert ? "松开即可输入" : "在悬浮窗复制文字")
      .font(.callout).foregroundStyle(.secondary).monospacedDigit()
  }
}
