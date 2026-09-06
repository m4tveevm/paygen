# frozen_string_literal: true

# Disposable, loopback-only provider wire probe. /__evidence belongs only to
# this example process; it is not a new product endpoint or a validation bypass.
require 'paygen'
require 'paygen/runtime/simulator'
require 'puma'

config = Paygen::Project.new(ARGV.fetch(0)).ir.config
simulator = Paygen::Runtime::Simulator.new(config: config, strict_auth: true)
app = lambda do |env|
  if env['REQUEST_METHOD'] == 'GET' && env['PATH_INFO'] == '/__evidence'
    [200, { 'content-type' => 'application/json' }, [JSON.generate(simulator.evidence)]]
  else
    simulator.call(env)
  end
end
server = Puma::Server.new(app)
server.add_tcp_listener('127.0.0.1', Integer(ARGV.fetch(1)))
trap('INT') { server.stop }
trap('TERM') { server.stop }
server.run.join
