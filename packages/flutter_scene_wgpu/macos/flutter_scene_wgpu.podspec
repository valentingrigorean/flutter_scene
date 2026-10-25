Pod::Spec.new do |s|
  s.name             = 'flutter_scene_wgpu'
  s.version          = '0.0.1'
  s.summary          = 'Presents wgpu frames through a Flutter external texture.'
  s.description      = <<-DESC
Presents wgpu frames through a Flutter external texture.
                       DESC
  s.homepage         = 'https://fscene.dev'
  s.license          = { :type => 'BSD' }
  s.author           = { 'flutter_scene' => 'https://fscene.dev' }

  s.source           = { :path => '.' }
  s.source_files = 'flutter_scene_wgpu/Sources/flutter_scene_wgpu/**/*'

  s.dependency 'FlutterMacOS'

  s.platform = :osx, '12.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version = '5.0'
end
