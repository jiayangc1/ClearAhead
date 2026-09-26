require "json"

package = JSON.parse(File.read(File.join(__dir__, "package.json")))
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
    "ios/Models/ModelManager.swift",
    "ios/Risk/CollisionTracker.swift",
    "ios/Risk/EventPrioritizer.swift",
    "ios/Types.swift",
    "cpp/**/*.{hpp,cpp}",
  ]

  s.frameworks = ["AVFoundation", "Accelerate", "CoreHaptics", "CoreML", "CoreMotion", "CryptoKit", "UIKit", "Vision"]
  s.resources = ["models/YOLO26*.mlpackage"]

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
