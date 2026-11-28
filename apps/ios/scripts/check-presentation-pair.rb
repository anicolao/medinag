#!/usr/bin/env ruby
# Read-only contract check for the A/B experiment; not a delivery test.
require 'yaml'
require 'json'
require 'open3'

root = File.expand_path('..', __dir__)
spec = File.join(root, 'project.yml')
# This trusted repository spec intentionally uses YAML aliases. Psych 4+
# disables aliases in load_file by default; older system Ruby uses Psych 3.
project = YAML.respond_to?(:unsafe_load_file) ? YAML.unsafe_load_file(spec) : YAML.load_file(spec)
a = project.fetch('targets').fetch('MediNagAlarmReliability')
b = project.fetch('targets').fetch('MediNagAlarmPresentation')
widget = { 'target' => 'MediNagAlarmPrototypeLiveActivity', 'embed' => true }
raise 'B must add exactly the matching widget' unless b.fetch('dependencies') == [widget] + a.fetch('dependencies')

normalize = lambda do |target|
  copy = Marshal.load(Marshal.dump(target))
  copy.fetch('settings').fetch('base').delete('INFOPLIST_FILE')
  copy.delete('dependencies')
  copy
end
raise 'A/B differ beyond widget packaging' unless normalize.call(a) == normalize.call(b)

read_plist = lambda do |target|
  path = File.join(root, target.fetch('settings').fetch('base').fetch('INFOPLIST_FILE'))
  json, status = Open3.capture2('plutil', '-convert', 'json', '-o', '-', path)
  raise "Invalid plist: #{path}" unless status.success?
  JSON.parse(json)
end
pa, pb = read_plist.call(a), read_plist.call(b)
raise 'A must not declare Live Activities' if pa.key?('NSSupportsLiveActivities')
raise 'B must declare Live Activities' unless pb.delete('NSSupportsLiveActivities') == true
raise 'A/B plist differs beyond Live Activities' unless pa == pb
puts 'Presentation A/B contract passed: same sources, configuration and dependencies except widget packaging.'
