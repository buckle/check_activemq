#!/usr/bin/env ruby

# check_activemq.rb -u "https://mq-dev:8162/admin" -q "buckle.test.email.MailPost,1:2,3:,1:,1:"
# queuespec:   "<queuename>,<queuesizewarnrange>,<queuesizecritrange>,<queueconsumerwarnrange>,<queueconsumercritrange>"
# check_activemq.rb -u "https://mq-dev:8162/admin" -t "buckle.test.inventory,:1,:1"
# topicspec:   "<topicname>,<topicconsumerwarnrange>,<topicconsumercritrange>"
# check_activemq.rb -u "https://mq-dev:8162/admin" -n "buckle.nagios.test,nagios,password"
# queuespec:   "<queuename>,<username>,<password>"

# TODO:
# Name: check_activemq.rb
# Author: https://github.com/phrawzty/rabbitmq-collectd-plugin/commits/master
# Description: Nagios plugin that makes an HTTP connection and parses the JSON result.
#
# Copyright 2012 Daniel Maher
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Requires.
require 'rubygems'
require 'rexml/document'
require 'net/http'
require 'uri'
require 'optparse'
require 'timeout'
require 'stomp'
require 'date'

# Herp derp.
options = {}
STATETOINT = {
  'OK'       => 0,
  'WARNING'  => 1,
  'CRITICAL' => 2,
  'UNKNOWN'  => 3,
}

# Display verbose output (if being run by a human for example).
def say (v, msg)
  if v == true
    puts '+ %s' % [msg]
  end
end

# Manage the exit code explicitly.
def do_exit (v, code)
  if v == true
    exit 3
  else
    exit code
  end
end

# Parse the Nagios range syntax.
# http://nagiosplug.sourceforge.net/developer-guidelines.html#THRESHOLDFORMAT
def check_threshold(state, threshold, value, v, label)
  retval = nil
  msg    = ''
  lhs    = nil
  rhs    = nil
  colon  = nil

  # Check if we're to alert if inside the range
  negate = false
  if threshold.gsub!(/^@/,'') != nil then
    negate = true
  end

  if threshold =~ /^([\d~]+)?(:)?(\d+)?$/ then
    lhs   = $1
    colon = $2
    rhs   = $3
  else
    msg = "UNKNOWN: Unable to parse #{state} threshold of #{threshold}."
    return [retval, msg]
  end

  if rhs == nil then
    if colon == nil then
      rhs = lhs
      lhs = 0
    else
      rhs = 1.0/0
    end
  end

  if lhs == '~' then
    lhs = 1.0/0 * -1
  end

  say(v, 'label = %s state = %s threshold = %s lhs = %s rhs = %s negate = %s value = %s' % [label, state, threshold, lhs,rhs,negate, value])

  if lhs.to_f <= value.to_f and value.to_f <= rhs.to_f then
    retval = negate ? STATETOINT[state] : STATETOINT['OK']
    msg    = '%s is inside range [%s] (%s)' % [label, threshold, value]
  else
    retval = negate ? STATETOINT['OK'] : STATETOINT[state]
    msg    = '%s is outside range [%s] (%s)' % [label, threshold, value]
  end

  return [retval, msg]
end

# Deal with a URI target.
def uri_target(uri,options)
  uri = URI.parse(uri)
  http = Net::HTTP.new(uri.host, uri.port)

  # Timeout handler, just in case.
  response = nil
  begin
    Timeout::timeout(options[:timeout]) do
      request = Net::HTTP::Get.new(uri.request_uri)
      if (options[:user] and options[:pass]) then
        request.basic_auth(options[:user], options[:pass])
      end
      response = http.request(request)
    end
  # I'm not sure whether a timeout should be CRIT or UNKNOWN. -- phrawzty
  rescue Timeout::Error
    say(options[:v], 'The HTTP connection timed out after %i seconds.' % [options[:timeout]])
    puts 'CRIT: Connection timed out.'
    do_exit(options[:v], 2)
  rescue Exception => e
    say(options[:v], 'Exception occured: %s.' % [e])
    puts 'UNKNOWN: HTTP connection failed.'
    do_exit(options[:v], 3)
  end

  # We must get a proper response.
  if not response.code.to_i == 200 then
    puts 'WARN: Received HTTP code %s instead of 200.' % [response.code]
    do_exit(options[:v], 1)
  end

