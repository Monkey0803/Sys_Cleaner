#!/usr/bin/env ruby
# Regenerate the checked-in Xcode project after adding Swift source files.
require 'xcodeproj'

root = File.expand_path('..', __dir__)
project_path = File.join(root, 'SysCleaner.xcodeproj')
project = Xcodeproj::Project.new(project_path)
project.root_object.attributes['LastUpgradeCheck'] = '2700'

target = project.new_target(:application, 'Sys Cleaner', :osx, '14.0')
app_group = project.main_group.new_group('App', 'App')
core_group = project.main_group.new_group('SysCleanerCore', 'Sources/SysCleanerCore')

Dir.glob(File.join(root, 'App', '*.swift')).sort.each do |path|
  target.source_build_phase.add_file_reference(app_group.new_file(File.basename(path)))
end
Dir.glob(File.join(root, 'Sources/SysCleanerCore', '*.swift')).sort.each do |path|
  target.source_build_phase.add_file_reference(core_group.new_file(File.basename(path)))
end

strings = app_group.new_variant_group('Localizable.strings')
%w[en zh-Hans].each do |language|
  reference = strings.new_file("#{language}.lproj/Localizable.strings")
  reference.name = language
end
target.resources_build_phase.add_file_reference(strings)
target.resources_build_phase.add_file_reference(app_group.new_file('Assets.xcassets'))

target.build_configurations.each do |configuration|
  settings = configuration.build_settings
  settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'org.syscleaner.SysCleaner'
  settings['PRODUCT_NAME'] = 'Sys Cleaner'
  settings['MARKETING_VERSION'] = '1.0.0'
  settings['CURRENT_PROJECT_VERSION'] = '1'
  settings['SWIFT_VERSION'] = '5.0'
  settings['MACOSX_DEPLOYMENT_TARGET'] = '14.0'
  settings['GENERATE_INFOPLIST_FILE'] = 'YES'
  settings['INFOPLIST_KEY_CFBundleDisplayName'] = 'Sys Cleaner'
  settings['INFOPLIST_KEY_LSApplicationCategoryType'] = 'public.app-category.utilities'
  settings['INFOPLIST_KEY_NSDocumentsFolderUsageDescription'] = 'Scan files you choose for storage analysis and cleanup.'
  settings['INFOPLIST_KEY_NSDownloadsFolderUsageDescription'] = 'Scan files you choose for storage analysis and cleanup.'
  settings['INFOPLIST_KEY_NSDesktopFolderUsageDescription'] = 'Scan files you choose for storage analysis and cleanup.'
  settings['INFOPLIST_KEY_NSPrincipalClass'] = 'NSApplication'
  settings['INFOPLIST_KEY_CFBundleLocalizations'] = 'en zh-Hans'
  settings['ENABLE_HARDENED_RUNTIME'] = configuration.name == 'Release' ? 'YES' : 'NO'
  settings['CODE_SIGN_STYLE'] = 'Automatic'
  settings['CLANG_ENABLE_MODULES'] = 'YES'
end

project.save
puts "Generated #{project_path}"
