Pod::Spec.new do |s|
  s.name             = 'et_plate_reader'
  s.version          = '0.1.0'
  s.summary          = 'Ethiopian licence plate reader (camera + on-device OCR).'
  s.description      = 'AVFoundation preview and Vision text recognition for et_plate_reader.'
  s.homepage         = 'https://github.com/seyoumt/et_plate_reader'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'et_plate_reader' => 'nebiat1921@gmail.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform         = :ios, '15.0'
  s.frameworks       = 'AVFoundation', 'Vision'
  s.resource_bundles = { 'et_plate_reader_privacy' => ['Resources/PrivacyInfo.xcprivacy'] }

  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'
end
