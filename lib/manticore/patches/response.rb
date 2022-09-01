# encoding: utf-8
require 'elastic_apm'

module Manticore
  class Response
    def call
      env = { 'HTTP_ELASTIC_APM_TRACEPARENT' => @request.headers['traceparent'] }
      context = ElasticAPM::TraceContext.parse(env: env)
      ElasticAPM.start_transaction('manticore', trace_context: context)

      return background! if @background
      raise "Already called" if @called
      @called = true
      begin
        @client.client.execute @request, self, @context
      rescue Java::JavaNet::SocketTimeoutException => e
        ex = Manticore::SocketTimeout
      rescue Java::OrgApacheHttpConn::ConnectTimeoutException => e
        ex = Manticore::ConnectTimeout
      rescue Java::JavaNet::SocketException => e
        ex = Manticore::SocketException
      rescue Java::OrgApacheHttpClient::ClientProtocolException, Java::JavaxNetSsl::SSLHandshakeException,
        Java::OrgApacheHttpConn::HttpHostConnectException, Java::OrgApacheHttp::NoHttpResponseException,
        Java::OrgApacheHttp::ConnectionClosedException => e
        ex = Manticore::ClientProtocolException
      rescue Java::JavaNet::UnknownHostException => e
        ex = Manticore::ResolutionFailure
      rescue Java::JavaLang::IllegalArgumentException => e
        ex = Manticore::InvalidArgumentException
      rescue Java::JavaLang::IllegalStateException => e
        if (e.message || '').index('Connection pool shut down')
          ex = Manticore::ClientStoppedException
        else
          @exception = e
        end
      rescue Java::JavaLang::Exception => e # Handle anything we may have missed from java
        ex = Manticore::UnknownException
      rescue StandardError => e
        @exception = e
      end

      # TODO: If calling async, execute_complete may fail and then silently swallow exceptions. How do we fix that?
      if ex || @exception
        @exception ||= ex.new(e)
        @handlers[:failure].call @exception
        execute_complete
        ElasticAPM.report(@exception)
        ElasticAPM.end_transaction('exception')
        nil
      else
        execute_complete
        ElasticAPM.end_transaction('success')
        self
      end

    end
  end
end
