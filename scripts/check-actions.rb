# Checks what actionlint does not: the composite actions' own metadata, and
# the references the reusable workflows make to them.
require 'yaml'

errors = []
actions = Dir.glob('*/action.yml').sort
abort 'no actions found' if actions.empty?

actions.each do |file|
  text = File.read(file)
  action = YAML.safe_load(text, aliases: true)
  errors << "#{file}: needs a name and a description" unless action['name'] && action['description']
  runs = action['runs'] || {}
  errors << "#{file}: runs.using must be composite" unless runs['using'] == 'composite'

  inputs = action['inputs'] || {}
  inputs.each { |name, spec| errors << "#{file}: input #{name} has no description" unless spec.is_a?(Hash) && spec['description'] }
  text.scan(/inputs\.([A-Za-z0-9_-]+)/).flatten.uniq.each do |name|
    errors << "#{file}: uses input #{name}, which it does not declare" unless inputs.key?(name)
  end

  steps = runs['steps'] || []
  ids = steps.map { |step| step['id'] }.compact
  steps.each_with_index do |step, index|
    label = step['name'] || step['uses'] || "step #{index + 1}"
    errors << "#{file}: #{label} runs a script without a shell" if step['run'] && !step['shell']
    next unless step['uses']
    next if step['uses'].start_with?('./')
    errors << "#{file}: #{label} is not pinned to a full commit" unless step['uses'] =~ /@[0-9a-f]{40}\z/
  end
  pinned = text.scan(/uses: \S+@[0-9a-f]{40}(.*)$/).flatten
  errors << "#{file}: a pinned action lacks its version comment" if pinned.any? { |rest| rest !~ /# v\d/ }

  (action['outputs'] || {}).each do |name, spec|
    ref = spec['value'].to_s[/steps\.([A-Za-z0-9_-]+)\.outputs/, 1]
    errors << "#{file}: output #{name} reads step #{ref}, which does not exist" if ref && !ids.include?(ref)
  end
end

known = actions.map { |file| File.dirname(file) }
Dir.glob('.github/workflows/*.yaml').sort.each do |file|
  File.read(file).scan(%r{uses: roxiegrillo/workflows/([A-Za-z0-9_-]+)@(\S+)}).each do |name, ref|
    errors << "#{file}: uses roxiegrillo/workflows/#{name}, which is not an action here" unless known.include?(name)
    errors << "#{file}: uses roxiegrillo/workflows/#{name}@#{ref}; the workflows follow the major tag v1" unless ref == 'v1'
  end
end

if errors.empty?
  puts "#{actions.size} actions checked."
else
  warn errors.join("\n")
  exit 1
end
