# frozen_string_literal: true
# Sources: provider_api.yaml (organizer-supplied NovaPay); local declared host contract.
require 'digest'
require 'fileutils'
require 'json'
require 'openssl'
require 'tmpdir'
require 'uri'
require_relative '../lib/paygen'
require_relative '../lib/paygen/runtime/adapter'
require_relative '../lib/paygen/runtime/reference_provider'

# This is a small executable host contract, not the organizer's private backend.
module PaygenHostExample
  Operation = Struct.new(:id, :amount, :currency, :payout_requisite, :provider_operation_id, :state, keyword_init: true)

  class Backend
    attr_reader :operations, :effects, :prechecks
    attr_accessor :fail_next, :raise_next

    def initialize
      @operations, @effects, @prechecks = {}, [], []
    end

    def apply(id, state)
      if @raise_next
        @raise_next = false
        raise IOError, 'Synthetic host storage unavailable before mutation'
      end
      if @fail_next
        @fail_next = false
        return { 'success' => false, 'error' => { 'code' => 'backend_busy' } }
      end
      operation = operations.fetch(id)
      operation.state = state
      effects << [id, state]
      { 'success' => true }
    end
  end

  class BaseService
    attr_reader :backend

    def initialize(backend:, **settings)
      @backend = backend
      configure_paygen(**settings)
    end

    def check_conditions(operation, action)
      backend.prechecks << [operation.id, action]
      return { 'success' => false, 'error' => { 'code' => 'host_refused' } } if operation.id == 'host-denied'
      { 'success' => true }
    end

    private

    def approve_operation(id) = backend.apply(id, 'approved')
    def reject_operation(id, _reason) = backend.apply(id, 'rejected')
  end

  module CallbackBridge
    def paygen_callback_result(result, payload)
      paygen_backend_callback_result(result, payload)
    end
  end

  # Independently specified wire expectations, not derived from generated fixtures/config.
  class ContractTransport
    attr_reader :requests

    def initialize
      @requests, @records = [], {}
    end

    def request(method:, url:, headers:, body:)
      raise 'Wrong credential header' unless headers['X-API-Key'] == 'synthetic-host-key'
      path = URI(url).path
      if method == 'POST' && path == '/v1/payouts'
        raise 'Wrong media type' unless headers['Content-Type'] == 'application/json'
        wire = JSON.parse(body)
        expected = { 'amount' => 150000, 'currency' => 'RUB', 'external_id' => wire['external_id'],
                     'recipient' => { 'type' => 'sbp', 'phone' => '79990000001', 'bank_code' => '000000000' } }
        raise 'Unexpected payout wire payload' unless wire == expected
        raise 'Missing idempotency key' if headers['Idempotency-Key'].to_s.empty?
        id = "local-#{@records.size + 1}"
        @records[id] = { 'id' => id, 'external_id' => wire.fetch('external_id'), 'amount' => 150000,
                         'currency' => 'RUB', 'status' => 'pending', 'created_at' => '2026-09-06T00:00:00Z' }
        response = @records.fetch(id)
        status = 201
      elsif method == 'GET' && path.start_with?('/v1/payouts/')
        raise 'GET has a body' unless body.nil?
        response = @records.fetch(path.split('/').last).merge('status' => 'processing')
        status = 200
      else
        raise "Unexpected request #{method} #{path}"
      end
      requests << { 'method' => method, 'path' => path }
      { status: status, headers: { 'Content-Type' => 'application/json' }, body: JSON.generate(response) }
    end
  end

  def self.operation(id)
    Operation.new(id: id, amount: '1500.00', currency: 'RUB', state: 'new',
                  payout_requisite: { 'sbp' => { 'phone' => '79990000001', 'bank_code' => '000000000' } })
  end

  def self.deliver(service, id:, reference:, status:, invalid: false)
    payload = { 'event' => "payout.#{status}", 'payout_id' => id, 'external_id' => reference, 'status' => status }
    # Deliberate whitespace: HMAC must authenticate these exact bytes.
    raw = JSON.pretty_generate(payload) + "\n"
    signature = OpenSSL::HMAC.hexdigest('SHA256', invalid ? 'wrong-test-secret' : 'synthetic-host-secret', raw)
    service.process_callback(payload, raw_body: raw, headers: { 'X-NovaPay-Signature' => signature })
  end

  def self.run(output)
    raise 'Output directory must be new' if File.exist?(output)
    FileUtils.mkdir_p(output)
    root = File.expand_path('../..', __dir__)
    answers = Paygen::Core::Input.read(File.join(root, 'fixtures/novapay/integration.yml'))
    answers['action_mapping'] = { 'sbp' => 'create', 'check' => 'status' }
    profile = File.join(output, 'host-profile.yml')
    File.write(profile, YAML.dump(answers))
    project = Paygen::Project.init(File.join(root, 'fixtures/novapay/openapi.yaml'), output: File.join(output, 'project'), profile: profile)
    Paygen::Generator.new(project).generate
    backend, transport = Backend.new, ContractTransport.new
    service_class = Paygen::Runtime::ReferenceProvider.load_service(source: File.read(project.path('generated/novapay_service.rb')),
                                                                  class_name: 'NovaPayService', base_service: BaseService)
    service_class.prepend(CallbackBridge)
    service = service_class.new(backend: backend, transport: transport,
                                credentials: { api_key: 'synthetic-host-key', callback_secret: 'synthetic-host-secret' })
    checks = []
    check = lambda do |condition, name|
      raise "Host contract failed: #{name}" unless condition
      checks << name
    end
    check.call(service.class.superclass == BaseService, 'generated subclass loads against declared host')
    check.call(service.create_request(operation('host-denied'), 'sbp').dig('error', 'code') == 'host_refused', 'superclass can refuse before HTTP')
    tiny = operation('too-small'); tiny.amount = '1.00'
    check.call(service.create_request(tiny, 'sbp').dig('error', 'code') == 'validation_error', 'alias cannot bypass amount prechecks')
    check.call(service.create_request(operation('unknown'), 'POST').dig('error', 'code') == 'operation_not_supported', 'unknown logical action rejected')
    check.call(transport.requests.empty?, 'precheck refusals make zero transport calls')
    op = operation('host-approved')
    created = service.create_request(op, 'sbp')
    check.call(created['success'] && created['status'] == 'in_progress', 'object operation creates expected independent wire payload')
    op.provider_operation_id = created.fetch('provider_id')
    backend.operations[op.provider_operation_id] = op
    check.call(backend.prechecks.include?([op.id, 'sbp']), 'base precheck sees declared external logical action')
    check.call(service.create_request(op, 'create')['provider_id'] == op.provider_operation_id, 'alias and canonical create share idempotency state')
    check.call(transport.requests.size == 1, 'retry produces no second provider create')
    denied_status = operation('host-denied')
    denied_status.provider_operation_id = op.provider_operation_id
    check.call(service.create_request(denied_status, 'check').dig('error', 'code') == 'host_refused', 'status alias honors superclass refusal')
    check.call(transport.requests.size == 1, 'status precheck refusal makes no transport call')
    check.call(service.fetch_status(op)['status'] == 'in_progress', 'fetch_status accepts application object')
    check.call(service.create_request(op, 'check')['status'] == 'in_progress', 'logical status alias uses the status endpoint')
    progress = deliver(service, id: op.provider_operation_id, reference: op.id, status: 'processing')
    check.call(progress['status'] == 'in_progress' && backend.effects.empty?, 'progress callback does not approve backend')
    invalid = deliver(service, id: op.provider_operation_id, reference: op.id, status: 'completed', invalid: true)
    check.call(invalid.dig('error', 'code') == 'invalid_signature' && backend.effects.empty?, 'invalid signature makes no backend mutation')
    backend.fail_next = true
    failed = deliver(service, id: op.provider_operation_id, reference: op.id, status: 'completed')
    check.call(failed.dig('error', 'code') == 'backend_busy' && op.state == 'new', 'backend refusal does not consume callback')
    approved = deliver(service, id: op.provider_operation_id, reference: op.id, status: 'completed')
    check.call(approved['backend_applied'] && op.state == 'approved', 'same signed callback retries backend mutation')
    duplicate = deliver(service, id: op.provider_operation_id, reference: op.id, status: 'completed')
    check.call(duplicate['ignored'] == 'duplicate' && backend.effects.size == 1, 'duplicate does not repeat completed effect')
    late = deliver(service, id: op.provider_operation_id, reference: op.id, status: 'processing')
    check.call(late['ignored'] && op.state == 'approved', 'late progress cannot regress backend')
    rejected_op = operation('host-rejected')
    rejected_op.provider_operation_id = service.create_request(rejected_op, 'sbp').fetch('provider_id')
    backend.operations[rejected_op.provider_operation_id] = rejected_op
    backend.raise_next = true
    begin
      deliver(service, id: rejected_op.provider_operation_id, reference: rejected_op.id, status: 'failed')
      raise 'Expected host storage failure'
    rescue IOError
      check.call(rejected_op.state == 'new' && backend.effects.size == 1, 'backend exception leaves callback effect uncommitted')
    end
    rejected = deliver(service, id: rejected_op.provider_operation_id, reference: rejected_op.id, status: 'failed')
    check.call(rejected['backend_applied'] && rejected_op.state == 'rejected', 'signed failed callback invokes host reject')
    check.call(deliver(service, id: rejected_op.provider_operation_id, reference: rejected_op.id, status: 'failed')['ignored'] == 'duplicate', 'failed callback duplicate is deduplicated')
    report = { 'success' => true, 'passed' => checks.length, 'failed' => 0, 'skipped' => 0, 'checks' => checks,
               'transport_requests' => transport.requests, 'backend_effects' => backend.effects,
               'scope' => 'Independent synthetic wire assertions and in-memory host; no network, database or distributed exactly-once claim.' }
    File.write(File.join(output, 'report.json'), JSON.pretty_generate(report) + "\n")
    report
  end
end

if $PROGRAM_NAME == __FILE__
  puts JSON.pretty_generate(PaygenHostExample.run(File.expand_path(ARGV.fetch(0))))
end