#  say(options[:v], "RESPONSE:\n---\n%s\n---" % [response.body])

  return response.body
end

# Parse cli args.
def parse_args(options)
  options[:queues]      = []
  options[:topics]      = []
  optparse = OptionParser.new do |opts|
    #TODO
    opts.banner = 'Usage: %s -u <URI> -e <element> -w <warn> -c <crit>' % [$0]

    opts.on('-h', '--help', 'Help info.') do
      puts opts
      do_exit(true, 3)
    end

    options[:v] = false
    opts.on('-v', '--verbose', 'Additional human output.') do
      options[:v] = true
    end

    options[:uri] = nil
    opts.on('-u', '--uri URI', 'Target URI.') do |x|
      options[:uri] = x
    end

    options[:user] = nil
    opts.on('--user USERNAME', 'HTTP basic authentication username.') do |x|
      options[:user] = x
    end

    options[:pass] = nil
    opts.on('--pass PASSWORD', 'HTTP basic authentication password.') do |x|
      options[:pass] = x
    end

    opts.on('-q', '--queue QUEUESPEC', 'Queue Specification') do |x|
      fields = x.split(/,/)
      #TODO: catch invalid specs
      queue = {
        :name              => fields[0].to_s,
        :sizewarnrange     => fields[1].to_s,
        :sizecritrange     => fields[2].to_s,
        :consumerwarnrange => fields[3].to_s,
        :consumercritrange => fields[4].to_s,
      }
      options[:queues] << queue
    end

    opts.on('-t', '--topic TOPICSPEC', 'Topic Specification') do |x|
      fields = x.split(/,/)
      #TODO: catch invalid specs
      topic = {
        :name              => fields[0].to_s,
        :consumerwarnrange => fields[1].to_s,
        :consumercritrange => fields[2].to_s,
      }
      options[:topics] << topic
    end

    options[:nagiosqueue] = nil
    opts.on('-n', '--nagiosqueue NAGIOSQUEUESPEC', 'Nagios Queue Specification') do |x|
      #TODO: catch invalid specs
      fields = x.split(/,/)
      options[:nagiosqueue]     = fields[0].to_s
      options[:nagiosqueueuser] = fields[1].to_s
      options[:nagiosqueuepass] = fields[2].to_s
    end

    options[:port] = 61613
    opts.on('-p', '--port', 'Broker port') do |x|
      options[:port] = x
    end


    options[:ssl] = false
    options[:timeout] = 5
  end

  optparse.parse!
  return options
end

# Sanity check.
def sanity_check(options)
  error_msg = []

  if not (options[:uri]) then
    error_msg.push('Must specify target URI with -u.')
  end

  if not (options[:uri] =~ /\/admin/) then
    error_msg.push('URI must end with string "/admin".')
  end

  if (options[:user] and not options[:pass]) or (options[:pass] and not options[:user]) then
    error_msg.push('Must specify both a username and a password for basic auth.')
  end

  if not (options[:nagiosqueue]) then
    error_msg.push('Must specify a queue for Nagios to use for testing.')
  end

  if error_msg.length > 0 then
    # First line is Nagios-friendly.
    puts 'UNKNOWN: Insufficient or incompatible arguments.'
    # Subsequent lines are for humans.
    error_msg.each do |msg|
      puts msg
    end
    puts '"%s --help" for more information.' % [$0]
    do_exit(true, 3)
  end

  # Remove trailing slash if present in URI
  options[:uri].gsub!(/\/$/,'')

end

#Fetch the xml for the queue, compare it to thresholds
def check_queue(queue, options)
  uri = options[:uri] + '/xml/queues.jsp'
  # Set up the xml object.
  xml = nil
  body = uri_target(uri, options)

  # Make a XML object from the response.
  xml = REXML::Document.new(body)
  begin
  root = xml.root

  # Get our values:
  queue[:consumerCount] = root.elements["queue[@name='#{queue[:name]}']"].elements['stats'].attributes['consumerCount']
  queue[:size] = root.elements["queue[@name='#{queue[:name]}']"].elements['stats'].attributes['size']
  rescue
    puts("Unable to parse XML at #{uri} for queue #{queue[:name]}")
  end
end

