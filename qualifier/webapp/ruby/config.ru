require_relative './app.rb'

## rack-lineprof
# require 'rack-lineprof'
# use Rack::Lineprof, profile: "app.rb"

## ruby-prof
# require 'ruby-prof'
# require 'rack/contrib/profiler'
# use Rack::Profiler

## printout
# require 'rack/contrib/printout'
# use Rack::Printout

run Isucon4::App
