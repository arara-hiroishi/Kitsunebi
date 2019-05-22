//
//  KBAnimationView.swift
//  Kitsunebi
//
//  Created by Tomoya Hirano on 2018/04/13.
//

import UIKit

public protocol KBAnimationViewDelegate: class {
  func didUpdateFrame(_ index: Int, animationView: KBAnimationView)
  func animationViewDidFinish(_ animationView: KBAnimationView)
}

open class KBAnimationView: UIView, KBVideoEngineUpdateDelegate, KBVideoEngineDelegate {
  private var backingWidth: GLint = 0
  private var backingHeight: GLint = 0
  private var viewRenderbuffer: GLuint = 0
  private var viewFramebuffer: GLuint = 0
  private var positionRenderTexture: GLuint = 0
  private var positionRenderbuffer: GLuint = 0
  private var positionFramebuffer: GLuint = 0
  private var displayProgram: GLuint = 0
  private var uniformLocation: Int32 = 0
  
  private let glContext: EAGLContext
  
  private var textureCache: CVOpenGLESTextureCache? = nil
  private var threadsafeSize: CGSize = .zero
  private var applicationHandler = KBApplicationHandler()
  
  public weak var delegate: KBAnimationViewDelegate? = nil
  
  internal let vsh: String = """
  attribute vec4 position;
  attribute vec4 inputTextureCoordinate;
  varying vec2 textureCoordinate;
  void main() {
    gl_Position = position;
    textureCoordinate = inputTextureCoordinate.xy;
  }
  """
  
  internal let fsh: String = """
  varying highp vec2 textureCoordinate;
  uniform sampler2D videoFrame;
  uniform sampler2D videoFrame2;
  void main() {
    highp vec4 color = texture2D(videoFrame, textureCoordinate);
    highp vec4 colorAlpha = texture2D(videoFrame2, textureCoordinate);
    gl_FragColor = vec4(color.r, color.g, color.b, colorAlpha.r);
  }
  """
  
  internal enum ATTRIB: UInt32 {
    case VERTEX
    case TEXTUREPOSITON
  }
  
  internal var engineInstance: KBVideoEngine? = nil
  
  public func play(mainVideoURL: URL, alphaVideoURL: URL, fps: Int) throws {
    engineInstance?.purge()
    engineInstance = KBVideoEngine(mainVideoUrl: mainVideoURL,
                                   alphaVideoUrl: alphaVideoURL,
                                   fps: fps)
    engineInstance?.updateDelegate = self
    engineInstance?.delegate = self
    try engineInstance?.play()
  }

  public func pause() {
    engineInstance?.pause()
  }
    
  public func resume() {
    engineInstance?.resume()
  }
    
  public func stop() {
    engineInstance?.stop()
  }
  
  override open class var layerClass: Swift.AnyClass {
    return CAEAGLLayer.self
  }
  
  public init?(frame: CGRect, context: EAGLContext = EAGLContext(api: .openGLES2)!) {
    glContext = context
    glContext.isMultiThreaded = true
    super.init(frame: frame)
    applicationHandler.delegate = self
    guard prepare() else { return nil }
  }
  
  required public init?(coder aDecoder: NSCoder) {
    glContext = EAGLContext(api: .openGLES2)!
    glContext.isMultiThreaded = true
    super.init(coder: aDecoder)
    guard prepare() else { return nil }
  }
  
  deinit {
    NotificationCenter.default.removeObserver(self)
    destroyFramebuffer()
  }
  
  private func prepare() -> Bool {
    backgroundColor = .clear
    let eaglLayer: CAEAGLLayer = self.layer as! CAEAGLLayer
    eaglLayer.isOpaque = false
    eaglLayer.drawableProperties = [kEAGLDrawablePropertyRetainedBacking : false,
                                    kEAGLDrawablePropertyColorFormat : kEAGLColorFormatRGBA8]
    guard glContext.use() else { return false }
    guard createCache() else { return false }
    guard createFramebuffers() else { return false }
    load(for: &displayProgram, vsh: vsh, fsh: fsh)
    return true
  }
  
