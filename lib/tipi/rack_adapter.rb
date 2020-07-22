# frozen_string_literal: true

require 'rack'
require 'rack/builder'

module Tipi
  module RackAdapter
    # Implements a rack input stream:
    # https://www.rubydoc.info/github/rack/rack/master/file/SPEC#label-The+Input+Stream
    class InputStream
      def initialize(request)
        @request = request
      end
      
      def gets; end
      
      def read(length = nil, outbuf = nil); end
      
      def each(&block)
        @request.each_chunk(&block)
      end
      
      def rewind; end
    end
    
    class << self
      def run(app)
        ->(req) { respond(req, app.(env(req))) }
      end
      
      def load(path)
        run(Rack::Builder.parse_file(path).first)
      end

      RACK_ENV = {
        'SCRIPT_NAME'                    => '',
        'rack.version'                   => Rack::VERSION,
        'SERVER_PORT'                    => '80', # ?
        'rack.url_scheme'                => 'http', # ?
        'rack.errors'                    => STDERR, # ?
        'rack.multithread'               => false,
        'rack.run_once'                  => false,
        'rack.hijack?'                   => false,
        'rack.hijack'                    => nil,
        'rack.hijack_io'                 => nil,
        'rack.session'                   => nil,
        'rack.logger'                    => nil,
        'rack.multipart.buffer_size'     => nil,
        'rack.multipar.tempfile_factory' => nil
      }.freeze
      
      def env(request)
        Hash.new do |h, k|
          h[k] = env_value_from_request(request, k)
        end
      end

      HTTP_HEADER_RE = /^HTTP_(.+)$/.freeze

      def env_value_from_request(request, key)
        case key
        when 'REQUEST_METHOD' then request.method
        when 'PATH_INFO'      then request.path
        when 'QUERY_STRING'   then request.query_string || ''
        when 'SERVER_NAME'    then request.headers['Host']
        when 'rack.input'     then InputStream.new(request)
        when HTTP_HEADER_RE   then request.headers[$1.downcase]
        else                       RACK_ENV[key]
        end
      end
      
      def respond(request, (status_code, headers, body))
        headers[':status'] = status_code.to_s
        buffer = +''
        body.each { |b| buffer << b }
        request.respond(buffer, headers)
      end
    end
  end
end
