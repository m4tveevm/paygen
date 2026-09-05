# frozen_string_literal: true

module Paygen
  module Core
    # Reviewable, deterministic guidance. Candidates are never applied as facts.
    class Onboarding
      QUESTIONS = {
        'operations' => 'Which methods send money, read its state, cancel it and receive callbacks? Confirm direction and production/sandbox purpose in the provider documentation.',
        'request_mapping' => 'Map your operation fields to the provider request. Confirm recipient identifiers, account context and required fields.',
        'response' => 'Which response fields identify the transfer and its individual settlement state? A batch acceptance is not item settlement.',
        'status_mapping' => 'Which documented states mean pending, settled, rejected or returned? Unknown states must remain unknown.',
        'amount' => 'Confirm amount units, decimal scale, currencies and documented limits. Do not infer units from the field name.',
        'idempotency' => 'Confirm the supported key location, retention window and reconciliation procedure after timeout.',
        'auth' => 'Confirm credential names, scopes and the authentication needed for each selected operation.',
        'callback' => 'Confirm raw-byte signature rules, event identity, account binding and ordering; configure verification before trusting callbacks.'
      }.freeze

      def initialize(ir)
        @ir = ir
      end

      def report
        {
          'ready' => @ir.diagnostics.none? { |item| item['severity'] == 'blocker' },
          'profile' => @ir.profile,
          'candidates' => @ir.candidates,
          'questions' => QUESTIONS.map do |key, prompt|
            origins = @ir.provenance.select { |path, _| path == key || path.start_with?(key + '.') }.values.map { |fact| fact['origin'] }.uniq
            { 'path' => key, 'question' => prompt, 'configured' => @ir.profile.key?(key),
              'origins' => origins, 'review_required' => !origins.empty? && origins.all? { |origin| origin == 'inference' } }
          end,
          'selected_parameters' => @ir.config.fetch('endpoints').transform_values { |op| op.fetch('parameters', []) },
          'diagnostics' => @ir.diagnostics,
          'next_steps' => [
            'Review candidates against official business documentation; operation names alone are insufficient.',
            'Write a YAML/JSON profile with confirmed answers and apply it using paygen configure PROJECT --answers FILE.',
            'Use paygen configure PROJECT --set operations.create=OPERATION_ID for small edits.',
            'Run paygen generate PROJECT, then verify independently chosen request/response fixtures.'
          ]
        }
      end
    end
  end
end
