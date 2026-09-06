# frozen_string_literal: true

# Deliberately faulty adapter, confined to this disposable subprocess. There is
# no production flag, generated-file edit, global prepend, or changed profile.
require 'paygen'
require 'paygen/runtime/reference_provider'
require 'paygen/runtime/state_fuzzer'
require_relative 'support'

module PaygenShowcase
  module Mutation
    def self.run(project_path, output)
      project = Paygen::Project.new(project_path)
      generator = Paygen::Generator.new(project)
      PaygenShowcase.assert(generator.diff.empty?, 'mutant input must be drift-clean')
      files = generator.render
      config = JSON.parse(files.fetch('config.json'))
      source = files.fetch("#{config.fetch('provider')}_service.rb")
      service = Paygen::Runtime::ReferenceProvider.load_service(source: source, class_name: config.fetch('class_name'))
      broken = service.new
      # One defect: forget the merchant-operation reservation, allowing another
      # actual POST. Provider deduplication is not promised by NovaPay's profile.
      broken.define_singleton_method(:reserve_create_request) { |_request, _operation, _role| nil }
      fuzzer = Paygen::Runtime::StateFuzzer.new(adapter: broken, seed: 4242)
      report = fuzzer.run(cases: 6, steps: 20)
      File.write(File.join(output, 'mutant-failure.json'), Paygen.json(report))
      PaygenShowcase.assert(report['success'] == false && report.dig('failure', 'invariant') == 'duplicate_payout', 'mutant was not detected')
      PaygenShowcase.assert(report.dig('shrunk_trace', 'steps').length < report.dig('trace', 'steps').length, 'trace was not reduced')
      # Read the persisted bytes, not a parallel handwritten trace.
      saved = JSON.parse(File.read(File.join(output, 'mutant-failure.json')))
      replay = fuzzer.replay(saved)
      File.write(File.join(output, 'mutant-replay.json'), Paygen.json(replay))
      PaygenShowcase.assert(replay['success'] == false && replay.dig('failure', 'committed_ids').length == 2, 'mutant replay did not reproduce two commits')
      File.write(File.join(output, 'mutant-trace.json'), Paygen.json(saved.fetch('shrunk_trace')))
      puts JSON.generate('success' => true, 'expected_failure_observed' => true,
                         'original_steps' => report.dig('trace', 'steps').length,
                         'shrunk_steps' => report.dig('shrunk_trace', 'steps').length,
                         'profile_sha256' => report.fetch('profile_sha256'))
    end
  end
end

PaygenShowcase::Mutation.run(*ARGV) if $PROGRAM_NAME == __FILE__