  override open func layoutSubviews() {
    super.layoutSubviews()
    threadsafeSize = bounds.size
  }
  
  private func createCache() -> Bool {
    let err = CVOpenGLESTextureCacheCreate(kCFAllocatorDefault,
                                           nil,
                                           glContext,
                                           nil,
                                           &textureCache)
    return err != kCVReturnError
  }
  
  @discardableResult
  private func createFramebuffers() -> Bool {
    glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
    glDisable(GLenum(GL_DEPTH_TEST))
    
    // Onscreen framebuffer object
    glGenFramebuffers(1, &viewFramebuffer)
    glBindFramebuffer(GLenum(GL_FRAMEBUFFER), viewFramebuffer)
    
    glGenRenderbuffers(1, &viewRenderbuffer)
    glBindRenderbuffer(GLenum(GL_RENDERBUFFER), viewRenderbuffer)
    
    glContext.renderbufferStorage(Int(GL_RENDERBUFFER), from: layer as! CAEAGLLayer)
    
    glGetRenderbufferParameteriv(GLenum(GL_RENDERBUFFER), GLenum(GL_RENDERBUFFER_WIDTH), &backingWidth)
    glGetRenderbufferParameteriv(GLenum(GL_RENDERBUFFER), GLenum(GL_RENDERBUFFER_HEIGHT), &backingHeight)
    
    glFramebufferRenderbuffer(GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0), GLenum(GL_RENDERBUFFER), viewRenderbuffer)
    
    if glCheckFramebufferStatus(GLenum(GL_FRAMEBUFFER)) != GL_FRAMEBUFFER_COMPLETE {
      print("failure with framebuffer generation")
      return false
    }
    
    // Offscreen position framebuffer object
    glGenFramebuffers(1, &positionFramebuffer)
    guard positionFramebuffer != 0 else { return false }
    glBindFramebuffer(GLenum(GL_FRAMEBUFFER), positionFramebuffer)
    
    glGenRenderbuffers(1, &positionRenderbuffer)
    guard positionRenderbuffer != 0 else { return false }
    glBindRenderbuffer(GLenum(GL_RENDERBUFFER), positionRenderbuffer)
    
