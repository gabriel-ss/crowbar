{% if compare_versions(Crystal::VERSION, "1.15.0") < 0 %}
  class HTTP::Cookie
    def to_set_cookie_header(io : IO) : Nil
      path = @path
      expires = @expires
      max_age = @max_age
      domain = @domain
      samesite = @samesite

      to_cookie_header(io)
      io << "; domain=#{domain}" if domain
      io << "; path=#{path}" if path
      io << "; expires=#{HTTP.format_time(expires)}" if expires
      io << "; max-age=#{max_age.to_i}" if max_age
      io << "; Secure" if @secure
      io << "; HttpOnly" if @http_only
      io << "; SameSite=#{samesite}" if samesite
      io << "; #{@extension}" if @extension
    end
  end
{% end %}
