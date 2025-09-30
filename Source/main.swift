@main
class GameLoop {
  static func main() {
    let game = GameLoop()

    game.initialize()
    game.update()
    game.exit()
  }

  func initialize() {}
  func update() {}
  func exit() {}
}