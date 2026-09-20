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

  # Keep this list explicit so source moves change the podspec checksum and are
  # reflected when CocoaPods regenerates the Pods project.
  s.source_files = [
    "ios/ClearAheadEngine.swift",
    "ios/Entry/Module.swift",
    "ios/Entry/ModuleBridge.m",
    "ios/Entry/ModuleEntry.swift",
    "ios/Feedback/Feedback.swift",
    "ios/ModelOutput.swift",
    "ios/Risk/CollisionTracker.swift",
    "ios/Risk/EventPrioritizer.swift",
    "ios/Types.swift",
    "cpp/**/*.{hpp,cpp}",
  ]

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
