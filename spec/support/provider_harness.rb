# frozen_string_literal: true

# Explicit local contract for generated code; production BaseService is owned by
# its backend and can override the documented adapter hooks in extensions.
module Provider
  class BaseService
    def initialize(**configuration)
      configure_paygen(**configuration)
    end
  end
end