    glRenderbufferStorage(GLenum(GL_RENDERBUFFER), GLenum(GL_RGBA8_OES), GLsizei(self.frame.size.width), GLsizei(self.frame.size.height))
    glFramebufferRenderbuffer(GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0), GLenum(GL_RENDERBUFFER), positionRenderbuffer)
    
    // Offscreen position framebuffer texture target
    glGenTextures(1, &positionRenderTexture)
    guard positionRenderTexture != 0 else { return false }
    glBindTexture(GLenum(GL_TEXTURE_2D), positionRenderTexture)
    glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MIN_FILTER), GL_NEAREST)
    glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MAG_FILTER), GL_NEAREST)
    glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_S), GL_CLAMP_TO_EDGE)
    glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_T), GL_CLAMP_TO_EDGE)
    glHint(GLenum(GL_GENERATE_MIPMAP_HINT), GLenum(GL_NICEST))
    
    glTexImage2D(GLenum(GL_TEXTURE_2D), 0, GL_RGBA, GLsizei(bounds.size.width), GLsizei(bounds.size.height), 0, GLenum(GL_RGBA), GLenum(GL_UNSIGNED_BYTE), nil)
    
    glFramebufferTexture2D(GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0), GLenum(GL_TEXTURE_2D), positionRenderTexture, 0)
    
    return true
  }
  
  private func destroyFramebuffer() {
    glContext.use()
    if viewFramebuffer != 0 {
      glDeleteFramebuffers(1, &viewFramebuffer)
      viewFramebuffer = 0
    }
    if viewRenderbuffer != 0 {
      glDeleteRenderbuffers(1, &viewRenderbuffer)
      viewRenderbuffer = 0
    }
  }
  
  @discardableResult
  private func load(for programPointer: UnsafeMutablePointer<GLuint>, vsh: String, fsh: String) -> Bool {
    var vertexShader: GLuint = 0
    var fragShader: GLuint = 0
    
    // Create shader program.
    programPointer.pointee = glCreateProgram()
    
    // Create and compile vertex shader.
    if !GLESHelper.compileShader(&vertexShader, type:GLenum(GL_VERTEX_SHADER), shaderString:vsh) {
      print("failed to compile vertex shader")
      return false
    }
    
    // Create and compile fragment shader.
    if !GLESHelper.compileShader(&fragShader, type:GLenum(GL_FRAGMENT_SHADER), shaderString:fsh) {
      print("failed to compile fragment shader")
      return false
    }
    
    // Attach vertex shader to program.
    glAttachShader(programPointer.pointee, vertexShader)
    
    // Attach fragment shader to program.
    glAttachShader(programPointer.pointee, fragShader)
    
    // Bind attribute locations.
    // This needs to be done prior to linking.
    glBindAttribLocation(programPointer.pointee, ATTRIB.VERTEX.rawValue, "position")
    glBindAttribLocation(programPointer.pointee, ATTRIB.TEXTUREPOSITON.rawValue, "inputTextureCoordinate")
    
    // Link program.
    if !GLESHelper.linkProgram(programPointer.pointee) {
      print("failed to link program: \(programPointer.pointee)")
      
      if vertexShader != 0 {
        glDeleteShader(vertexShader)
        vertexShader = 0
      }
      if fragShader != 0 {
        glDeleteShader(fragShader)
        fragShader = 0
      }
      if programPointer.pointee != 0 {
        glDeleteProgram(programPointer.pointee)
        programPointer.pointee = 0
      }
      
      return false
    }
    
    // Get uniform locations.
    uniformLocation = glGetUniformLocation(programPointer.pointee, "videoFrame2")
    
    // Release vertex and fragment shaders.
    if vertexShader != 0 {
      glDeleteShader(vertexShader)
    }
    if fragShader != 0 {
      glDeleteShader(fragShader)
    }
    
    return true
  }
  
  func didOutputFrame(_ basePixelBuffer: CVPixelBuffer, alphaPixelBuffer: CVPixelBuffer) -> Bool {
    return drawImage(with: basePixelBuffer, alphaPixelBuffer: alphaPixelBuffer)
  }
  
  func didReceiveError(_ error: Swift.Error?) {
    clear()
  }
  
  func didCompleted() {
    clear()
  }
  
  private func clear() {
    glClearColor(0, 0, 0, 0)
    glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
    glBindRenderbuffer(GLenum(GL_RENDERBUFFER), viewRenderbuffer)
    glContext.presentRenderbuffer(Int(GL_RENDERBUFFER))
  }
  
  @discardableResult
  private func drawImage(with basePixelBuffer: CVPixelBuffer, alphaPixelBuffer: CVPixelBuffer) -> Bool {
    guard applicationHandler.isActive else { return false }
    let width = CVPixelBufferGetWidth(basePixelBuffer)
    let height = CVPixelBufferGetHeight(basePixelBuffer)
    let extent = CGRect(x: 0, y: 0, width: width, height: height)
    
    // main //
    var baseTexture: CVOpenGLESTexture? = nil
    var baseTextureName: GLuint = GLuint()
    guard GLESHelper.setupOriginTexture(with: basePixelBuffer,
                                        texture: &baseTexture,
                                        textureCahce: textureCache!,
                                        textureOriginInput: &baseTextureName,
                                        width: GLsizei(width),
                                        height: GLsizei(height)) else { return false }
    
    // alpha //
    var alphaTexture: CVOpenGLESTexture? = nil
    var alphaTextureName: GLuint = GLuint()
    guard GLESHelper.setupOriginTexture(with: alphaPixelBuffer,
                                        texture: &alphaTexture,
                                        textureCahce: textureCache!,
                                        textureOriginInput: &alphaTextureName,
                                        width: GLsizei(width),
                                        height: GLsizei(height)) else { return false }
    
    // render //
    drawFrame(with: baseTextureName, alphaTexture: alphaTextureName, edge: fillEdge(from: extent))

    CVOpenGLESTextureCacheFlush(textureCache!, 0)
    return true
  }
  
  @discardableResult
  private func drawFrame(with texture: GLuint, alphaTexture: GLuint, edge: UIEdgeInsets) -> Bool {
    guard glContext.use() else { return false }
    
    let squareVertices: [GLfloat] = [
      -1.0 - GLfloat(edge.left), -1.0 - GLfloat(edge.bottom),
      1.0 + GLfloat(edge.right), -1.0 - GLfloat(edge.bottom),
      -1.0 - GLfloat(edge.left),  1.0 + GLfloat(edge.top),
      1.0 + GLfloat(edge.right),  1.0 + GLfloat(edge.top),
    ]
    
    let textureVertices: [GLfloat] = [
      0.0, 1.0,
      1.0, 1.0,
      0.0,  0.0,
      1.0,  0.0,
    ]
    
    // Use shader program.
    if viewFramebuffer == 0 {
      createFramebuffers()
    }
    
    glBindFramebuffer(GLenum(GL_FRAMEBUFFER), viewFramebuffer)
    
    glViewport(0, 0, backingWidth, backingHeight)
    glUseProgram(displayProgram)
    
    glActiveTexture(GLenum(GL_TEXTURE0))
    glBindTexture(GLenum(GL_TEXTURE_2D), texture)
    
    glActiveTexture(GLenum(GL_TEXTURE1))
    glBindTexture(GLenum(GL_TEXTURE_2D), alphaTexture);
    
    // Update uniform values
    glUniform1i(uniformLocation, 1)
    
    // Update attribute values.
    glVertexAttribPointer(ATTRIB.VERTEX.rawValue, 2, GLenum(GL_FLOAT), 0, 0, squareVertices)
    glEnableVertexAttribArray(ATTRIB.VERTEX.rawValue)
    glVertexAttribPointer(ATTRIB.TEXTUREPOSITON.rawValue, 2, GLenum(GL_FLOAT), 0, 0, textureVertices)
    glEnableVertexAttribArray(ATTRIB.TEXTUREPOSITON.rawValue)
    
    glDrawArrays(GLenum(GL_TRIANGLE_STRIP), 0, 4)
    
    glBindRenderbuffer(GLenum(GL_RENDERBUFFER), viewRenderbuffer)
    return glContext.presentRenderbuffer(Int(GL_RENDERBUFFER))
  }

  private func fillEdge(from extent: CGRect) -> UIEdgeInsets {
    let imageRatio = extent.width / extent.height
    let viewRatio = threadsafeSize.width / threadsafeSize.height
    if viewRatio < imageRatio { // viewの方が細長い //横がはみ出るパターン //iPhoneX
      let imageWidth = threadsafeSize.height * imageRatio
      let left = ((imageWidth / threadsafeSize.width) - 1.0) / 2.0
      return UIEdgeInsets(top: 0, left: left, bottom: 0, right: left)
    } else if viewRatio > imageRatio { //iPad
      let viewWidth = extent.height * viewRatio
      let top = ((viewWidth / extent.width) - 1.0) / 2.0
      return UIEdgeInsets(top: top, left: 0, bottom: top, right: 0)
    } else {
      return UIEdgeInsets.zero
    }
  }
  
  internal func didUpdateFrame(_ index: Int, engine: KBVideoEngine) {
    delegate?.didUpdateFrame(index, animationView: self)
  }
  
  internal func engineDidFinishPlaying(_ engine: KBVideoEngine) {
    delegate?.animationViewDidFinish(self)
  }
}

extension KBAnimationView: KBApplicationHandlerDelegate {
  func didBecomeActive(_ notification: Notification) {
    engineInstance?.resume()
  }
  func willResignActive(_ notification: Notification) {
    engineInstance?.pause()
  }
}
