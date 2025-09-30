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