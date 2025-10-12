@main
final class GameLoop {
  static func main() {
    let game = GameLoop()

    game.initialize()
    game.update()
    game.exit()
  }

  var doFrame = true
  
  let windowWidth: Int32 = 800
  let windowHeight: Int32 = 600
  
  private var window: Window?

  // MARK: - 초기화
  func initialize() {
    window = Window(w: windowWidth, h: windowHeight, name: "Ikyo")
  }

  // MARK: - 업데이트
  func update() {
    while doFrame {
      window?.pollEvents()
    }
  }

  // MARK: - 종료
  func exit() {}
}
