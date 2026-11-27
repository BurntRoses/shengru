import SwiftUI

struct WelcomeView: View {
  @ObservedObject var d: Desk
  var complete: () -> Void
  @LocalState private var step = 0
  var body: some View {
    VStack(alignment:.leading,spacing:20) {
      HStack(spacing:12) {
        BrandBadge(size:48).accessibilityHidden(true)
        Text(["欢迎使用如流本地语音输入","听写权限","记录与偏好"][step])
          .font(.system(size:22,weight:.semibold)).accessibilityAddTraits(.isHeader)
        Spacer(); Text("\(step+1) / 3").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
          .accessibilityLabel("第 \(step+1) 步，共 3 步")
      }
      switch step {
      case 0:
        Surface(inset:20,spacing:16) {
          HStack(spacing:10) {
            Image(systemName:"keyboard").foregroundStyle(Color.inkMint)
            Text(d.options.trigger.rawValue).font(.system(size:24,weight:.semibold,design:.rounded))
          }
          VStack(alignment:.leading,spacing:6) {
            Text("按住说话，松开输入").font(.headline)
            if d.options.shortToggle { Text("连续听写：短按开始，再按结束。").font(.callout).foregroundStyle(.secondary) }
          }
          Divider()
          HStack(spacing:24) {
            Label("离线听写",systemImage:"waveform"); Label("本地存储",systemImage:"internaldrive")
          }.font(.callout).foregroundStyle(.secondary)
        }
      case 1: Surface(inset:14) { PermissionRows(d:d) }
      default:
        Surface(inset:12) {
          guideToggle("保存文字",$d.options.keepText);Divider();guideToggle("保存录音",$d.options.keepAudio);Divider();guideToggle("按语境校对用词",$d.options.proofWords);Divider();guideToggle("记住改词",$d.options.learning);Divider();guideToggle("收录常用词",$d.options.collectFrequent).disabled(!d.options.keepText);Divider();guideToggle("关联连续听写",$d.options.linkContext).disabled(!d.options.keepText)
        }
      }
      Spacer(minLength:0)
      HStack { if step>0 {Button("上一步"){step-=1}.deskAction()};Spacer();Button(["设置权限","记录偏好","完成设置"][step]) {if step<2 {step+=1} else {complete()}}.deskAction(primary:true,large:true).keyboardShortcut(.defaultAction) }
    }.padding(22).frame(width:460,height:369).tint(.inkMint).workspaceKeyboard()
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
