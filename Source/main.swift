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
  
  private var window: ikyoWindow?

  // MARK: - Initialize
  func initialize() {
    window = ikyoWindow(w: windowWidth, h: windowHeight, name: "Ikyo")
  }

  // MARK: - Update
  func update() {
    while doFrame {
      window?.pollEvents()
    }
  }

  // MARK: - Exit
  func exit() {}
}
