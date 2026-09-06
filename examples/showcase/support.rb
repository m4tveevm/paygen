# frozen_string_literal: true

# Presenter/test tooling only. None of these files are loaded by the product.
require 'json'
require 'net/http'
require 'socket'
require 'fileutils'
require 'rbconfig'
require 'time'

module PaygenShowcase
  class Failure < StandardError; end

  def self.assert(condition, message)
    raise Failure, message unless condition
  end

  class Client
    def initialize(port)
      @port = port
    end

    def request(method, path, payload: nil, raw: nil, headers: {})
      uri = URI("http://127.0.0.1:#{@port}#{path}")
      request = Net::HTTP.const_get(method.capitalize).new(uri)
      request['Content-Type'] = 'application/json' unless payload.nil? && raw.nil?
      headers.each { |key, value| request[key] = value }
      request.body = raw || JSON.generate(payload) unless payload.nil? && raw.nil?
      # Explicit nil proxy prevents ambient HTTP_PROXY from receiving test data.
      response = Net::HTTP.start(uri.host, uri.port, nil, nil, nil, nil,
                                open_timeout: 1, read_timeout: 2, write_timeout: 2) { |http| http.request(request) }
      { 'http_status' => response.code.to_i, 'body' => JSON.parse(response.body) }
    end
  end

  class Processes
    attr_reader :records

    def initialize
      @children = {}
      @records = []
    end

    def start(argv, log:, stderr: log)
      pid = Process.spawn(*argv, out: log, err: stderr == log ? [:child, :out] : stderr, pgroup: true)
      @children[pid] = true
      @records << { 'pid' => pid, 'argv' => argv, 'status' => 'RUNNING' }
      pid
    end

    def poll(pid)
      pair = Process.waitpid2(pid, Process::WNOHANG)
      return unless pair

      @children.delete(pid)
      record = @records.find { |item| item['pid'] == pid && item['status'] == 'RUNNING' }
      record.merge!('status' => 'EXITED', 'exit_code' => pair.last.exitstatus, 'signal' => pair.last.termsig)
      pair.last
    end

    def wait(pid, seconds: 60)
      deadline = monotonic + seconds
      loop do
        result = poll(pid)
        return result if result
        raise Failure, "owned subprocess #{pid} exceeded #{seconds}s" if monotonic >= deadline

        sleep 0.05
      end
    ensure
      stop(pid) if @children.key?(pid)
    end

    def stop(pid)
      return unless @children.key?(pid)
      return if poll(pid)

      # Only a process group created and still owned by this launcher is signaled.
      Process.kill('TERM', -pid)
      deadline = monotonic + 3
      until poll(pid)
        if monotonic >= deadline
          Process.kill('KILL', -pid)
          wait(pid, seconds: 2)
          break
        end
        sleep 0.05
      end
    rescue Errno::ESRCH
      poll(pid)
    end

    def stop_all
      @children.keys.each { |pid| stop(pid) }
    end

    private

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
