#!/usr/bin/env ruby
# Regenerate the checked-in Xcode project after adding Swift source files.
require 'xcodeproj'

root = File.expand_path('..', __dir__)
project_path = File.join(root, 'SysCleaner.xcodeproj')
project = File.exist?(project_path) ? Xcodeproj::Project.open(project_path) : Xcodeproj::Project.new(project_path)
project.root_object.attributes['LastUpgradeCheck'] = '2700'

target = project.targets.find { |candidate| candidate.name == 'Sys Cleaner' } ||
  project.new_target(:application, 'Sys Cleaner', :osx, '14.0')
app_group = project.main_group.children.find { |child| child.display_name == 'App' } ||
  project.main_group.new_group('App', 'App')
core_group = project.main_group.children.find { |child| child.display_name == 'SysCleanerCore' } ||
  project.main_group.new_group('SysCleanerCore', 'Sources/SysCleanerCore')

def add_source(target, group, filename)
  reference = group.files.find { |file| file.path == filename } || group.new_file(filename)
  target.source_build_phase.add_file_reference(reference) unless target.source_build_phase.files_references.include?(reference)
end

def add_resource(target, reference)
  target.resources_build_phase.add_file_reference(reference) unless target.resources_build_phase.files_references.include?(reference)
end

def add_strings(target, group, name)
  variant = group.children.find { |child| child.display_name == name } || group.new_variant_group(name)
  %w[en zh-Hans].each do |language|
    path = "#{language}.lproj/#{name}"
    unless variant.files.any? { |file| file.path == path }
      reference = variant.new_file(path)
      reference.name = language
    end
  end
  add_resource(target, variant)
end

Dir.glob(File.join(root, 'App', '*.swift')).sort.each do |path|
  add_source(target, app_group, File.basename(path))
end
Dir.glob(File.join(root, 'Sources/SysCleanerCore', '*.swift')).sort.each do |path|
  add_source(target, core_group, File.basename(path))
end

add_strings(target, app_group, 'Localizable.strings')
add_strings(target, app_group, 'ServicesMenu.strings')
assets = app_group.files.find { |file| file.path == 'Assets.xcassets' } || app_group.new_file('Assets.xcassets')
add_resource(target, assets)
app_group.new_file('Info.plist') unless app_group.files.any? { |file| file.path == 'Info.plist' }

target.build_configurations.each do |configuration|
  settings = configuration.build_settings
  settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'org.syscleaner.SysCleaner'
  settings['PRODUCT_NAME'] = 'Sys Cleaner'
  settings['MARKETING_VERSION'] = '1.0.0'
  settings['CURRENT_PROJECT_VERSION'] = '1'
  settings['SWIFT_VERSION'] = '5.0'
  settings['MACOSX_DEPLOYMENT_TARGET'] = '14.0'
  settings['GENERATE_INFOPLIST_FILE'] = 'NO'
  settings['INFOPLIST_FILE'] = 'App/Info.plist'
  settings['ENABLE_HARDENED_RUNTIME'] = configuration.name == 'Release' ? 'YES' : 'NO'
  settings['CODE_SIGN_STYLE'] = 'Automatic'
  settings['CLANG_ENABLE_MODULES'] = 'YES'
end

project.save
puts "Generated #{project_path}"
