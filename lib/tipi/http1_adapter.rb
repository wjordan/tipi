# frozen_string_literal: true

require 'http/parser'
require_relative './request'
require_relative './http2_adapter'

module Tipi
  # HTTP1 protocol implementation
  class HTTP1Adapter
    # Initializes a protocol adapter instance
    def initialize(conn, opts)
      @conn = conn
      @opts = opts
      @parser = ::HTTP::Parser.new(self)
    end
    
    def each(&block)
      @conn.read_loop do |data|
        return if handle_incoming_data(data, &block)
      end
    rescue SystemCallError, IOError
      # ignore
    ensure
      finalize_client_loop
    end
    
    # return [Boolean] true if client loop should stop
    def handle_incoming_data(data, &block)
      @parser << data
      while (request = @requests_head)
        return true if upgrade_connection(request.headers, &block)
        
        @requests_head = request.__next__
        block.call(request)
        return true unless request.keep_alive?
      end
      nil
    end
    
    def finalize_client_loop
      # release references to various objects
      @requests_head = @requests_tail = nil
      @parser = nil
      @conn.close
    end
    
    # Reads a body chunk for the current request. Transfers control to the parse
    # loop, and resumes once the parse_loop has fired the on_body callback
    def get_body_chunk
      @waiting_for_body_chunk = true
      @next_chunk = nil
      while !@requests_tail.complete? && (data = @conn.readpartial(8192))
        @parser << data
        return @next_chunk if @next_chunk
        
        snooze
      end
      nil
    ensure
      @waiting_for_body_chunk = nil
    end
    
    # Waits for the current request to complete. Transfers control to the parse
    # loop, and resumes once the parse_loop has fired the on_message_complete
    # callback
    def consume_request
      request = @requests_head
      loop do
        data = @conn.readpartial(8192)
        @parser << data
        return if request.complete?
        
        snooze
      rescue EOFError
        break
      end
    end
    
    def protocol
      version = @parser.http_version
      "HTTP #{version.join('.')}"
    end
    
    def on_headers_complete(headers)
      headers[':path'] = @parser.request_url
      headers[':method'] = @parser.http_method
      queue_request(Request.new(headers, self))
    end
    
    def queue_request(request)
      if @requests_head
        @requests_tail.__next__ = request
        @requests_tail = request
      else
        @requests_head = @requests_tail = request
      end
    end
    
    def on_body(chunk)
      if @waiting_for_body_chunk
        @next_chunk = chunk
        @waiting_for_body_chunk = nil
      else
        @requests_tail.buffer_body_chunk(chunk)
      end
    end
    
    def on_message_complete
      @waiting_for_body_chunk = nil
      @requests_tail.complete!(@parser.keep_alive?)
    end
    
    # Upgrades the connection to a different protocol, if the 'Upgrade' header is
    # given. By default the only supported upgrade protocol is HTTP2. Additional
    # protocols, notably WebSocket, can be specified by passing a hash to the
    # :upgrade option when starting a server:
    #
    #     opts = {
    #       upgrade: {
    #         websocket: Tipi::Websocket.handler(&method(:ws_handler))
    #       }
    #     }
    #     Tipi.serve('0.0.0.0', 1234, opts) { |req| ... }
    #
    # @param headers [Hash] request headers
    # @return [boolean] truthy if the connection has been upgraded
    def upgrade_connection(headers, &block)
      upgrade_protocol = headers['Upgrade']
      return nil unless upgrade_protocol
      
      upgrade_protocol = upgrade_protocol.downcase.to_sym
      upgrade_handler = @opts[:upgrade] && @opts[:upgrade][upgrade_protocol]
      return upgrade_with_handler(upgrade_handler, headers) if upgrade_handler
      return upgrade_to_http2(headers, &block) if upgrade_protocol == :h2c
      
      nil
    end
    
    def upgrade_with_handler(handler, headers)
      @parser = @requests_head = @requests_tail = nil
      handler.(@conn, headers)
      true
    end
    
    def upgrade_to_http2(headers, &block)
      @parser = @requests_head = @requests_tail = nil
      HTTP2Adapter.upgrade_each(@conn, @opts, http2_upgraded_headers(headers), &block)
      true
    end
    
    # Returns headers for HTTP2 upgrade
    # @param headers [Hash] request headers
    # @return [Hash] headers for HTTP2 upgrade
    def http2_upgraded_headers(headers)
      headers.merge(
        ':scheme'    => 'http',
        ':authority' => headers['Host']
      )
    end
    
    # response API
    
    # Sends response including headers and body. Waits for the request to complete
    # if not yet completed. The body is sent using chunked transfer encoding.
    # @param body [String] response body
    # @param headers
    def respond(body, headers)
      consume_request if @parsing
      data = format_headers(headers, body)
      if body
        data << if @parser.http_minor == 0
          body
        else
          "#{body.bytesize.to_s(16)}\r\n#{body}\r\n0\r\n\r\n"
        end
      end
      @conn << data
    end
    
    DEFAULT_HEADERS_OPTS = {
      empty_response:  false,
      consume_request: true
    }.freeze
    
    # Sends response headers. If empty_response is truthy, the response status
    # code will default to 204, otherwise to 200.
    # @param headers [Hash] response headers
    # @param empty_response [boolean] whether a response body will be sent
    # @return [void]
    def send_headers(headers, opts = DEFAULT_HEADERS_OPTS)
      @conn << format_headers(headers, !opts[:empty_response])
    end
    
    # Sends a response body chunk. If no headers were sent, default headers are
    # sent using #send_headers. if the done option is true(thy), an empty chunk
    # will be sent to signal response completion to the client.
    # @param chunk [String] response body chunk
    # @param done [boolean] whether the response is completed
    # @return [void]
    def send_chunk(chunk, done: false)
      data = +"#{chunk.bytesize.to_s(16)}\r\n#{chunk}\r\n"
      data << "0\r\n\r\n" if done
      @conn << data
    end
    
    # Finishes the response to the current request. If no headers were sent,
    # default headers are sent using #send_headers.
    # @return [void]
    def finish
      @conn << "0\r\n\r\n"
    end
    
    def close
      @conn.close
    end
    
    private
    
    # Formats response headers. If empty_response is true(thy), the response
    # status code will default to 204, otherwise to 200.
    # @param headers [Hash] response headers
    # @param empty_response [boolean] whether a response body will be sent
    # @return [String] formatted response headers
    def format_headers(headers, body)
      status = headers[':status'] || (body ? 200 : 204)
      data = format_status_line(body, status)
      
      headers.each do |k, v|
        next if k =~ /^:/
        next if k =~ /Content-Length/i # Always use chunked TE
        data << format_header_lines(k, v)
      end
      data << "\r\n"
    end
    
    def format_header_lines(key, value)
      if value.is_a?(Array)
        value.inject(+'') { |data, item| data << "#{key}: #{item}\r\n" }
      else
        "#{key}: #{value}\r\n"
      end
    end
    
    def format_status_line(body, status)
      if !body
        empty_status_line(status)
      else
        with_body_status_line(status, body)
      end
    end
    
    def empty_status_line(status)
      if status == 204
        +"HTTP/1.1 #{status}\r\n"
      else
        +"HTTP/1.1 #{status}\r\nContent-Length: 0\r\n"
      end
    end
    
    def with_body_status_line(status, body)
      if @parser.http_minor == 0
        +"HTTP/1.0 #{status}\r\nContent-Length: #{body.bytesize}\r\n"
      else
        +"HTTP/1.1 #{status}\r\nTransfer-Encoding: chunked\r\n"
      end
    end
  end
end
