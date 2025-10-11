import CGLFW

class Window {
  private let width: Int32
  private let height: Int32
  private let windowName: String
  private var window: OpaquePointer?
  
  init (w: Int32, h: Int32, name: String) {
    self.width = w
    self.height = h
    self.windowName = name
    self.window = nil
    
    initWindow()
  }
  
  deinit {
    glfwDestroyWindow(window)
    glfwTerminate()
  }
  
  func pollEvents() {
    glfwPollEvents()
  }
  
  private func initWindow() {
    glfwInit()
    glfwWindowHint(GLFW_CLIENT_API, GLFW_NO_API)
    glfwWindowHint(GLFW_RESIZABLE, GLFW_FALSE)
    
    window = glfwCreateWindow(width, height, windowName, nil, nil)
  }
}
