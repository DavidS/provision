#!/usr/bin/env ruby
require 'json'
require 'net/http'
require 'yaml'
require 'puppet_litmus'
require 'etc'
require_relative '../lib/task_helper'
include PuppetLitmus::InventoryManipulation

def default_uri
  'https://facade-release-6f3kfepqcq-ew.a.run.app/v1/provision'
end

def platform_to_cloud_request_parameters(platform, cloud, region, zone)
  params = case platform
           when String
             { cloud: cloud, region: region, zone: zone, images: [platform] }
           when Array
             { cloud: cloud, region: region, zone: zone, images: platform }
           else
             platform[:cloud] = cloud unless cloud.nil?
             platform[:images] = [platform[:images]] if platform[:images].is_a?(String)
             platform
           end
  params
end

# curl -X POST https://facade-validation-6f3kfepqcq-ew.a.run.app/v1/provision --data @test_machines.json
def invoke_cloud_request(params, uri, job_url, verb)
  case verb.downcase
  when 'post'
    request = Net::HTTP::Post.new(uri, { 'Accept' => 'application/json', 'Content-Type' => 'application/json' })
    machines = []
    machines << params
    request.body = { url: job_url, VMs: machines }.to_json
  when 'delete'
    request = Net::HTTP::Delete.new(uri)
    request.body = { uuid: params }.to_json
  else
    raise StandardError "Unknown verb: '#{verb}'"
  end

  File.open('request.json', 'wb') do |f|
    f.write(request.body)
  end

  req_options = {
    use_ssl: uri.scheme == 'https',
    read_timeout: 60 * 5, # timeout reads after 5 minutes - that's longer than the backend service would keep the request open
  }

  response = Net::HTTP.start(uri.hostname, uri.port, req_options) do |http|
    http.request(request)
  end
  # rubocop:disable Style/GuardClause
  if response.code == '200'
    return response.body
  else
    begin
      body = JSON.parse(response.body)
      body_json = true
    rescue JSON::ParserError
      body = response.body
      body_json = false
    end
    puts({ _error: { kind: 'provision_service/service_error', msg: 'provision service returned an error', code: response.code, body: body, body_json: body_json } }.to_json)
    exit 1
  end
  # rubocop:enable Style/GuardClause
end

def provision(platform, inventory_location, vars)
  # Call the provision service with the information necessary and write the inventory file locally

  job_url = ENV['GITHUB_URL'] || "https://api.github.com/repos/#{ENV['GITHUB_REPOSITORY']}/actions/runs/#{ENV['GITHUB_RUN_ID']}"
  uri = URI.parse(ENV['SERVICE_URL'] || default_uri)
  cloud = ENV['CLOUD']
  region = ENV['REGION']
  zone = ENV['ZONE']
  if job_url.nil?
    data = JSON.parse(vars.tr(';', ','))
    job_url = data['job_url']
  end
  inventory_full_path = File.join(inventory_location, 'inventory.yaml')

  params = platform_to_cloud_request_parameters(platform, cloud, region, zone)
  response = invoke_cloud_request(params, uri, job_url, 'post')
  if File.file?(inventory_full_path)
    inventory_hash = inventory_hash_from_inventory_file(inventory_full_path)
    response_hash = YAML.safe_load(response)

    inventory_hash['groups'].each do |g|
      response_hash['groups'].each do |bg|
        if g['name'] == bg['name']
          g['targets'] = g['targets'] + bg['targets']
        end
      end
    end

    File.open(inventory_full_path, 'w') { |f| f.write inventory_hash.to_yaml }
  else
    File.open('inventory.yaml', 'wb') do |f|
      f.write(response)
    end
  end
  { status: 'ok', node_name: platform }
end

def tear_down(platform, inventory_location, _vars)
  # remove all provisioned resources
  uri = URI.parse(ENV['SERVICE_URL'] || default_uri)

  inventory_full_path = File.join(inventory_location, 'inventory.yaml')
  # rubocop:disable Style/GuardClause
  if File.file?(inventory_full_path)
    inventory_hash = inventory_hash_from_inventory_file(inventory_full_path)
    facts = facts_from_node(inventory_hash, platform)
    job_id = facts['uuid']
    response = invoke_cloud_request(job_id, uri, '', 'delete')
    return response.to_json
  end
  # rubocop:enable Style/GuardClause
end

params = JSON.parse(STDIN.read)
platform = params['platform']
action = params['action']
vars = params['vars']
node_name = params['node_name']
inventory_location = sanitise_inventory_location(params['inventory'])

begin
  case action
  when 'provision'
    raise 'specify a platform when provisioning' if platform.nil?
    result = provision(platform, inventory_location, vars)
  when 'tear_down'
    raise 'specify a node_name when tearing down' if node_name.nil?
    result = tear_down(node_name, inventory_location, vars)
  else
    result = { _error: { kind: 'provision_service/argument_error', msg: "Unknown action '#{action}'" } }
  end
  puts result.to_json
  exit 0
rescue => e
  puts({ _error: { kind: 'provision_service/failure', msg: e.message } }.to_json)
  exit 1
end
