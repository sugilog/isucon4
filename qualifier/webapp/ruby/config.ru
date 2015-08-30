require_relative './app.rb'

SINATRA_ROOT = File.expand_path("../", __FILE__)

## rack-lineprof
require 'rack-lineprof'
# use Rack::Lineprof, profile: "app.rb"
logfile = File.join(SINATRA_ROOT, "log", "lineprof.log")
use Rack::LineprofAsJSON, profile: "app.rb", logger: Logger.new(logfile)

## ruby-prof
# require 'ruby-prof'
# require 'rack/contrib/profiler'
# use Rack::Profiler

## printout
# require 'rack/contrib/printout'
# use Rack::Printout

run Isucon4::App
