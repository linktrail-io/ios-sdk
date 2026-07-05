Pod::Spec.new do |s|
  s.name        = 'LinkTrailSDK'
  s.version     = '0.0.7'
  s.summary     = 'Mobile attribution and deferred deep linking for iOS.'
  s.description = <<-DESC
    LinkTrail attributes app installs to the marketing links that drove them and
    routes users to the right in-app content — including deferred deep links,
    where the link was tapped before the app was installed. Distributed as a
    binary XCFramework; the module name is LinkTrailSDK and the API type is LinkTrail.
  DESC

  s.homepage = 'https://github.com/linktrail-io/ios-sdk'
  s.license  = { :type => 'Commercial', :file => 'LICENSE' }
  s.author   = 'LinkTrail'
  s.source   = { :git => 'https://github.com/linktrail-io/ios-sdk.git', :tag => s.version.to_s }

  s.platform              = :ios, '15.0'
  s.swift_version         = '5.9'
  s.vendored_frameworks   = 'LinkTrailSDK.xcframework'
end
