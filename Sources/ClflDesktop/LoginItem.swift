import Foundation

/// 로그인 항목 상태. `SMAppService.Status` 를 우리 말로 옮긴 것.
///
/// 앱 타겟에만 두면 테스트를 못 한다. `ServiceManagement` 를 부르는 자리는
/// 앱에 남기고 그다음 판단은 여기서 한다.
public enum LoginItemState: Sendable, Equatable, CaseIterable {
    case off
    case on
    /// 등록은 됐고 사용자가 시스템 설정에서 허용해야 한다.
    case needsApproval
    /// 번들을 못 찾는다. 대개 빌드 디렉토리에서 돌리는 중이다.
    case unavailable

    public var label: String {
        switch self {
        case .off, .on:      return "로그인할 때 실행"
        case .needsApproval: return "로그인할 때 실행 (승인 대기)"
        case .unavailable:   return "로그인할 때 실행 (불가)"
        }
    }

    /// 사용자가 할 일이 남았을 때만 말한다. 다 잘 되고 있으면 잔소리하지 않는다.
    public var hint: String? {
        switch self {
        case .on, .off:
            return nil
        case .needsApproval:
            return "시스템 설정 > 일반 > 로그인 항목에서 켜야 한다"
        case .unavailable:
            return "앱을 Applications 로 옮겨야 등록된다"
        }
    }

    /// 승인 대기 중을 켜진 것으로 그리면 다음 부팅에 안 뜨고 사용자는 모른다.
    public var isChecked: Bool { self == .on }

    /// 못 켜는 상태에서 체크박스를 살려두면 눌러도 아무 일이 없다.
    /// 승인 대기 중에는 끌 수 있어야 한다. 취소할 길을 막으면 안 된다.
    public var isToggleable: Bool { self != .unavailable }

    /// `SMAppService.Status` 의 원시값을 우리 상태로 옮긴다.
    ///
    /// 실측으로 잡은 것이 있다. 한 번도 등록한 적이 없으면 `.notRegistered`(0)
    /// 가 아니라 **`.notFound`(3) 가 온다.** 그걸 "등록 불가" 로 읽으면
    /// 체크박스가 처음부터 잠겨 아무도 이 기능을 못 쓴다.
    ///
    /// 진짜 불가능한 경우는 자리로 판별한다. 시스템에 묻기 전에 거른다.
    public static func from(statusRawValue raw: Int, path: String) -> LoginItemState {
        guard isStableLocation(path) else { return .unavailable }
        switch raw {
        case 1:  return .on              // enabled
        case 2:  return .needsApproval   // requiresApproval
        case 0:  return .off             // notRegistered
        case 3:  return .off             // notFound. 아직 한 번도 안 걸었다
        default: return .off             // 모르는 값을 켜진 것처럼 그리지 않는다
        }
    }

    /// 빌드 디렉토리에 있는 앱은 다음 빌드에 지워진다. 승인을 받아도 헛일이다.
    public static func isStableLocation(_ path: String) -> Bool {
        let volatile = ["/.build/", "/DerivedData/", "/Downloads/", "/tmp/"]
        guard !volatile.contains(where: { path.contains($0) }) else { return false }
        return path.contains("/Applications/")
    }
}
