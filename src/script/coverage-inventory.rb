# frozen_string_literal: true
# Sources: fixtures/corpus/{manifest,report}.json and bundled executable profiles.
require 'digest'
require 'json'
require 'open3'

root = File.expand_path('../..', __dir__)
manifest = JSON.parse(File.read(File.join(root, 'fixtures/corpus/manifest.json')))
report = JSON.parse(File.read(File.join(root, 'fixtures/corpus/report.json')))
sources = manifest.fetch('sources')
results = report.fetch('results')
raise 'Corpus provider inventory differs' unless sources.map { |s| s.fetch('provider') }.sort == results.map { |r| r.fetch('provider') }.sort
raise 'Duplicate corpus providers' unless sources.map { |s| s.fetch('provider') }.uniq.length == sources.length
sources.each do |source|
  result = results.find { |row| row['provider'] == source['provider'] }
  raise "Corpus input identity mismatch: #{source['provider']}" unless %w[sha256 bytes source_url].all? { |key| source[key] == result[key] }
end
profiles = {
  'novapay' => 'fixtures/novapay/integration.yml', 'stripe' => 'fixtures/stripe/integration.yml',
  'adyen' => 'fixtures/adyen/integration.yml', 'paypal' => 'fixtures/paypal/integration.yml',
  'native-paystack' => 'fixtures/native-paystack/profile.yml', 'native-paypal' => 'fixtures/native-paypal/profile.yml',
  'raiffeisen_payouts' => 'fixtures/raiffeisen_payouts/integration.yml'
}
raise 'Missing profile' unless profiles.values.all? { |path| File.file?(File.join(root, path)) }
files, status = Open3.capture2('git', 'ls-files', '-z', chdir: root)
raise 'Cannot enumerate tracked code' unless status.success?
languages = Hash.new { |hash, key| hash[key] = { 'files' => 0, 'lines' => 0 } }
files.split("\0").each do |name|
  language = { '.rb' => 'Ruby', '.cjs' => 'JavaScript', '.js' => 'JavaScript', '.py' => 'Python', '.sh' => 'Shell', '.html' => 'HTML' }[File.extname(name)]
  body = File.binread(File.join(root, name))
  language ||= 'Shell' if body.start_with?('#!/usr/bin/env bash', '#!/bin/bash')
  language ||= 'Ruby' if body.start_with?('#!/usr/bin/env ruby')
  next unless language
  languages[language]['files'] += 1
  languages[language]['lines'] += body.lines.length
end
original = Digest::SHA256.file(File.join(root, 'fixtures/novapay/openapi.yaml')).hexdigest
raise 'NovaPay original changed' unless original == '415f50ee36fb331dfab49ceed0e8ed3b0ebe16053d7e00dbabd32282f4396551'
puts JSON.pretty_generate(
  'success' => true, 'corpus_brands' => sources.length,
  'recorded_import_passes' => results.count { |row| row['import'] == 'pass' },
  'import_evidence' => 'Recount of pinned historical report; not a fresh import or provider sandbox execution.',
  'executable_profiles' => profiles, 'executable_profile_count' => profiles.length,
  'profile_evidence' => 'Inventory only; run verify-fixtures and smoke for current execution evidence.',
  'novapay_original_sha256' => original, 'tracked_source_lines' => languages.sort.to_h,
  'line_count_scope' => 'Tracked programming files including comments and tests; excludes JSON/YAML contracts, Markdown, dependencies and generated outputs.'
)