#Fetch the xml for the topic, compare it to thresholds
def check_topic(topic, options)
  uri = options[:uri] + '/xml/topics.jsp'
  # Set up the xml object.
  xml = nil
  body = uri_target(uri, options)

  # Make a XML object from the response.
  xml = REXML::Document.new(body)
  begin
  root = xml.root

  # Get our values:
  topic[:consumerCount] = root.elements["topic[@name='#{topic[:name]}']"].elements['stats'].attributes['consumerCount']
  rescue
    puts("Unable to parse XML at #{uri} for topic #{topic[:name]}")
  end
end

def queue_send_receive(options)

  config = {
    :hosts => [
      # First connect is to remotehost1
      {:login => options[:nagiosqueueuser], :passcode => options[:nagiosqueuepass], :host => URI.parse(options[:uri]).host, :port => options[:port], :ssl => options[:ssl]},
    ],
  }
  queue = "/queue/#{options[:nagiosqueue]}"

  nagios_msg = ''
  state = STATETOINT['OK']
  now = DateTime.now.to_s
  begin
    Timeout::timeout(2) do
      stomp = Stomp::Client.new(config)
      stomp.publish(queue, "Nagios Test: #{now}")
      stomp.publish(queue, "Nagios Test2: #{now}")
      stomp.close
    end
  rescue Timeout::Error
    nagios_msg = "Failed to send message within the 2 second timeout"
    state = STATETOINT['CRITICAL']
  end

  client = nil
  begin
    Timeout::timeout(2) do
    client = Stomp::Connection.new(config)
    client.subscribe(queue)
    msg = client.receive
    end
  rescue Timeout::Error
    nagios_msg = "Failed to receive message within the 2 second timeout"
    state = STATETOINT['CRITICAL']
  end
  client.disconnect
  return [state, nagios_msg]
end

# Grab args
options = parse_args(options)
sanity_check(options)

overall_state = STATETOINT['OK']
overall_msg   = ''
# Check the queues first:
options[:queues].each do |queue|
  check_queue(queue, options)

  # Compare to thresholds
  if queue[:sizewarnrange] then
    state,msg = check_threshold('WARNING', queue[:sizewarnrange], queue[:size], options[:v], "#{queue[:name]} pending messages")
    if state > overall_state then
      overall_state = state
      overall_msg  += msg
    end
  end

  if queue[:sizecritrange] then
    state,msg = check_threshold('CRITICAL', queue[:sizecritrange], queue[:size], options[:v], "#{queue[:name]} pending messages")
    if state > overall_state then
      overall_state = state
      overall_msg  += msg
    end
  end

  if queue[:consumerwarnrange] then
    state,msg = check_threshold('WARNING', queue[:consumerwarnrange], queue[:consumerCount], options[:v], "#{queue[:name]} consumers")
    if state > overall_state then
      overall_state = state
      overall_msg  += msg
    end
  end

  if queue[:consumercritrange] then
    state,msg = check_threshold('CRITICAL', queue[:consumercritrange], queue[:consumerCount], options[:v], "#{queue[:name]} consumers")
    if state > overall_state then
      overall_state = state
      overall_msg  += msg
    end
  end
end

# Then check the topics:
options[:topics].each do |topic|
  check_topic(topic, options)
  # Compare to thresholds
  if topic[:consumerwarnrange] then
    state,msg = check_threshold('WARNING', topic[:consumerwarnrange], topic[:consumerCount], options[:v], "#{topic[:name]} consumers")
    if state > overall_state then
      overall_state = state
      overall_msg   += msg
    end
  end
  if topic[:consumercritrange] then
    state,msg = check_threshold('CRITICAL', topic[:consumercritrange], topic[:consumerCount], options[:v], "#{topic[:name]} consumers")
    if state > overall_state then
      overall_state = state
      overall_msg   += msg
    end
  end
end

state,msg = queue_send_receive(options)
if state > overall_state then
  msg.overall_state = state
  overall_msg   += msg
end

if overall_state = STATETOINT['OK'] then
  overall_msg = 'OK: All topics and queues within thresholds'
elsif overall_state = STATETOINT['WARNING'] then
  overall_msg = "WARNING: #{overall_msg}"
elsif overall_state = STATETOINT['CRITICAL'] then
  overall_msg = "CRITICAL: #{overall_msg}"
end

puts overall_msg

do_exit(options[:v], overall_state)
