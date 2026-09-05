# frozen_string_literal: true

# Explicit local contract for generated code; production BaseService is owned by
# its backend and can override the documented adapter hooks in extensions.
module Provider
  class BaseService
    def initialize(**configuration)
      configure_paygen(**configuration)
    end

    def check_conditions(_operation, _request_method)
      { 'success' => true, 'status' => 'valid' }
    end
  end
end
