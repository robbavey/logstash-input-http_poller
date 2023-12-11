# encoding: utf-8

module Manticore
  class Response
    def call
      transaction = Java::co.elastic.apm.api.ElasticApm.startTransactionWithRemoteParent do | header_name |
        @request.headers['traceparent']
      end
      transaction.setName("#{@request.headers['traceparent_name']}:manticore")
      transaction.setType("input")
      transaction_scope = transaction.activate

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
        transaction_scope.close
        transaction.end
        nil
      else
        execute_complete
        transaction_scope.close
        transaction.end
        self
      end

    end
  end
end
