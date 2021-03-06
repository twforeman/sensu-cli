require 'rubygems' if RUBY_VERSION < '1.9.0'
require 'net/https'
require 'json'
require 'sensu-cli/settings'
require 'sensu-cli/cli'
require 'sensu-cli/editor'
require 'rainbow'

module SensuCli
  class Core

    def setup
      clis = Cli.new
      cli = clis.global
      settings
      api_path(cli)
      make_call
    end

    def settings
      directory = "#{Dir.home}/.sensu"
      file = "#{directory}/settings.rb"
      alt = "/etc/sensu/sensu-cli/settings.rb"
      settings = Settings.new
      if settings.is_file?(file)
        SensuCli::Config.from_file(file)
      elsif settings.is_file?(alt)
        SensuCli::Config.from_file(alt)
      else
        settings.create(directory,file)
      end
    end

    def api_path(cli)
      @command = cli[:command]
      case @command
      when 'clients'
        path = "/clients" << (cli[:fields][:name] ? "/#{cli[:fields][:name]}" : "") << (cli[:fields][:history] ? "/history" : "")
      when 'info'
        path = "/info"
      when 'health'
        path = "/health?consumers=#{cli[:fields][:consumers]}&messages=#{cli[:fields][:messages]}"
      when 'stashes'
        if cli[:fields][:create]
          e = Editor.new
          payload = e.create_stash(cli[:fields][:create_path]).to_json
        end
        path = "/stashes" << (cli[:fields][:path] ? "/#{cli[:fields][:path]}" : "")
      when 'checks'
        if cli[:fields][:name]
          path = "/check/#{cli[:fields][:name]}"
        elsif cli[:fields][:subscribers]
          path = "/check/request"
          payload = {:check => cli[:fields][:check],:subscribers => cli[:fields][:subscribers]}.to_json
        else
          path = "/checks"
        end
      when 'events'
        path = "/events" << (cli[:fields][:client] ? "/#{cli[:fields][:client]}" : "") << (cli[:fields][:check] ? "/#{cli[:fields][:check]}" : "")
      when 'resolve'
        payload = {:client => cli[:fields][:client], :check => cli[:fields][:check]}.to_json
        path = "/event/resolve"
      when 'silence'
        payload = {:timestamp => Time.now.to_i}
        payload.merge!({:reason => cli[:fields][:reason]}) if cli[:fields][:reason]
        if cli[:fields][:expires]
          expires = Time.now.to_i + (cli[:fields][:expires] * 60)
          payload.merge!({:expires => expires})
        end
        payload = payload.to_json
        path = "/stashes/silence" << (cli[:fields][:client] ? "/#{cli[:fields][:client]}" : "") << (cli[:fields][:check] ? "/#{cli[:fields][:check]}" : "")
      when 'aggregates'
        path = "/aggregates" << (cli[:fields][:check] ? "/#{cli[:fields][:check]}" : "") << (cli[:fields][:id] ? "/#{cli[:fields][:id]}" : "")
      end
      path << pagination(cli) if ["stashes","clients","aggregates"].include?(@command)
      @api = {:path => path, :method => cli[:method], :command => cli[:command], :payload => (payload || false)}
    end

    def pagination(cli)
      if cli[:fields].has_key?(:limit) && cli[:fields].has_key?(:offset)
        page = "?limit=#{cli[:fields][:limit]}&offset=#{cli[:fields][:offset]}"
      elsif cli[:fields].has_key?(:limit)
        page = "?limit=#{cli[:fields][:limit]}"
      else
        page = ""
      end
    end

    def http_request
      http = Net::HTTP.new(Config.host, Config.port)
      http.read_timeout = 15
      http.open_timeout = 5
      if Config.ssl
        http.use_ssl = true
        http.verify_mode = OpenSSL::SSL::VERIFY_NONE
      end
      case @api[:method]
      when 'Get'
        req =  Net::HTTP::Get.new(@api[:path])
      when 'Delete'
        req =  Net::HTTP::Delete.new(@api[:path])
      when 'Post'
        req =  Net::HTTP::Post.new(@api[:path],initheader = {'Content-Type' => 'application/json'})
        req.body = @api[:payload]
      end
      req.basic_auth(Config.user, Config.password) if Config.user && Config.password
      begin
        http.request(req)
      rescue Timeout::Error
        puts "HTTP request has timed out.".color(:red)
        exit
      rescue StandardError => e
        puts "An HTTP error occurred.  Check your settings. #{e}".color(:red)
        exit
      end
    end

    def make_call
      res = http_request
      msg = response_codes(res.code,res.body)
      res.code != '200' ? exit : pretty(msg)
      count(msg)
    end

    def response_codes(code,body)
      case code
      when '200'
        JSON.parse(body)
      when '201'
        puts "The stash has been created." if @command == "stashes"
      when '202'
        puts "The item was submitted for processing."
      when '204'
        puts "Sensu is healthy" if @command == 'health'
        puts "The item was successfully deleted." if @command == 'aggregates' || @command == 'stashes'
      when '400'
        puts "The payload is malformed.".color(:red)
      when '401'
        puts "The request requires user authentication.".color(:red)
      when '404'
        puts "The item did not exist.".color(:cyan)
      else
        (@command == 'health') ? (puts "Sensu is not healthy.".color(:red)) : (puts "There was an error while trying to complete your request. Response code: #{code}".color(:red))
      end
    end

    def pretty(res)
      if !res.empty?
        if res.is_a?(Hash)
          res.each do |key,value|
            puts "#{key}:  ".color(:cyan) + "#{value}".color(:green)
          end
        elsif res.is_a?(Array)
          res.each do |item|
            puts "-------".color(:yellow)
            if item.is_a?(Hash)
              item.each do |key,value|
                puts "#{key}:  ".color(:cyan) + "#{value}".color(:green)
              end
            else
              puts item.to_s.color(:cyan)
            end
          end
        end
      else
        puts "no values for this request".color(:cyan)
      end
    end

    def count(res)
      res.is_a?(Hash) ? count = res.length : count = res.count
      puts "#{count} total items".color(:yellow) if count
    end

  end
end
