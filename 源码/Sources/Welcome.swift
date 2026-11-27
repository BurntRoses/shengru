import SwiftUI

struct WelcomeView: View {
  @ObservedObject var d: Desk
  var complete: () -> Void
  @LocalState private var step = 0
  var body: some View {
    VStack(alignment:.leading,spacing:16) {
      HStack(spacing:12) {
        BrandBadge(size:48)
        VStack(alignment:.leading,spacing:4) {
          Text(["欢迎使用如流","开启听写权限","选择本机记录"][step]).font(.title2.bold()).accessibilityAddTraits(.isHeader)
          Text(["PhraseFlow · 本地中英听写","由 macOS 授权，返回后自动生效。","推荐项已选好，你可以按需关闭。"][step]).font(.callout).foregroundStyle(.secondary)
        };Spacer();Text("\(step+1) / 3").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
      }
      switch step {
      case 0:
        Surface(inset:20,spacing:14) {
          Label("在光标处说话",systemImage:"text.cursor").font(.headline)
          Text(d.options.trigger.rawValue).font(.system(size:31,weight:.semibold,design:.rounded)).foregroundStyle(Color.inkMint)
          Text("按住说，松开输入。短按开始长句，再按一次结束。").font(.body)
          Divider();Label("语音与文字留在这台 Mac，断网也能听写。",systemImage:"lock").font(.callout).foregroundStyle(.secondary)
        }
      case 1: Surface(inset:14) { PermissionRows(d:d) }
      default:
        Surface(inset:12) {
          guideToggle("保存听写文字",$d.options.keepText);Divider();guideToggle("保留录音，可复听校正",$d.options.keepAudio);Divider();guideToggle("按语境校对用词",$d.options.proofWords);Divider();guideToggle("记住已确认的改词",$d.options.learning);Divider();guideToggle("自动收录常用词",$d.options.collectFrequent).disabled(!d.options.keepText);Divider();guideToggle("关联连续听写",$d.options.linkContext).disabled(!d.options.keepText)
        }
      }
      Spacer(minLength:0)
      HStack { if step>0 {Button("上一步"){step-=1}.deskAction()};Spacer();Button(["设置权限","选择记录偏好","开始使用"][step]) {if step<2 {step+=1} else {complete()}}.deskAction(primary:true,large:true).keyboardShortcut(.defaultAction) }
    }.padding(22).frame(width:460,height:417).tint(.inkMint).workspaceKeyboard()
  }
  private func guideToggle(_ title:String,_ value:Binding<Bool>)->some View {Toggle(isOn:value){Text(title).frame(maxWidth:.infinity,alignment:.leading)}.toggleStyle(.switch).keyCue().frame(minHeight:27)}
}

struct ReleaseSheet:View {
  @ObservedObject var d:Desk
  @ObservedObject var updates:AppUpdates
  let highlights:Bool, close:()->Void
  var body:some View {
    VStack(alignment:.leading,spacing:16) {
      if highlights {
        HStack { BrandBadge(size:50); VStack(alignment:.leading,spacing:4){ Text("如流已更新").font(.title2.bold());Text(AppUpdates.installed.label).foregroundStyle(.secondary) } }
        Divider();Text(AppUpdates.installed.notes).font(.body).lineSpacing(4).fixedSize(horizontal:false,vertical:true)
      } else {UpdatePane(d:d,updates:updates)}
      HStack {Spacer();Button(highlights ? "开始使用" : updates.stage == .found ? "稍后再说" : "关闭"){close()}.deskAction(primary:highlights)}
    }.padding(20).frame(width:444).fixedSize(horizontal:false,vertical:true).tint(.inkMint).workspaceKeyboard()
      .onChange(of:updates.stage){old,new in if !highlights && old == .found && new == .idle {close()} }
  }
}
