# frozen_string_literal: true

require 'json'
require 'janeway'
require 'timeout'
require 'uri'

module Paygen
  module Core
    # Overlay 1.1 action semantics. JSONPath is delegated intact to Janeway's
    # RFC 9535 parser; selectors are never translated into Ruby expressions.
    class Overlay
      MAX_ACTIONS = 1_000
      MAX_SELECTOR = 8_192
      attr_reader :diagnostics

      def initialize(document = nil, source_uri: nil)
        @document = document
        @source_uri = source_uri
        @diagnostics = []
      end

      def apply(overlay, overlay_uri: nil)
        validate!(overlay)
        @diagnostics = []
        source = @document
        if overlay['extends']
          target_uri = resolve_uri(overlay['extends'], overlay_uri)
          if source.nil?
            source = Input.load(target_uri)
          elsif @source_uri && canonical_uri(@source_uri) != canonical_uri(target_uri)
            invalid('OVERLAY_EXTENDS', 'Overlay extends a different source document')
          elsif !@source_uri
            @diagnostics << diagnostic('OVERLAY_EXTENDS_UNVERIFIED', 'Target identity was not supplied for extends verification', '/extends')
          end
        end
        invalid('OVERLAY_SOURCE', 'An OpenAPI document or extends target is required') unless source.is_a?(Hash)
        # Each apply is transactional: even a later invalid action cannot modify
        # the caller's source or any node referenced from its overlay.
        result = copy(source)
        Timeout.timeout(10) do
          overlay.fetch('actions').each_with_index do |action, index|
            apply_action(result, action, index)
            Input.fail_security('OVERLAY_SIZE', 'Overlay output exceeds the document size limit') if JSON.generate(result).bytesize > Input::MAX_BYTES
          end
        end
        result
      rescue Timeout::Error
        Input.fail_security('OVERLAY_COMPLEXITY', 'Overlay execution exceeded the time limit')
      rescue Janeway::Error
        invalid('OVERLAY_JSONPATH', 'Invalid RFC 9535 JSONPath selector')
      end

      def validate!(overlay)
        invalid('OVERLAY_INVALID', 'Overlay must be an object') unless overlay.is_a?(Hash)
        unknown!(overlay, %w[overlay info extends actions], '')
        unless overlay['overlay'].is_a?(String) && overlay['overlay'].match?(/\A1\.1\.\d+\z/)
          invalid('OVERLAY_VERSION', 'Expected Overlay 1.1.x')
        end
        info = overlay['info']
        unless info.is_a?(Hash) && %w[title version].all? { |key| info[key].is_a?(String) }
          invalid('OVERLAY_INFO', 'Overlay info.title and info.version must be strings')
        end
        unknown!(info, %w[title version description], '/info')
        string_field!(info, 'description')
        string_field!(overlay, 'extends')
        actions = overlay['actions']
        invalid('OVERLAY_ACTIONS', 'Overlay requires a nonempty actions array') unless actions.is_a?(Array) && !actions.empty?
        Input.fail_security('OVERLAY_LIMIT', 'Too many overlay actions') if actions.length > MAX_ACTIONS
        actions.each do |action|
          invalid('OVERLAY_ACTION', 'Each overlay action must be an object') unless action.is_a?(Hash)
          unknown!(action, %w[target description update remove copy], '/actions')
          selector!(action['target'])
          string_field!(action, 'description')
          if action.key?('remove') && ![true, false].include?(action['remove'])
            invalid('OVERLAY_REMOVE', 'remove must be a boolean')
          end
          selector!(action['copy']) if action.key?('copy')
        end
        overlay
      rescue Janeway::Error
        invalid('OVERLAY_JSONPATH', 'Invalid RFC 9535 JSONPath selector')
      end

      private

      def apply_action(document, action, index)
        matches = select(document, action['target'])
        if matches.empty?
          @diagnostics << diagnostic('PATCH_STALE', 'Overlay target matched no nodes', "/actions/#{index}/target")
          return
        end
        if action['remove'] == true
          remove(matches)
          return
        end
        if action.key?('update') && action.key?('copy')
          # Overlay 1.1 defines both modifiers as having no effect when the
          # other is present. The schema permits both; do not invent precedence.
          @diagnostics << diagnostic('OVERLAY_MODIFIERS_IGNORED', 'update and copy suppress each other in the same action', "/actions/#{index}")
          return
        end
        return unless action.key?('update') || action.key?('copy')
        kinds = matches.map { |match| kind(match[0]) }.uniq
        invalid('OVERLAY_MIXED_TYPES', 'An action must select only objects, only arrays, or only primitives') unless kinds.size == 1
        update = if action.key?('copy')
                   values = select(document, action['copy'])
                   invalid('OVERLAY_COPY', 'copy must select exactly one node') unless values.size == 1
                   copy(values.first[0])
                 else
                   action['update']
                 end
        # Compute all replacements before editing any selected target. This
        # preserves copy snapshots and prevents partially applied actions.
        matches.each { |value, _parent, _key, path| merge(value, update, path) }
        matches.each do |_value, _parent, _key, path|
          # Revisit the normalized location after an ancestor update. Keeping
          # stale parent objects would lose updates to descendants.
          select(document, path).each do |current, parent, key, _normalized|
            replacement = merge(current, update, path)
            if parent.nil?
              document.replace(replacement)
            else
              parent[key] = replacement
            end
          end
        end
      end

      def select(document, selector)
        matches = []
        Janeway.enum_for(selector, document).each do |value, parent, key, path|
          matches << [value, parent, key, path]
          Input.fail_security('OVERLAY_LIMIT', 'Too many selected nodes') if matches.length > Input::MAX_NODES
        end
        matches.uniq { |match| match[3] }
      end

      def remove(matches)
        invalid('OVERLAY_REMOVE_ROOT', 'The document root has no container and cannot be removed') if matches.any? { |match| match[1].nil? }
        # Array removals use descending indexes for each parent, so selections
        # retain their original meaning after earlier elements are removed.
        groups = matches.group_by { |match| match[1].object_id }
        groups.each_value do |group|
          parent = group.first[1]
          keys = group.map { |match| match[2] }.uniq
          if parent.is_a?(Array)
            keys.sort.reverse_each { |key| parent.delete_at(key) }
          else
            keys.each { |key| parent.delete(key) }
          end
        end
      end

      def merge(target, update, path)
        case target
        when Hash
          incompatible(path) unless update.is_a?(Hash)
          result = copy(target)
          update.each do |key, value|
            if result.key?(key)
              incompatible(path) unless kind(result[key]) == kind(value)
              result[key] = merge(result[key], value, path)
            else
              result[key] = copy(value)
            end
          end
          result
        when Array
          copy(target) + (update.is_a?(Array) ? copy(update) : [copy(update)])
        else
          incompatible(path) unless kind(update) == :primitive
          copy(update)
        end
      end

      def incompatible(path)
        invalid('OVERLAY_TYPE', "Incompatible overlay value types at #{path}")
      end

      def kind(value)
        return :object if value.is_a?(Hash)
        return :array if value.is_a?(Array)
        :primitive
      end

      def copy(value)
        JSON.parse(JSON.generate(value), max_nesting: Input::MAX_DEPTH)
      rescue JSON::NestingError
        Input.fail_security('OVERLAY_DEPTH', 'Overlay exceeds the document nesting limit')
      end

      def selector!(selector)
        invalid('OVERLAY_JSONPATH', 'A selector must be a nonempty string') unless selector.is_a?(String) && !selector.empty?
        Input.fail_security('OVERLAY_LIMIT', 'JSONPath selector is too long') if selector.bytesize > MAX_SELECTOR
        Timeout.timeout(2) { Janeway.parse(selector) }
      rescue Timeout::Error
        Input.fail_security('OVERLAY_COMPLEXITY', 'JSONPath parsing exceeded the time limit')
      end

      def string_field!(object, field)
        invalid('OVERLAY_INVALID', "#{field} must be a string") if object.key?(field) && !object[field].is_a?(String)
      end

      def unknown!(object, fields, path)
        extra = object.keys.reject { |key| fields.include?(key) || key.start_with?('x-') }
        invalid('OVERLAY_FIELD', "Unknown Overlay field at #{path}") unless extra.empty?
      end

      def resolve_uri(reference, overlay_uri)
        return reference if reference.match?(/\A[a-z][a-z0-9+.-]*:/i) || reference.start_with?('/')
        return File.expand_path(reference) unless overlay_uri
        if overlay_uri.match?(/\Ahttps:/i)
          URI.join(overlay_uri, reference).to_s
        else
          File.expand_path(reference, File.dirname(File.expand_path(overlay_uri)))
        end
      rescue URI::InvalidURIError
        invalid('OVERLAY_EXTENDS', 'Invalid extends URI')
      end

      def canonical_uri(reference)
        return URI.parse(reference).normalize.to_s if reference.match?(/\A[a-z][a-z0-9+.-]*:/i)
        File.expand_path(reference)
      rescue URI::InvalidURIError
        invalid('OVERLAY_EXTENDS', 'Invalid source URI')
      end

      def diagnostic(code, message, path)
        { 'code' => code, 'severity' => 'warning', 'message' => message, 'path' => path }
      end

      def invalid(code, message)
        raise Error.new(message, code: code, exit_code: 3)
      end
    end
  end
end
