#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint flutter_uwb.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'flutter_uwb'
  s.version          = '1.0.0'
  s.summary          = 'BLE OOB + UWB ranging for Flutter (Android Jetpack UWB, iOS Nearby Interaction).'
  s.description      = <<-DESC
A Flutter plugin for Ultra-Wideband (UWB) precise ranging. Same-OS pairs
(iPhone↔iPhone, Android↔Android) use a BLE GATT (Android) or
MultipeerConnectivity (iOS) sidechannel for out-of-band discovery and
token exchange. UWB ranging itself runs on Jetpack UWB on Android and
NearbyInteraction (NISession) on iOS. iOS additionally supports the
Apple NI Accessory Protocol for Qorvo / NXP / MFi UWB tags.
                       DESC
  s.homepage         = 'https://github.com/AhmedJHamdan/flutter_uwb'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Ahmed Hamdan' => 'contact@ahmedhamdan.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.resource_bundles = {'flutter_uwb_privacy' => ['Resources/PrivacyInfo.xcprivacy']}
  s.dependency 'Flutter'
  s.platform         = :ios, '16.0'
  s.frameworks       = 'NearbyInteraction', 'CoreBluetooth', 'MultipeerConnectivity', 'ARKit'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
  }
  s.swift_version    = '5.0'
end
