require "json"

package = JSON.parse(File.read(File.join(__dir__, "package.json")))
required_models = %w[YOLO26n.mlpackage YOLO26nDepth.mlpackage]
missing_models = required_models.reject { |name| File.directory?(File.join(__dir__, "models", name)) }
unless missing_models.empty?
  raise Pod::Informative, "Missing required Clear Ahead Core ML packages: #{missing_models.join(', ')}. Run `python3 -m pip install -r scripts/model-requirements.txt && npm run models` from the repository root before installing pods."
end

Pod::Spec.new do |s|
  s.name         = "ClearAheadVision"
  s.version      = package["version"]
  s.summary      = package["description"]
  s.homepage     = package["homepage"]
  s.license      = package["license"]
  s.authors      = package["author"]

  s.platforms    = { :ios => min_ios_version_supported, :visionos => 1.0 }
  s.source       = { :git => "https://github.com/jiayangc1/cac.git", :tag => "#{s.version}" }

  s.source_files = [
    # Implementation (Swift)
    "ios/**/*.{swift}",
    # Autolinking/Registration (Objective-C++)
    "ios/**/*.{m,mm}",
    # Implementation (C++ objects)
    "cpp/**/*.{hpp,cpp}",
  ]
  s.exclude_files = ["ios/Tests/**/*"]

  s.frameworks = ["AVFoundation", "Accelerate", "CoreHaptics", "CoreML", "CoreMotion", "Vision"]
  s.resources = ["models/*.mlmodel", "models/*.mlpackage"]

  load 'nitrogen/generated/ios/ClearAheadVision+autolinking.rb'
  add_nitrogen_files(s)

  s.dependency 'React-jsi'
  s.dependency 'React-callinvoker'
  s.dependency 'VisionCamera'
  install_modules_dependencies(s)

  s.test_spec 'Tests' do |test_spec|
    test_spec.source_files = 'ios/Tests/**/*.swift'
  end
end
