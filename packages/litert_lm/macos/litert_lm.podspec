Pod::Spec.new do |s|
  s.name             = 'litert_lm'
  s.version          = '0.0.1'
  s.summary          = 'Dart FFI-обёртка над C API LiteRT-LM.'
  s.homepage         = 'https://github.com/google-ai-edge/LiteRT-LM'
  s.license          = { :type => 'Apache-2.0' }
  s.author           = { 'znaika' => 'local' }
  s.source           = { :path => '.' }
  s.source_files     = 'litert_lm/Sources/litert_lm/**/*'
  s.vendored_frameworks = 'litert_lm/CLiteRTLM.xcframework'
  s.dependency 'FlutterMacOS'
  s.platform = :osx, '14.2'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version = '5.0'
end
