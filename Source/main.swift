// 이 엔진은 엔진 인스턴스와 게임 인스턴스를 동일하게 취급하며, Main이 곧 게임 루프의 역할을 수행합니다.
@main
final class GameLoop {
  static func main() {
    let game = GameLoop()

    game.initialize()
    game.update()
    game.exit()
  }

  var doFrame = false

  // MARK: - Initialize
  func initialize() {}

  // MARK: - Update
  func update() {
    while doFrame {}
  }

  // MARK: - Exit
  func exit() {}
}