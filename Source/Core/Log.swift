// glfw, 에디터, 콘솔에 한번에 로그를 전달하는 함수
// 디버그 빌드 시 작동
func log(a: String) {
  #if DEBUG
  print(a)
  #endif
}