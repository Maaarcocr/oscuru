Pod::Spec.new do |s|
  s.name           = 'OscuruEngine'
  s.version        = '0.1.0'
  s.summary        = 'RAW decoding and non-destructive rendering for Oscuru'
  s.description    = 'Decodes RAW and other photos with Core Image and renders an editing recipe to previews and exports.'
  s.license        = 'AGPL-3.0-only'
  s.author         = 'Oscuru'
  s.homepage       = 'https://github.com/Maaarcocr/oscuru'
  s.platforms      = { :ios => '16.4' }
  s.swift_version  = '5.9'
  s.source         = { git: 'https://github.com/Maaarcocr/oscuru.git' }
  s.static_framework = true

  s.dependency 'ExpoModulesCore'
  s.frameworks = 'CoreImage', 'ImageIO', 'PhotosUI', 'UniformTypeIdentifiers'

  s.source_files = '**/*.{h,m,swift}'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'SWIFT_COMPILATION_MODE' => 'wholemodule'
  }
end
