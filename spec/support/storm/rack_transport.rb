# frozen_string_literal: true

module Storm
  # A request through the whole middleware stack, on the calling thread.
  # Not wrapped in the executor: the ActionDispatch::Executor middleware
  # does that per request, and wrapping the thread would make its reset a
  # no-op — the very thing the in-process storm tests.
  RACK_TRANSPORT = lambda do |method, path, headers, body, ip|
    env = Rack::MockRequest.env_for(path, method: method.to_s.upcase, input: body.to_s,
                                          'CONTENT_TYPE' => 'application/json', 'REMOTE_ADDR' => ip)
    headers.each { |name, value| env["HTTP_#{name.upcase.tr('-', '_')}"] = value }
    status, _headers, response = Rails.application.call(env)
    chunks = +''
    response.each { |chunk| chunks << chunk }
    response.close if response.respond_to?(:close)
    [status, chunks]
  end
end
