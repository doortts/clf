import Foundation

/// 앞 창이 어느 계정 것인지.
///
/// 메뉴바는 이 답을 받은 계정 코드 아래에 파란 밑줄을 긋는다. 밑줄은
/// "지금 이 창" 이라는 말이라 Claude 창이 앞에 없으면 아무 계정도 답하지
/// 않는다. docs/design/focus-underline-mockup.html
public enum FocusMark {
    /// 앞 앱의 pid 와 실행 파일 경로로 계정을 찾는다.
    ///
    /// 별도 인스턴스와 기본 창은 실행 파일이 같다. 가르는 것은 pid 다.
    /// 인스턴스 목록에 있으면 그 계정이고, 없으면 기본 창이라 활성 계정이다.
    public static func focusedUUID(frontPid: Int32?, frontExecutable: String?,
                                   instances: [String: Int32],
                                   orgs: [OrgUsage], activeUUID: String?) -> String? {
        guard let frontPid, frontExecutable == AltInstance.executable else { return nil }
        if let slug = instances.first(where: { $0.value == frontPid })?.key {
            return orgs.first { AltInstance.slug($0.name) == slug }?.uuid
        }
        return activeUUID
    }
}
